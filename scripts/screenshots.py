"""Remake the Mac app's screenshots in docs/screenshots from a drawn sample photo.

The sample is drawn, not photographed, so the screenshots never carry anyone's
pictures: a 16-bit grey ramp from paper white to black with a soft dark disc and a
ramped bar, 1800 x 1200 px at 300 ppi. Build the app first (swift build in
swift/OpenQuadApp), then:

    uv run python scripts/screenshots.py
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
import tifffile

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "swift" / "OpenQuadApp" / ".build" / "debug" / "OpenQuad"
OUT = ROOT / "docs" / "screenshots"

#: Each screenshot: its file name and the app's --snapshot options (the photo is added).
SHOTS = {
    "mac-app-print.png": ["--tab", "print"],
    "mac-app-negative.png": ["--negative"],
}


def sample_photo(width: int = 1800, height: int = 1200) -> np.ndarray:
    """The sample: white to black left to right, a dark disc, a bar ramped top to bottom."""
    y, x = np.mgrid[0:height, 0:width].astype(np.float64)
    tone = 0.08 + 0.85 * x / (width - 1)  # 0 = white paper, 1 = black
    cx, cy, r = width * 0.33, height * 0.5, height * 0.27
    disc = np.clip(1 - np.hypot(x - cx, y - cy) / r, 0, 1)
    tone = np.where(disc > 0, np.maximum(tone, 0.95 * np.sqrt(disc)), tone)
    bar = (x > width * 0.62) & (x < width * 0.72) & (y > height * 0.18) & (y < height * 0.82)
    tone = np.where(bar, 0.05 + 0.9 * (y - height * 0.18) / (height * 0.64), tone)
    pixels: np.ndarray = np.round((1 - np.clip(tone, 0, 1)) * 65535).astype(np.uint16)
    return pixels


def main() -> int:
    if not APP.exists():
        print(f"build the app first: {APP} is missing", file=sys.stderr)
        return 1
    with tempfile.TemporaryDirectory() as folder:
        photo = Path(folder) / "sample.tif"
        tifffile.imwrite(photo, sample_photo(), resolution=(300, 300), resolutionunit="INCH")
        for name, options in SHOTS.items():
            subprocess.run(
                [str(APP), "--snapshot", str(OUT / name), "--photo", str(photo), *options],
                check=True,
                timeout=120,
            )
            print(f"wrote {OUT / name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
