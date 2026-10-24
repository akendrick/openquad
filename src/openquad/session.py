"""A print session: everything the print window shows and does, without any Qt.

The desktop app is a thin view over this class, so all the logic is tested the
same way as the rest of the core. Colour toning is never on by default: a new
session uses the neutral preset until the user picks another.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
from numpy.typing import NDArray
from PIL import Image

from openquad.chart import ProcessCurve, load_process
from openquad.composite import DEFAULT_PRESET, PRESETS, composite
from openquad.greybalance import Calibration, load_calibration
from openquad.imageio import save_rgb, srgb_profile
from openquad.negative import NEGATIVE_COLOURS, NegativeSettings, make_negative, negative_ppi
from openquad.paper import DEFAULT_MARGIN, PAPER_SIZES, fit_ppi, print_size
from openquad.photo import Photo, load_photo
from openquad.printing import PrintJob, Runner, run_command, send

FALLBACK_PPI = 300.0


class SessionError(ValueError):
    """The session can't do that yet (e.g. no photo or no printer chosen)."""


@dataclass
class PrintSession:
    photo: Photo | None = None
    source: Path | None = None
    preset: str = DEFAULT_PRESET
    calibration: Calibration | None = None
    calibration_path: Path | None = None
    printer: str | None = None
    paper: str = "Letter"
    fit: bool = True
    margin: float = DEFAULT_MARGIN
    ppi: float | None = None  # used when fit is off; None = the photo's own DPI
    notes: list[str] = field(default_factory=list)
    # Digital negative mode: the photo becomes a negative for contact printing.
    mode: str = "print"  # "print" or "negative"
    negative_colour: str = "green"
    process: ProcessCurve | None = None
    process_path: Path | None = None
    mirror: bool = False
    safe_edge: float = 0.25

    # --- choosing things ------------------------------------------------------------

    def open(self, path: str | Path) -> None:
        self.photo = load_photo(path)
        self.source = Path(path)
        self.notes = []
        if self.photo.cropped:
            self.notes.append("Transparent edges were cropped off.")
        if self.photo.converted:
            self.notes.append("This is a colour image; it was converted to greyscale.")

    def set_preset(self, name: str) -> None:
        if name not in PRESETS:
            raise SessionError(f"unknown preset {name!r}")
        self.preset = name

    def set_calibration(self, path: str | Path | None) -> None:
        if path is None:
            self.calibration, self.calibration_path = None, None
            return
        self.calibration = load_calibration(path)
        self.calibration_path = Path(path)

    def set_mode(self, mode: str) -> None:
        if mode not in ("print", "negative"):
            raise SessionError(f"unknown mode {mode!r}")
        self.mode = mode

    def set_negative_colour(self, colour: str) -> None:
        if colour not in NEGATIVE_COLOURS:
            raise SessionError(f"unknown negative colour {colour!r}")
        if self.process is not None and self.process.colour != colour:
            raise SessionError(f"the process curve is for {self.process.colour} negatives")
        self.negative_colour = colour

    def set_process(self, path: str | Path | None) -> None:
        """Use a process curve; it decides the negative colour it was made for."""
        if path is None:
            self.process, self.process_path = None, None
            return
        self.process = load_process(path)
        self.process_path = Path(path)
        self.negative_colour = self.process.colour

    @property
    def negative(self) -> bool:
        return self.mode == "negative"

    def _negative_settings(self) -> NegativeSettings:
        return NegativeSettings(
            colour=self.negative_colour, mirror=self.mirror, safe_edge=self.safe_edge
        )

    def set_paper(self, paper: str) -> None:
        if paper not in PAPER_SIZES:
            raise SessionError(f"unknown paper {paper!r}")
        self.paper = paper

    # --- size -----------------------------------------------------------------------

    def _photo(self) -> Photo:
        if self.photo is None:
            raise SessionError("open a photo first")
        return self.photo

    def effective_ppi(self) -> float:
        photo = self._photo()
        if self.fit and self.negative:
            return negative_ppi(*photo.size, self.paper, self.safe_edge, self.margin)
        if self.fit:
            return fit_ppi(*photo.size, self.paper, self.margin)
        if self.ppi:
            return self.ppi
        return photo.dpi[0] if photo.dpi else FALLBACK_PPI

    def size_inches(self) -> tuple[float, float]:
        width, height = print_size(*self._photo().size, self.effective_ppi())
        if self.negative:  # the safe edge goes round the photo
            width, height = width + 2 * self.safe_edge, height + 2 * self.safe_edge
        return width, height

    def fits_on_paper(self) -> bool:
        width, height = self.size_inches()
        paper_w, paper_h = PAPER_SIZES[self.paper]
        return width <= paper_w + 1e-6 and height <= paper_h + 1e-6

    # --- rendering ------------------------------------------------------------------

    def render(self, pixels: NDArray[np.uint16], dpi: float | None = None) -> NDArray[np.uint16]:
        """What is sent to the printer: a toned, calibrated print, or (in negative mode)
        the negative through the process curve, with its safe edge at `dpi`."""
        if self.negative:
            if self.process is not None:
                pixels = self.process.apply(pixels)
            return make_negative(pixels, self._negative_settings(), dpi or self.effective_ppi())
        rgb = composite(pixels, PRESETS[self.preset])
        return self.calibration.apply(rgb) if self.calibration else rgb

    def preview(self, max_side: int = 900) -> NDArray[np.uint8]:
        """An 8-bit RGB preview of the toned photo (without calibration: what you'll see).

        The calibration corrects for the printer, so the print should look like this.
        """
        pixels = self._photo().pixels
        height, width = pixels.shape
        scale = min(1.0, max_side / max(height, width))
        if scale < 1.0:
            size = (max(1, round(width * scale)), max(1, round(height * scale)))
            image = Image.fromarray(pixels).resize(size, Image.Resampling.BILINEAR)
            pixels = np.asarray(image, dtype=np.uint16)
        if self.negative:  # the negative as it will look on the film
            shown = self.render(pixels, dpi=self.effective_ppi() * scale)
        else:
            shown = composite(pixels, PRESETS[self.preset])
        return (shown >> 8).astype(np.uint8)

    def summary(self) -> list[str]:
        """Lines for the print confirmation."""
        width, height = self.size_inches()
        calibration = self.calibration_path.name if self.calibration_path else "none"
        if self.negative:
            process = self.process_path.name if self.process_path else "none (uncalibrated)"
            return [
                f"Photo: {self.source.name if self.source else 'untitled'}",
                "Output: digital negative",
                f"Printer: {self.printer or 'not chosen'}",
                f"Paper: {self.paper}",
                f"Size: {width:.2f} x {height:.2f} in with a {self.safe_edge:g} in safe edge",
                f"Colour: {self.negative_colour}",
                f"Process curve: {process}",
                f"Mirrored: {'yes' if self.mirror else 'no'}",
            ]
        return [
            f"Photo: {self.source.name if self.source else 'untitled'}",
            f"Printer: {self.printer or 'not chosen'}",
            f"Paper: {self.paper}",
            f"Size: {width:.2f} x {height:.2f} in at {self.effective_ppi():.0f} ppi",
            f"Toning: {self.preset}",
            f"Calibration: {calibration}",
        ]

    # --- output ---------------------------------------------------------------------

    def write_print_file(self, path: str | Path) -> Path:
        """The full-resolution file to print: toned, calibrated, tagged with the print ppi."""
        ppi = self.effective_ppi()
        save_rgb(path, self.render(self._photo().pixels), (ppi, ppi), srgb_profile())
        return Path(path)

    def print_job(self, path: Path) -> PrintJob:
        if not self.printer:
            raise SessionError("choose a printer first")
        if not self.fits_on_paper():
            raise SessionError("the photo is larger than the paper at this size")
        title = f"OpenQuad: {self.source.name}" if self.source else "OpenQuad"
        return PrintJob(
            path=path, printer=self.printer, paper=self.paper, ppi=self.effective_ppi(),
            title=title,
        )  # fmt: skip

    def print(self, scratch: str | Path, runner: Runner = run_command) -> str:
        """Render to `scratch` folder and send to the printer; returns the CUPS job id."""
        if not self.printer:
            raise SessionError("choose a printer first")
        path = self.write_print_file(Path(scratch) / "openquad-print.tif")
        return send(self.print_job(path), runner)
