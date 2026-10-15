"""Split a 16-bit greyscale image into per-ink channels using a curve.

Image convention: 0 is black and 65535 is white. Curve convention: index 0 is
paper white. So each pixel's curve position is `65535 - pixel`.
"""

from __future__ import annotations

import warnings

import numpy as np
from numpy.typing import NDArray

from openquad.curves import curve_luts
from openquad.quadfile import MAX_VALUE, QuadCurve


class InkLimitWarning(UserWarning):
    """A curve lays down more total ink than the requested limit."""


def max_total_ink(curve: QuadCurve) -> float:
    """The highest combined ink of all channels at any tone, as a percentage.

    100% is one channel at full ink. Interpolation is linear, so the maximum is
    always at one of the 256 curve points.
    """
    totals = curve.values.astype(np.float64).sum(axis=0)
    return float(totals.max() / MAX_VALUE * 100.0)


def check_total_ink(curve: QuadCurve, limit_percent: float) -> float:
    """Warn with `InkLimitWarning` if the curve's total ink exceeds the limit."""
    total = max_total_ink(curve)
    if total > limit_percent:
        warnings.warn(
            f"curve lays down up to {total:.1f}% total ink, above the {limit_percent:.1f}% limit",
            InkLimitWarning,
            stacklevel=2,
        )
    return total


def separate(
    image: NDArray[np.uint16],
    curve: QuadCurve,
    *,
    total_ink_limit: float | None = None,
    chunk_rows: int = 512,
) -> NDArray[np.uint16]:
    """Return ink amounts with shape (channels, height, width), dtype uint16.

    Works in bands of `chunk_rows` rows so large prints don't need a temporary
    array of the full size per step.
    """
    if image.dtype != np.uint16:
        raise TypeError(f"image must be uint16, got {image.dtype}")
    if image.ndim != 2:
        raise ValueError(f"image must be 2-D greyscale, got shape {image.shape}")
    if chunk_rows < 1:
        raise ValueError(f"chunk_rows must be at least 1, got {chunk_rows}")
    if total_ink_limit is not None:
        check_total_ink(curve, total_ink_limit)

    luts = curve_luts(curve)
    height, width = image.shape
    out = np.empty((len(curve.channels), height, width), dtype=np.uint16)
    for top in range(0, height, chunk_rows):
        band = MAX_VALUE - image[top : top + chunk_rows]
        out[:, top : top + chunk_rows] = luts[:, band]
    return out
