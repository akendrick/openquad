"""Step wedges printed beside the photo: a 31-step grey wedge, and for colour prints a
colour gamut wedge.

The grey wedge runs from paper white to full black in 31 equal steps and goes through the
same toning, calibration or process curve as the photo, so the print shows what that
does to every tone. The colour wedge is 31 hues round the colour wheel in three rows (a
tint, the full colour and a shade), to see how much of the colour the printer reaches.

A wedge is as long as the photo's side it sits along, and sits `gap` inches from the
print (or the negative's safe edge) on the chosen side, centred along it.
"""

from __future__ import annotations

from collections.abc import Sequence

import numpy as np
from numpy.typing import NDArray

from openquad.quadfile import MAX_VALUE

WEDGE_STEPS = 31
WEDGE_WIDTH = 0.4  # inches across the grey wedge
COLOUR_ROW = 0.2  # inches across each of the colour wedge's three rows
DEFAULT_GAP = 0.25  # inches between the print and its wedge
MAX_GAP = 2.0
SIDES = ("top", "bottom", "left", "right")
#: The colour wedge's rows: (saturation, value) for a tint, the full colour and a shade.
COLOUR_ROWS = ((0.5, 1.0), (1.0, 1.0), (1.0, 0.5))


def _edges(length: int, count: int) -> list[int]:
    """Where `count` equal patches start and end along `length` pixels."""
    return [round(i * length / count) for i in range(count + 1)]


def grey_wedge(length: int, thickness: int, horizontal: bool) -> NDArray[np.uint16]:
    """The grey wedge, greyscale (0 black, 65535 white): white to black, left to right
    (or top to bottom), `length` x `thickness` pixels."""
    if length < 1 or thickness < 1:
        raise ValueError("the wedge has no pixels")
    edges = _edges(length, WEDGE_STEPS)
    strip = np.empty(length, dtype=np.uint16)
    for i in range(WEDGE_STEPS):
        strip[edges[i] : edges[i + 1]] = round(
            MAX_VALUE * (WEDGE_STEPS - 1 - i) / (WEDGE_STEPS - 1)
        )
    wedge = np.tile(strip, (thickness, 1))
    return wedge if horizontal else np.ascontiguousarray(wedge.T)


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


def thickness(kind: str, border: float = 0.0) -> float:
    """Inches across a wedge ("grey" or "colour"), with `border` on each side."""
    across = WEDGE_WIDTH if kind == "grey" else COLOUR_ROW * len(COLOUR_ROWS)
    return across + 2 * border


def extra(kinds: Sequence[str], side: str, gap: float, border: float = 0.0) -> tuple[float, float]:
    """(width, height) in inches the wedges add to the print."""
    added = sum(gap + thickness(kind, border) for kind in kinds)
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
