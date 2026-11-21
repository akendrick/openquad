"""Step wedges printed beside the photo: a grey step wedge, and for colour prints a colour
gamut wedge.

The grey wedge runs from paper white to full black in equal steps and goes through the
same toning, calibration or process curve as the photo, so the print shows what that
does to every tone. The colour wedge is 31 hues round the colour wheel in three rows (a
tint, the full colour and a shade), to see how much of the colour the printer reaches.

The grey wedge has 11, 21, 31 or 51 steps, any width from 0.2 to 1 in, and comes as a plain
strip or in the style of the printer calibration target: two rows (white to black, then
black to white) inside a thin black frame. Its steps can be numbered in a band beside it.

A wedge is as long as the photo's side it sits along, and sits `gap` inches from the
print (or the negative's safe edge) on the chosen side, centred along it.
"""

from __future__ import annotations

from collections.abc import Sequence

import numpy as np
from numpy.typing import NDArray

from openquad.negative import DIGIT_GLYPHS
from openquad.quadfile import MAX_VALUE

WEDGE_STEPS = 31
STEP_CHOICES = (11, 21, 31, 51)
WEDGE_WIDTH = 0.4  # inches across the grey wedge
MIN_WIDTH, MAX_WIDTH = 0.2, 1.0
STYLES = ("strip", "calibration")
FRAME = 0.03  # inches: the calibration style's black frame, and the white inset inside it
LABEL_BAND = 0.15  # inches across the band of step numbers
COLOUR_ROW = 0.2  # inches across each of the colour wedge's three rows
DEFAULT_GAP = 0.0  # inches between the print and its wedge
MAX_GAP = 2.0
SIDES = ("top", "bottom", "left", "right")
#: The colour wedge's rows: (saturation, value) for a tint, the full colour and a shade.
COLOUR_ROWS = ((0.5, 1.0), (1.0, 1.0), (1.0, 0.5))


def _edges(length: int, count: int) -> list[int]:
    """Where `count` equal patches start and end along `length` pixels."""
    return [round(i * length / count) for i in range(count + 1)]


def _frame(length: int, thickness: int, steps: int, frame: int) -> int:
    """The calibration style's frame in pixels: none if the wedge is too small for it."""
    if (thickness - 6 * frame) // 2 < 1 or length - 4 * frame < steps:
        return 0
    return frame


def _patches(
    length: int, thickness: int, steps: int, calibration: bool, frame: int
) -> tuple[int, list[int]]:
    """Where the patches start along the wedge: (offset, edges)."""
    if not calibration:
        return 0, _edges(length, steps)
    f = _frame(length, thickness, steps, frame)
    return 2 * f, _edges(length - 4 * f, steps)


def _level(i: int, steps: int) -> int:
    return round(MAX_VALUE * (steps - 1 - i) / (steps - 1))


def _grey_area(
    length: int, thickness: int, steps: int, calibration: bool, frame: int
) -> NDArray[np.uint16]:
    """The wedge itself, laid out horizontally: (thickness, length)."""
    area = np.full((thickness, length), MAX_VALUE, dtype=np.uint16)
    offset, edges = _patches(length, thickness, steps, calibration, frame)
    if not calibration:
        for i in range(steps):
            area[:, edges[i] : edges[i + 1]] = _level(i, steps)
        return area
    f = offset // 2
    if f:
        area[:f], area[-f:], area[:, :f], area[:, -f:] = 0, 0, 0, 0
    rows = (thickness - 6 * f) // 2
    second = thickness - 2 * f - rows
    for i in range(steps):
        left, right = offset + edges[i], offset + edges[i + 1]
        area[2 * f : 2 * f + rows, left:right] = _level(i, steps)
        area[second : second + rows, left:right] = _level(steps - 1 - i, steps)
    return area


def _label_band(
    length: int, thickness: int, band: int, steps: int, calibration: bool, frame: int,
    horizontal: bool,
) -> NDArray[np.uint16]:  # fmt: skip
    """The step numbers in black on white, beside the wedge: (band, length) or (length, band).
    Every step is numbered if there's room, else every 2nd, 5th, 10th..."""
    canvas = np.full((band, length) if horizontal else (length, band), MAX_VALUE, dtype=np.uint16)
    cell = band // 12
    if cell < 1:
        return canvas
    offset, edges = _patches(length, thickness, steps, calibration, frame)
    narrowest = min(edges[i + 1] - edges[i] for i in range(steps))
    needed = (6 * len(str(steps)) + 1) * cell if horizontal else 8 * cell
    every = next((k for k in (1, 2, 5, 10, 25) if needed <= narrowest * k), steps)
    for i in range(0, steps, every):
        text = str(i + 1)
        wide, high = len(text) * 6 * cell - cell, 7 * cell
        start, span = offset + edges[i], edges[i + 1] - edges[i]
        if wide > (length if horizontal else band) or high > (band if horizontal else length):
            break
        if horizontal:
            x = min(max(start + (span - wide) // 2, 0), length - wide)
            y = (band - high) // 2
        else:
            x = (band - wide) // 2
            y = min(max(start + (span - high) // 2, 0), length - high)
        for j, digit in enumerate(text):
            glyph = np.kron(DIGIT_GLYPHS[int(digit)], np.ones((cell, cell), dtype=bool))
            left = x + j * 6 * cell
            region = canvas[y : y + high, left : left + 5 * cell]
            region[glyph] = 0
    return canvas


def grey_wedge(
    length: int, thickness: int, horizontal: bool, steps: int = WEDGE_STEPS,
    calibration: bool = False, frame: int = 0, band: int = 0, band_first: bool = False,
) -> NDArray[np.uint16]:  # fmt: skip
    """The grey wedge, greyscale (0 black, 65535 white): white to black, left to right (or
    top to bottom), `length` x `thickness` pixels, plus a `band` of step numbers beside it
    (before the wedge if `band_first`). The calibration style has two rows inside a black
    frame `frame` pixels wide."""
    if length < 1 or thickness < 1:
        raise ValueError("the wedge has no pixels")
    if steps < 2:
        raise ValueError(f"a wedge needs at least 2 steps, got {steps}")
    calibration = calibration and thickness >= 2
    wedge = _grey_area(length, thickness, steps, calibration, frame)
    if not horizontal:
        wedge = np.ascontiguousarray(wedge.T)
    if band < 1:
        return wedge
    labels = _label_band(length, thickness, band, steps, calibration, frame, horizontal)
    parts = [labels, wedge] if band_first else [wedge, labels]
    return np.ascontiguousarray(np.concatenate(parts, axis=0 if horizontal else 1))


def hsv_to_rgb(hue: float, saturation: float, value: float) -> tuple[float, float, float]:
    """HSV (each 0-1) to RGB (0-1), as colorsys does."""
    if saturation == 0.0:
        return value, value, value
    i = int(hue * 6.0)
    f = hue * 6.0 - i
    p, q = value * (1.0 - saturation), value * (1.0 - saturation * f)
    t = value * (1.0 - saturation * (1.0 - f))
    return [(value, t, p), (q, value, p), (p, value, t), (p, q, value), (t, p, value),
            (value, p, q)][i % 6]  # fmt: skip


def colour_wedge(length: int, row: int, horizontal: bool) -> NDArray[np.uint16]:
    """The colour gamut wedge, 16-bit sRGB: 31 hues from red round the wheel, in three rows
    (tint, full colour, shade) of `row` pixels each."""
    if length < 1 or row < 1:
        raise ValueError("the wedge has no pixels")
    edges = _edges(length, WEDGE_STEPS)
    wedge = np.empty((row * len(COLOUR_ROWS), length, 3), dtype=np.uint16)
    for r, (saturation, value) in enumerate(COLOUR_ROWS):
        for i in range(WEDGE_STEPS):
            rgb = hsv_to_rgb(i / WEDGE_STEPS, saturation, value)
            wedge[r * row : (r + 1) * row, edges[i] : edges[i + 1]] = [
                round(MAX_VALUE * c) for c in rgb
            ]
    return wedge if horizontal else np.ascontiguousarray(wedge.transpose(1, 0, 2))


def thickness(
    kind: str, border: float = 0.0, width: float = WEDGE_WIDTH, labels: bool = False
) -> float:
    """Inches across a wedge ("grey" or "colour"), with `border` on each side; a grey wedge
    `width` wide, with its band of step numbers if `labels`."""
    if kind == "grey":
        across = width + (LABEL_BAND if labels else 0.0)
    else:
        across = COLOUR_ROW * len(COLOUR_ROWS)
    return across + 2 * border


def extra(
    kinds: Sequence[str], side: str, gap: float, border: float = 0.0,
    width: float = WEDGE_WIDTH, labels: bool = False,
) -> tuple[float, float]:  # fmt: skip
    """(width, height) in inches the wedges add to the print."""
    added = sum(gap + thickness(kind, border, width, labels) for kind in kinds)
    return (added, 0.0) if side in ("left", "right") else (0.0, added)


def attach(
    image: NDArray[np.uint16], wedges: Sequence[NDArray[np.uint16]], side: str, gap: int
) -> NDArray[np.uint16]:
    """The image with its wedges on `side`, nearest first, `gap` pixels apart, each centred
    along the side, on white (clear film on a negative)."""
    if not wedges:
        return image
    if side not in SIDES:
        raise ValueError(f"unknown side {side!r}; choose from {', '.join(SIDES)}")
    horizontal = side in ("top", "bottom")
    axis = 0 if horizontal else 1  # the wedges stack along this axis
    parts: list[NDArray[np.uint16] | int] = [image]
    for wedge in wedges:
        parts += [gap, wedge]
    if side in ("top", "left"):
        parts.reverse()
    along = sum(p if isinstance(p, int) else p.shape[axis] for p in parts)
    across = max(p.shape[1 - axis] for p in parts if not isinstance(p, int))
    shape = (along, across, 3) if horizontal else (across, along, 3)
    canvas = np.full(shape, MAX_VALUE, dtype=np.uint16)
    at = 0
    for part in parts:
        if isinstance(part, int):
            at += part
            continue
        size, cross = part.shape[axis], part.shape[1 - axis]
        offset = (across - cross) // 2
        if horizontal:
            canvas[at : at + size, offset : offset + cross] = part
        else:
            canvas[offset : offset + cross, at : at + size] = part
        at += size
    return canvas
