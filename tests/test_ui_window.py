"""The print window, headless. Dialogs and the printer are replaced; nothing prints."""

from pathlib import Path

import numpy as np
import pytest
import tifffile

pytest.importorskip("PySide6")

from openquad.greybalance import Calibration, save_calibration
from openquad.settings import Settings
from openquad.ui.main_window import MainWindow
from tests.test_printing import FakeRunner

REPLY = "request id is Canon_MG3600_series-42 (1 file(s))\n"


def photo(tmp_path: Path) -> Path:
    path = tmp_path / "portrait.tif"
    pixels = np.tile(np.linspace(0, 65535, 300).astype(np.uint16), (400, 1))
    tifffile.imwrite(path, pixels, resolution=(72, 72), resolutionunit="INCH")
    return path


@pytest.fixture
def window(qtbot, tmp_path: Path):  # type: ignore[no-untyped-def]
    runner = FakeRunner(REPLY)
    win = MainWindow(
        settings_path=tmp_path / "settings.json",
        printers=lambda: ["Canon_MG3600_series", "Office_Laser"],
        runner=runner,
    )
    win.runner_fake = runner  # type: ignore[attr-defined]
    win.errors = []  # type: ignore[attr-defined]
    win.show_error = win.errors.append  # type: ignore[attr-defined]
    qtbot.addWidget(win)
    return win


def open_photo(window, qtbot, tmp_path: Path) -> None:  # type: ignore[no-untyped-def]
    window.ask_open_path = lambda: str(photo(tmp_path))
    window.open_photo()
    qtbot.waitUntil(lambda: window._pixmap is not None, timeout=5000)


def test_starts_neutral_with_printers_listed(window) -> None:  # type: ignore[no-untyped-def]
    assert window.preset_box.currentData() == "neutral"
    assert window.session.preset == "neutral"
    assert window.printer_box.count() == 2
    assert not window.print_button.isEnabled()  # nothing to print yet


def test_open_shows_preview_size_and_info(window, qtbot, tmp_path: Path) -> None:  # type: ignore[no-untyped-def]
    open_photo(window, qtbot, tmp_path)
    assert "portrait.tif" in window.photo_info.text()
    assert "7.50 × 10.00 in" in window.size_label.text()
    assert window.print_button.isEnabled()
    assert window.preview_label.pixmap() is not None


def test_choosing_black_red_changes_the_preview(window, qtbot, tmp_path: Path) -> None:  # type: ignore[no-untyped-def]
    open_photo(window, qtbot, tmp_path)
    neutral = window._pixmap.toImage().pixelColor(150, 200)
    window._pixmap = None
    window.preset_box.setCurrentIndex(window.preset_box.findData("black-red"))
    qtbot.waitUntil(lambda: window._pixmap is not None, timeout=5000)
    red = window._pixmap.toImage().pixelColor(150, 200)
    assert window.session.preset == "black-red"
    assert neutral.red() == neutral.green()
    assert red.red() > red.green() + 20


def test_print_asks_first_and_sends_the_job(window, qtbot, tmp_path: Path) -> None:  # type: ignore[no-untyped-def]
    open_photo(window, qtbot, tmp_path)
    shown: list[str] = []
    window.confirm = lambda summary: shown.append(summary) or True
    window.print_photo()
    qtbot.waitUntil(lambda: "job" in window.statusBar().currentMessage(), timeout=10000)
    assert "Toning: neutral" in shown[0]
    assert "Printer: Canon_MG3600_series" in shown[0]
    assert "Canon_MG3600_series-42" in window.statusBar().currentMessage()
    assert window.runner_fake.commands[0][:3] == ["lp", "-d", "Canon_MG3600_series"]


def test_declining_the_confirmation_prints_nothing(window, qtbot, tmp_path: Path) -> None:  # type: ignore[no-untyped-def]
    open_photo(window, qtbot, tmp_path)
    window.confirm = lambda summary: False
    window.print_photo()
    assert window.runner_fake.commands == []


def test_print_failure_is_reported(window, qtbot, tmp_path: Path) -> None:  # type: ignore[no-untyped-def]
    open_photo(window, qtbot, tmp_path)
    window.runner = FakeRunner(returncode=1, stderr="printer is offline")
    window.confirm = lambda summary: True
    window.print_photo()
    qtbot.waitUntil(lambda: bool(window.errors), timeout=10000)
    assert "printer is offline" in window.errors[0]
    assert window.print_button.isEnabled()


def test_too_big_is_flagged_and_not_printed(window, qtbot, tmp_path: Path) -> None:  # type: ignore[no-untyped-def]
    open_photo(window, qtbot, tmp_path)
    window.fit_box.setChecked(False)
    window.ppi_box.setValue(50)  # 300 x 400 px at 50 ppi = 6 x 8 in: fits
    assert "too big" not in window.size_label.text()
    window.paper_box.setCurrentIndex(window.paper_box.findData("4x6"))
    assert "too big" in window.size_label.text()
    window.print_photo()
    assert "larger than the paper" in window.errors[0]
    assert window.runner_fake.commands == []


def test_calibration_choose_and_clear(window, qtbot, tmp_path: Path) -> None:  # type: ignore[no-untyped-def]
    cal = tmp_path / "canon.oqcal"
    save_calibration(Calibration.identity(), cal)
    window.ask_calibration_path = lambda: str(cal)
    window.choose_calibration()
    assert window.calibration_label.text() == "canon.oqcal"
    window.clear_calibration_button.click()
    assert window.calibration_label.text() == "None"


def test_bad_files_are_reported(window, qtbot, tmp_path: Path) -> None:  # type: ignore[no-untyped-def]
    bad = tmp_path / "bad.tif"
    bad.write_text("not an image")
    window.ask_open_path = lambda: str(bad)
    window.open_photo()
    window.ask_calibration_path = lambda: str(bad)
    window.choose_calibration()
    assert len(window.errors) == 2


def test_save_print_file(window, qtbot, tmp_path: Path) -> None:  # type: ignore[no-untyped-def]
    open_photo(window, qtbot, tmp_path)
    out = tmp_path / "out.tif"
    window.ask_save_path = lambda: str(out)
    window.save_print_file()
    assert tifffile.imread(out).shape == (400, 300, 3)
    window.ask_save_path = lambda: str(tmp_path / "missing-dir" / "x.tif")
    window.save_print_file()
    assert window.errors


def test_settings_remember_printer_paper_calibration_but_not_toning(qtbot, tmp_path: Path) -> None:  # type: ignore[no-untyped-def]
    settings_path = tmp_path / "settings.json"
    cal = tmp_path / "canon.oqcal"
    save_calibration(Calibration.identity(), cal)
    first = MainWindow(settings_path=settings_path, printers=lambda: ["A", "B"])
    qtbot.addWidget(first)
    first.printer_box.setCurrentIndex(1)
    first.paper_box.setCurrentIndex(first.paper_box.findData("A4"))
    first.ask_calibration_path = lambda: str(cal)
    first.choose_calibration()
    first.preset_box.setCurrentIndex(first.preset_box.findData("black-red"))

    second = MainWindow(settings_path=settings_path, printers=lambda: ["A", "B"])
    qtbot.addWidget(second)
    assert second.session.printer == "B"
    assert second.session.paper == "A4"
    assert second.calibration_label.text() == "canon.oqcal"
    assert second.session.preset == "neutral"  # toning is never remembered
    assert Settings.load(settings_path).printer == "B"


def test_no_printers(qtbot, tmp_path: Path) -> None:  # type: ignore[no-untyped-def]
    def broken() -> list[str]:
        raise OSError("no cups")

    win = MainWindow(settings_path=tmp_path / "s.json", printers=broken)
    qtbot.addWidget(win)
    assert win.printer_box.currentData() is None
    win.errors = []  # type: ignore[attr-defined]
    win.show_error = win.errors.append  # type: ignore[attr-defined]
    win.ask_open_path = lambda: str(photo(tmp_path))
    win.open_photo()
    win.print_photo()
    assert "No printer" in win.errors[0]
