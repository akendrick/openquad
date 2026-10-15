"""Calibration targets: step wedges to print and measure."""

from __future__ import annotations

import numpy as np
from numpy.typing import NDArray

from openquad.quadfile import MAX_VALUE


def wedge_levels(steps: int) -> NDArray[np.uint16]:
    """`steps` evenly spaced grey levels from white (65535) to black (0)."""
    if steps < 2:
        raise ValueError(f"a wedge needs at least 2 steps, got {steps}")
    return np.rint(np.linspace(MAX_VALUE, 0, steps)).astype(np.uint16)


def step_wedge(
    steps: int = 21,
    patch_width: int = 100,
    patch_height: int = 100,
    *,
    vertical: bool = False,
) -> NDArray[np.uint16]:
    """A step wedge image: one flat patch per level, white first.

    Horizontal by default (patches left to right); `vertical=True` stacks them
    top to bottom.
    """
    if patch_width < 1 or patch_height < 1:
        raise ValueError(f"patch size must be positive, got {patch_width}x{patch_height}")
    levels = wedge_levels(steps)
    if vertical:
        return np.repeat(levels, patch_height)[:, np.newaxis].repeat(patch_width, axis=1)
    return np.repeat(levels, patch_width)[np.newaxis, :].repeat(patch_height, axis=0)
