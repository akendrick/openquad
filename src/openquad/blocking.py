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
ERODE = 3  # px (on a ~500 px working copy) of shrinking before finding the sheet
EDGE_LEAK = 10.0  # safe edge this much darker than bare paper = even opaque ink let light through


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
    paper: float = 100.0  # L* of bare paper on the scan
    edge: float = 100.0  # L* of the safe edge
    white: float = 100.0  # L* of the best-blocked area: the process's own white

    @property
    def edge_leaks(self) -> bool:
        """Even the best blocker printed well below paper white: the exposure was too long."""
        return self.paper - self.white > EDGE_LEAK

    @property
    def safe_edge_leaks(self) -> bool:
        """The (black) safe edge let noticeably more light through than the best blocker."""
        return self.white - self.edge > FULL_BLOCK_DELTA

    def best(self) -> ColourResult | None:
        """The fully blocking colour with the most usable steps (longest range on ties)."""
        if self.edge_leaks:
            return None
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
        out.append(
            f"Process white (best blocker) L* {self.white:.1f}; bare paper L* {self.paper:.1f} "
            f"(difference {self.paper - self.white:.1f}; tissue stain is normally a few L*)"
        )
        if self.safe_edge_leaks and not self.edge_leaks:
            out.append(
                f"The black safe edge leaked (L* {self.edge:.1f}): print safe edges in the best "
                "blocking colour."
            )
        best = self.best()
        if self.edge_leaks:
            out.append(
                "Even the best-blocking ink let light through: the exposure was too long for this "
                "film and ink. Try a shorter exposure, then repeat the test."
            )
        elif best:
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


def _dark_regions(dark: NDArray[np.bool_]) -> list[tuple[int, int, int, int, int, bool]]:
    """Connected dark regions as (pixels, top, left, bottom, right, touches the border)."""
    from collections import deque

    height, width = dark.shape
    seen = np.zeros_like(dark)
    regions = []
    for start in zip(*np.nonzero(dark), strict=True):
        if seen[start]:
            continue
        seen[start] = True
        queue = deque([start])
        count, top, left, bottom, right = 0, start[0], start[1], start[0], start[1]
        while queue:
            y, x = queue.popleft()
            count += 1
            top, bottom, left, right = min(top, y), max(bottom, y), min(left, x), max(right, x)
            for ny, nx in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
                if 0 <= ny < height and 0 <= nx < width and dark[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True
                    queue.append((ny, nx))
        touches = top == 0 or left == 0 or bottom == height - 1 or right == width - 1
        regions.append((count, top, left, bottom, right, touches))
    return regions


def _find_sheet(lightness: NDArray[np.float64], aspect: float = 0.0) -> tuple[int, int, int, int]:
    """(top, left, bottom, right) of the sheet's exposed inner area.

    That area is clear film, so it prints dark, and the light safe edge encloses it.
    Of the dark regions that don't reach the scan's border, it is the one shaped like
    the sheet (`aspect` = width / height, either way round); an exposed field of tissue
    around the negative is a different shape.
    """
    light, deep = np.percentile(lightness, [98, 2])
    if light - deep < 20:
        raise BlockingError("no exposed area found; is this a scan of the exposed print?")
    step = max(1, round(max(lightness.shape) / 500))
    small = lightness[::step, ::step] < (light + deep) / 2
    # Shrink the dark areas first, so thin dark lines (ink drips, scratches, tape gaps)
    # crossing the safe edge don't join the sheet to the exposed tissue around it.
    shrunk = _erode(small, ERODE)
    inside = [r for r in _dark_regions(shrunk) if not r[5] and r[0] >= 0.01 * small.size]
    if not inside:
        raise BlockingError(
            "couldn't find the sheet inside a light safe edge; is the whole sheet on the scan?"
        )

    def shape_error(region: tuple[int, int, int, int, int, bool]) -> float:
        if not aspect:
            return 0.0
        _, top, left, bottom, right, _ = region
        found = (right - left + 1) / (bottom - top + 1)
        return min(abs(found / aspect - 1), abs(found * aspect - 1))

    _, top, left, bottom, right, _ = min(inside, key=lambda r: (round(shape_error(r), 2), -r[0]))
    top, left = max(top - ERODE, 0), max(left - ERODE, 0)
    bottom, right = min(bottom + ERODE, small.shape[0] - 1), min(right + ERODE, small.shape[1] - 1)
    return top * step, left * step, (bottom + 1) * step, (right + 1) * step


def _erode(mask: NDArray[np.bool_], radius: int) -> NDArray[np.bool_]:
    """Keep only pixels whose whole (2r+1)-square neighbourhood is set."""
    out = mask.copy()
    padded = np.pad(mask, radius, constant_values=False)
    h, w = mask.shape
    for dy in range(2 * radius + 1):
        for dx in range(2 * radius + 1):
            out &= padded[dy : dy + h, dx : dx + w]
    return out


def analyse(scan: NDArray[np.float64], layout: BlockingLayout | None = None) -> BlockingReport:
    """Read a scanned print of the blocking sheet (encoded sRGB floats, (H, W, 3)).

    The print may be turned any way (including 90 degrees) or mirrored, and the
    tissue may extend past the negative. Patches are judged against the safe edge,
    the most-blocked area, since the process's white (stained tissue) is often not
    the paper's white.
    """
    layout = layout or BlockingLayout()
    lightness = _lightness(scan)
    expected_aspect = layout.width / layout.height
    top, left, bottom, right = _find_sheet(lightness, expected_aspect)
    area = scan[top:bottom, left:right]
    expected = layout.width / layout.height
    turned = ""
    if abs((area.shape[0] / area.shape[1]) / expected - 1) < abs(
        (area.shape[1] / area.shape[0]) / expected - 1
    ):
        area, turned = np.rot90(area), "turned 90°, "
    ratio = (area.shape[1] / area.shape[0]) / expected
    if abs(ratio - 1) > 0.06:
        raise BlockingError(
            f"the exposed area's shape doesn't match the sheet ({ratio:.2f}x); "
            "check the whole sheet is on the scan and placed square"
        )
    per_inch = max(area.shape) / layout.width
    paper = _safe_edge_lightness(lightness, (top, left, bottom, right), per_inch)

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
    if turned:
        orientation = "sideways, mirrored" if "mirrored" in orientation else "sideways"
    fulls = [sample(region, layout.full_box(row)) for row in range(len(layout.colours))]
    process_white = max([paper, *fulls])  # the best blocker: the process's own white
    results = tuple(
        ColourResult(
            name=name,
            full=fulls[row],
            wedge=tuple(sample(region, layout.step_box(row, s)) for s in reversed(range(STEPS))),
            paper=process_white,
        )
        for row, name in enumerate(layout.colours)
    )
    paper_white = float(np.percentile(lightness, 99))
    return BlockingReport(
        results=results,
        orientation=orientation,
        paper=paper_white,
        edge=paper,
        white=process_white,
    )


def _safe_edge_lightness(
    lightness: NDArray[np.float64], box: tuple[int, int, int, int], per_inch: float
) -> float:
    """Median L* of the safe edge: thin bands just outside the inner area on all sides."""
    top, left, bottom, right = box
    near, far = round(0.06 * per_inch), round(0.14 * per_inch)
    h, w = lightness.shape
    cy0, cy1 = top + (bottom - top) // 4, bottom - (bottom - top) // 4
    cx0, cx1 = left + (right - left) // 4, right - (right - left) // 4
    bands = [
        lightness[max(top - far, 0) : max(top - near, 0), cx0:cx1],
        lightness[min(bottom + near, h) : min(bottom + far, h), cx0:cx1],
        lightness[cy0:cy1, max(left - far, 0) : max(left - near, 0)],
        lightness[cy0:cy1, min(right + near, w) : min(right + far, w)],
    ]
    values = np.concatenate([b.ravel() for b in bands if b.size])
    if values.size == 0:
        raise BlockingError("no safe edge around the sheet on the scan")
    return float(np.median(values))


def colours_from(names: Sequence[str] | None) -> tuple[str, ...]:
    return tuple(names) if names else tuple(NEGATIVE_COLOURS)
