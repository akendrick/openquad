"""The calibration wizard: print a comparison page, scan it, measure, improve.

A thin view over `openquad.calibrate.CalibrationRun`. Printing, scanning,
measuring and finding scanners run on a thread pool. Every step that uses paper
or the scanner asks first; dialogs are attributes so tests can replace them.
"""

from __future__ import annotations

from collections.abc import Callable
from datetime import datetime
from pathlib import Path
from typing import Any

from PySide6.QtCore import QObject, QRunnable, QThreadPool, Signal
from PySide6.QtWidgets import (
    QComboBox,
    QDialog,
    QDoubleSpinBox,
    QFormLayout,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QMessageBox,
    QPlainTextEdit,
    QPushButton,
    QVBoxLayout,
    QWidget,
)

from openquad.calibrate import CalibrationRun
from openquad.escl import Fetch, discover, http_fetch
from openquad.greybalance import Calibration
from openquad.paper import PAPER_SIZES
from openquad.printing import Runner, run_command
from openquad.ui.charts import WedgeChart

Discover = Callable[[], list[tuple[str, str]]]


class _Signals(QObject):
    done = Signal(str, object)  # (step, result)
    failed = Signal(str, str)  # (step, message)


class _Task(QRunnable):
    def __init__(self, step: str, work: Callable[[], Any], signals: _Signals) -> None:
        super().__init__()
        self.step, self.work, self.signals = step, work, signals

    def run(self) -> None:
        try:
            self.signals.done.emit(self.step, self.work())
        except Exception as exc:  # report every failure in the dialog, never crash
            self.signals.failed.emit(self.step, str(exc))


class CalibrationDialog(QDialog):
    calibration_chosen = Signal(str)

    def __init__(
        self,
        folder: Path,
        printers: list[str],
        printer: str | None = None,
        paper: str = "Letter",
        scanner_host: str | None = None,
        starting: Calibration | None = None,
        starting_name: str | None = None,
        runner: Runner = run_command,
        fetch: Fetch = http_fetch,
        find_scanners: Discover = discover,
        parent: QWidget | None = None,
    ) -> None:
        super().__init__(parent)
        self.setWindowTitle("Calibrate a printer")
        self.folder = folder
        self.starting, self.runner, self.fetch, self.find_scanners = (
            starting,
            runner,
            fetch,
            find_scanners,
        )
        self.run: CalibrationRun | None = None
        self.pool = QThreadPool.globalInstance()
        self.signals = _Signals()
        self.signals.done.connect(self._done)
        self.signals.failed.connect(self._failed)
        self.confirm: Callable[[str, str], bool] = self._confirm
        self.show_error: Callable[[str], None] = self._show_error
        self.recommended: str | None = None
        self._build(printers, printer, paper, scanner_host, starting_name)
        self._update_buttons()

    # --- layout ---------------------------------------------------------------------

    def _build(
        self, printers: list[str], printer: str | None, paper: str, scanner_host: str | None,
        starting_name: str | None,
    ) -> None:  # fmt: skip
        self.printer_box = QComboBox()
        for name in printers:
            self.printer_box.addItem(name, name)
        if printer and self.printer_box.findData(printer) >= 0:
            self.printer_box.setCurrentIndex(self.printer_box.findData(printer))
        self.paper_box = QComboBox()
        for name in PAPER_SIZES:
            self.paper_box.addItem(name, name)
        self.paper_box.setCurrentIndex(max(self.paper_box.findData(paper), 0))
        self.name_edit = QLineEdit(self._default_name())
        self.scanner_box = QComboBox()
        self.scanner_box.setEditable(True)
        if scanner_host:
            self.scanner_box.addItem(scanner_host, scanner_host)
        self.find_button = QPushButton("Find")
        self.find_button.clicked.connect(self.search_scanners)
        scanner_row = QHBoxLayout()
        scanner_row.addWidget(self.scanner_box, 1)
        scanner_row.addWidget(self.find_button)
        self.start_box = QComboBox()
        self.start_box.addItem("No correction", "none")
        if self.starting is not None:
            self.start_box.addItem(f"Current calibration ({starting_name or 'loaded'})", "current")
            self.start_box.setCurrentIndex(1)
        self.start_button = QPushButton("Start")
        self.start_button.clicked.connect(self.start)

        setup = QFormLayout()
        setup.addRow("Printer", self.printer_box)
        setup.addRow("Paper", self.paper_box)
        setup.addRow("Name", self.name_edit)
        setup.addRow("Scanner", scanner_row)
        setup.addRow("Start from", self.start_box)
        setup.addRow(self.start_button)

        self.print_button = QPushButton("1. Print comparison page")
        self.print_button.clicked.connect(self.print_page)
        self.scan_button = QPushButton("2. Scan and measure")
        self.scan_button.clicked.connect(self.scan_and_measure)
        steps = QHBoxLayout()
        steps.addWidget(self.print_button)
        steps.addWidget(self.scan_button)

        self.chart = WedgeChart()
        self.result_label = QLabel("")
        self.result_label.setWordWrap(True)

        self.grey_button = QPushButton("Improve grey balance")
        self.grey_button.clicked.connect(lambda: self.improve("grey balance"))
        self.linear_button = QPushButton("Even out tone")
        self.linear_button.clicked.connect(lambda: self.improve("linearize"))
        self.shadow_box = QDoubleSpinBox()
        self.shadow_box.setRange(0.0, 1.0)
        self.shadow_box.setSingleStep(0.1)
        self.shadow_box.setValue(0.5)
        self.use_button = QPushButton("Use this calibration")
        self.use_button.clicked.connect(self.use)
        improve = QHBoxLayout()
        improve.addWidget(self.grey_button)
        improve.addWidget(QLabel("shadow strength"))
        improve.addWidget(self.shadow_box)
        improve.addWidget(self.linear_button)
        improve.addStretch(1)
        improve.addWidget(self.use_button)

        self.log = QPlainTextEdit()
        self.log.setReadOnly(True)
        self.log.setMaximumHeight(110)

        layout = QVBoxLayout(self)
        layout.addLayout(setup)
        layout.addLayout(steps)
        layout.addWidget(self.chart, 1)
        layout.addWidget(self.result_label)
        layout.addLayout(improve)
        layout.addWidget(self.log)
        self.resize(760, 760)

    def _default_name(self) -> str:
        printer = (self.printer_box.currentData() or "printer").split("_")[0].lower()
        return f"{printer}-{(self.paper_box.currentData() or 'paper').lower()}-plain"

    def _say(self, message: str) -> None:
        self.log.appendPlainText(message)

    def _busy(self, busy: bool) -> None:
        for button in (self.print_button, self.scan_button, self.grey_button, self.linear_button,
                       self.use_button, self.start_button, self.find_button):  # fmt: skip
            button.setEnabled(not busy)
        if not busy:
            self._update_buttons()

    def _update_buttons(self) -> None:
        run = self.run
        started = run is not None
        printed = bool(run and run.current.job)
        measured = bool(run and len(run.current.measurements) == 2)
        self.start_button.setEnabled(not started)
        self.print_button.setEnabled(started)
        self.scan_button.setEnabled(printed)
        self.grey_button.setEnabled(measured)
        self.linear_button.setEnabled(measured)
        self.use_button.setEnabled(bool(run and (measured or run.current.version > 0)))
        for button, action in (
            (self.grey_button, "grey balance"),
            (self.linear_button, "linearize"),
        ):
            button.setDefault(measured and self.recommended == action)

    # --- steps ----------------------------------------------------------------------

    def _go(self, step: str, work: Callable[[], Any]) -> None:
        self._busy(True)
        self.pool.start(_Task(step, work, self.signals))

    def search_scanners(self) -> None:
        self._say("Looking for scanners…")
        self._go("find", self.find_scanners)

    def start(self) -> None:
        printer = self.printer_box.currentData()
        scanner = self.scanner_box.currentData() or self.scanner_box.currentText().strip()
        if not printer:
            self.show_error("No printer is set up on this computer.")
            return
        stamp = datetime.now().strftime("%Y%m%d-%H%M")
        name = self.name_edit.text().strip()
        try:
            self.run = CalibrationRun.start(
                self.folder / f"{name}-{stamp}",
                name,
                printer,
                self.paper_box.currentData(),
                scanner,
                starting=self.starting if self.start_box.currentData() == "current" else None,
            )
        except (OSError, ValueError, RuntimeError) as exc:
            self.show_error(f"Couldn't start: {exc}")
            return
        self._say(f"Started {name} in {self.run.folder}")
        self._update_buttons()

    def print_page(self) -> None:
        run = self.run
        if run is None:
            return
        question = (
            f"Print a comparison page on {run.printer} ({run.paper})? "
            "It uses one sheet and a quarter of a page of ink."
        )
        if not self.confirm("Print?", question):
            return
        self._say(f"Printing round {run.current.version}…")
        self._go("print", lambda: run.print_page(self.runner))

    def scan_and_measure(self) -> None:
        run = self.run
        if run is None:
            return
        if not (self.scanner_box.currentData() or self.scanner_box.currentText().strip()):
            self.show_error("Choose a scanner first (Find looks on the network).")
            return
        run.scanner_host = self.scanner_box.currentData() or self.scanner_box.currentText().strip()
        question = "Is the printed page dry, face down on the scanner glass, with the lid closed?"
        if not self.confirm("Scan?", question):
            return
        self._say("Scanning and measuring…")

        def work() -> object:
            run.scan_page(self.fetch)
            return run.measure()

        self._go("measure", work)

    def improve(self, action: str) -> None:
        run = self.run
        if run is None:
            return
        try:
            path = run.improve(action, shadow_damping=self.shadow_box.value())
        except (OSError, ValueError, RuntimeError) as exc:
            self.show_error(f"Couldn't build the calibration: {exc}")
            return
        self.recommended = None
        self.chart.set_data(None, None)
        self.result_label.setText(f"Built {path.name}. Print a new comparison page to check it.")
        self._say(f"{action.capitalize()}: built {path.name}")
        self._update_buttons()

    def use(self) -> None:
        if self.run is None:
            return
        self.calibration_chosen.emit(str(self.run.calibration_path))
        self._say(f"Using {self.run.calibration_path.name}")
        self.accept()

    # --- results --------------------------------------------------------------------

    def _done(self, step: str, result: object) -> None:
        if step == "find":
            found = result if isinstance(result, list) else []
            self.scanner_box.clear()
            for name, host in found:
                self.scanner_box.addItem(f"{name} ({host})", host)
            self._say(f"Found {len(found)} scanner(s).")
        elif step == "print":
            self._say(f"Sent to the printer: job {result}. Let it dry, then scan it.")
        elif step == "measure" and isinstance(result, tuple):
            uncorrected, corrected, assessment = result
            self.chart.set_data(uncorrected, corrected)
            self.recommended = assessment.next_step
            advice = {
                "grey balance": "Next: improve grey balance.",
                "linearize": "Next: even out tone.",
                "done": "Both goals are met: use this calibration.",
            }[assessment.next_step]
            self.result_label.setText(f"{assessment.summary()} {advice}")
            self._say(f"Measured: {advice}")
        self._busy(False)

    def _failed(self, step: str, message: str) -> None:
        self._busy(False)
        self.show_error(f"{step.capitalize()} failed: {message}")

    # --- default dialogs -------------------------------------------------------------

    def _confirm(self, title: str, question: str) -> bool:
        return QMessageBox.question(self, title, question) == QMessageBox.StandardButton.Yes

    def _show_error(self, message: str) -> None:
        QMessageBox.warning(self, "OpenQuad", message)
