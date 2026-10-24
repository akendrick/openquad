"""The process calibration wizard: chart page, contact print, scan, read, refine.

A thin view over `openquad.process_run.ProcessRun`. The film can be printed here
(CUPS) or from GIMP with the usual settings ("I printed it elsewhere"); the
contact print can be scanned here (eSCL) or a scan file chosen. Printing and
scanning run on a thread pool and ask first; dialogs are attributes for tests.
"""

from __future__ import annotations

import contextlib
from collections.abc import Callable
from datetime import datetime
from pathlib import Path
from typing import Any

from PySide6.QtCore import QObject, Signal
from PySide6.QtWidgets import (
    QCheckBox,
    QComboBox,
    QDialog,
    QFileDialog,
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

from openquad.chart import reading_from_json
from openquad.escl import Fetch, discover, http_fetch
from openquad.negative import NEGATIVE_COLOURS
from openquad.printing import Runner, run_command
from openquad.process_run import TONE_GOAL, ProcessRun
from openquad.ui import background
from openquad.ui.charts import ToneChart

DEFAULT_COLOURS = ("green", "orange")
DEFAULT_PRINTING = "Fine glossy paper, Extra detail, Diffusion, 600 x 600"


def _emit(signal: Any, *args: object) -> None:
    """Emit from a background job; the window may have been closed meanwhile."""
    with contextlib.suppress(RuntimeError):  # its signal hub was deleted with the window
        signal.emit(*args)


class _Signals(QObject):
    done = Signal(str, object)
    failed = Signal(str, str)


class ProcessDialog(QDialog):
    process_chosen = Signal(str)

    def __init__(
        self,
        folder: Path,
        printers: list[str],
        printer: str | None = None,
        scanner_host: str | None = None,
        runner: Runner = run_command,
        fetch: Fetch = http_fetch,
        find_scanners: Callable[[], list[tuple[str, str]]] = discover,
        parent: QWidget | None = None,
    ) -> None:
        super().__init__(parent)
        self.setWindowTitle("Calibrate a negative process")
        self.folder, self.runner, self.fetch, self.find_scanners = (
            folder,
            runner,
            fetch,
            find_scanners,
        )
        self.run: ProcessRun | None = None
        self.signals = _Signals(self)  # deleted with this window: no late deliveries
        self.signals.done.connect(self._done)
        self.signals.failed.connect(self._failed)
        self.confirm: Callable[[str, str], bool] = self._confirm
        self.show_error: Callable[[str], None] = self._show_error
        self.ask_scan_path: Callable[[], str | None] = self._ask_scan_path
        self._build(printers, printer, scanner_host)
        self._update_buttons()

    # --- layout ---------------------------------------------------------------------

    def _build(self, printers: list[str], printer: str | None, scanner_host: str | None) -> None:
        self.name_edit = QLineEdit("carbon-office-film")
        self.colour_boxes: dict[str, QCheckBox] = {}
        colours = QHBoxLayout()
        for name in NEGATIVE_COLOURS:
            box = QCheckBox(name)
            box.setChecked(name in DEFAULT_COLOURS)
            self.colour_boxes[name] = box
            colours.addWidget(box)
        self.printer_box = QComboBox()
        for name in printers:
            self.printer_box.addItem(name, name)
        if printer and self.printer_box.findData(printer) >= 0:
            self.printer_box.setCurrentIndex(self.printer_box.findData(printer))
        self.scanner_box = QComboBox()
        self.scanner_box.setEditable(True)
        if scanner_host:
            self.scanner_box.addItem(scanner_host, scanner_host)
        self.find_button = QPushButton("Find")
        self.find_button.clicked.connect(self.search_scanners)
        scanner_row = QHBoxLayout()
        scanner_row.addWidget(self.scanner_box, 1)
        scanner_row.addWidget(self.find_button)
        self.mirror_box = QCheckBox("Mirror the negatives")
        self.film_edit = QLineEdit("inkjet-coated office transparency")
        self.printing_edit = QLineEdit(DEFAULT_PRINTING)
        self.start_button = QPushButton("Start")
        self.start_button.clicked.connect(self.start)

        setup = QFormLayout()
        setup.addRow("Name", self.name_edit)
        setup.addRow("Colours", colours)
        setup.addRow("Printer", self.printer_box)
        setup.addRow("Scanner", scanner_row)
        setup.addRow(self.mirror_box)
        setup.addRow("Film", self.film_edit)
        setup.addRow("Print settings", self.printing_edit)
        setup.addRow(self.start_button)

        self.page_label = QLabel("")
        self.page_label.setWordWrap(True)
        self.print_button = QPushButton("1. Print chart page here")
        self.print_button.clicked.connect(self.print_page)
        self.elsewhere_button = QPushButton("…or I printed it from GIMP")
        self.elsewhere_button.clicked.connect(self.printed_elsewhere)
        self.scan_button = QPushButton("2. Scan the contact print and read it")
        self.scan_button.clicked.connect(self.scan_and_read)
        self.scan_file_button = QPushButton("…or read a scan file")
        self.scan_file_button.clicked.connect(self.read_scan_file)
        steps = QHBoxLayout()
        for button in (self.print_button, self.elsewhere_button, self.scan_button,
                       self.scan_file_button):  # fmt: skip
            steps.addWidget(button)

        self.chart = ToneChart()
        self.result_label = QLabel("")
        self.result_label.setWordWrap(True)
        self.refine_button = QPushButton("3. Refine the curves")
        self.refine_button.clicked.connect(self.refine)
        self.use_box = QComboBox()
        self.use_button = QPushButton("Use this colour's curve")
        self.use_button.clicked.connect(self.use)
        improve = QHBoxLayout()
        improve.addWidget(self.refine_button)
        improve.addStretch(1)
        improve.addWidget(self.use_box)
        improve.addWidget(self.use_button)

        self.log = QPlainTextEdit()
        self.log.setReadOnly(True)
        self.log.setMaximumHeight(100)

        layout = QVBoxLayout(self)
        layout.addLayout(setup)
        layout.addWidget(self.page_label)
        layout.addLayout(steps)
        layout.addWidget(self.chart, 1)
        layout.addWidget(self.result_label)
        layout.addLayout(improve)
        layout.addWidget(self.log)
        self.resize(860, 820)

    def _say(self, message: str) -> None:
        self.log.appendPlainText(message)

    def _colours(self) -> list[str]:
        return [name for name, box in self.colour_boxes.items() if box.isChecked()]

    def _scanner(self) -> str:
        return str(self.scanner_box.currentData() or self.scanner_box.currentText().strip())

    def _update_buttons(self, busy: bool = False) -> None:
        run = self.run
        started = run is not None
        printed = bool(run and run.current.job)
        read = bool(run and run.current.results)
        self.start_button.setEnabled(not started and not busy)
        self.find_button.setEnabled(not busy)
        self.print_button.setEnabled(started and not busy and bool(self.printer_box.currentData()))
        self.elsewhere_button.setEnabled(started and not busy)
        self.scan_button.setEnabled(printed and not busy)
        self.scan_file_button.setEnabled(printed and not busy)
        self.refine_button.setEnabled(read and not busy)
        has_curve = bool(run and (read or run.current.version > 0))
        self.use_button.setEnabled(has_curve and not busy)

    def _go(self, step: str, work: Callable[[], Any]) -> None:
        self._update_buttons(busy=True)
        signals = self.signals

        def job() -> None:
            try:
                result = work()
            except Exception as exc:  # report every failure in the dialog, never crash
                _emit(signals.failed, step, str(exc))
                return
            _emit(signals.done, step, result)

        background.submit(job)

    # --- steps ----------------------------------------------------------------------

    def search_scanners(self) -> None:
        self._say("Looking for scanners…")
        find = self.find_scanners  # background jobs hold no reference to this window
        self._go("find", lambda: find())

    def start(self) -> None:
        colours = self._colours()
        stamp = datetime.now().strftime("%Y%m%d-%H%M")
        name = self.name_edit.text().strip()
        try:
            self.run = ProcessRun.start(
                self.folder / f"{name}-{stamp}",
                name,
                colours,
                printer=self.printer_box.currentData() or "",
                scanner_host=self._scanner(),
                mirror=self.mirror_box.isChecked(),
                film=self.film_edit.text().strip(),
                printing=self.printing_edit.text().strip(),
            )
            page = self.run.make_page()
        except (OSError, ValueError, RuntimeError) as exc:
            self.show_error(f"Couldn't start: {exc}")
            self.run = None
            return
        self.use_box.clear()
        for colour in colours:
            self.use_box.addItem(colour, colour)
        self.page_label.setText(
            f"Chart page: {page} ({' over '.join(colours)}). Print it on film at 100% "
            f"(300 ppi) with: {self.run.printing or 'your usual settings'}."
        )
        self._say(f"Started {name}: {', '.join(colours)}")
        self._update_buttons()

    def print_page(self) -> None:
        run = self.run
        if run is None:
            return
        if not self.confirm("Print?", f"Print the chart page on {run.printer}? Load film first."):
            return
        self._say("Printing the chart page…")
        runner = self.runner  # background jobs hold no reference to this window
        self._go("print", lambda: run.print_page(runner))

    def printed_elsewhere(self) -> None:
        if self.run is None:
            return
        self.run.mark_printed("printed from GIMP")
        self._say("Marked as printed elsewhere. Contact print it, then scan the print.")
        self._update_buttons()

    def scan_and_read(self) -> None:
        run = self.run
        if run is None:
            return
        run.scanner_host = self._scanner()
        if not run.scanner_host:
            self.show_error("Choose a scanner first (Find looks on the network).")
            return
        if not self.confirm("Scan?", "Is the dry contact print face down on the scanner glass?"):
            return
        self._say("Scanning and reading the charts…")

        fetch = self.fetch  # background jobs hold no reference to this window

        def work() -> object:
            run.scan_page(fetch)
            return run.measure()

        self._go("read", work)

    def read_scan_file(self) -> None:
        run = self.run
        path = self.ask_scan_path()
        if run is None or not path:
            return
        self._say(f"Reading {Path(path).name}…")

        def work() -> object:
            run.use_scan(path)
            return run.measure()

        self._go("read", work)

    def refine(self) -> None:
        run = self.run
        if run is None:
            return
        try:
            run.refine()
            page = run.make_page()
        except (OSError, ValueError, RuntimeError) as exc:
            self.show_error(f"Couldn't refine: {exc}")
            return
        self.chart.set_readings({})
        self.result_label.setText(
            f"Round {run.current.version}: print the new chart page ({page.name})."
        )
        self._say(f"Refined the curves (round {run.current.version}).")
        self._update_buttons()

    def use(self) -> None:
        run, colour = self.run, self.use_box.currentData()
        if run is None or not colour:
            return
        self.process_chosen.emit(str(run.curve_path(colour)))
        self.accept()

    # --- results --------------------------------------------------------------------

    def _done(self, step: str, result: object) -> None:
        run = self.run
        if step == "find":
            found = result if isinstance(result, list) else []
            self.scanner_box.clear()
            for name, host in found:
                self.scanner_box.addItem(f"{name} ({host})", host)
            self._say(f"Found {len(found)} scanner(s).")
        elif step == "print":
            self._say(f"Sent to the printer: job {result}. Contact print it, then scan the print.")
        elif step == "read" and run is not None and isinstance(result, dict):
            readings = {
                c: reading_from_json((run.folder / run.current.readings[c]).read_text())
                for c in run.colours
            }
            self.chart.set_readings(readings)
            lines = []
            for colour, r in result.items():
                verdict = "on target" if r.done else "refine"
                lines.append(f"{colour}: worst {r.worst:.1f} L*, mean {r.mean:.2f} ({verdict})")
            best = run.best_colour()
            if best:
                self.use_box.setCurrentIndex(self.use_box.findData(best))
            goal = f"Goal: every patch within {TONE_GOAL:g} L*. Best: {best}."
            self.result_label.setText("; ".join(lines) + ". " + goal)
            self._say("Read: " + "; ".join(lines))
        self._update_buttons()

    def _failed(self, step: str, message: str) -> None:
        self._update_buttons()
        self.show_error(f"{step.capitalize()} failed: {message}")

    # --- default dialogs -------------------------------------------------------------

    def _confirm(self, title: str, question: str) -> bool:
        return QMessageBox.question(self, title, question) == QMessageBox.StandardButton.Yes

    def _show_error(self, message: str) -> None:
        QMessageBox.warning(self, "OpenQuad", message)

    def _ask_scan_path(self) -> str | None:
        path, _ = QFileDialog.getOpenFileName(
            self, "Choose a scan of the contact print", str(Path.home()),
            "Scans (*.jpg *.jpeg *.png *.tif *.tiff)",
        )  # fmt: skip
        return path or None
