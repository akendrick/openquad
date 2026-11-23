"""Colour maths: sRGB transfer functions, CIE XYZ and L*a*b*, and the CIEDE2000 difference.

OpenQuad's own measurements are L*a*b* under D65 (sRGB's white). Reference data for
measuring targets (IT8.7/2, ICC profiles) is under D50, so the XYZ to L*a*b* conversion
takes the white point.
"""

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
#: The ICC profile connection space white (D50), as XYZ with Y = 1.
D50_WHITE = np.array([0.9642, 1.0, 0.8249])


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


def xyz_to_lab(xyz: ArrayLike, white: ArrayLike = D65_WHITE) -> NDArray[np.float64]:
    """CIE XYZ (..., 3), Y = 1 for white, to L*a*b* (..., 3) relative to `white`."""
    ratio = np.asarray(xyz, dtype=np.float64) / np.asarray(white, dtype=np.float64)
    delta = 6.0 / 29.0
    f = np.where(ratio > delta**3, np.cbrt(ratio), ratio / (3 * delta**2) + 4.0 / 29.0)
    lab: NDArray[np.float64] = np.empty_like(f)
    lab[..., 0] = 116.0 * f[..., 1] - 16.0
    lab[..., 1] = 500.0 * (f[..., 0] - f[..., 1])
    lab[..., 2] = 200.0 * (f[..., 1] - f[..., 2])
    return lab


def lab_to_xyz(lab: ArrayLike, white: ArrayLike = D65_WHITE) -> NDArray[np.float64]:
    """CIE L*a*b* (..., 3) relative to `white` back to XYZ (..., 3), Y = 1 for white."""
    lab = np.asarray(lab, dtype=np.float64)
    fy = (lab[..., 0] + 16.0) / 116.0
    f = np.stack([fy + lab[..., 1] / 500.0, fy, fy - lab[..., 2] / 200.0], axis=-1)
    delta = 6.0 / 29.0
    ratio = np.where(f > delta, f**3, 3 * delta**2 * (f - 4.0 / 29.0))
    xyz: NDArray[np.float64] = ratio * np.asarray(white, dtype=np.float64)
    return xyz


def linear_rgb_to_lab(rgb: ArrayLike) -> NDArray[np.float64]:
    """Linear sRGB (..., 3) to CIE L*a*b* (..., 3), D65 white."""
    return xyz_to_lab(np.asarray(rgb, dtype=np.float64) @ _RGB_TO_XYZ.T)


def delta_e_2000(lab1: ArrayLike, lab2: ArrayLike) -> NDArray[np.float64]:
    """The CIEDE2000 colour difference between L*a*b* colours (..., 3), with kL = kC = kH = 1.

    Follows Sharma, Wu and Dalal (2005), whose test pairs the tests check against.
    """
    lab1, lab2 = np.asarray(lab1, dtype=np.float64), np.asarray(lab2, dtype=np.float64)
    l1, a1, b1 = lab1[..., 0], lab1[..., 1], lab1[..., 2]
    l2, a2, b2 = lab2[..., 0], lab2[..., 1], lab2[..., 2]
    c_mean = (np.hypot(a1, b1) + np.hypot(a2, b2)) / 2
    g = 0.5 * (1 - np.sqrt(c_mean**7 / (c_mean**7 + 25.0**7)))
    a1p, a2p = (1 + g) * a1, (1 + g) * a2
    c1p, c2p = np.hypot(a1p, b1), np.hypot(a2p, b2)
    h1p = np.degrees(np.arctan2(b1, a1p)) % 360
    h2p = np.degrees(np.arctan2(b2, a2p)) % 360

    dl = l2 - l1
    dc = c2p - c1p
    dh = h2p - h1p
    dh = np.where(dh > 180, dh - 360, np.where(dh < -180, dh + 360, dh))
    dh = np.where(c1p * c2p == 0, 0.0, dh)
    dhh = 2 * np.sqrt(c1p * c2p) * np.sin(np.radians(dh / 2))

    l_mean = (l1 + l2) / 2
    cp_mean = (c1p + c2p) / 2
    h_sum = h1p + h2p
    h_mean = np.where(
        np.abs(h1p - h2p) <= 180,
        h_sum / 2,
        np.where(h_sum < 360, (h_sum + 360) / 2, (h_sum - 360) / 2),
    )
    h_mean = np.where(c1p * c2p == 0, h_sum, h_mean)
    t = (
        1
        - 0.17 * np.cos(np.radians(h_mean - 30))
        + 0.24 * np.cos(np.radians(2 * h_mean))
        + 0.32 * np.cos(np.radians(3 * h_mean + 6))
        - 0.20 * np.cos(np.radians(4 * h_mean - 63))
    )
    sl = 1 + 0.015 * (l_mean - 50) ** 2 / np.sqrt(20 + (l_mean - 50) ** 2)
    sc = 1 + 0.045 * cp_mean
    sh = 1 + 0.015 * cp_mean * t
    rc = 2 * np.sqrt(cp_mean**7 / (cp_mean**7 + 25.0**7))
    rt = -np.sin(np.radians(60 * np.exp(-(((h_mean - 275) / 25) ** 2)))) * rc
    result: NDArray[np.float64] = np.sqrt(
        (dl / sl) ** 2 + (dc / sc) ** 2 + (dhh / sh) ** 2 + rt * (dc / sc) * (dhh / sh)
    )
    return result


def luminance(rgb: ArrayLike) -> NDArray[np.float64]:
    """Relative luminance Y (0-1) of linear sRGB values (..., 3)."""
    result: NDArray[np.float64] = np.asarray(rgb, dtype=np.float64) @ _RGB_TO_XYZ[1]
    return result
