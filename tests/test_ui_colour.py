"""The print window's colour print and its Profile picker, headless. Nothing prints."""

from __future__ import annotations

import shutil
from pathlib import Path

import pytest

pytest.importorskip("PySide6")

from openquad.colour_verify import colour_profiles
from openquad.settings import Settings
from openquad.ui.main_window import MainWindow
from tests.test_colour_print import make_library
from tests.test_printing import FakeRunner
from tests.test_session import colour_file
from tests.test_ui_window import REPLY


@pytest.fixture(scope="module")
def library(tmp_path_factory: pytest.TempPathFactory) -> Path:
    return make_library(tmp_path_factory.mktemp("library"))


def make_window(qtbot, tmp_path: Path, folder: Path) -> MainWindow:  # type: ignore[no-untyped-def]
    win = MainWindow(
        settings_path=tmp_path / "settings.json",
        printers=lambda: ["Canon_MG3600_series", "Office_Laser"],
        runner=FakeRunner(REPLY),
        calibrations_folder=folder,
    )
    win.errors = []  # type: ignore[attr-defined]
    win.show_error = win.errors.append  # type: ignore[attr-defined]
    qtbot.addWidget(win)
    return win


def open_colour(window, qtbot, tmp_path: Path) -> None:  # type: ignore[no-untyped-def]
    window.ask_open_path = lambda: str(colour_file(tmp_path, profile=None))
    window.open_photo()
    qtbot.waitUntil(lambda: window._pixmap is not None, timeout=5000)


def labels(window) -> list[str]:  # type: ignore[no-untyped-def]
    box = window.colour_profile_box
    return [box.itemText(i) for i in range(box.count())]


def test_colour_print_and_the_profile_picker(qtbot, tmp_path: Path, library: Path) -> None:  # type: ignore[no-untyped-def]
    window = make_window(qtbot, tmp_path, library)
    assert not window.colour_box.isEnabled()  # no photo yet
    # The Canon is chosen first, so its newest profile is matched.
    assert window.session.colour_profile_path == library / "canon" / "plain-v1.icc"
    open_colour(window, qtbot, tmp_path)
    assert window.colour_box.isEnabled() and not window.colour_profile_box.isEnabled()
    window.colour_box.setChecked(True)
    assert window.session.prints_colour and window.colour_profile_box.isEnabled()
    assert not window.preset_box.isEnabled() and not window.calibration_button.isEnabled()
    found = labels(window)
    assert found[0] == "macOS (driver's profile)" and len(found) == 3  # the Canon's two rounds
    assert all(text.startswith("Canon MG3600 · Letter plain") for text in found[1:])
    assert window.colour_profile_box.currentData() == str(library / "canon" / "plain-v1.icc")
    # macOS's own profile, then an OpenQuad one; the choice is remembered.
    window.colour_profile_box.setCurrentIndex(0)
    assert window.session.colour_profile is None
    assert Settings.load(tmp_path / "settings.json").colour_profile is None
    v0 = window.colour_profile_box.findData(str(library / "canon" / "plain-v0.icc"))
    window.colour_profile_box.setCurrentIndex(v0)
    assert window.session.converts_colour
    saved = Settings.load(tmp_path / "settings.json").colour_profile
    assert saved == str(library / "canon" / "plain-v0.icc")
    shown: list[str] = []
    window.confirm = lambda summary: shown.append(summary) or False
    window.print_photo()
    assert "through the printer profile plain-v0.icc" in shown[0]
    # Another printer with no profile of its own drops the Canon's.
    window.printer_box.setCurrentIndex(window.printer_box.findData("Office_Laser"))
    assert window.session.colour_profile is None and labels(window) == ["macOS (driver's profile)"]
    window.colour_box.setChecked(False)
    assert window.preset_box.isEnabled() and not window.session.prints_colour
    assert window.errors == []  # type: ignore[attr-defined]


def test_the_profile_is_restored_and_outside_ones_are_kept(
    qtbot, tmp_path: Path, library: Path
) -> None:  # type: ignore[no-untyped-def]
    outside = tmp_path / "elsewhere.icc"
    shutil.copy(library / "canon" / "plain-v0.icc", outside)
    settings = Settings(printer="Office_Laser", colour_profile=str(outside))
    settings.save(tmp_path / "settings.json")
    window = make_window(qtbot, tmp_path, library)
    assert window.session.colour_profile_path == outside
    assert labels(window) == ["macOS (driver's profile)", "elsewhere.icc"]
    assert window.colour_profile_box.currentIndex() == 1
    # A saved profile that's gone, or isn't a printer profile, is dropped quietly.
    for bad in (tmp_path / "gone.icc", colour_file(tmp_path)):
        Settings(printer="Office_Laser", colour_profile=str(bad)).save(tmp_path / "settings.json")
        assert make_window(qtbot, tmp_path, library).session.colour_profile is None


def test_bad_choices_are_reported(qtbot, tmp_path: Path, library: Path) -> None:  # type: ignore[no-untyped-def]
    window = make_window(qtbot, tmp_path, tmp_path / "empty")
    assert colour_profiles(tmp_path / "empty") == []
    window.set_colour_profile(str(colour_file(tmp_path)))
    assert "isn't an RGB printer profile" in window.errors[0]  # type: ignore[attr-defined]
    window.colour_box.setEnabled(True)
    window.colour_box.setChecked(True)  # no photo: refused
    assert "only a colour photo" in window.errors[1]  # type: ignore[attr-defined]
    assert not window.session.colour_print and not window.colour_box.isChecked()
