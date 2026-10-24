"""ChartThrob-style process calibration for digital negatives (Phase 7, step 3).

The chart follows ChartThrob's design (Kevin Bjorke's ChartThrob, original chart by
Thomas Howard; layout as in the ChartThrob GIMP port): a 10 x 10 grid of patches in
1% steps plus an extra black patch (101 tones), a 21-step strip and a gradient bar.
OpenQuad's version differs so that real carbon prints can be read reliably: the
background is clear film (it prints dark) with small gaps between patches, and it
has a marker square, a safe edge and an orientation F, as the blocking test does.

The chart is printed as a negative in the chosen colour, contact printed (carbon),
and the print is scanned. The 101 measured patches give the process's response;
the process curve reshapes a photo's tones so the print lands on target: each grey
level at its sRGB lightness, scaled between the process's black and white.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path

import numpy as np
from numpy.typing import NDArray

from openquad.blocking import (
    MARKER_CONTRAST,
    BlockingError,
    _deskew,
    _find_sheet,
    _fit_layout,
    _marker_contrast,
    _safe_edge_lightness,
    _view,
)
from openquad.colour import linear_rgb_to_lab, srgb_to_linear
from openquad.linearize import target_lightness
from openquad.negative import NEGATIVE_COLOURS, NegativeSettings, make_negative
from openquad.quadfile import MAX_VALUE

PATCHES = 101  # 0% .. 100% in 1% steps
STRIP = 21
PROCESS_FORMAT = "openquad-process"


@dataclass(frozen=True)
class ChartLayout:
    """Sizes in inches, inside the safe edge."""

    patch: float = 0.36
    gap: float = 0.06
    marker: float = 0.3
    strip_width: float = 0.4
    gradient_width: float = 0.3

    @property
    def grid_left(self) -> float:
        return self.gap * 2

    @property
    def grid_top(self) -> float:
        return 3 * self.gap + self.marker

    @property
    def grid_width(self) -> float:
        return 10 * self.patch + 9 * self.gap

    @property
    def grid_height(self) -> float:
        return 11 * self.patch + 10 * self.gap

    @property
    def strip_left(self) -> float:
        return self.grid_left + self.grid_width + 3 * self.gap

    @property
    def gradient_left(self) -> float:
        return self.strip_left + self.strip_width + 2 * self.gap

    @property
    def width(self) -> float:
        return self.gradient_left + self.gradient_width + 2 * self.gap

    @property
    def height(self) -> float:
        return self.grid_top + self.grid_height + 2 * self.gap

    def marker_box(self) -> tuple[float, float, float, float]:
        return (self.gap * 2, self.gap * 2, self.gap * 2 + self.marker, self.gap * 2 + self.marker)

    def patch_box(self, n: int) -> tuple[float, float, float, float]:
        """Patch n (0 = white print .. 100 = black print), row by row; 100 sits alone in row 10."""
        row, column = divmod(n, 10)
        left = self.grid_left + column * (self.patch + self.gap)
        top = self.grid_top + row * (self.patch + self.gap)
        return (left, top, left + self.patch, top + self.patch)

    def strip_box(self, step: int) -> tuple[float, float, float, float]:
        height = self.grid_height / STRIP
        top = self.grid_top + step * height
        return (self.strip_left, top, self.strip_left + self.strip_width, top + height)

    def gradient_box(self) -> tuple[float, float, float, float]:
        return (
            self.gradient_left,
            self.grid_top,
            self.gradient_left + self.gradient_width,
            self.grid_top + self.grid_height,
        )


def patch_level(n: int) -> int:
    """The photo grey level (0 black .. 65535 white) of patch n: 0 is white, 100 black."""
    return round(MAX_VALUE * (1 - n / (PATCHES - 1)))


def chart_photo(layout: ChartLayout | None = None, dpi: float = 300.0) -> NDArray[np.uint16]:
    """The chart as the photo it stands for (before inversion): black background,
    the 101 patches, the 21-step strip, the gradient and a white marker."""
    layout = layout or ChartLayout()

    def px(box: tuple[float, float, float, float]) -> tuple[slice, slice]:
        l, t, r, b = (round(v * dpi) for v in box)  # noqa: E741
        return slice(t, b), slice(l, r)

    photo = np.zeros((round(layout.height * dpi), round(layout.width * dpi)), dtype=np.uint16)
    photo[px(layout.marker_box())] = MAX_VALUE  # prints white: full ink on the film
    for n in range(PATCHES):
        photo[px(layout.patch_box(n))] = patch_level(n)
    for step in range(STRIP):
        photo[px(layout.strip_box(step))] = round(MAX_VALUE * (1 - step / (STRIP - 1)))
    rows, columns = px(layout.gradient_box())
    height = rows.stop - rows.start
    ramp = np.rint(np.linspace(MAX_VALUE, 0, height)).astype(np.uint16)
    photo[rows, columns] = ramp[:, np.newaxis]
    return photo


def chart_negative(
    colour: str = "green",
    process: ProcessCurve | None = None,
    mirror: bool = False,
    dpi: float = 300.0,
    layout: ChartLayout | None = None,
) -> NDArray[np.uint16]:
    """The chart printed as a negative, through `process` if given (to check or refine it)."""
    photo = chart_photo(layout, dpi)
    if process is not None:
        photo = process.apply(photo)
    return make_negative(photo, NegativeSettings(colour=colour, mirror=mirror), dpi)


# --- reading the carbon print --------------------------------------------------------


@dataclass(frozen=True)
class ChartReading:
    levels: NDArray[np.uint16]  # photo level of each patch (as designed, before any curve)
    lightness: NDArray[np.float64]  # measured L* of each patch
    strip: NDArray[np.float64]  # measured L* of the 21 steps
    orientation: str
    paper: float

    @property
    def black(self) -> float:
        return float(self.lightness.min())

    @property
    def white(self) -> float:
        return float(self.lightness.max())


def _points(layout: ChartLayout) -> tuple[list[tuple[float, float]], list[tuple[float, float]]]:
    """(clear-film spots, heavily inked spots) for fitting the layout to a print."""
    dark = []
    for n in range(PATCHES - 1):  # gaps right of and below each patch
        l, t, r, b = layout.patch_box(n)  # noqa: E741
        dark.append((r + layout.gap / 2, (t + b) / 2))
        dark.append(((l + r) / 2, b + layout.gap / 2))
    l, t, r, b = layout.patch_box(PATCHES - 1)  # noqa: E741
    dark.append(((l + r) / 2, (t + b) / 2))  # the black patch prints like clear film
    for n in range(1, 10):  # the rest of row 10 is background
        dark.append(((l + r) / 2 + n * (layout.patch + layout.gap), (t + b) / 2))
    light = []
    for n in range(0, 30):
        l, t, r, b = layout.patch_box(n)  # noqa: E741
        light.append(((l + r) / 2, (t + b) / 2))
    return dark, light


def read_chart(scan: NDArray[np.float64], layout: ChartLayout | None = None) -> ChartReading:
    """Measure every patch of a scanned print of the chart (any way up, tilted, mirrored)."""
    layout = layout or ChartLayout()
    lightness = linear_rgb_to_lab(srgb_to_linear(scan))[..., 0]
    rough = _find_sheet(lightness, layout.width / layout.height)
    lightness, tilt = _deskew(lightness, rough)
    dark, light = _points(layout)
    box, fit, score = _fit_layout(lightness, rough, layout, dark, light)
    view = _view(lightness, box, fit)
    if score < 2 * MARKER_CONTRAST or _marker_contrast(view, layout) < MARKER_CONTRAST:
        raise BlockingError("couldn't find the chart's marker; is the whole chart on the scan?")
    h, w = view.shape
    if 0.36 * w / layout.width < 10:
        raise BlockingError("the patches are too small to read; scan at a higher resolution")

    def sample(patch_box: tuple[float, float, float, float]) -> float:
        l, t, r, b = patch_box  # noqa: E741
        sx, sy = w / layout.width, h / layout.height
        cx, cy, hw, hh = (l + r) / 2 * sx, (t + b) / 2 * sy, (r - l) * sx / 4, (b - t) * sy / 4
        return float(
            np.median(view[round(cy - hh) : round(cy + hh), round(cx - hw) : round(cx + hw)])
        )

    from openquad.blocking import _orientation_name

    return ChartReading(
        levels=np.array([patch_level(n) for n in range(PATCHES)], dtype=np.uint16),
        lightness=np.array([sample(layout.patch_box(n)) for n in range(PATCHES)]),
        strip=np.array([sample(layout.strip_box(s)) for s in range(STRIP)]),
        orientation=_orientation_name(*fit) + (f", tilted {tilt:+.1f}°" if tilt else ""),
        paper=_safe_edge_lightness(lightness, box, w / layout.width),
    )


# --- the process curve ---------------------------------------------------------------


@dataclass(frozen=True, eq=False)
class ProcessCurve:
    """Photo grey level in (0-65535) -> level to make the negative from."""

    levels: NDArray[np.uint16]
    curve: NDArray[np.uint16]
    colour: str = "green"
    process: str = "carbon"
    film: str = ""
    printing: str = ""
    created: str = field(default_factory=lambda: datetime.now(UTC).isoformat(timespec="seconds"))

    def __post_init__(self) -> None:
        if self.colour not in NEGATIVE_COLOURS:
            raise ValueError(f"unknown negative colour {self.colour!r}")
        if self.levels.shape != self.curve.shape or len(self.levels) < 2:
            raise ValueError("levels and curve must be the same length (at least 2)")
        if np.any(np.diff(self.levels.astype(int)) <= 0):
            raise ValueError("levels must be strictly ascending")

    @classmethod
    def identity(cls, colour: str = "green") -> ProcessCurve:
        levels = np.rint(np.linspace(0, MAX_VALUE, 257)).astype(np.uint16)
        return cls(levels=levels, curve=levels.copy(), colour=colour)

    def apply(self, photo: NDArray[np.uint16]) -> NDArray[np.uint16]:
        lut = np.rint(
            np.interp(np.arange(MAX_VALUE + 1), self.levels, self.curve.astype(np.float64))
        ).astype(np.uint16)
        result: NDArray[np.uint16] = lut[photo]
        return result

    def to_json(self) -> str:
        return json.dumps(
            {
                "format": PROCESS_FORMAT,
                "version": 1,
                "process": self.process,
                "colour": self.colour,
                "film": self.film,
                "printing": self.printing,
                "created": self.created,
                "levels": self.levels.tolist(),
                "curve": self.curve.tolist(),
            },
            indent=1,
        )

    @classmethod
    def from_json(cls, text: str) -> ProcessCurve:
        try:
            data = json.loads(text)
        except json.JSONDecodeError as exc:
            raise ValueError(f"not valid JSON: {exc}") from None
        if not isinstance(data, dict) or data.get("format") != PROCESS_FORMAT:
            raise ValueError("not an OpenQuad process curve")
        return cls(
            levels=np.array(data["levels"], dtype=np.uint16),
            curve=np.array(data["curve"], dtype=np.uint16),
            colour=data.get("colour", "green"),
            process=data.get("process", "carbon"),
            film=data.get("film", ""),
            printing=data.get("printing", ""),
            created=data.get("created", ""),
        )


def tone_errors(reading: ChartReading) -> NDArray[np.float64]:
    """Measured minus target L* for each patch (target: sRGB lightness scaled to the process)."""
    target = target_lightness(reading.levels.astype(np.float64), reading.white, reading.black)
    result: NDArray[np.float64] = reading.lightness - target
    return result


def build_process_curve(
    reading: ChartReading,
    previous: ProcessCurve | None = None,
    *,
    film: str = "",
    printing: str = "",
) -> ProcessCurve:
    """The curve that puts each grey level on target, from a reading of a chart printed
    through `previous` (default: no curve). Each pass uses what was actually sent."""
    previous = previous or ProcessCurve.identity()
    sent = previous.apply(reading.levels).astype(np.float64)
    order = np.argsort(sent, kind="stable")
    x, measured = sent[order], reading.lightness[order]
    # More ink (a lighter photo level) must never print darker; tiny ramp keeps it invertible.
    response = np.maximum.accumulate(measured) + np.arange(len(measured)) * 1e-6
    if response[-1] - response[0] < 10:
        raise ValueError("the patches barely differ; check the exposure and the scan")
    grid = np.rint(np.linspace(0, MAX_VALUE, 257)).astype(np.uint16)
    wanted = target_lightness(grid.astype(np.float64), reading.white, reading.black)
    curve = np.interp(wanted, response, x)
    curve[0], curve[-1] = x[0], x[-1]
    curve = np.maximum.accumulate(np.clip(curve, 0, MAX_VALUE))
    return ProcessCurve(
        levels=grid,
        curve=np.rint(curve).astype(np.uint16),
        colour=previous.colour,
        film=film or previous.film,
        printing=printing or previous.printing,
    )


def load_process(path: str | Path) -> ProcessCurve:
    return ProcessCurve.from_json(Path(path).read_text(encoding="utf-8"))


def save_process(curve: ProcessCurve, path: str | Path) -> None:
    Path(path).write_text(curve.to_json() + "\n", encoding="utf-8")
