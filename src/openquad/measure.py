"""Measure a scanned grey-balance target.

The scan is located by its black frame. Each patch is sampled over its central
half (median, which ignores dust and JPEG noise), the two rows are averaged per
level, and colours are normalised to the paper white measured inside the frame
so the scanner's own white cast is removed. Results are L*a*b* (D65).
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import tifffile
from numpy.typing import NDArray
from PIL import Image

from openquad.colour import linear_rgb_to_lab, srgb_to_linear
from openquad.targets import FramedLayout, wedge_levels

DARK = 0.35  # encoded value below which a pixel counts as frame/ink
EDGE_IGNORE = 0.02  # fraction of the scan at each border ignored (lid shadows)
SAMPLE = 0.5  # central fraction of each patch that is sampled


class MeasureError(ValueError):
    """The scan couldn't be measured (e.g. the frame wasn't found)."""


@dataclass(frozen=True, eq=False)
class Measurement:
    """One measured wedge.

    `levels` are the grey levels in the target (0 black .. 65535 white).
    `sent` is the 16-bit RGB actually sent to the printer for each level (differs
    from the level when a calibration was applied). `rgb` is the measured linear
    RGB relative to paper white; `lab` the matching L*a*b*.
    """

    levels: NDArray[np.uint16]
    sent: NDArray[np.uint16]
    rgb: NDArray[np.float64]
    lab: NDArray[np.float64]

    def to_json(self) -> str:
        return json.dumps(
            {
                "format": "openquad-measurement",
                "version": 1,
                "levels": self.levels.tolist(),
                "sent": self.sent.tolist(),
                "rgb": np.round(self.rgb, 6).tolist(),
                "lab": np.round(self.lab, 3).tolist(),
            },
            indent=1,
        )

    @classmethod
    def from_json(cls, text: str) -> Measurement:
        data = json.loads(text)
        if data.get("format") != "openquad-measurement":
            raise MeasureError("not an OpenQuad measurement file")
        return cls(
            levels=np.array(data["levels"], dtype=np.uint16),
            sent=np.array(data["sent"], dtype=np.uint16),
            rgb=np.array(data["rgb"], dtype=np.float64),
            lab=np.array(data["lab"], dtype=np.float64),
        )

    def worst_cast(self) -> float:
        """The largest |a*| or |b*| of any patch."""
        return float(np.abs(self.lab[:, 1:]).max())


def load_scan(path: str | Path) -> NDArray[np.float64]:
    """A scan as encoded sRGB floats 0-1, shape (height, width, 3). JPEG, PNG or TIFF."""
    path = Path(path)
    if path.suffix.lower() in (".tif", ".tiff"):
        pixels = np.asarray(tifffile.imread(path))
        scale = 65535.0 if pixels.dtype == np.uint16 else 255.0
    else:
        with Image.open(path) as image:
            pixels = np.asarray(image.convert("RGB"))
        scale = 255.0
    if pixels.ndim != 3 or pixels.shape[-1] < 3:
        raise MeasureError(f"{path}: expected a colour scan, got shape {pixels.shape}")
    return pixels[..., :3].astype(np.float64) / scale


def find_frame(
    scan: NDArray[np.float64], edge_ignore: float = EDGE_IGNORE
) -> tuple[int, int, int, int]:
    """(left, top, right, bottom) pixel edges of the target's outer frame.

    `edge_ignore` is the fraction of the scan at each border that is skipped, so
    lid shadows along the edges aren't mistaken for the frame.
    """
    height, width = scan.shape[:2]
    dark = scan.mean(axis=-1) < DARK
    ey, ex = round(height * edge_ignore), round(width * edge_ignore)
    dark[:ey], dark[height - ey :], dark[:, :ex], dark[:, width - ex :] = False, False, False, False

    def span(counts: NDArray[np.int_]) -> tuple[int, int]:
        if counts.max() == 0:
            raise MeasureError("no target frame found in the scan")
        hits = np.flatnonzero(counts >= 0.5 * counts.max())
        return int(hits[0]), int(hits[-1]) + 1

    top, bottom = span(dark.sum(axis=1))
    left, right = span(dark.sum(axis=0))
    return left, top, right, bottom


def locate_frame(
    scan: NDArray[np.float64], layout: FramedLayout | None = None
) -> tuple[int, int, int, int]:
    """Find the frame and check its shape matches the layout."""
    layout = layout or FramedLayout()
    expected = layout.width / layout.height
    # Skip the scan's borders first (lid shadows); if the scanner cropped tight to
    # the target, the frame sits in those borders, so try again without skipping.
    for edge_ignore in (EDGE_IGNORE, 0.0):
        left, top, right, bottom = find_frame(scan, edge_ignore)
        found = (right - left) / max(bottom - top, 1)
        if abs(found / expected - 1) <= 0.04:
            break
    else:
        raise MeasureError(
            f"frame shape {found:.2f}:1 doesn't match the target ({expected:.2f}:1); "
            "check the whole target is on the scan and placed square"
        )
    return left, top, right, bottom


def _median(
    scan: NDArray[np.float64], box: tuple[float, float, float, float]
) -> NDArray[np.float64]:
    left, top, right, bottom = box
    cx, cy = (left + right) / 2, (top + bottom) / 2
    hw, hh = (right - left) * SAMPLE / 2, (bottom - top) * SAMPLE / 2
    region = scan[round(cy - hh) : round(cy + hh), round(cx - hw) : round(cx + hw)]
    if region.size == 0:
        raise MeasureError("patch too small to sample; scan at a higher resolution")
    result: NDArray[np.float64] = np.median(region.reshape(-1, 3), axis=0)
    return result


def measure_scan(
    scan: NDArray[np.float64],
    layout: FramedLayout | None = None,
    sent: NDArray[np.uint16] | None = None,
) -> Measurement:
    """Measure every level of a scanned framed target.

    `sent` is the (steps, 3) RGB sent for each level, if a calibration was applied
    when printing; by default each level was sent as R = G = B = level.
    """
    layout = layout or FramedLayout()
    left, top, right, bottom = locate_frame(scan, layout)
    sx, sy = (right - left) / layout.width, (bottom - top) / layout.height

    def to_pixels(box: tuple[float, float, float, float]) -> tuple[float, float, float, float]:
        x0, y0, x1, y1 = box
        return (left + x0 * sx, top + y0 * sy, left + x1 * sx, top + y1 * sy)

    paper = srgb_to_linear(_median(scan, to_pixels(layout.paper_box())))
    if paper.min() <= 0.2:
        raise MeasureError("paper white measured too dark; check the scan")
    samples: list[list[NDArray[np.float64]]] = [[] for _ in range(layout.steps)]
    for level, *box in layout.patch_boxes():
        samples[level].append(srgb_to_linear(_median(scan, to_pixels(tuple(box)))))  # type: ignore[arg-type]
    rgb = np.array([np.mean(s, axis=0) for s in samples]) / paper

    levels = wedge_levels(layout.steps)
    if sent is None:
        sent = np.repeat(levels[:, np.newaxis], 3, axis=1)
    elif sent.shape != (layout.steps, 3):
        raise MeasureError(f"sent must have shape ({layout.steps}, 3), got {sent.shape}")
    return Measurement(
        levels=levels, sent=sent.astype(np.uint16), rgb=rgb, lab=linear_rgb_to_lab(rgb)
    )


def count_marks(scan: NDArray[np.float64], frame: tuple[int, int, int, int]) -> int:
    """Black squares beside a frame: 1 = uncorrected, 2 = corrected target.

    Looks in strips just left and right of the frame, since full-page scans may
    come back rotated 180 degrees.
    """
    left, top, right, bottom = frame
    width = scan.shape[1]
    reach = max(round((bottom - top) * 0.2), 4)
    dark = scan.mean(axis=-1) < DARK
    counts = []
    for x0, x1 in (
        (max(left - reach, 0), max(left - 2, 0)),
        (right + 2, min(right + reach, width)),
    ):
        if x1 <= x0:
            continue
        rows = dark[top:bottom, x0:x1].any(axis=1).astype(int)
        counts.append(int(np.count_nonzero(np.diff(np.r_[0, rows]) == 1)))
    return max(counts, default=0)


def split_pair(scan: NDArray[np.float64]) -> tuple[NDArray[np.float64], NDArray[np.float64]]:
    """Split a scan of a two-target page at the widest ink-free band between them.

    A row counts as ink-free only with (almost) no dark pixels: the frame's side
    lines run through the gap between a target's own two rows, but nothing runs
    through the gap between the two targets.
    """
    height = scan.shape[0]
    margin = round(height * EDGE_IGNORE)
    dark = scan[margin : height - margin].mean(axis=-1) < DARK
    rows = np.flatnonzero(dark.sum(axis=1) > 0.005 * scan.shape[1]) + margin
    if len(rows) < 2:
        raise MeasureError("no targets found in the scan")
    gaps = np.diff(rows)
    widest = int(np.argmax(gaps))
    if gaps[widest] < 0.05 * height:
        raise MeasureError("expected two targets one above the other; found one")
    split = int(rows[widest] + rows[widest + 1]) // 2
    return scan[:split], scan[split:]


def measure_pair(
    scan: NDArray[np.float64],
    sent: NDArray[np.uint16],
    layout: FramedLayout | None = None,
) -> tuple[Measurement, Measurement]:
    """Measure a comparison page: returns (uncorrected, corrected).

    The targets are told apart by their marks (one square vs two), so the page
    may be scanned either way up. `sent` is what the calibration sent for the
    corrected target.
    """
    found: dict[int, Measurement] = {}
    for part in split_pair(scan):
        frame = locate_frame(part, layout)
        marks = count_marks(part, frame)
        if marks not in (1, 2) or marks in found:
            raise MeasureError(f"couldn't identify a target by its marks (found {marks})")
        found[marks] = measure_scan(part, layout, sent=sent if marks == 2 else None)
    return found[1], found[2]
