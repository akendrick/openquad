"""Build one page with an uncorrected and a corrected grey-balance target.

    uv run python scripts/make_comparison_page.py CALIBRATION.oqcal [output.tif]

Scanning both targets in one scan gives them identical scanner processing, so
the comparison isn't affected by the scanner's automatic adjustments. The
uncorrected target is on top, marked with one black square at the left; the
corrected one is below, marked with two squares.
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from numpy.typing import NDArray

from openquad.greybalance import Calibration, load_calibration
from openquad.imageio import save_rgb, srgb_profile
from openquad.targets import framed_target

GAP_IN, MARK_IN, LEAD_IN = 1.0, 0.15, 0.4


def build_page(calibration: Calibration, dpi: int = 300) -> NDArray[np.uint16]:
    """(height, width, 3) uint16 page: uncorrected target above, corrected below."""
    plain = framed_target(dpi=dpi)
    corrected = calibration.apply(plain)
    h, w = plain.shape[:2]
    gap, mark, lead = round(GAP_IN * dpi), round(MARK_IN * dpi), round(LEAD_IN * dpi)
    page = np.full((2 * h + gap, w + lead, 3), 65535, dtype=np.uint16)
    page[:h, lead:] = plain
    page[h + gap :, lead:] = corrected
    pad = round(0.07 * dpi)
    for count, top in ((1, 0), (2, h + gap)):
        for i in range(count):
            y = top + pad + i * (mark + pad)
            page[y : y + mark, pad : pad + mark] = 0
    return page


def main(argv: list[str]) -> None:
    if len(argv) < 2:
        raise SystemExit(__doc__)
    output = Path(argv[2]) if len(argv) > 2 else Path("comparison-page.tif")
    save_rgb(output, build_page(load_calibration(argv[1])), (300.0, 300.0), srgb_profile())
    print(f"wrote {output}")


if __name__ == "__main__":
    main(sys.argv)
