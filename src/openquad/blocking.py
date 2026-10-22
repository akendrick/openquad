"""Blocking-colour test for digital negatives (Phase 7, step 2).

The sheet is printed as a negative on film. Each row is one candidate ink
colour: a full-strength patch, then an 11-step wedge from 100% down to 0% ink
(so each row ends in clear film, which keeps the orientation check unambiguous). You
expose it on carbon tissue (or any contact process) at your usual time and scan
the finished print. Where an ink blocks the light fully, the print stays paper
white; the wedge shows how long a tonal range each colour gives.

Layout, inside the safe edge (inches): a label column on the left with an opaque
marker square at its top (it prints paper white, and tells the analysis which
way up and which way round the scan is), then one row per colour. Everything
not inked is clear film, so it prints at the process's maximum density.
"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass

import numpy as np
from numpy.typing import NDArray
from PIL import Image, ImageDraw, ImageFont

from openquad.colour import linear_rgb_to_lab, srgb_to_linear
from openquad.negative import NEGATIVE_COLOURS, NegativeSettings, add_safe_edge, ink_to_rgb
from openquad.quadfile import MAX_VALUE

STEPS = 11  # 0%, 10%, ... 100% ink
FULL_BLOCK_DELTA = 3.0  # within this many L* of paper white = blocks fully
DISTINCT_STEP = 1.5  # wedge steps at least this far apart in L* count as usable
MIN_STEP_PIXELS = 12  # a wedge patch must be at least this wide in the scan
MARKER_CONTRAST = 10.0  # L* by which the marker must outshine the other candidate spots


class BlockingError(ValueError):
    """The scan couldn't be read as a blocking-test print."""


@dataclass(frozen=True)
class BlockingLayout:
    colours: tuple[str, ...] = tuple(NEGATIVE_COLOURS)
    label_width: float = 1.0
    marker: float = 0.3
    full_width: float = 0.6
    step_width: float = 0.35
    row_height: float = 0.45
    gap: float = 0.12

    @property
    def width(self) -> float:
        return (
            self.label_width
            + self.gap
            + self.full_width
            + self.gap
            + STEPS * self.step_width
            + self.gap
        )

    @property
    def height(self) -> float:
        return self.gap + self.marker + self.gap + len(self.colours) * (self.row_height + self.gap)

    def row_top(self, row: int) -> float:
        return 2 * self.gap + self.marker + row * (self.row_height + self.gap)

    def full_box(self, row: int) -> tuple[float, float, float, float]:
        left = self.label_width + self.gap
        top = self.row_top(row)
        return (left, top, left + self.full_width, top + self.row_height)

    def step_box(self, row: int, step: int) -> tuple[float, float, float, float]:
        left = self.label_width + 2 * self.gap + self.full_width + step * self.step_width
        top = self.row_top(row)
        return (left, top, left + self.step_width, top + self.row_height)

    def marker_box(self) -> tuple[float, float, float, float]:
        return (self.gap, self.gap, self.gap + self.marker, self.gap + self.marker)


def blocking_sheet(
    layout: BlockingLayout | None = None,
    dpi: float = 300.0,
    mirror: bool = False,
    safe_edge: float = 0.25,
) -> NDArray[np.uint16]:
    """The test sheet as a negative: (H, W, 3) uint16 sRGB, clear film = 65535."""
    layout = layout or BlockingLayout()
    for name in layout.colours:
        if name not in NEGATIVE_COLOURS:
            raise BlockingError(f"unknown colour {name!r}")

    def px(box: tuple[float, float, float, float]) -> tuple[slice, slice]:
        l, t, r, b = (round(v * dpi) for v in box)  # noqa: E741
        return slice(t, b), slice(l, r)

    height, width = round(layout.height * dpi), round(layout.width * dpi)
    sheet = np.full((height, width, 3), MAX_VALUE, dtype=np.uint16)  # clear film
    sheet[px(layout.marker_box())] = 0  # opaque marker
    for row, name in enumerate(layout.colours):
        colour = NEGATIVE_COLOURS[name]
        sheet[px(layout.full_box(row))] = ink_to_rgb(np.ones(1), colour)[0]
        for step in range(STEPS):
            coverage = np.array([1.0 - step / (STEPS - 1)])  # 100% next to the full patch
            sheet[px(layout.step_box(row, step))] = ink_to_rgb(coverage, colour)[0]
    _draw_labels(sheet, layout, dpi)
    settings = NegativeSettings(mirror=mirror, safe_edge=safe_edge)
    return add_safe_edge(sheet, settings, dpi)


def _draw_labels(sheet: NDArray[np.uint16], layout: BlockingLayout, dpi: float) -> None:
    """Colour names in black ink in the label column (they print paper white)."""
    height, width = sheet.shape[:2]
    mask = Image.new("L", (width, height), 0)
    draw = ImageDraw.Draw(mask)
    font = ImageFont.load_default(size=max(8, round(layout.row_height * dpi * 0.4)))
    for row, name in enumerate(layout.colours):
        x = round(layout.gap * dpi)
        y = round((layout.row_top(row) + layout.row_height * 0.25) * dpi)
        draw.text((x, y), name, fill=255, font=font)
    sheet[np.asarray(mask) > 127] = 0


# --- reading the scanned print -------------------------------------------------------


@dataclass(frozen=True)
class ColourResult:
    name: str
    full: float  # L* of the full-strength patch
    wedge: tuple[float, ...]  # L* from 0% to 100% ink
    paper: float  # L* of paper white

    @property
    def blocks_fully(self) -> bool:
        return self.paper - self.full <= FULL_BLOCK_DELTA

    @property
    def tonal_range(self) -> float:
        """L* from clear film (0% ink) to full ink."""
        return self.wedge[-1] - self.wedge[0]

    @property
    def usable_steps(self) -> int:
        """Wedge steps that differ from the previous kept one by at least DISTINCT_STEP L*."""
        kept, last = 1, self.wedge[0]
        for value in self.wedge[1:]:
            if value - last >= DISTINCT_STEP:
                kept, last = kept + 1, value
        return kept


@dataclass(frozen=True)
class BlockingReport:
    results: tuple[ColourResult, ...]
    orientation: str  # how the scan was turned to read it

    def best(self) -> ColourResult | None:
        """The fully blocking colour with the most usable steps (longest range on ties)."""
        blocking = [r for r in self.results if r.blocks_fully]
        if not blocking:
            return None
        return max(blocking, key=lambda r: (r.usable_steps, r.tonal_range))

    def lines(self) -> list[str]:
        out = [f"{'colour':<8} {'full L*':>8} {'blocks':>7} {'range':>6} {'steps':>6}"]
        for r in self.results:
            out.append(
                f"{r.name:<8} {r.full:8.1f} {'yes' if r.blocks_fully else 'no':>7} "
                f"{r.tonal_range:6.1f} {r.usable_steps:>4}/{STEPS}"
            )
        best = self.best()
        if best:
            out.append(
                f"Best: {best.name} ({best.usable_steps} usable steps, {best.tonal_range:.1f} L*)"
            )
        else:
            out.append(
                "No colour blocked fully: this ink and film can't reach paper white at this "
                "exposure. Try a shorter exposure, more sensitizer, or denser film (Pictorico)."
            )
        return out


# How a scan may be turned relative to the sheet: (description, row step, column step).
ORIENTATIONS: tuple[tuple[str, int, int], ...] = (
    ("as scanned", 1, 1),
    ("turned 180°", -1, -1),
    ("mirrored", 1, -1),
    ("mirrored and turned 180°", -1, 1),
)


def _lightness(scan: NDArray[np.float64]) -> NDArray[np.float64]:
    result: NDArray[np.float64] = linear_rgb_to_lab(srgb_to_linear(scan))[..., 0]
    return result


def analyse(scan: NDArray[np.float64], layout: BlockingLayout | None = None) -> BlockingReport:
    """Read a scanned print of the blocking sheet (encoded sRGB floats, (H, W, 3))."""
    layout = layout or BlockingLayout()
    lightness = _lightness(scan)
    paper = float(np.percentile(lightness, 99))
    dark = lightness < paper - 20
    if dark.sum() < 0.01 * dark.size:
        raise BlockingError("no exposed area found; is this a scan of the exposed print?")
    rows, cols = dark.sum(axis=1), dark.sum(axis=0)
    top, bottom = (int(i) for i in np.flatnonzero(rows >= 0.3 * rows.max())[[0, -1]])
    left, right = (int(i) for i in np.flatnonzero(cols >= 0.3 * cols.max())[[0, -1]])
    area = scan[top : bottom + 1, left : right + 1]
    ratio = (area.shape[1] / area.shape[0]) / (layout.width / layout.height)
    if abs(ratio - 1) > 0.06:
        raise BlockingError(
            f"the exposed area's shape doesn't match the sheet ({ratio:.2f}x); "
            "check the whole sheet is on the scan and placed square"
        )

    if layout.step_width * area.shape[1] / layout.width < MIN_STEP_PIXELS:
        raise BlockingError("the patches are too small to read; scan at a higher resolution")

    def sample(region: NDArray[np.float64], box: tuple[float, float, float, float]) -> float:
        h, w = region.shape[:2]
        sx, sy = w / layout.width, h / layout.height
        l, t, r, b = box  # noqa: E741
        cx, cy, hw, hh = (l + r) / 2 * sx, (t + b) / 2 * sy, (r - l) * sx / 4, (b - t) * sy / 4
        patch = region[round(cy - hh) : round(cy + hh), round(cx - hw) : round(cx + hw)]
        if patch.size == 0:
            raise BlockingError("patches too small to read; scan at a higher resolution")
        return float(np.median(_lightness(patch)))

    # The marker is the most-blocking spot on the sheet: of the four places it could be
    # (depending on how the print was turned), it is the clearly lightest one. Relative,
    # so an over-exposed print, where even the marker leaks, is still read.
    candidates = [
        (sample(area[::row_step, ::col_step], layout.marker_box()), name, row_step, col_step)
        for name, row_step, col_step in ORIENTATIONS
    ]
    candidates.sort(reverse=True)
    (lightest, orientation, row_step, col_step), runner_up = candidates[0], candidates[1][0]
    if lightest - runner_up < MARKER_CONTRAST:
        raise BlockingError("couldn't find the marker square; is the sheet fully on the scan?")
    region = area[::row_step, ::col_step]
    results = tuple(
        ColourResult(
            name=name,
            full=sample(region, layout.full_box(row)),
            wedge=tuple(sample(region, layout.step_box(row, s)) for s in reversed(range(STEPS))),
            paper=paper,
        )
        for row, name in enumerate(layout.colours)
    )
    return BlockingReport(results=results, orientation=orientation)


def colours_from(names: Sequence[str] | None) -> tuple[str, ...]:
    return tuple(names) if names else tuple(NEGATIVE_COLOURS)
