"""Darkroom marks: a black guide line round the image and registration marks.

Red and orange negatives all but vanish under a red safelight, so lining one up on the
tissue is guesswork. Black ink shows there. Both marks sit in the band round the image
(a negative's safe edge, or a white border added round a print), so on a negative they
block UV like the rest of the safe edge and never reach the contact print:

- the guide line: a thin black line right against the image, showing exactly where it is;
- registration marks: a crosshair target centred on each side, and corner crop marks
  that continue the image's edges out to the edge of the sheet.

For separations (several negatives printed in register on one sheet of paper) the targets can
instead be cut clear, like the F: they expose onto the paper with the first coat, and each
later negative is lined up on them.

Everything is in whole pixels from the band's width, so Swift (Marks.swift) matches.
"""

from __future__ import annotations

import numpy as np
from numpy.typing import NDArray

# Inches of white paper added round a print to carry its marks.
PRINT_BORDER = 0.25
# The line is an eighth of the band, but never thicker than this (inches).
MAX_LINE = 0.04


def line_width(band: int, dpi: float) -> int:
    """Pixels across the guide line and the registration marks."""
    return max(1, min(band // 8, round(MAX_LINE * dpi)))


def mark_mask(
    width: int, height: int, band: int, dpi: float, guide: bool, registration: bool
) -> NDArray[np.bool_]:
    """Where the marks go on a `width` x `height` sheet whose image sits `band` pixels in
    from every side: True for black ink."""
    mask = np.zeros((height, width), dtype=bool)
    line = line_width(band, dpi)
    if band <= line:
        return mask  # no room round the image
    right, bottom = width - band, height - band  # the image's far edges (exclusive)
    if guide:
        mask[band - line : bottom + line, band - line : right + line] = True
        mask[band:bottom, band:right] = False
    if registration:
        crop = band // 2  # corner marks: the image's edges carried out to the sheet's
        for x in (band - line, right):
            mask[:crop, x : x + line] = True
            mask[height - crop :, x : x + line] = True
        for y in (band - line, bottom):
            mask[y : y + line, :crop] = True
            mask[y : y + line, width - crop :] = True
        _draw_targets(mask, band, line)
    return mask


def target_mask(width: int, height: int, band: int, dpi: float) -> NDArray[np.bool_]:
    """Just the crosshair targets of the registration marks (no crop marks)."""
    mask = np.zeros((height, width), dtype=bool)
    line = line_width(band, dpi)
    if band > line:
        _draw_targets(mask, band, line)
    return mask


def _draw_targets(mask: NDArray[np.bool_], band: int, line: int) -> None:
    """A crosshair target centred in the band on each side of the sheet."""
    height, width = mask.shape
    radius, arm = band * 3 // 10, band * 2 // 5
    if radius > line:
        middle_x, middle_y = width // 2, height // 2
        centres = [
            (middle_x, band // 2), (middle_x, height - 1 - band // 2),
            (band // 2, middle_y), (width - 1 - band // 2, middle_y),
        ]  # fmt: skip
        reach = max(radius, arm) + line  # every mark pixel is this close to its centre
        for cx, cy in centres:
            top, left = max(0, cy - reach), max(0, cx - reach)
            ys, xs = np.mgrid[top : min(height, cy + reach + 1), left : min(width, cx + reach + 1)]
            dx, dy = xs - cx, ys - cy
            distance = dx * dx + dy * dy
            target = (distance < radius * radius) & (distance >= (radius - line) ** 2)
            across = (dx >= -(line // 2)) & (dx < line - line // 2)
            down = (dy >= -(line // 2)) & (dy < line - line // 2)
            target |= (across & (np.abs(dy) <= arm)) | (down & (np.abs(dx) <= arm))
            mask[top : top + target.shape[0], left : left + target.shape[1]] |= target


def add_print_marks(
    image: NDArray[np.uint16], dpi: float, guide: bool, registration: bool
) -> NDArray[np.uint16]:
    """A print (H, W, 3) inside a white border carrying its marks in black."""
    if not (guide or registration):
        return image
    band = round(PRINT_BORDER * dpi)
    framed = np.pad(image, ((band, band), (band, band), (0, 0)), constant_values=65535)
    framed[mark_mask(framed.shape[1], framed.shape[0], band, dpi, guide, registration)] = 0
    return framed
