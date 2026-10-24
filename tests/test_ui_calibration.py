"""The calibration wizard, headless, against the simulated printer and scanner."""

from pathlib import Path

import pytest

pytest.importorskip("PySide6")

from openquad.greybalance import Calibration, load_calibration, save_calibration
from openquad.ui.calibration_dialog import CalibrationDialog
from openquad.ui.main_window import MainWindow
from tests.simulation import SimulatedLab

FOUND = [("Sim scanner", "scanner.local:80")]


def make_dialog(qtbot, tmp_path: Path, lab: SimulatedLab, **kwargs) -> CalibrationDialog:  # type: ignore[no-untyped-def]
    dialog = CalibrationDialog(
        tmp_path / "calibrations",
        ["Sim"],
        printer="Sim",
        runner=lab.runner,
        fetch=lab.fetch,
        find_scanners=lambda: FOUND,
        **kwargs,
    )
    dialog.asked: list[str] = []  # type: ignore[attr-defined]
    dialog.confirm = lambda title, question: dialog.asked.append(title) or True  # type: ignore[attr-defined]
    dialog.errors: list[str] = []  # type: ignore[attr-defined]
    dialog.show_error = dialog.errors.append  # type: ignore[attr-defined]
    qtbot.addWidget(dialog)
    return dialog


def wait_idle(qtbot, dialog: CalibrationDialog) -> None:  # type: ignore[no-untyped-def]
    qtbot.waitUntil(lambda: dialog.start_button.isEnabled() or dialog.print_button.isEnabled(),
                    timeout=20000)  # fmt: skip


def do_round(qtbot, dialog: CalibrationDialog) -> None:  # type: ignore[no-untyped-def]
    dialog.print_page()
    qtbot.waitUntil(lambda: dialog.scan_button.isEnabled(), timeout=20000)
    dialog.scan_and_measure()
    qtbot.waitUntil(lambda: dialog.recommended is not None, timeout=30000)


def test_buttons_follow_the_steps(qtbot, tmp_path: Path) -> None:  # type: ignore[no-untyped-def]
    dialog = make_dialog(qtbot, tmp_path, SimulatedLab())
    assert dialog.start_button.isEnabled()
    assert not dialog.print_button.isEnabled()
    assert not dialog.scan_button.isEnabled()
    assert dialog.name_edit.text() == "sim-letter-plain"


def test_find_scanners(qtbot, tmp_path: Path) -> None:  # type: ignore[no-untyped-def]
    dialog = make_dialog(qtbot, tmp_path, SimulatedLab())
    dialog.search_scanners()
    qtbot.waitUntil(lambda: dialog.scanner_box.count() == 1, timeout=5000)
    assert dialog.scanner_box.currentData() == "scanner.local:80"
    assert "Sim scanner" in dialog.scanner_box.currentText()


def test_whole_loop_in_the_wizard(qtbot, tmp_path: Path) -> None:  # type: ignore[no-untyped-def]
    lab = SimulatedLab()
    dialog = make_dialog(qtbot, tmp_path, lab, scanner_host="scanner.local:80")
    dialog.start()
    assert dialog.run is not None and dialog.print_button.isEnabled()
    seen = []
    for _ in range(6):
        do_round(qtbot, dialog)
        seen.append(dialog.recommended)
        if dialog.recommended == "done":
            break
        dialog.improve(dialog.recommended or "")
    assert seen[0] == "grey balance"
    assert seen[-1] == "done"
    assert "Both goals are met" in dialog.result_label.text()
    assert dialog.chart.corrected is not None
    assert dialog.asked.count("Print?") == len(seen)  # every print was confirmed
    chosen: list[str] = []
    dialog.calibration_chosen.connect(chosen.append)
    dialog.use()
    assert chosen and Path(chosen[0]).name.endswith(".oqcal")


def test_nothing_happens_without_confirmation(qtbot, tmp_path: Path) -> None:  # type: ignore[no-untyped-def]
    lab = SimulatedLab()
    dialog = make_dialog(qtbot, tmp_path, lab, scanner_host="scanner.local:80")
    dialog.confirm = lambda title, question: False
    dialog.start()
    dialog.print_page()
    assert lab.jobs == 0


def test_scan_needs_a_scanner(qtbot, tmp_path: Path) -> None:  # type: ignore[no-untyped-def]
    lab = SimulatedLab()
    dialog = make_dialog(qtbot, tmp_path, lab)
    dialog.start()
    dialog.print_page()
    qtbot.waitUntil(lambda: dialog.scan_button.isEnabled(), timeout=20000)
    dialog.scan_and_measure()
    assert "Choose a scanner" in dialog.errors[0]


def test_failures_are_reported(qtbot, tmp_path: Path) -> None:  # type: ignore[no-untyped-def]
    lab = SimulatedLab()
    dialog = make_dialog(qtbot, tmp_path, lab, scanner_host="scanner.local:80")
    dialog.start()
    dialog.print_page()
    qtbot.waitUntil(lambda: dialog.scan_button.isEnabled(), timeout=20000)
    dialog.fetch = lambda method, url, body: (500, "", b"")
    dialog.scan_and_measure()
    qtbot.waitUntil(lambda: bool(dialog.errors), timeout=20000)
    assert dialog.errors[0].startswith("Measure failed")
    assert dialog.scan_button.isEnabled()  # can try again


def test_no_printer_and_bad_name(qtbot, tmp_path: Path) -> None:  # type: ignore[no-untyped-def]
    lab = SimulatedLab()
    empty = CalibrationDialog(tmp_path, [], runner=lab.runner, fetch=lab.fetch)
    qtbot.addWidget(empty)
    empty.errors = []  # type: ignore[attr-defined]
    empty.show_error = empty.errors.append  # type: ignore[attr-defined]
    empty.start()
    assert "No printer" in empty.errors[0]
    dialog = make_dialog(qtbot, tmp_path, lab)
    dialog.name_edit.setText("a/b")
    dialog.start()
    assert "Couldn't start" in dialog.errors[0]


def test_start_from_current_calibration(qtbot, tmp_path: Path) -> None:  # type: ignore[no-untyped-def]
    cal = Calibration.identity()
    dialog = make_dialog(qtbot, tmp_path, SimulatedLab(), starting=cal, starting_name="canon.oqcal")
    assert dialog.start_box.currentData() == "current"
    assert "canon.oqcal" in dialog.start_box.currentText()
    dialog.start()
    assert dialog.run is not None


def test_main_window_uses_the_calibration_made(qtbot, tmp_path: Path) -> None:  # type: ignore[no-untyped-def]
    lab = SimulatedLab()
    window = MainWindow(
        settings_path=tmp_path / "settings.json",
        printers=lambda: ["Sim"],
        runner=lab.runner,
        fetch=lab.fetch,
        find_scanners=lambda: FOUND,
        calibrations_folder=tmp_path / "cals",
    )
    qtbot.addWidget(window)
    dialog = window.open_calibration(show=False)
    dialog.scanner_box.addItem("scanner.local:80", "scanner.local:80")
    dialog.confirm = lambda title, question: True
    dialog.start()
    do_round(qtbot, dialog)
    dialog.improve("grey balance")
    dialog.use()
    assert window.session.calibration_path is not None
    assert window.session.calibration_path.name.endswith("-v1.oqcal")
    assert window.calibration_label.text().endswith("-v1.oqcal")
    assert window.settings.scanner_host == "scanner.local:80"
    path = tmp_path / "x.oqcal"
    save_calibration(load_calibration(window.session.calibration_path), path)


def test_chart_draws_with_and_without_data(qtbot, tmp_path: Path) -> None:  # type: ignore[no-untyped-def]
    from openquad.measure import Measurement
    from openquad.ui.charts import WedgeChart

    chart = WedgeChart()
    qtbot.addWidget(chart)
    chart.resize(500, 300)
    blank = chart.grab().toImage()
    real = Path(__file__).resolve().parents[1] / "calibration-data" / "canon-mg3600-plain"
    plain = Measurement.from_json((real / "2026-10-22" / "m7-uncorrected.json").read_text())
    fixed = Measurement.from_json((real / "2026-10-22" / "m7-corrected.json").read_text())
    chart.set_data(plain, fixed)
    drawn = chart.grab().toImage()
    assert drawn != blank
    chart.set_data(None, fixed)  # corrected only
    assert chart.grab().toImage() != blank
