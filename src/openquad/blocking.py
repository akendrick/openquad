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
from typing import Protocol

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
NEAR_SQUARE = 0.15  # sheets within this of square are tried in every orientation
MAX_TILT = 6.0  # degrees of tilt on the scanner that are corrected
MARKER_SLACK = 0.12  # inches the marker may sit off its nominal spot
EDGE_REACH = 0.04  # fraction of the box size searched when pinning each edge
ERODE = 3  # px (on a ~500 px working copy) of shrinking before finding the sheet
EDGE_LEAK = 10.0  # safe edge this much darker than bare paper = even opaque ink let light through


class SheetSpec(Protocol):
    """What the print reader needs to know about a sheet (sizes in inches)."""

    @property
    def width(self) -> float: ...

    @property
    def height(self) -> float: ...

    @property
    def gap(self) -> float: ...

    def marker_box(self) -> tuple[float, float, float, float]: ...


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
    h, w = small.shape

    def reaches_border(r: tuple[int, int, int, int, int, bool]) -> bool:
        # The shrinking pulled regions ERODE px away from the border: allow for it.
        return r[1] <= ERODE or r[2] <= ERODE or r[3] >= h - 1 - ERODE or r[4] >= w - 1 - ERODE

    inside = [
        r for r in _dark_regions(shrunk) if not reaches_border(r) and r[0] >= 0.01 * small.size
    ]
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


# The eight ways a print can lie on the scanner: quarter turns (0 or 1) x flips.
FITS: tuple[tuple[int, int, int], ...] = tuple(
    (k, rs, cs) for k in (0, 1) for rs, cs in ((1, 1), (-1, -1), (1, -1), (-1, 1))
)


def _orientation_name(k: int, rs: int, cs: int) -> str:
    mirrored = rs != cs
    if k:
        return "sideways, mirrored" if mirrored else "sideways"
    if mirrored:
        return "mirrored" if rs == 1 else "mirrored and turned 180°"
    return "as scanned" if rs == 1 else "turned 180°"


def _view(
    lightness: NDArray[np.float64], box: tuple[int, int, int, int], fit: tuple[int, int, int]
) -> NDArray[np.float64]:
    top, left, bottom, right = box
    k, rs, cs = fit
    view: NDArray[np.float64] = np.rot90(lightness[top:bottom, left:right], k)[::rs, ::cs]
    return view


def _point(view: NDArray[np.float64], layout: SheetSpec, x: float, y: float, r: int) -> float:
    """Median L* in a small square around a point given in sheet inches."""
    h, w = view.shape
    px, py = round(x / layout.width * w), round(y / layout.height * h)
    patch = view[max(py - r, 0) : py + r + 1, max(px - r, 0) : px + r + 1]
    return float(np.median(patch)) if patch.size else 0.0


def _dark_points(layout: BlockingLayout) -> list[tuple[float, float]]:
    """Places that are clear film on every sheet, so they print darkest: the gaps
    between rows, the gap before each wedge, and the 0% end of each wedge."""
    points = []
    rows = len(layout.colours)
    columns = [(layout.full_box(0)[0] + layout.full_box(0)[2]) / 2] + [
        (layout.step_box(0, s)[0] + layout.step_box(0, s)[2]) / 2 for s in range(0, STEPS, 2)
    ]
    for gap_row in range(rows + 1):
        y = layout.row_top(gap_row) - layout.gap / 2
        points += [(x, y) for x in columns]
    gap_x = layout.full_box(0)[2] + layout.gap / 2
    for row in range(rows):
        top, bottom = layout.row_top(row), layout.row_top(row) + layout.row_height
        points.append((gap_x, (top + bottom) / 2))
        l, t, r, b = layout.step_box(row, STEPS - 1)  # noqa: E741
        points.append(((l + r) / 2, (t + b) / 2))
    return points


def _light_points(layout: BlockingLayout) -> list[tuple[float, float]]:
    """Places with the most ink on every sheet: full patches and the dense half of each
    wedge. Even a poor blocker prints lighter there than clear film does."""
    points = []
    for row in range(len(layout.colours)):
        for box in [layout.full_box(row), *(layout.step_box(row, s) for s in range(4))]:
            l, t, r, b = box  # noqa: E741
            points.append(((l + r) / 2, (t + b) / 2))
    return points


def _marker_lightness(view: NDArray[np.float64], layout: SheetSpec) -> float:
    """Median L* of the marker square, allowing it to sit up to MARKER_SLACK inches off
    its nominal spot (carbon tissue can stretch a little in processing)."""
    h, w = view.shape
    l, t, r, b = layout.marker_box()  # noqa: E741
    inset = (r - l) * 0.2
    best = 0.0
    for dx in (-MARKER_SLACK, 0.0, MARKER_SLACK):
        for dy in (-MARKER_SLACK, 0.0, MARKER_SLACK):
            region = view[
                max(round((t + inset + dy) / layout.height * h), 0) : round(
                    (b - inset + dy) / layout.height * h
                ),
                max(round((l + inset + dx) / layout.width * w), 0) : round(
                    (r - inset + dx) / layout.width * w
                ),
            ]
            if region.size:
                best = max(best, float(np.median(region)))
    return best


def _marker_contrast(view: NDArray[np.float64], layout: SheetSpec) -> float:
    """Marker square L* minus the clear film around it (its label-column neighbourhood)."""
    h, w = view.shape
    l, t, r, b = layout.marker_box()  # noqa: E741
    inset = (r - l) * 0.2

    def median(x0: float, y0: float, x1: float, y1: float) -> float:
        region = view[
            round(y0 / layout.height * h) : round(y1 / layout.height * h),
            round(x0 / layout.width * w) : round(x1 / layout.width * w),
        ]
        return float(np.median(region)) if region.size else 0.0

    marker = _marker_lightness(view, layout)
    beside = median(r + layout.gap, t + inset, r + layout.gap + (r - l), b - inset)  # clear film
    return marker - beside


def _fit_score(
    lightness: NDArray[np.float64],
    box: tuple[int, int, int, int],
    fit: tuple[int, int, int],
    layout: SheetSpec,
    dark: list[tuple[float, float]],
    light: list[tuple[float, float]],
) -> float:
    """How well the layout fits: the inked spots and the marker should be light, the
    clear-film spots dark. Returns (inked - clear film) + (marker - clear film), in L*."""
    view = _view(lightness, box, fit)
    if view.shape[0] < 20 or view.shape[1] < 20:
        return -1e9
    r = max(1, round(min(view.shape) / 200))
    # The marker decides the orientation, so read its whole square (median): label text
    # in the same corner of a wrongly turned sheet is mostly dark, so it can't pass for it.
    marker = _marker_lightness(view, layout)
    darks = float(np.mean([_point(view, layout, x, y, r) for x, y in dark]))
    lights = float(np.mean([_point(view, layout, x, y, r) for x, y in light]))
    return (lights - darks) + (marker - darks)


def _deskew(
    lightness: NDArray[np.float64], rough: tuple[int, int, int, int]
) -> tuple[NDArray[np.float64], float]:
    """Square up a print laid a few degrees off: returns the rotated scan and the angle.

    The gaps between the colour rows are straight dark lines; the tilt at which they
    line up with the scan's rows (or columns, for a sideways print) makes the profile
    across them the most contrasty.
    """
    top, left, bottom, right = rough
    crop = lightness[top:bottom, left:right].astype(np.float32)
    if crop.size == 0:
        return lightness, 0.0
    fill = float(np.median(crop))
    across = 1 if crop.shape[0] > crop.shape[1] else 0  # sideways: rows run up and down
    image = Image.fromarray(crop, mode="F")
    h, w = crop.shape

    def contrast(angle: float) -> float:
        turned = np.asarray(
            image.rotate(angle, resample=Image.Resampling.BILINEAR, fillcolor=fill)
        )[h // 8 : h - h // 8, w // 8 : w - w // 8]
        return float(np.var(turned.mean(axis=across)))

    angles = np.arange(-MAX_TILT, MAX_TILT + 1e-9, 0.25)
    coarse = max(angles, key=contrast)
    best = max(np.arange(coarse - 0.25, coarse + 0.26, 0.05), key=contrast)
    if abs(best) < 0.1:
        return lightness, 0.0
    whole = Image.fromarray(lightness.astype(np.float32), mode="F")
    centre = ((left + right) / 2, (top + bottom) / 2)
    turned = whole.rotate(
        float(best), resample=Image.Resampling.BILINEAR, center=centre,
        fillcolor=float(np.percentile(lightness, 99)),
    )  # fmt: skip
    return np.asarray(turned, dtype=np.float64), float(best)


def _refine_edges(
    lightness: NDArray[np.float64], rough: tuple[int, int, int, int]
) -> tuple[int, int, int, int]:
    """Move each side of the rough box to the sharpest step from the lighter safe edge
    (outside) to the darker clear film (inside). Works even when the safe edge leaked
    and printed grey, as long as it is lighter than clear film."""
    top, left, bottom, right = rough
    span_y, span_x = bottom - top, right - left
    # The rough box is already within a few percent; searching further finds other
    # light-to-dark steps (tape edges) that look just like the safe edge.
    reach_y, reach_x = round(EDGE_REACH * span_y), round(EDGE_REACH * span_x)
    win = max(2, round(0.012 * max(span_y, span_x)))
    rows = lightness[:, left + span_x // 5 : right - span_x // 5]
    cols = lightness[top + span_y // 5 : bottom - span_y // 5, :]
    row_profile = np.median(rows, axis=1)  # one value per scan row
    col_profile = np.median(cols, axis=0)  # one value per scan column

    def best_step(profile: NDArray[np.float64], centre: int, reach: int, inward: int) -> int:
        best_pos, best_jump = centre, -1e9
        for pos in range(max(centre - reach, win), min(centre + reach, len(profile) - win)):
            outside = profile[pos - win : pos] if inward > 0 else profile[pos : pos + win]
            inside = profile[pos : pos + win] if inward > 0 else profile[pos - win : pos]
            # Prefer steps near the rough edge: a small penalty per pixel of distance.
            jump = float(np.median(outside) - np.median(inside)) - 2.0 * abs(pos - centre) / reach
            if jump > best_jump:
                best_pos, best_jump = pos, jump
        return best_pos

    return (
        best_step(row_profile, top, reach_y, +1),
        best_step(col_profile, left, reach_x, +1),
        best_step(row_profile, bottom, reach_y, -1),
        best_step(col_profile, right, reach_x, -1),
    )


def _fit_layout(
    lightness: NDArray[np.float64],
    rough: tuple[int, int, int, int],
    layout: SheetSpec,
    dark: list[tuple[float, float]] | None = None,
    light: list[tuple[float, float]] | None = None,
) -> tuple[tuple[int, int, int, int], tuple[int, int, int], float]:
    """Pin the sheet's edges, then pick the orientation whose layout fits best there.

    The box is fixed before orientations are compared, so no orientation can drift
    to a position where its spots happen to land well.
    """
    if dark is None or light is None:
        assert isinstance(layout, BlockingLayout)
        dark, light = _dark_points(layout), _light_points(layout)
    box = _refine_edges(lightness, rough)
    # The box's shape says whether the sheet lies sideways; only compare those layouts
    # (all eight when the sheet is nearly square and its shape can't tell).
    candidates = list(FITS)
    if abs(layout.width / layout.height - 1) > NEAR_SQUARE:
        portrait = (box[2] - box[0]) > (box[3] - box[1])
        sideways = portrait == (layout.width > layout.height)
        candidates = [fit for fit in FITS if bool(fit[0]) == sideways]
    scored = sorted(
        ((_fit_score(lightness, box, fit, layout, dark, light), fit) for fit in candidates),
        reverse=True,
    )
    return box, scored[0][1], scored[0][0]


def analyse(scan: NDArray[np.float64], layout: BlockingLayout | None = None) -> BlockingReport:
    """Read a scanned print of the blocking sheet (encoded sRGB floats, (H, W, 3)).

    The print may lie any way on the scanner (turned, sideways, mirrored), the tissue
    may extend past the negative, and the safe edge may have leaked. The sheet is found
    roughly, then the layout is fitted to the print: its clear-film spots must be the
    darkest and its marker the lightest. Patches are judged against the best-blocking
    area, since the process's white (stained tissue) is often not the paper's white.
    """
    layout = layout or BlockingLayout()
    lightness = _lightness(scan)
    expected = layout.width / layout.height
    rough = _find_sheet(lightness, expected)
    # Rotating about the sheet's own centre keeps it where the rough box already is.
    lightness, tilt = _deskew(lightness, rough)
    box, fit, score = _fit_layout(lightness, rough, layout)
    view = _view(lightness, box, fit)
    if score < 2 * MARKER_CONTRAST or _marker_contrast(view, layout) < MARKER_CONTRAST:
        raise BlockingError("couldn't find the marker square; is the sheet fully on the scan?")
    ratio = (view.shape[1] / view.shape[0]) / expected
    if abs(ratio - 1) > 0.08:
        raise BlockingError(
            f"the exposed area's shape doesn't match the sheet ({ratio:.2f}x); "
            "check the whole sheet is on the scan and placed square"
        )
    if layout.step_width * view.shape[1] / layout.width < MIN_STEP_PIXELS:
        raise BlockingError("the patches are too small to read; scan at a higher resolution")
    per_inch = view.shape[1] / layout.width
    edge = _safe_edge_lightness(lightness, box, per_inch)

    def sample(patch_box: tuple[float, float, float, float]) -> float:
        h, w = view.shape
        sx, sy = w / layout.width, h / layout.height
        l, t, r, b = patch_box  # noqa: E741
        cx, cy, hw, hh = (l + r) / 2 * sx, (t + b) / 2 * sy, (r - l) * sx / 4, (b - t) * sy / 4
        patch = view[round(cy - hh) : round(cy + hh), round(cx - hw) : round(cx + hw)]
        return float(np.median(patch))

    fulls = [sample(layout.full_box(row)) for row in range(len(layout.colours))]
    process_white = max([edge, *fulls])  # the best blocker: the process's own white
    results = tuple(
        ColourResult(
            name=name,
            full=fulls[row],
            wedge=tuple(sample(layout.step_box(row, s)) for s in reversed(range(STEPS))),
            paper=process_white,
        )
        for row, name in enumerate(layout.colours)
    )
    return BlockingReport(
        results=results,
        orientation=_orientation_name(*fit) + (f", tilted {tilt:+.1f}°" if tilt else ""),
        paper=float(np.percentile(lightness, 99)),
        edge=edge,
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
