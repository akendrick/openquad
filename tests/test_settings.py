"""Remembered app settings."""

from pathlib import Path

import pytest

from openquad import settings as settings_module
from openquad.settings import Settings, default_path


def test_round_trip(tmp_path: Path) -> None:
    path = tmp_path / "deep" / "settings.json"
    Settings(printer="Canon", paper="A4", calibration="/c.oqcal", last_folder="/photos").save(path)
    loaded = Settings.load(path)
    assert (loaded.printer, loaded.paper, loaded.calibration, loaded.last_folder) == (
        "Canon",
        "A4",
        "/c.oqcal",
        "/photos",
    )


def test_has_no_preset_field() -> None:
    assert "preset" not in Settings.__dataclass_fields__


@pytest.mark.parametrize("content", ["", "not json", "[1, 2]", '{"preset": "black-red"}'])
def test_bad_or_foreign_files_give_defaults(tmp_path: Path, content: str) -> None:
    path = tmp_path / "s.json"
    path.write_text(content)
    assert Settings.load(path) == Settings()


def test_missing_file_gives_defaults(tmp_path: Path) -> None:
    assert Settings.load(tmp_path / "nope.json") == Settings()


def test_default_path(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.setenv("OPENQUAD_SETTINGS", str(tmp_path / "x.json"))
    assert default_path() == tmp_path / "x.json"
    monkeypatch.delenv("OPENQUAD_SETTINGS")
    monkeypatch.setattr(settings_module.sys, "platform", "darwin")
    assert default_path().parts[-3:] == ("Application Support", "OpenQuad", "settings.json")
    monkeypatch.setattr(settings_module.sys, "platform", "linux")
    assert default_path().parts[-3:] == (".config", "openquad", "settings.json")


def test_max_size_is_remembered(tmp_path: Path) -> None:
    from openquad.settings import Settings

    path = tmp_path / "settings.json"
    Settings(max_size=[8.0, 10.0]).save(path)
    assert Settings.load(path).max_size == [8.0, 10.0]
    assert Settings.load(tmp_path / "missing.json").max_size is None
