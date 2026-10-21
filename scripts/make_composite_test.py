"""Build the composite-path test sheet: neutral and black + red duotone wedges.

    uv run python scripts/make_composite_test.py [output-dir]

Writes `composite-test-sheet.tif`: a 7.5 x 5 inch, 300 dpi, 16-bit sRGB TIFF
(sRGB ICC profile embedded when macOS provides one). Print it at 100% scale.
Rows, top to bottom:

1. Neutral 21-step wedge (black layer only, should match plain greyscale)
2. Black + red duotone 21-step wedge
3. Black + red duotone smooth gradient
4. Red layer alone, 21-step wedge
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from numpy.typing import NDArray

from openquad.composite import PRESETS, composite
from openquad.imageio import save_rgb
from openquad.targets import step_wedge

SRGB_PROFILE = Path("/System/Library/ColorSync/Profiles/sRGB Profile.icc")
ROWS = (
    ("Neutral 21-step wedge", "neutral", "wedge"),
    ("Black + red 21-step wedge", "black-red", "wedge"),
    ("Black + red smooth gradient", "black-red", "gradient"),
    ("Red layer alone, 21-step wedge", "red-only", "wedge"),
)
WIDTH_IN, HEIGHT_IN = 7.5, 5.0
MARGIN_IN, ROW_IN, GAP_IN = 0.25, 0.9, 0.3
STEPS = 21


def build_sheet(dpi: int = 300) -> NDArray[np.uint16]:
    """The whole sheet as a (height, width, 3) uint16 sRGB array on white paper."""
    width, height = round(WIDTH_IN * dpi), round(HEIGHT_IN * dpi)
    margin, row_h, gap = round(MARGIN_IN * dpi), round(ROW_IN * dpi), round(GAP_IN * dpi)
    patch_w = (width - 2 * margin) // STEPS
    content_w = patch_w * STEPS
    left = (width - content_w) // 2

    sheet = np.full((height, width, 3), 65535, dtype=np.uint16)
    for index, (_, preset, kind) in enumerate(ROWS):
        if kind == "wedge":
            grey = step_wedge(STEPS, patch_width=patch_w, patch_height=row_h)
        else:
            ramp = np.rint(np.linspace(65535, 0, content_w)).astype(np.uint16)
            grey = np.tile(ramp, (row_h, 1))
        top = margin + index * (row_h + gap)
        sheet[top : top + row_h, left : left + content_w] = composite(grey, PRESETS[preset])
    return sheet


def main(argv: list[str]) -> None:
    out_dir = Path(argv[1]) if len(argv) > 1 else Path("test-prints")
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "composite-test-sheet.tif"
    icc = SRGB_PROFILE.read_bytes() if SRGB_PROFILE.exists() else None
    save_rgb(path, build_sheet(), dpi=(300.0, 300.0), icc_profile=icc)
    print(f"wrote {path} ({WIDTH_IN} x {HEIGHT_IN} in, 300 dpi, sRGB profile: {bool(icc)})")
    for number, (label, _, _) in enumerate(ROWS, start=1):
        print(f"  row {number}: {label}")


if __name__ == "__main__":
    main(sys.argv)
