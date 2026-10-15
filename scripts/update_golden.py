"""Regenerate the golden-file fixtures in fixtures/golden/.

Run only when a change to the output is intended, then review the diff in the PR:

    uv run python scripts/update_golden.py
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
from numpy.typing import NDArray

from openquad.curves import InkSpec, build_curve
from openquad.quadfile import read_quad, write_quad
from openquad.separate import separate

GOLDEN = Path(__file__).resolve().parents[1] / "fixtures" / "golden"
CURVE_PATH = GOLDEN / "three-ink.quad"
SEPARATION_PATH = GOLDEN / "three-ink-separation.npz"


def golden_image() -> NDArray[np.uint16]:
    """A 16 x 1024 image covering the full tonal range, rows offset so values vary."""
    ramp = np.linspace(0, 65535, 1024)
    offsets = np.arange(16)[:, np.newaxis] * 37
    return np.clip(np.rint(ramp + offsets), 0, 65535).astype(np.uint16)


def golden_curve_specs() -> list[InkSpec]:
    return [
        InkSpec("LLK", limit=30.0, start=0.0, peak=0.33, end=0.66),
        InkSpec("LK", limit=40.0, start=0.2, peak=0.66, end=1.0),
        InkSpec("K", limit=60.0, start=0.5, peak=1.0),
    ]


def main() -> None:
    GOLDEN.mkdir(parents=True, exist_ok=True)
    write_quad(build_curve(golden_curve_specs(), gamma=1.2), CURVE_PATH)
    separation = separate(golden_image(), read_quad(CURVE_PATH))
    np.savez_compressed(SEPARATION_PATH, separation=separation)
    print(f"wrote {CURVE_PATH.name} and {SEPARATION_PATH.name}")


if __name__ == "__main__":
    main()
