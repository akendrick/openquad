"""The print window: open a photo, choose toning and calibration, preview, print.

A thin view over `openquad.session.PrintSession`. Slow work (previews, printing)
runs on a thread pool so the window stays responsive; dialogs are attributes so
tests can replace them.
"""

from __future__ import annotations

import contextlib
import tempfile
from collections.abc import Callable
from pathlib import Path

import numpy as np
from numpy.typing import NDArray
from PySide6.QtCore import QObject, QRunnable, Qt, QThreadPool, QTimer, Signal
from PySide6.QtGui import QImage, QPixmap, QResizeEvent
from PySide6.QtWidgets import (
    QCheckBox,
    QComboBox,
    QDoubleSpinBox,
    QFileDialog,
    QFormLayout,
    QHBoxLayout,
    QLabel,
    QMainWindow,
    QMessageBox,
    QPushButton,
    QVBoxLayout,
    QWidget,
)

from openquad.composite import PRESETS
from openquad.escl import Fetch, discover, http_fetch
from openquad.paper import PAPER_SIZES
from openquad.printing import PrintError, Runner, list_printers, run_command
from openquad.session import PrintSession
from openquad.settings import Settings, data_dir
from openquad.ui.calibration_dialog import CalibrationDialog

PRESET_LABELS = {
    "neutral": "Neutral (no toning)",
    "black-red": "Black + red duotone",
    "red-only": "Red only",
    "warm-split": "Warm split tone",
}
IMAGE_FILTER = "Images (*.tif *.tiff *.png *.jpg *.jpeg)"


class _Signals(QObject):
    preview_ready = Signal(int, QImage)
    printed = Signal(str)
    failed = Signal(str)


class _Task(QRunnable):
    def __init__(self, work: Callable[[], None]) -> None:
        super().__init__()
        self._work = work

    def run(self) -> None:
        self._work()


def to_qimage(rgb: NDArray[np.uint8]) -> QImage:
    rgb = np.ascontiguousarray(rgb)
    height, width = rgb.shape[:2]
    image = QImage(rgb.data, width, height, 3 * width, QImage.Format.Format_RGB888)
    return image.copy()  # own the pixels; the numpy buffer may go away


class MainWindow(QMainWindow):
    def __init__(
        self,
        session: PrintSession | None = None,
        settings: Settings | None = None,
        settings_path: Path | None = None,
        printers: Callable[[], list[str]] = list_printers,
        runner: Runner = run_command,
        fetch: Fetch = http_fetch,
        find_scanners: Callable[[], list[tuple[str, str]]] = discover,
        calibrations_folder: Path | None = None,
    ) -> None:
        super().__init__()
        self.setWindowTitle("OpenQuad")
        self.session = session or PrintSession()
        self.settings = settings or Settings.load(settings_path)
        self.settings_path = settings_path
        self.runner = runner
        self.fetch, self.find_scanners = fetch, find_scanners
        self.calibrations_folder = calibrations_folder or data_dir() / "calibrations"
        self.calibration_dialog: CalibrationDialog | None = None
        self.pool = QThreadPool.globalInstance()
        self.signals = _Signals()
        self.signals.preview_ready.connect(self._show_preview)
        self.signals.printed.connect(self._printed)
        self.signals.failed.connect(self._failed)
        self._preview_token = 0
        self._pixmap: QPixmap | None = None
        # Dialogs, replaceable in tests.
        self.ask_open_path: Callable[[], str | None] = self._ask_open_path
        self.ask_calibration_path: Callable[[], str | None] = self._ask_calibration_path
        self.ask_save_path: Callable[[], str | None] = self._ask_save_path
        self.confirm: Callable[[str], bool] = self._confirm
        self.show_error: Callable[[str], None] = self._show_error

        self._build(printers)
        self._restore()
        self._refresh()

    # --- layout ---------------------------------------------------------------------

    def _build(self, printers: Callable[[], list[str]]) -> None:
        self.preview_label = QLabel("Open a photo to begin")
        self.preview_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.preview_label.setMinimumSize(420, 420)

        self.open_button = QPushButton("Open photo…")
        self.open_button.clicked.connect(self.open_photo)
        self.photo_info = QLabel("")
        self.photo_info.setWordWrap(True)

        self.preset_box = QComboBox()
        for name in sorted(PRESETS, key=lambda n: (n != "neutral", n)):
            self.preset_box.addItem(PRESET_LABELS.get(name, name), name)
        self.preset_box.currentIndexChanged.connect(self._preset_changed)

        self.calibration_label = QLabel("None")
        self.calibration_button = QPushButton("Choose…")
        self.calibration_button.clicked.connect(self.choose_calibration)
        self.clear_calibration_button = QPushButton("Clear")
        self.clear_calibration_button.clicked.connect(lambda: self.set_calibration(None))
        self.calibrate_button = QPushButton("Calibrate…")
        self.calibrate_button.clicked.connect(self.open_calibration)
        self.calibration_label.setWordWrap(True)
        calibration_row = QHBoxLayout()
        calibration_row.addWidget(self.calibration_button)
        calibration_row.addWidget(self.clear_calibration_button)
        calibration_row.addWidget(self.calibrate_button)

        self.printer_box = QComboBox()
        try:
            names = printers()
        except (PrintError, OSError):
            names = []
        for name in names:
            self.printer_box.addItem(name, name)
        if not names:
            self.printer_box.addItem("(no printers found)", None)
        self.printer_box.currentIndexChanged.connect(self._printer_changed)

        self.paper_box = QComboBox()
        for name in PAPER_SIZES:
            self.paper_box.addItem(name, name)
        self.paper_box.currentIndexChanged.connect(self._paper_changed)

        self.fit_box = QCheckBox("Fit to page (0.5 in margins)")
        self.fit_box.setChecked(self.session.fit)
        self.fit_box.toggled.connect(self._fit_changed)
        self.ppi_box = QDoubleSpinBox()
        self.ppi_box.setRange(50, 2400)
        self.ppi_box.setDecimals(0)
        self.ppi_box.setSuffix(" ppi")
        self.ppi_box.setValue(300)
        self.ppi_box.valueChanged.connect(self._ppi_changed)
        self.size_label = QLabel("")

        self.save_button = QPushButton("Save print file…")
        self.save_button.clicked.connect(self.save_print_file)
        self.print_button = QPushButton("Print…")
        self.print_button.setDefault(True)
        self.print_button.clicked.connect(self.print_photo)

        form = QFormLayout()
        form.addRow(self.open_button)
        form.addRow(self.photo_info)
        form.addRow("Toning", self.preset_box)
        form.addRow("Calibration", self.calibration_label)
        form.addRow("", calibration_row)
        form.addRow("Printer", self.printer_box)
        form.addRow("Paper", self.paper_box)
        form.addRow(self.fit_box)
        form.addRow("Resolution", self.ppi_box)
        form.addRow("Print size", self.size_label)
        buttons = QHBoxLayout()
        buttons.addWidget(self.save_button)
        buttons.addWidget(self.print_button)
        panel = QVBoxLayout()
        panel.addLayout(form)
        panel.addStretch(1)
        panel.addLayout(buttons)

        root = QHBoxLayout()
        root.addWidget(self.preview_label, 1)
        side = QWidget()
        side.setLayout(panel)
        side.setFixedWidth(340)
        root.addWidget(side)
        central = QWidget()
        central.setLayout(root)
        self.setCentralWidget(central)
        self.resize(1000, 720)

    def _restore(self) -> None:
        # Read every saved value before touching a widget: changing a widget saves the
        # settings, which would overwrite values not yet restored.
        printer, paper, calibration = (
            self.settings.printer,
            self.settings.paper,
            self.settings.calibration,
        )
        for box, value in ((self.printer_box, printer), (self.paper_box, paper)):
            index = box.findData(value) if value else -1
            if index >= 0:
                box.blockSignals(True)
                box.setCurrentIndex(index)
                box.blockSignals(False)
        self.session.printer = self.printer_box.currentData()
        self.session.set_paper(self.paper_box.currentData())
        if calibration and Path(calibration).is_file():
            try:
                self.session.set_calibration(calibration)
            except (OSError, ValueError):
                self.session.set_calibration(None)

    def _remember(self) -> None:
        self.settings.printer = self.session.printer
        self.settings.paper = self.session.paper
        path = self.session.calibration_path
        self.settings.calibration = str(path) if path else None
        with contextlib.suppress(OSError):  # settings are a convenience; never block printing
            self.settings.save(self.settings_path)

    # --- actions --------------------------------------------------------------------

    def open_photo(self) -> None:
        path = self.ask_open_path()
        if not path:
            return
        try:
            self.session.open(path)
        except (OSError, ValueError) as exc:
            self.show_error(f"Couldn't open {Path(path).name}: {exc}")
            return
        self.settings.last_folder = str(Path(path).parent)
        self._remember()
        self._refresh()

    def choose_calibration(self) -> None:
        path = self.ask_calibration_path()
        if path:
            self.set_calibration(path)

    def set_calibration(self, path: str | None) -> None:
        try:
            self.session.set_calibration(path)
        except (OSError, ValueError) as exc:
            self.show_error(f"Couldn't load the calibration: {exc}")
            return
        self._remember()
        self._refresh()

    def open_calibration(self, show: bool = True) -> CalibrationDialog:
        printers = [
            self.printer_box.itemData(i)
            for i in range(self.printer_box.count())
            if self.printer_box.itemData(i)
        ]
        dialog = CalibrationDialog(
            self.calibrations_folder,
            printers,
            printer=self.session.printer,
            paper=self.session.paper,
            scanner_host=self.settings.scanner_host,
            starting=self.session.calibration,
            starting_name=self.session.calibration_path.name
            if self.session.calibration_path
            else None,
            runner=self.runner,
            fetch=self.fetch,
            find_scanners=self.find_scanners,
            parent=self,
        )
        dialog.calibration_chosen.connect(self._calibration_made)
        self.calibration_dialog = dialog
        if show:
            dialog.open()
        return dialog

    def _calibration_made(self, path: str) -> None:
        dialog = self.calibration_dialog
        if dialog is not None and dialog.run is not None:
            self.settings.scanner_host = dialog.run.scanner_host or self.settings.scanner_host
        self.set_calibration(path)
        self.statusBar().showMessage(f"Using calibration {Path(path).name}")

    def save_print_file(self) -> None:
        if self.session.photo is None:
            return
        path = self.ask_save_path()
        if not path:
            return
        try:
            self.session.write_print_file(path)
        except (OSError, ValueError) as exc:
            self.show_error(f"Couldn't save: {exc}")
            return
        self.statusBar().showMessage(f"Saved {Path(path).name}")

    def print_photo(self) -> None:
        if self.session.photo is None:
            return
        if not self.session.printer:
            self.show_error("No printer is set up on this computer.")
            return
        if not self.session.fits_on_paper():
            self.show_error("The photo is larger than the paper at this size.")
            return
        if not self.confirm("\n".join(self.session.summary())):
            return
        self.print_button.setEnabled(False)
        self.statusBar().showMessage("Preparing the print…")
        session, runner, signals = self.session, self.runner, self.signals

        def work() -> None:
            try:
                with tempfile.TemporaryDirectory(prefix="openquad-") as scratch:
                    signals.printed.emit(session.print(scratch, runner))
            except (OSError, ValueError, PrintError) as exc:
                signals.failed.emit(str(exc))

        self.pool.start(_Task(work))

    # --- reacting to changes --------------------------------------------------------

    def _preset_changed(self) -> None:
        self.session.set_preset(self.preset_box.currentData())
        self._refresh()

    def _printer_changed(self) -> None:
        self.session.printer = self.printer_box.currentData()
        self._remember()

    def _paper_changed(self) -> None:
        self.session.set_paper(self.paper_box.currentData())
        self._remember()
        self._refresh()

    def _fit_changed(self, checked: bool) -> None:
        self.session.fit = checked
        self._refresh()

    def _ppi_changed(self, value: float) -> None:
        self.session.ppi = value
        self._refresh()

    def _refresh(self) -> None:
        session = self.session
        has_photo = session.photo is not None
        name = session.calibration_path.name if session.calibration_path else "None"
        self.calibration_label.setText(name)
        self.calibration_label.setToolTip(str(session.calibration_path or ""))
        self.ppi_box.setEnabled(not session.fit)
        self.save_button.setEnabled(has_photo)
        self.print_button.setEnabled(has_photo and bool(session.printer))
        if not has_photo:
            self.size_label.setText("")
            return
        width, height = session.size_inches()
        text = f"{width:.2f} × {height:.2f} in at {session.effective_ppi():.0f} ppi"
        fits = session.fits_on_paper()
        self.size_label.setText(text if fits else text + " (too big for the paper)")
        self.size_label.setStyleSheet("" if fits else "color: #b00020")
        source = session.source.name if session.source else ""
        w_px, h_px = session.photo.size if session.photo else (0, 0)
        self.photo_info.setText(" ".join([f"{source} — {w_px} × {h_px} px.", *session.notes]))
        self._request_preview()

    def _request_preview(self) -> None:
        self._preview_token += 1
        token, session, signals = self._preview_token, self.session, self.signals
        side = max(self.preview_label.width(), self.preview_label.height(), 420)

        def work() -> None:
            signals.preview_ready.emit(token, to_qimage(session.preview(max_side=side)))

        self.statusBar().showMessage("Rendering preview…")
        self.pool.start(_Task(work))

    # --- results from the thread pool ----------------------------------------------

    def _show_preview(self, token: int, image: QImage) -> None:
        if token != self._preview_token:
            return  # a newer preview is on its way
        self._pixmap = QPixmap.fromImage(image)
        self._fit_pixmap()
        self.statusBar().clearMessage()

    def _fit_pixmap(self) -> None:
        if self._pixmap is not None:
            self.preview_label.setPixmap(
                self._pixmap.scaled(
                    self.preview_label.size(),
                    Qt.AspectRatioMode.KeepAspectRatio,
                    Qt.TransformationMode.SmoothTransformation,
                )
            )

    def resizeEvent(self, event: QResizeEvent) -> None:  # noqa: N802 (Qt override)
        super().resizeEvent(event)
        QTimer.singleShot(0, self._fit_pixmap)

    def _printed(self, job: str) -> None:
        self.print_button.setEnabled(True)
        self.statusBar().showMessage(f"Sent to the printer: job {job}")

    def _failed(self, message: str) -> None:
        self.print_button.setEnabled(True)
        self.statusBar().clearMessage()
        self.show_error(f"Printing failed: {message}")

    # --- default dialogs -------------------------------------------------------------

    def _ask_open_path(self) -> str | None:
        folder = self.settings.last_folder or str(Path.home())
        path, _ = QFileDialog.getOpenFileName(self, "Open photo", folder, IMAGE_FILTER)
        return path or None

    def _ask_calibration_path(self) -> str | None:
        path, _ = QFileDialog.getOpenFileName(
            self, "Choose calibration", str(Path.home()), "Calibrations (*.oqcal)"
        )
        return path or None

    def _ask_save_path(self) -> str | None:
        stem = self.session.source.stem if self.session.source else "print"
        suggested = f"{stem}-{self.session.preset}.tif"
        path, _ = QFileDialog.getSaveFileName(self, "Save print file", suggested, "TIFF (*.tif)")
        return path or None

    def _confirm(self, summary: str) -> bool:
        answer = QMessageBox.question(self, "Print?", f"Print with these settings?\n\n{summary}")
        return answer == QMessageBox.StandardButton.Yes

    def _show_error(self, message: str) -> None:
        QMessageBox.warning(self, "OpenQuad", message)
