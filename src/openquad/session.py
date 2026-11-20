"""A print session: everything the print window shows and does, without any Qt.

The desktop app is a thin view over this class, so all the logic is tested the
same way as the rest of the core. Colour toning is never on by default: a new
session uses the neutral preset until the user picks another.
"""

from __future__ import annotations

from dataclasses import dataclass, field, replace
from pathlib import Path

import numpy as np
from numpy.typing import NDArray
from PIL import Image

from openquad import wedge as wedges
from openquad.chart import ProcessCurve, load_process
from openquad.colour_separations import ColourSeparation, hex_colour
from openquad.colour_separations import coat_image as colour_coat_image
from openquad.composite import DEFAULT_PRESET, PRESETS, composite
from openquad.greybalance import Calibration, load_calibration
from openquad.imageio import save_rgb, srgb_profile
from openquad.marks import PRINT_BORDER, add_print_marks
from openquad.negative import NEGATIVE_COLOURS, NegativeSettings, make_negative, negative_ppi
from openquad.paper import DEFAULT_MARGIN, PAPER_SIZES, box_ppi, fit_ppi, oriented, print_size
from openquad.photo import Photo, load_photo
from openquad.printing import PrintJob, Runner, run_command, send
from openquad.quadfile import MAX_VALUE
from openquad.separations import SeparationPlan, coat_image
from openquad.units import box, check, length, size

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
    # Driver options for printing straight to the printer (lp -o), e.g. its media type and
    # quality: {"CNIJMediaType": "28"}. The print panel has its own.
    printer_options: dict[str, str] = field(default_factory=dict)
    paper: str = "Letter"
    fit: bool = True
    margin: float = DEFAULT_MARGIN
    ppi: float | None = None  # used when fit is off; None = the photo's own DPI
    # With fit: also keep within this (width, height) in inches, turned to match the photo;
    # for a negative it is the outer edge, safe edge included (e.g. the carbon tissue's size).
    max_size: tuple[float, float] | None = None
    notes: list[str] = field(default_factory=list)
    # Digital negative mode: the photo becomes a negative for contact printing.
    mode: str = "print"  # "print" or "negative"
    negative_colour: str = "green"
    process: ProcessCurve | None = None
    process_path: Path | None = None
    mirror: bool = False
    safe_edge: float = 0.25
    outline: float = 0.0  # inches of black between the safe edge and the photo (0 = none)
    # Darkroom marks in black: in a negative's safe edge, or a white border round a print.
    guide: bool = False  # a guide line round the image
    registration: bool = False  # crosshair targets and corner crop marks
    # Step wedges beside the print, `wedge_gap` inches away on `wedge_side`: the 31-step grey
    # wedge (through the same toning, calibration or process curve as the photo), and for a
    # colour print a colour gamut wedge.
    wedge: bool = False
    colour_wedge: bool = False
    wedge_side: str = "bottom"
    wedge_gap: float = wedges.DEFAULT_GAP
    units: str = "in"  # how the summary shows lengths: "in" or "mm"
    # Separations: the photo split into several negatives by tone, printed one after another
    # in register on one sheet. None for a single negative. `layer` is the negative shown and
    # printed (0 = the lightest band); a negative can have its own process curve.
    separation: SeparationPlan | None = None
    layer: int = 0
    layer_processes: dict[int, ProcessCurve] = field(default_factory=dict)
    layer_process_paths: dict[int, Path] = field(default_factory=dict)
    # The coats curve: the whole stack of coats calibrated as one process (from a chart printed
    # through every negative), applied to the photo before it is split.
    coats_curve: ProcessCurve | None = None
    coats_curve_path: Path | None = None
    # Or the photo split by colour: one negative per coat of a coloured pigment, from the
    # photo's own colour. Only one of the two separations is set at a time.
    colour_separation: ColourSeparation | None = None
    # Print a colour photo in colour, on a colour-managed printer: its own colour and ICC
    # profile go to macOS, with no toning or calibration. Off (greyscale) for each new photo.
    colour_print: bool = False
    # Where a negative goes on the page: its outer top-left corner, in inches from the paper's
    # left and top edges, kept inside the margins. None = centred (as a print always is).
    placement: tuple[float, float] | None = None

    # --- choosing things ------------------------------------------------------------

    def open(self, path: str | Path) -> None:
        self.photo = load_photo(path)
        self.source = Path(path)
        self.notes = []
        self.colour_print = False
        if self.photo.cropped:
            self.notes.append("Transparent edges were cropped off.")
        if self.photo.converted:
            self.notes.append(
                "This is a colour image; it is converted to greyscale unless printed in colour."
            )

    def set_colour_print(self, on: bool) -> None:
        """Print the photo in its own colour (colour-managed), or in greyscale."""
        if on and (self.photo is None or self.photo.colour is None):
            raise SessionError("only a colour photo can be printed in colour")
        self.colour_print = on

    @property
    def prints_colour(self) -> bool:
        """The print is the photo's own colour: colour print on, in print mode."""
        return self.colour_print and not self.negative and self._colour() is not None

    def _colour(self) -> NDArray[np.uint16] | None:
        return self.photo.colour if self.photo is not None else None

    def set_units(self, units: str) -> None:
        self.units = check(units)

    def set_wedge_side(self, side: str) -> None:
        if side not in wedges.SIDES:
            raise SessionError(f"unknown side {side!r}; choose from {', '.join(wedges.SIDES)}")
        self.wedge_side = side

    def set_wedge_gap(self, gap: float) -> None:
        if not np.isfinite(gap) or not 0 <= gap <= wedges.MAX_GAP:
            raise SessionError(f"the gap must be 0 to {wedges.MAX_GAP:g} in, got {gap}")
        self.wedge_gap = gap

    @property
    def wedge_kinds(self) -> list[str]:
        """The wedges printed, nearest the print first: "grey", and "colour" on a colour print."""
        kinds = ["grey"] if self.wedge else []
        if self.colour_wedge and not self.negative and self.prints_colour:
            kinds.append("colour")
        return kinds

    def _wedge_extra(self) -> tuple[float, float]:
        border = self.safe_edge if self.negative else 0.0
        return wedges.extra(self.wedge_kinds, self._wedge_side(), self.wedge_gap, border)

    def _wedge_side(self) -> str:
        """The side as laid out before a negative is mirrored, so it prints on the side chosen."""
        flipped = {"left": "right", "right": "left"}
        return (
            flipped.get(self.wedge_side, self.wedge_side)
            if self.negative and self.mirror
            else self.wedge_side
        )

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

    def set_separation(self, plan: SeparationPlan | None) -> None:
        """Split the negative into `plan.count` negatives by tone (None or 1: just one)."""
        self.separation = plan if plan is not None and plan.count > 1 else None
        if self.separation is not None:
            self.colour_separation = None
        self._fit_layers()

    def set_colour_separation(self, separation: ColourSeparation | None) -> None:
        """Split the negative by colour, one negative per coat (None: no colour separation)."""
        self.colour_separation = separation
        if separation is not None:
            self.separation = None
        self._fit_layers()

    @property
    def negative_count(self) -> int:
        """How many negatives the photo is split into (1 without a separation)."""
        if self.colour_separation is not None:
            return self.colour_separation.count
        return self.separation.count if self.separation else 1

    @property
    def separated(self) -> bool:
        return self.negative_count > 1

    def _fit_layers(self) -> None:
        """Keep the shown negative and the negatives' own curves within the count."""
        count = self.negative_count
        self.layer = min(self.layer, count - 1)
        for k in [k for k in self.layer_processes if k >= count]:
            del self.layer_processes[k]
            del self.layer_process_paths[k]

    def set_layer(self, layer: int) -> None:
        count = self.negative_count
        if not 0 <= layer < count:
            raise SessionError(f"there is no negative {layer + 1} of {count}")
        self.layer = layer

    def set_layer_process(self, layer: int, path: str | Path | None) -> None:
        """Give one negative of the separation its own process curve (None: the shared one)."""
        count = self.negative_count
        if not 0 <= layer < count:
            raise SessionError(f"there is no negative {layer + 1} of {count}")
        if path is None:
            self.layer_processes.pop(layer, None)
            self.layer_process_paths.pop(layer, None)
            return
        self.layer_processes[layer] = load_process(path)
        self.layer_process_paths[layer] = Path(path)

    def set_coats_curve(self, path: str | Path | None) -> None:
        """Calibrate the stacked coats: a curve read from a chart printed through every
        negative (`openquad chart`), applied before splitting. None for none."""
        if path is None:
            self.coats_curve, self.coats_curve_path = None, None
            return
        self.coats_curve = load_process(path)
        self.coats_curve_path = Path(path)

    def layer_process(self, layer: int) -> ProcessCurve | None:
        """The process curve negative `layer` is made with: its own, or the shared one."""
        return self.layer_processes.get(layer, self.process)

    def _layer_process_name(self, layer: int) -> str:
        path = self.layer_process_paths.get(layer, self.process_path)
        return path.name if path else "none (uncalibrated)"

    @property
    def negative(self) -> bool:
        return self.mode == "negative"

    def _negative_settings(self, layer: int | None = None) -> NegativeSettings:
        separated = self.separated and layer is not None
        process = self.layer_process(layer) if separated and layer is not None else None
        return NegativeSettings(
            colour=process.colour if process else self.negative_colour,
            mirror=self.mirror,
            safe_edge=self.safe_edge,
            outline=self.outline,
            guide=self.guide,
            registration=self.registration,
            label=layer + 1 if separated and layer is not None else 0,
            clear_targets=separated,
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
        if self.fit:
            extra_w, extra_h = self._wedge_extra()
            if extra_w or extra_h:
                ppi = self._page_ppi(extra_w, extra_h)
            elif self._border:
                ppi = negative_ppi(*photo.size, self.paper, self._border, self.margin)
            else:
                ppi = fit_ppi(*photo.size, self.paper, self.margin)
            if self.max_size:  # smaller of the page and the box (never past the page)
                ppi = max(ppi, box_ppi(*photo.size, self.max_size, self._border))
            return ppi
        if self.ppi:
            return self.ppi
        return photo.dpi[0] if photo.dpi else FALLBACK_PPI

    def _page_ppi(self, extra_w: float, extra_h: float) -> float:
        """The resolution that fits the photo, its border and its wedges within the margins."""
        width, height = self._photo().size
        paper_w, paper_h = PAPER_SIZES[self.paper]
        room_w = paper_w - 2 * self.margin - 2 * self._border - extra_w
        room_h = paper_h - 2 * self.margin - 2 * self._border - extra_h
        if room_w <= 0 or room_h <= 0:
            raise SessionError(f"no room for the photo and its wedge on {self.paper}")
        return max(width / room_w, height / room_h)

    def size_inches(self) -> tuple[float, float]:
        width, height = print_size(*self._photo().size, self.effective_ppi())
        # A negative's safe edge, or a print's border for its marks, goes round the photo;
        # any wedges sit beside it.
        extra_w, extra_h = self._wedge_extra()
        return width + 2 * self._border + extra_w, height + 2 * self._border + extra_h

    def fits_on_paper(self) -> bool:
        width, height = self.size_inches()
        paper_w, paper_h = PAPER_SIZES[self.paper]
        return width <= paper_w + 1e-6 and height <= paper_h + 1e-6

    # --- placing a negative on the page ---------------------------------------------

    def set_placement(self, placement: tuple[float, float] | None) -> None:
        """Put the negative's top-left corner at (left, top) inches on the page; None centres it."""
        if placement is not None and not all(np.isfinite(placement)):
            raise SessionError(f"not a position on the page: {placement}")
        self.placement = placement

    @property
    def placed(self) -> bool:
        """A negative moved from the centre, with room to move inside the margins."""
        if not self.negative or self.placement is None:
            return False
        room_w, room_h = self._room()
        width, height = self.size_inches()
        return width <= room_w + 1e-6 and height <= room_h + 1e-6

    def _room(self) -> tuple[float, float]:
        paper_w, paper_h = PAPER_SIZES[self.paper]
        return paper_w - 2 * self.margin, paper_h - 2 * self.margin

    def page_position(self) -> tuple[float, float]:
        """Where the print's top-left corner lands: inches from the paper's left and top."""
        width, height = self.size_inches()
        paper_w, paper_h = PAPER_SIZES[self.paper]
        if not self.placed or self.placement is None:
            return (paper_w - width) / 2, (paper_h - height) / 2
        left, top = self.placement
        return (
            min(max(left, self.margin), paper_w - self.margin - width),
            min(max(top, self.margin), paper_h - self.margin - height),
        )

    def _on_page(self, image: NDArray[np.uint16], ppi: float) -> NDArray[np.uint16]:
        """The image on clear film filling the page inside its margins, at its position. That
        area prints centred on the page, so the negative lands where it was put."""
        room_w, room_h = self._room()
        height, width = image.shape[:2]
        page_w, page_h = max(round(room_w * ppi), width), max(round(room_h * ppi), height)
        left, top = self.page_position()
        x = min(max(round((left - self.margin) * ppi), 0), page_w - width)
        y = min(max(round((top - self.margin) * ppi), 0), page_h - height)
        page = np.full((page_h, page_w, image.shape[2]), MAX_VALUE, dtype=np.uint16)
        page[y : y + height, x : x + width] = image
        return page

    # --- rendering ------------------------------------------------------------------

    def render(self, pixels: NDArray[np.uint16], dpi: float | None = None) -> NDArray[np.uint16]:
        """What is sent to the printer: a toned, calibrated print, or (in negative mode)
        the negative through the process curve, with its safe edge at `dpi`."""
        if self.negative:
            return self.render_layer(pixels, self.layer, dpi)
        dpi = dpi or self.effective_ppi()
        rgb = composite(pixels, PRESETS[self.preset])
        rgb = self.calibration.apply(rgb) if self.calibration else rgb
        printed = add_print_marks(rgb, dpi, self.guide, self.registration)
        return self._with_print_wedges(printed, pixels.shape[:2], dpi, calibrated=True)

    def render_colour(
        self, rgb: NDArray[np.uint16], dpi: float | None = None
    ) -> NDArray[np.uint16]:
        """A colour print: the photo's own colour, untouched, with any darkroom marks and wedges."""
        dpi = dpi or self.effective_ppi()
        printed = add_print_marks(rgb, dpi, self.guide, self.registration)
        return self._with_print_wedges(printed, rgb.shape[:2], dpi, colour=True)

    def _with_print_wedges(
        self, image: NDArray[np.uint16], shape: tuple[int, ...], dpi: float,
        calibrated: bool = False, colour: bool = False,
    ) -> NDArray[np.uint16]:  # fmt: skip
        """A print with its wedges: the grey wedge toned (and calibrated) like the photo, or
        left neutral on a colour print, and the colour wedge."""
        horizontal = self.wedge_side in ("top", "bottom")
        length = shape[1] if horizontal else shape[0]
        made = []
        for kind in self.wedge_kinds:
            if kind == "grey":
                ramp = wedges.grey_wedge(
                    length, max(1, round(wedges.WEDGE_WIDTH * dpi)), horizontal
                )
                if colour:
                    made.append(np.stack([ramp] * 3, -1))
                    continue
                rgb = composite(ramp, PRESETS[self.preset])
                made.append(self.calibration.apply(rgb) if calibrated and self.calibration else rgb)
            else:
                row = max(1, round(wedges.COLOUR_ROW * dpi))
                made.append(wedges.colour_wedge(length, row, horizontal))
        return wedges.attach(image, made, self.wedge_side, round(self.wedge_gap * dpi))

    def render_print(self) -> NDArray[np.uint16]:
        """The full-resolution print: in colour, or rendered from the greyscale photo."""
        colour = self._colour()
        if self.prints_colour and colour is not None:
            return self.render_colour(colour)
        image = self.render(self._source())
        return self._on_page(image, self.effective_ppi()) if self.placed else image

    def _source(self) -> NDArray[np.uint16]:
        """The pixels negatives are made from: the photo's colour for a colour separation
        (its greyscale if it has none), otherwise its greyscale."""
        colour = self._colour()
        if self.negative and self.colour_separation is not None and colour is not None:
            return colour
        return self._photo().pixels

    def print_profile(self) -> bytes | None:
        """The ICC profile the print file carries: a colour print's own (sRGB if untagged)."""
        if self.prints_colour and self._photo().icc_profile:
            return self._photo().icc_profile
        return srgb_profile()

    def render_layer(
        self, pixels: NDArray[np.uint16], layer: int, dpi: float | None = None
    ) -> NDArray[np.uint16]:
        """Negative `layer` of the separation (any layer is the whole negative without one).
        `pixels` are greyscale, or 16-bit colour (height, width, 3) for a colour separation.
        A grey wedge is made into a negative the same way, with its own safe edge."""
        dpi = dpi or self.effective_ppi()
        settings = self._negative_settings(layer if self.separated else None)
        image = self._negative_layer(pixels, layer, dpi, settings)
        if not self.wedge:
            return image
        side = self._wedge_side()
        horizontal = side in ("top", "bottom")
        length = pixels.shape[1] if horizontal else pixels.shape[0]
        ramp = wedges.grey_wedge(length, max(1, round(wedges.WEDGE_WIDTH * dpi)), horizontal)
        if self.colour_separation is not None:
            ramp = np.stack([ramp] * 3, -1)
        bare = replace(settings, outline=0.0, guide=False, registration=False, mark=False,
                       label=0, clear_targets=False)  # fmt: skip
        wedge = self._negative_layer(ramp, layer, dpi, bare)
        return wedges.attach(image, [wedge], side, round(self.wedge_gap * dpi))

    def _negative_layer(
        self, pixels: NDArray[np.uint16], layer: int, dpi: float, settings: NegativeSettings
    ) -> NDArray[np.uint16]:
        if self.colour_separation is not None:
            pixels = colour_coat_image(pixels, self.colour_separation, layer)
            process = self.layer_process(layer)
        elif self.separation is None:
            if pixels.ndim == 3:
                raise SessionError("a colour photo makes negatives only for a colour separation")
            process = self.process
        else:
            if self.coats_curve is not None:
                pixels = self.coats_curve.apply(pixels)
            pixels = coat_image(pixels, self.separation, layer)
            process = self.layer_process(layer)
        if process is not None:
            pixels = process.apply(pixels)
        return make_negative(pixels, settings, dpi)

    def preview(self, max_side: int = 900) -> NDArray[np.uint8]:
        """An 8-bit RGB preview of the toned photo (without calibration: what you'll see).

        The calibration corrects for the printer, so the print should look like this.
        """
        pixels = self._photo().pixels
        height, width = pixels.shape
        scale = min(1.0, max_side / max(height, width))
        size = (max(1, round(width * scale)), max(1, round(height * scale)))

        def shrink(channel: NDArray[np.uint16]) -> NDArray[np.uint16]:
            if scale >= 1.0:
                return channel
            image = Image.fromarray(channel).resize(size, Image.Resampling.BILINEAR)
            return np.asarray(image, dtype=np.uint16)

        colour = self._colour()
        if self.prints_colour and colour is not None:  # in its own colour, not proofed
            rgb = np.stack([shrink(np.ascontiguousarray(colour[..., c])) for c in range(3)], -1)
            return (self.render_colour(rgb, self.effective_ppi() * scale) >> 8).astype(np.uint8)
        if self.negative:  # the negative as it will look on the film
            source = self._source()
            if source.ndim == 3:
                planes = [shrink(np.ascontiguousarray(source[..., c])) for c in range(3)]
                source = np.stack(planes, -1)
            else:
                source = shrink(source)
            shown = self.render(source, dpi=self.effective_ppi() * scale)
            return (shown >> 8).astype(np.uint8)
        small = shrink(pixels)
        dpi = self.effective_ppi() * scale
        toned = composite(small, PRESETS[self.preset])
        shown = add_print_marks(toned, dpi, self.guide, self.registration)
        shown = self._with_print_wedges(shown, small.shape, dpi)
        return (shown >> 8).astype(np.uint8)

    @property
    def _border(self) -> float:
        """Inches round the photo: in a negative the black outline plus the safe edge; in a
        print the white border carrying its darkroom marks (if any)."""
        if self.negative:
            return self.outline + self.safe_edge
        return PRINT_BORDER if self.guide or self.registration else 0.0

    def _wedge_lines(self) -> list[str]:
        where = {"top": "above", "bottom": "below", "left": "left of", "right": "right of"}[
            self.wedge_side
        ]
        thing = "negative" if self.negative else "print"
        names = {
            "grey": f"Step wedge: {wedges.WEDGE_STEPS} steps",
            "colour": f"Colour wedge: {wedges.WEDGE_STEPS} hues",
        }
        return [f"{names[kind]}, {where} the {thing}, {self._length(self.wedge_gap)} away"
                for kind in self.wedge_kinds]  # fmt: skip

    def _marks_line(self) -> list[str]:
        named = ((self.guide, "guide line"), (self.registration, "registration marks"))
        marks = [name for on, name in named if on]
        return [f"Darkroom marks: {' and '.join(marks)}"] if marks else []

    def _position_line(self) -> list[str]:
        if self.placement is None:
            return []
        if not self.placed:
            return ["Position: centred (no room to move it inside the margins)"]
        left, top = self.page_position()
        return [f"Position: {self._length(left)} from the left, {self._length(top)} from the top"]

    def _length(self, inches: float) -> str:
        return length(inches, self.units)

    def _within(self) -> list[str]:
        if not (self.fit and self.max_size):
            return []
        box_w, box_h = oriented(self.max_size, *self._photo().size)
        return [f"Fit within: {box(box_w, box_h, self.units)}"]

    def _separation_lines(self, process: str) -> list[str]:
        if self.colour_separation is not None:
            sep, k = self.colour_separation, self.layer
            return [
                f"Colour separation: {sep.describe()}",
                f"This negative: coat {k + 1} of {sep.count} ({hex_colour(sep.coats[k])})",
                f"Colour: {self._negative_settings(k).colour}",
                f"Process curve: {self._layer_process_name(k)}",
            ]
        if self.separation is None:
            return [f"Colour: {self.negative_colour}", f"Process curve: {process}"]
        plan, k = self.separation, self.layer
        lower, upper = plan.bands[k]
        colour = self._negative_settings(k).colour
        return [
            f"Separation: {plan.describe()}",
            f"This negative: {k + 1} of {plan.count} (steps {lower * plan.steps:g}-"
            f"{upper * plan.steps:g}, then full strength)",
            f"Colour: {colour}",
            f"Process curve: {self._layer_process_name(k)}",
            f"Coats curve: {self.coats_curve_path.name if self.coats_curve_path else 'none'}",
        ]

    def summary(self) -> list[str]:
        """Lines for the print confirmation."""
        width, height = self.size_inches()
        calibration = self.calibration_path.name if self.calibration_path else "none"
        if self.negative:
            process = self.process_path.name if self.process_path else "none (uncalibrated)"
            outline = f" and a {self._length(self.outline)} black outline" if self.outline else ""
            return [
                f"Photo: {self.source.name if self.source else 'untitled'}",
                "Output: digital negative",
                f"Printer: {self.printer or 'not chosen'}",
                f"Paper: {self.paper}",
                *self._within(),
                f"Size: {size(width, height, self.units)} with a {self._length(self.safe_edge)} "
                f"safe edge{outline}",
                *self._position_line(),
                *self._separation_lines(process),
                f"Mirrored: {'yes' if self.mirror else 'no'}",
                *self._marks_line(),
                *self._wedge_lines(),
            ]
        if self.prints_colour:
            embedded = self._photo().icc_profile is not None
            profile = "embedded in the photo" if embedded else "none (read as sRGB)"
            tones = ["Output: colour print (colour-managed by macOS)", f"Colour profile: {profile}"]
        else:
            tones = [f"Toning: {self.preset}", f"Calibration: {calibration}"]
        return [
            f"Photo: {self.source.name if self.source else 'untitled'}",
            f"Printer: {self.printer or 'not chosen'}",
            f"Paper: {self.paper}",
            *self._within(),
            f"Size: {size(width, height, self.units)} at {self.effective_ppi():.0f} ppi",
            *tones,
            *self._marks_line(),
            *self._wedge_lines(),
        ]

    # --- output ---------------------------------------------------------------------

    def write_print_file(self, path: str | Path) -> Path:
        """The full-resolution file to print, tagged with the print ppi: toned and calibrated
        (sRGB), or a colour print in the photo's own colour and profile."""
        ppi = self.effective_ppi()
        save_rgb(path, self.render_print(), (ppi, ppi), self.print_profile())
        return Path(path)

    def write_separations(self, folder: str | Path, stem: str | None = None) -> list[Path]:
        """Every negative of the separation as `<stem>-<k>of<n>.tif` in `folder`."""
        if not self.separated or not self.negative:
            raise SessionError("set up a separation of the negative first")
        stem = stem or (self.source.stem if self.source else "negative")
        ppi, count, source = self.effective_ppi(), self.negative_count, self._source()
        paths = []
        for k in range(count):
            path = Path(folder) / f"{stem}-{k + 1}of{count}.tif"
            negative = self.render_layer(source, k, ppi)
            save_rgb(path, negative, (ppi, ppi), srgb_profile())
            paths.append(path)
        return paths

    def print_job(self, path: Path) -> PrintJob:
        if not self.printer:
            raise SessionError("choose a printer first")
        if not self.fits_on_paper():
            raise SessionError("the photo is larger than the paper at this size")
        title = f"OpenQuad: {self.source.name}" if self.source else "OpenQuad"
        if self.negative and self.separated:
            title += f" (negative {self.layer + 1} of {self.negative_count})"
        return PrintJob(
            path=path, printer=self.printer, paper=self.paper, ppi=self.effective_ppi(),
            title=title, options=tuple(sorted(self.printer_options.items())),
        )  # fmt: skip

    def print(self, scratch: str | Path, runner: Runner = run_command) -> str:
        """Render to `scratch` folder and send to the printer; returns the CUPS job id."""
        if not self.printer:
            raise SessionError("choose a printer first")
        path = self.write_print_file(Path(scratch) / "openquad-print.tif")
        return send(self.print_job(path), runner)
