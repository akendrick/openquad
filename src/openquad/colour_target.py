"""The colour target, and measuring a scan of it (colour calibration, phase 1).

The target shows what the printer does with colour: a grid of RGB colours (6 levels a
channel, 216 patches; or 9, 729 patches over two pages for papers with a bigger gamut),
21 extra greys, and the primaries and secondaries as tints at three strengths. It's
printed the way photos will be: sRGB-tagged RGB through the same print path, so the
calibration describes "this RGB, sent this way, on this paper".

Each page has its patches edge to edge inside a thin black frame, like the grey
target, with bare paper round them (the paper white everything is measured against).
The patches are shuffled (always the same way) so a streaky print or an uneven scan
doesn't all land on one hue. Black squares to the left of the frame number the page
(one square for page 1, two for page 2), so scans can be read in any order and any way
up: a scan comes back rotated 180 degrees if the marks are on the right.

What was sent where is saved with the target as JSON, which measuring reads back.
Measured colours are CIE XYZ (D50, from a scanner model made in phase 0; without one,
the scan is taken as sRGB) and L*a*b* relative to the paper (paper white is L* 100,
as relative colourimetric printing treats it).
"""

from __future__ import annotations

import json
import math
from collections.abc import Sequence
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
from numpy.typing import NDArray

from openquad.colour import D50_WHITE, d65_to_d50, linear_rgb_to_xyz, srgb_to_linear, xyz_to_lab
from openquad.measure import DARK, EDGE_IGNORE, MeasureError, count_marks, find_frame
from openquad.quadfile import MAX_VALUE
from openquad.scanner_profile import ScannerModel
from openquad.targets import wedge_levels

PRINTABLE = (7.5, 10.0)  # inches: Letter inside 0.5 in margins
GRIDS = (6, 9)
NEUTRALS = 21
TINTS = (0.3, 0.5, 0.7)  # strengths of the primary and secondary tints
#: Red, green, blue, cyan, magenta, yellow, as RGB at full strength (0 or 1).
HUES = ((1, 0, 0), (0, 1, 0), (0, 0, 1), (0, 1, 1), (1, 0, 1), (1, 1, 0))
SHUFFLE_SEED = 7
SAMPLE = 0.5  # central fraction of each patch sampled


def colour_patches(grid: int = 6) -> NDArray[np.uint16]:
    """The colours on the target, unshuffled: the RGB grid, the greys, then the tints."""
    if grid not in GRIDS:
        raise ValueError(f"grid must be one of {', '.join(map(str, GRIDS))}, got {grid}")
    levels = np.rint(np.linspace(0, MAX_VALUE, grid))
    r, g, b = np.meshgrid(levels, levels, levels, indexing="ij")
    cube = np.stack([r.ravel(), g.ravel(), b.ravel()], axis=-1)
    greys = np.repeat(wedge_levels(NEUTRALS)[:, None].astype(np.float64), 3, axis=1)
    tints = [[MAX_VALUE * (1 - s * (1 - c)) for c in hue] for hue in HUES for s in TINTS]
    return np.rint(np.concatenate([cube, greys, np.array(tints)])).astype(np.uint16)


@dataclass(frozen=True)
class ColourTarget:
    """The target's layout and what each patch sent, page by page, in inches.

    Patch boxes are measured from the outer corner of the page's frame; `lead` is the
    space to the frame's left that holds the page marks."""

    pages: tuple[NDArray[np.uint16], ...]  # each (patches, 3), in reading order
    columns: int
    patch: float
    grid: int = 6
    frame: float = 0.04
    inset: float = 0.15
    lead: float = 0.4
    mark: float = 0.15
    pad: float = 0.07

    @property
    def edge(self) -> float:
        return self.frame + self.inset

    def rows(self, page: int) -> int:
        return math.ceil(len(self.pages[page]) / self.columns)

    def frame_size(self, page: int) -> tuple[float, float]:
        """(width, height) of a page's frame."""
        return (
            self.columns * self.patch + 2 * self.edge,
            self.rows(page) * self.patch + 2 * self.edge,
        )

    def page_size(self, page: int) -> tuple[float, float]:
        """(width, height) of a page's image: the marks, then the frame."""
        width, height = self.frame_size(page)
        return width + self.lead, height

    def patch_boxes(self, page: int) -> list[tuple[float, float, float, float]]:
        """Each patch's (left, top, right, bottom), in the page's order."""
        boxes = []
        for i in range(len(self.pages[page])):
            row, column = divmod(i, self.columns)
            left, top = self.edge + column * self.patch, self.edge + row * self.patch
            boxes.append((left, top, left + self.patch, top + self.patch))
        return boxes

    def paper_boxes(self, page: int) -> list[tuple[float, float, float, float]]:
        """Strips of bare paper above and below the patches."""
        width, height = self.frame_size(page)
        strips = []
        for top in (self.frame, height - self.edge):
            strips.append(
                (self.edge, top + 0.25 * self.inset, width - self.edge, top + 0.75 * self.inset)
            )
        return strips

    @property
    def sent(self) -> NDArray[np.uint16]:
        """Every patch's RGB, page after page."""
        return np.concatenate(self.pages)

    def to_json(self) -> str:
        return json.dumps(
            {
                "kind": "openquad colour target",
                "version": 1,
                "grid": self.grid,
                "columns": self.columns,
                "patch": self.patch,
                "frame": self.frame,
                "inset": self.inset,
                "lead": self.lead,
                "mark": self.mark,
                "pad": self.pad,
                "pages": [page.tolist() for page in self.pages],
            }
        )

    @classmethod
    def from_json(cls, text: str) -> ColourTarget:
        data = json.loads(text)
        if data.get("kind") != "openquad colour target":
            raise ValueError("not an OpenQuad colour target layout")
        return cls(
            pages=tuple(np.array(p, dtype=np.uint16).reshape(-1, 3) for p in data["pages"]),
            columns=int(data["columns"]),
            patch=float(data["patch"]),
            grid=int(data.get("grid", 6)),
            frame=float(data["frame"]),
            inset=float(data["inset"]),
            lead=float(data["lead"]),
            mark=float(data["mark"]),
            pad=float(data["pad"]),
        )


def make_target(
    grid: int = 6, patch: float | None = None, printable: tuple[float, float] = PRINTABLE
) -> ColourTarget:
    """Lay the target's patches out, shuffled, on as many pages as they need.

    The patches are 0.43 in for the 6-level grid (one page) and 0.32 in for the 9-level
    one (two pages), unless `patch` is given."""
    patches = colour_patches(grid)
    order = np.random.default_rng(SHUFFLE_SEED).permutation(len(patches))
    size = patch or (0.43 if grid == 6 else 0.32)
    shell = ColourTarget(pages=(patches,), columns=1, patch=size, grid=grid)
    columns = math.floor((printable[0] - shell.lead - 2 * shell.edge) / size + 1e-9)
    rows = math.floor((printable[1] - 2 * shell.edge) / size + 1e-9)
    if columns < 4 or rows < 4:
        raise ValueError(
            f"patches of {size:g} in don't fit a {printable[0]:g} x {printable[1]:g} in page"
        )
    per_page = columns * rows
    shuffled = patches[order]
    pages = tuple(shuffled[i : i + per_page] for i in range(0, len(shuffled), per_page))
    return ColourTarget(pages=pages, columns=columns, patch=size, grid=grid)


def target_page(target: ColourTarget, page: int, dpi: float = 300.0) -> NDArray[np.uint16]:
    """One page of the target as 16-bit RGB on white, to print sRGB-tagged at 100%."""

    def px(inches: float) -> int:
        return round(inches * dpi)

    width, height = target.page_size(page)
    frame_w, frame_h = target.frame_size(page)
    image = np.full((px(height), px(width), 3), MAX_VALUE, dtype=np.uint16)
    x0 = px(target.lead)
    sheet = image[:, x0 : x0 + px(frame_w)]
    f = px(target.frame)
    sheet[:f], sheet[px(frame_h) - f : px(frame_h)] = 0, 0
    sheet[:, :f], sheet[:, px(frame_w) - f : px(frame_w)] = 0, 0
    for colour, (left, top, right, bottom) in zip(
        target.pages[page], target.patch_boxes(page), strict=True
    ):
        sheet[px(top) : px(bottom), px(left) : px(right)] = colour
    mark, pad = px(target.mark), px(target.pad)
    for i in range(page + 1):  # page marks, to the frame's left
        y = pad + i * (mark + pad)
        image[y : y + mark, pad : pad + mark] = 0
    return image


# --- measuring -------------------------------------------------------------------------


@dataclass(frozen=True, eq=False)
class ColourMeasurement:
    """What each patch sent and what it measured.

    `xyz` is D50 XYZ (Y = 1 for a perfect white), `paper_xyz` the paper's; `lab` is
    L*a*b* relative to the paper."""

    sent: NDArray[np.uint16]
    xyz: NDArray[np.float64]
    lab: NDArray[np.float64]
    paper_xyz: NDArray[np.float64]
    scanner: str = ""
    colourimetry: str = ""
    notes: list[str] = field(default_factory=list)

    def neutrals(self) -> NDArray[np.bool_]:
        """Which patches were sent as greys (R = G = B)."""
        grey: NDArray[np.bool_] = (self.sent[:, 0] == self.sent[:, 1]) & (
            self.sent[:, 1] == self.sent[:, 2]
        )
        return grey

    def summary(self) -> str:
        grey = self.neutrals()
        casts = np.abs(self.lab[grey, 1:]).max(axis=1)
        chroma = np.hypot(self.lab[:, 1], self.lab[:, 2])
        lines = [
            f"{len(self.sent)} patches measured ({self.colourimetry}).",
            f"Paper white: Y {self.paper_xyz[1]:.3f} "
            f"(L* {float(xyz_to_lab(self.paper_xyz, D50_WHITE)[0]):.1f} absolute).",
            f"Deepest black: L* {self.lab[:, 0].min():.1f} relative to the paper.",
            f"Greys: worst cast {casts.max():.1f} (mean {casts.mean():.2f}).",
        ]
        for name, rgb in zip(
            ("red", "green", "blue", "cyan", "magenta", "yellow"), HUES, strict=True
        ):
            full = np.all(self.sent == np.array(rgb) * MAX_VALUE, axis=1)
            if full.any():
                i = int(np.flatnonzero(full)[0])
                l_star, a_star, b_star = self.lab[i]
                lines.append(
                    f"Full {name}: L* {l_star:.1f}, a* {a_star:.1f}, b* {b_star:.1f} "
                    f"(chroma {chroma[i]:.1f})."
                )
        return "\n".join(lines + self.notes)

    def to_json(self) -> str:
        return json.dumps(
            {
                "kind": "openquad colour measurement",
                "version": 1,
                "scanner": self.scanner,
                "colourimetry": self.colourimetry,
                "paper_xyz": self.paper_xyz.tolist(),
                "sent": self.sent.tolist(),
                "xyz": np.round(self.xyz, 6).tolist(),
                "lab": np.round(self.lab, 4).tolist(),
            },
            indent=None,
        )

    @classmethod
    def from_json(cls, text: str) -> ColourMeasurement:
        data = json.loads(text)
        if data.get("kind") != "openquad colour measurement":
            raise ValueError("not an OpenQuad colour measurement")
        return cls(
            sent=np.array(data["sent"], dtype=np.uint16),
            xyz=np.array(data["xyz"], dtype=np.float64),
            lab=np.array(data["lab"], dtype=np.float64),
            paper_xyz=np.array(data["paper_xyz"], dtype=np.float64),
            scanner=data.get("scanner", ""),
            colourimetry=data.get("colourimetry", ""),
        )


def _marks_side(scan: NDArray[np.float64], frame: tuple[int, int, int, int]) -> str:
    """Which side of the frame the page marks are on: "left", "right" or "" (none)."""
    left, top, right, bottom = frame
    width = scan.shape[1]
    reach = max(round((bottom - top) * 0.2), 4)
    dark = scan.mean(axis=-1) < DARK
    found = {}
    for side, (x0, x1) in (
        ("left", (max(left - reach, 0), max(left - 2, 0))),
        ("right", (right + 2, min(right + reach, width))),
    ):
        found[side] = int(dark[top:bottom, x0:x1].sum()) if x1 > x0 else 0
    if max(found.values()) == 0:
        return ""
    return max(found, key=lambda side: found[side])


def _frames(scan: NDArray[np.float64]) -> list[tuple[int, int, int, int]]:
    """Candidate frames: skipping the scan's borders first (lid shadows), then not (for a
    scan cropped tight to the target, whose frame sits in those borders)."""
    frames = []
    for edge_ignore in (EDGE_IGNORE, 0.0):
        try:
            frames.append(find_frame(scan, edge_ignore))
        except MeasureError:
            continue
    if not frames:
        raise MeasureError("no target frame found in the scan")
    return frames


def _locate(
    scan: NDArray[np.float64], target: ColourTarget
) -> tuple[int, tuple[int, int, int, int], NDArray[np.float64]]:
    """(page, frame, scan the right way up) for one scan."""
    shapes = [width / height for width, height in map(target.frame_size, range(len(target.pages)))]
    problem = ""
    for frame in _frames(scan):
        left, top, right, bottom = frame
        found = (right - left) / max(bottom - top, 1)
        fits = [i for i, shape in enumerate(shapes) if abs(found / shape - 1) <= 0.04]
        if not fits:
            problem = problem or (
                f"the frame found is {found:.2f}:1 but the target's "
                f"{'pages are' if len(shapes) > 1 else 'is'} "
                f"{' and '.join(f'{shape:.2f}:1' for shape in shapes)}; check the whole page "
                "is on the scan and placed square"
            )
            continue
        upright = scan
        if _marks_side(scan, frame) == "right":  # scanned the other way up
            upright = np.ascontiguousarray(scan[::-1, ::-1])
            height, width = scan.shape[:2]
            frame = (width - right, height - bottom, width - left, height - top)
        marks = count_marks(upright, frame)
        if marks - 1 not in fits:
            pages = len(target.pages)
            problem = (
                f"couldn't tell which page this is (found {marks} page marks beside a frame "
                f"the shape of page {' or '.join(str(i + 1) for i in fits)}; the target has "
                f"{pages} page{'s' if pages != 1 else ''})"
            )
            continue
        return marks - 1, frame, upright
    raise MeasureError(problem)


def _median(
    scan: NDArray[np.float64], box: tuple[float, float, float, float]
) -> NDArray[np.float64]:
    left, top, right, bottom = box
    cx, cy = (left + right) / 2, (top + bottom) / 2
    hw, hh = (right - left) * SAMPLE / 2, (bottom - top) * SAMPLE / 2
    region = scan[round(cy - hh) : round(cy + hh), round(cx - hw) : round(cx + hw), :3]
    if region.shape[0] < 2 or region.shape[1] < 2:
        raise MeasureError("patches too small to sample; scan at 300 ppi or more")
    result: NDArray[np.float64] = np.median(region.reshape(-1, 3), axis=0)
    return result


def sample_page(
    scan: NDArray[np.float64], target: ColourTarget
) -> tuple[int, NDArray[np.float64], NDArray[np.float64]]:
    """(page, each patch's scanner RGB, the paper's), as the scanner encoded them (0-1)."""
    page, (left, top, right, bottom), scan = _locate(scan, target)
    width, height = target.frame_size(page)
    sx, sy = (right - left) / width, (bottom - top) / height

    def to_pixels(box: tuple[float, float, float, float]) -> tuple[float, float, float, float]:
        x0, y0, x1, y1 = box
        return (left + x0 * sx, top + y0 * sy, left + x1 * sx, top + y1 * sy)

    patches = np.array([_median(scan, to_pixels(box)) for box in target.patch_boxes(page)])
    paper = np.mean([_median(scan, to_pixels(box)) for box in target.paper_boxes(page)], axis=0)
    return page, patches, paper


def measure_target(
    scans: Sequence[NDArray[np.float64]],
    target: ColourTarget,
    model: ScannerModel | None = None,
    scanner: str = "",
) -> ColourMeasurement:
    """Measure scans of every page of the target, in any order and either way up."""
    found: dict[int, tuple[NDArray[np.float64], NDArray[np.float64]]] = {}
    for scan in scans:
        page, patches, paper = sample_page(scan, target)
        if page in found:
            raise MeasureError(f"two scans of page {page + 1}")
        found[page] = (patches, paper)
    missing = [str(p + 1) for p in range(len(target.pages)) if p not in found]
    if missing:
        raise MeasureError(f"no scan of page {', '.join(missing)}")
    encoded = np.concatenate([found[p][0] for p in range(len(target.pages))])
    papers = np.array([found[p][1] for p in range(len(target.pages))])
    if model is not None:
        xyz, paper_each = model.to_xyz(encoded), model.to_xyz(papers)
        colourimetry = f"scanner model{f' for {model.scanner}' if model.scanner else ''}, D50"
    else:
        xyz = d65_to_d50(linear_rgb_to_xyz(srgb_to_linear(encoded)))
        paper_each = d65_to_d50(linear_rgb_to_xyz(srgb_to_linear(papers)))
        colourimetry = "scan taken as sRGB (no scanner model)"
    xyz = np.maximum(xyz, 0.0)
    paper_xyz = paper_each.mean(axis=0)
    if paper_xyz[1] <= 0.2:
        raise MeasureError("paper white measured too dark; check the scan")
    notes = []
    if len(papers) > 1:
        spread = float(np.abs(paper_each[:, 1] / paper_xyz[1] - 1).max())
        if spread > 0.03:
            notes.append(
                f"Note: the pages' paper white differs by {100 * spread:.0f}%; scan every page "
                "with the same settings."
            )
    return ColourMeasurement(
        sent=target.sent,
        xyz=xyz,
        lab=xyz_to_lab(xyz, paper_xyz),
        paper_xyz=paper_xyz,
        scanner=scanner or (model.scanner if model else ""),
        colourimetry=colourimetry,
        notes=notes,
    )


def save_measurement(measurement: ColourMeasurement, path: str | Path) -> None:
    Path(path).write_text(measurement.to_json() + "\n", encoding="utf-8")


def load_target(path: str | Path) -> ColourTarget:
    return ColourTarget.from_json(Path(path).read_text(encoding="utf-8"))
