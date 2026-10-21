"""Calibration targets: step wedges to print and measure."""

from __future__ import annotations

from dataclasses import dataclass

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


@dataclass(frozen=True)
class FramedLayout:
    """Geometry of the framed grey-balance target, in inches.

    Two wedge rows sit inside a thin black frame: the top row runs white to
    black, the bottom row black to white, so unevenness across the page averages
    out. Measurement finds the frame in a scan and scales this layout to it.
    """

    steps: int = 21
    patch_width: float = 0.32
    patch_height: float = 0.8
    row_gap: float = 0.2
    frame: float = 0.04
    inset: float = 0.12

    @property
    def width(self) -> float:
        return self.steps * self.patch_width + 2 * (self.frame + self.inset)

    @property
    def height(self) -> float:
        return 2 * self.patch_height + self.row_gap + 2 * (self.frame + self.inset)

    def patch_boxes(self) -> list[tuple[int, float, float, float, float]]:
        """(level index, left, top, right, bottom) in inches from the frame's outer corner.

        Level index 0 is white. The top row runs 0..steps-1, the bottom row reversed.
        """
        edge = self.frame + self.inset
        boxes = []
        for row in range(2):
            top = edge + row * (self.patch_height + self.row_gap)
            for column in range(self.steps):
                level = column if row == 0 else self.steps - 1 - column
                left = edge + column * self.patch_width
                boxes.append((level, left, top, left + self.patch_width, top + self.patch_height))
        return boxes

    def paper_box(self) -> tuple[float, float, float, float]:
        """A strip of bare paper inside the frame, between the two rows."""
        edge = self.frame + self.inset
        top = edge + self.patch_height + 0.25 * self.row_gap
        return (edge, top, self.width - edge, top + 0.5 * self.row_gap)


def framed_target(layout: FramedLayout | None = None, dpi: float = 300.0) -> NDArray[np.uint16]:
    """The grey-balance target as neutral 16-bit RGB (R = G = B) on white paper."""
    layout = layout or FramedLayout()
    levels = wedge_levels(layout.steps)

    def px(inches: float) -> int:
        return round(inches * dpi)

    sheet = np.full((px(layout.height), px(layout.width), 3), MAX_VALUE, dtype=np.uint16)
    f = px(layout.frame)
    sheet[:f], sheet[-f:], sheet[:, :f], sheet[:, -f:] = 0, 0, 0, 0
    for level, left, top, right, bottom in layout.patch_boxes():
        sheet[px(top) : px(bottom), px(left) : px(right)] = levels[level]
    return sheet
