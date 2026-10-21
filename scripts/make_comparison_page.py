"""Build one page with an uncorrected and a corrected grey-balance target.

    uv run python scripts/make_comparison_page.py CALIBRATION.oqcal [output.tif]

Same as `openquad target --kind comparison --calibration CALIBRATION.oqcal`.
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from numpy.typing import NDArray

from openquad.greybalance import Calibration, comparison_page, load_calibration
from openquad.imageio import save_rgb, srgb_profile


def build_page(calibration: Calibration, dpi: int = 300) -> NDArray[np.uint16]:
    return comparison_page(calibration, dpi)


def main(argv: list[str]) -> None:
    if len(argv) < 2:
        raise SystemExit(__doc__)
    output = Path(argv[2]) if len(argv) > 2 else Path("comparison-page.tif")
    save_rgb(output, build_page(load_calibration(argv[1])), (300.0, 300.0), srgb_profile())
    print(f"wrote {output}")


if __name__ == "__main__":
    main(sys.argv)
