"""The app's digital negative mode and process wizard, headless, simulated carbon."""

from pathlib import Path

import numpy as np
import pytest
import tifffile

pytest.importorskip("PySide6")

from openquad.chart import ProcessCurve, save_process
from openquad.ui.main_window import MainWindow
from openquad.ui.process_dialog import ProcessDialog
from tests.simulation import CarbonLab

FOUND = [("Sim scanner", "scanner.local:80")]


def photo(tmp_path: Path) -> Path:
    path = tmp_path / "portrait.tif"
    tifffile.imwrite(path, np.tile(np.linspace(0, 65535, 300).astype(np.uint16), (400, 1)),
                     resolution=(72, 72), resolutionunit="INCH")  # fmt: skip
    return path


def window(qtbot, tmp_path: Path, lab: CarbonLab) -> MainWindow:  # type: ignore[no-untyped-def]
    win = MainWindow(
        settings_path=tmp_path / "settings.json",
        printers=lambda: ["Sim"],
        runner=lab.runner,
        fetch=lab.fetch,
        find_scanners=lambda: FOUND,
        calibrations_folder=tmp_path / "cals",
    )
    win.errors = []  # type: ignore[attr-defined]
    win.show_error = win.errors.append  # type: ignore[attr-defined]
    qtbot.addWidget(win)
    return win


def test_negative_mode_shows_its_controls_and_saves_a_negative(qtbot, tmp_path: Path) -> None:  # type: ignore[no-untyped-def]
    win = window(qtbot, tmp_path, CarbonLab())
    win.ask_open_path = lambda: str(photo(tmp_path))
    win.open_photo()
    assert win.form.isRowVisible(win._print_rows[0])
    assert not win.form.isRowVisible(win._negative_rows[0])
    win.mode_box.setCurrentIndex(win.mode_box.findData("negative"))
    assert win.session.negative
    assert not win.form.isRowVisible(win._print_rows[0])
    assert win.form.isRowVisible(win._negative_rows[0])
    assert win.save_button.text() == "Save negative…"
    assert "(with safe edge)" in win.size_label.text()
    win.mirror_box.setChecked(True)
    win.safe_edge_box.setValue(0.4)
    win.negative_colour_box.setCurrentIndex(win.negative_colour_box.findData("orange"))
    assert (win.session.mirror, win.session.safe_edge, win.session.negative_colour) == (
        True,
        0.4,
        "orange",
    )
    out = tmp_path / "neg.tif"
    win.ask_save_path = lambda: str(out)
    win.save_print_file()
    neg = tifffile.imread(out)
    assert np.abs(neg[2, neg.shape[1] // 2] / 65535 - np.array([0.95, 0.45, 0.05])).max() < 0.01


def test_process_curve_choose_clear_and_remembered(qtbot, tmp_path: Path) -> None:  # type: ignore[no-untyped-def]
    curve = tmp_path / "orange.oqproc"
    save_process(ProcessCurve.identity("orange"), curve)
    win = window(qtbot, tmp_path, CarbonLab())
    win.ask_process_path = lambda: str(curve)
    win.choose_process()
    assert win.process_label.text() == "orange.oqproc"
    assert win.session.negative_colour == "orange"
    assert not win.negative_colour_box.isEnabled()  # the curve decides the colour
    again = window(qtbot, tmp_path, CarbonLab())  # settings remembered
    assert again.session.process_path == curve
    win.clear_process_button.click()
    assert win.process_label.text() == "None (uncalibrated)"
    bad = tmp_path / "bad.oqproc"
    bad.write_text("nope")
    win.set_process(str(bad))
    assert win.errors


def dialog(qtbot, tmp_path: Path, lab: CarbonLab) -> ProcessDialog:  # type: ignore[no-untyped-def]
    d = ProcessDialog(
        tmp_path / "processes",
        ["Sim"],
        printer="Sim",
        scanner_host="scanner.local:80",
        runner=lab.runner,
        fetch=lab.fetch,
        find_scanners=lambda: FOUND,
    )
    d.confirm = lambda title, question: True
    d.errors = []  # type: ignore[attr-defined]
    d.show_error = d.errors.append  # type: ignore[attr-defined]
    qtbot.addWidget(d)
    return d


def read_round(qtbot, d: ProcessDialog) -> None:  # type: ignore[no-untyped-def]
    d.print_page()
    qtbot.waitUntil(lambda: d.scan_button.isEnabled(), timeout=30000)
    d.chart.readings = {}
    d.scan_and_read()
    qtbot.waitUntil(lambda: bool(d.chart.readings), timeout=60000)


def test_wizard_full_loop_and_use(qtbot, tmp_path: Path) -> None:  # type: ignore[no-untyped-def]
    lab = CarbonLab(scan_dpi=100)
    d = dialog(qtbot, tmp_path, lab)
    assert [c for c, box in d.colour_boxes.items() if box.isChecked()] == ["green", "orange"]
    d.start()
    assert d.run is not None and "green over orange" in d.page_label.text()
    read_round(qtbot, d)
    assert "refine" in d.result_label.text()
    d.refine()
    assert d.run.current.version == 1
    read_round(qtbot, d)
    assert d.result_label.text().count("on target") == 2
    chosen: list[str] = []
    d.process_chosen.connect(chosen.append)
    d.use()
    assert chosen and chosen[0].endswith("-v1.oqproc")


def test_wizard_printed_elsewhere_and_scan_file(qtbot, tmp_path: Path) -> None:  # type: ignore[no-untyped-def]
    lab = CarbonLab(scan_dpi=100)
    d = dialog(qtbot, tmp_path, lab)
    d.start()
    d.printed_elsewhere()
    assert d.scan_file_button.isEnabled()
    lab.contact_print_file(str(d.run.folder / d.run.current.page))  # type: ignore[union-attr]
    scan = tmp_path / "scan.jpg"
    scan.write_bytes(lab.fetch("GET", "x", None)[2])
    d.ask_scan_path = lambda: str(scan)
    d.read_scan_file()
    qtbot.waitUntil(lambda: bool(d.chart.readings), timeout=60000)
    assert set(d.chart.readings) == {"green", "orange"}


def test_wizard_find_errors_and_no_scanner(qtbot, tmp_path: Path) -> None:  # type: ignore[no-untyped-def]
    lab = CarbonLab(scan_dpi=100)
    d = dialog(qtbot, tmp_path, lab)
    d.search_scanners()
    qtbot.waitUntil(lambda: d.scanner_box.count() == 1 and d.find_button.isEnabled(), timeout=5000)
    assert d.scanner_box.currentData() == "scanner.local:80"
    d.name_edit.setText("a/b")
    d.start()
    assert "Couldn't start" in d.errors[0]
    d.name_edit.setText("ok")
    d.start()
    d.printed_elsewhere()
    d.scanner_box.clear()
    d.scanner_box.setEditText("")
    d.scan_and_read()
    assert "Choose a scanner" in d.errors[-1]
    d.fetch = lambda method, url, body: (500, "", b"")
    d.scanner_box.setEditText("scanner.local")
    d.scan_and_read()
    qtbot.waitUntil(lambda: len(d.errors) >= 3, timeout=20000)
    assert d.errors[-1].startswith("Read failed")


def test_main_window_takes_the_wizard_curve(qtbot, tmp_path: Path) -> None:  # type: ignore[no-untyped-def]
    lab = CarbonLab(scan_dpi=100)
    win = window(qtbot, tmp_path, lab)
    d = win.open_process_calibration(show=False)
    d.confirm = lambda title, question: True
    d.scanner_box.addItem("scanner.local:80", "scanner.local:80")
    d.start()
    read_round(qtbot, d)
    d.use()
    assert win.session.process_path is not None
    assert win.process_label.text().endswith("-v0.oqproc")


def test_tone_chart_draws(qtbot, tmp_path: Path) -> None:  # type: ignore[no-untyped-def]
    from openquad.chart import chart_negative, read_chart
    from openquad.ui.charts import ToneChart
    from tests.simulation import contact_print
    from tests.test_blocking import scanned

    chart = ToneChart()
    qtbot.addWidget(chart)
    chart.resize(500, 300)
    blank = chart.grab().toImage()
    reading = read_chart(scanned(contact_print(chart_negative("green", dpi=100))))
    chart.set_readings({"green": reading, "orange": reading})
    assert chart.grab().toImage() != blank
