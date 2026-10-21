"""Colour maths: sRGB transfer functions and CIE L*a*b* (D65)."""

from __future__ import annotations

import numpy as np
from numpy.typing import ArrayLike, NDArray

# Linear sRGB (D65) to CIE XYZ.
_RGB_TO_XYZ = np.array(
    [
        [0.4124564, 0.3575761, 0.1804375],
        [0.2126729, 0.7151522, 0.0721750],
        [0.0193339, 0.1191920, 0.9503041],
    ]
)
D65_WHITE = _RGB_TO_XYZ.sum(axis=1)


def srgb_to_linear(values: ArrayLike) -> NDArray[np.float64]:
    """sRGB-encoded 0-1 values to linear light."""
    v = np.asarray(values, dtype=np.float64)
    result: NDArray[np.float64] = np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)
    return result


def linear_to_srgb(values: ArrayLike) -> NDArray[np.float64]:
    """Linear light 0-1 values to sRGB encoding."""
    v = np.clip(np.asarray(values, dtype=np.float64), 0.0, 1.0)
    result: NDArray[np.float64] = np.where(
        v <= 0.0031308, v * 12.92, 1.055 * v ** (1 / 2.4) - 0.055
    )
    return result


def linear_rgb_to_lab(rgb: ArrayLike) -> NDArray[np.float64]:
    """Linear sRGB (..., 3) to CIE L*a*b* (..., 3), D65 white."""
    xyz = np.asarray(rgb, dtype=np.float64) @ _RGB_TO_XYZ.T / D65_WHITE
    delta = 6.0 / 29.0
    f = np.where(xyz > delta**3, np.cbrt(xyz), xyz / (3 * delta**2) + 4.0 / 29.0)
    lab: NDArray[np.float64] = np.empty_like(f)
    lab[..., 0] = 116.0 * f[..., 1] - 16.0
    lab[..., 1] = 500.0 * (f[..., 0] - f[..., 1])
    lab[..., 2] = 200.0 * (f[..., 1] - f[..., 2])
    return lab


def luminance(rgb: ArrayLike) -> NDArray[np.float64]:
    """Relative luminance Y (0-1) of linear sRGB values (..., 3)."""
    result: NDArray[np.float64] = np.asarray(rgb, dtype=np.float64) @ _RGB_TO_XYZ[1]
    return result
