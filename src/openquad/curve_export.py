"""Process curves as files other software reads, as ChartThrob's Photoshop curves are.

A process curve maps a photo's grey level to the level the negative is made from, so
applying the exported curve to a greyscale photo (then inverting it, in that colour)
makes the same negative OpenQuad does.

- .amp  Photoshop arbitrary map: 256 levels, the curve exactly (to 8 bits).
- .acv  Photoshop Curves: at most 16 points, placed where the spline strays most.
- .cube a 3D LUT (Adobe/Resolve format) for editors with LUT layers; 33 steps a side.
- .csv  the curve itself: 257 16-bit levels in, levels out.
- .tif  a greyscale photo with the curve applied (16-bit), ready to invert and print.
"""

from __future__ import annotations

import struct
from pathlib import Path

import numpy as np
from numpy.typing import NDArray

from openquad.chart import ProcessCurve
from openquad.quadfile import MAX_VALUE

ACV_POINTS = 16  # Photoshop's limit
CUBE_SIZE = 33
FORMATS = (".amp", ".acv", ".cube", ".csv")


def _value(curve: ProcessCurve, level: float) -> float:
    return float(np.interp(level, curve.levels.astype(np.float64), curve.curve.astype(np.float64)))


def _levels8(curve: ProcessCurve) -> list[float]:
    """The curve at 256 levels, unrounded (0-255 in and out)."""
    return [_value(curve, i * 257.0) / 257.0 for i in range(256)]


def lut8(curve: ProcessCurve) -> NDArray[np.uint8]:
    """The curve at 256 levels (0-255 in and out)."""
    return np.clip(np.rint(_levels8(curve)), 0, 255).astype(np.uint8)


def amp_bytes(curve: ProcessCurve) -> bytes:
    return lut8(curve).tobytes()


def spline(xs: list[int], ys: list[int], at: int) -> float:
    """A natural cubic spline through (xs, ys) at `at` (as Photoshop's Curves draws)."""
    n = len(xs)
    if n == 2:
        return ys[0] + (ys[1] - ys[0]) * (at - xs[0]) / (xs[1] - xs[0])
    h = [float(xs[k + 1] - xs[k]) for k in range(n - 1)]
    # Second derivatives m (m[0] = m[n-1] = 0) by the tridiagonal (Thomas) solve.
    diag = [2.0 * (h[k - 1] + h[k]) for k in range(1, n - 1)]
    rhs = [
        6.0 * ((ys[k + 1] - ys[k]) / h[k] - (ys[k] - ys[k - 1]) / h[k - 1]) for k in range(1, n - 1)
    ]
    for k in range(1, n - 2):
        f = h[k] / diag[k - 1]
        diag[k] -= f * h[k]
        rhs[k] -= f * rhs[k - 1]
    inner = [0.0] * (n - 2)
    for k in range(n - 3, -1, -1):
        upper = h[k + 1] * inner[k + 1] if k + 1 < n - 2 else 0.0
        inner[k] = (rhs[k] - upper) / diag[k]
    m = [0.0, *inner, 0.0]
    k = 0
    while k < n - 2 and at > xs[k + 1]:
        k += 1
    a, b = xs[k + 1] - at, at - xs[k]
    return (
        m[k] * a * a * a / (6.0 * h[k])
        + m[k + 1] * b * b * b / (6.0 * h[k])
        + (ys[k] - m[k] * h[k] * h[k] / 6.0) * a / h[k]
        + (ys[k + 1] - m[k + 1] * h[k] * h[k] / 6.0) * b / h[k]
    )


def acv_points(curve: ProcessCurve, limit: int = ACV_POINTS) -> list[tuple[int, int]]:
    """(input, output) points (0-255) whose spline follows the curve within half a level,
    or as near as `limit` points allow: each added where the spline strays most (from
    the unrounded curve, so points aren't spent on 8-bit rounding steps)."""
    exact = _levels8(curve)
    stored = [int(v) for v in lut8(curve)]
    xs = [0, 255]
    while len(xs) < limit:
        ys = [stored[x] for x in xs]
        errors = [abs(spline(xs, ys, i) - exact[i]) for i in range(256)]
        worst = max(range(256), key=lambda i: (errors[i], -i))
        if errors[worst] <= 0.5:
            break
        xs = sorted([*xs, worst])
    return [(x, stored[x]) for x in xs]


def acv_bytes(curve: ProcessCurve) -> bytes:
    """A Photoshop Curves file (version 1): the curve on the composite (grey) channel and
    unchanged red, green, blue and a spare, as Photoshop writes."""
    out = struct.pack(">HH", 1, 5)
    points = acv_points(curve)
    out += struct.pack(">H", len(points)) + b"".join(struct.pack(">HH", y, x) for x, y in points)
    for _ in range(4):
        out += struct.pack(">HHHHH", 2, 0, 0, 255, 255)
    return out


def cube_text(
    curve: ProcessCurve, size: int = CUBE_SIZE, title: str = "OpenQuad process curve"
) -> str:
    values = [_value(curve, k / (size - 1) * MAX_VALUE) / MAX_VALUE for k in range(size)]
    lines = [f'TITLE "{title}"', f"LUT_3D_SIZE {size}"]
    for b in range(size):
        for g in range(size):
            lines += [f"{values[r]:.6f} {values[g]:.6f} {values[b]:.6f}" for r in range(size)]
    return "\n".join(lines) + "\n"


def csv_text(curve: ProcessCurve) -> str:
    rows = [f"{i},{o}" for i, o in zip(curve.levels.tolist(), curve.curve.tolist(), strict=True)]
    return "\n".join(["input,output", *rows]) + "\n"


def export_curve(curve: ProcessCurve, path: str | Path) -> None:
    """Write `curve` in the format its suffix names (FORMATS)."""
    path = Path(path)
    suffix = path.suffix.lower()
    if suffix == ".amp":
        path.write_bytes(amp_bytes(curve))
    elif suffix == ".acv":
        path.write_bytes(acv_bytes(curve))
    elif suffix == ".cube":
        path.write_text(
            cube_text(curve, title=f"OpenQuad {curve.colour} process"), encoding="utf-8"
        )
    elif suffix == ".csv":
        path.write_text(csv_text(curve), encoding="utf-8")
    else:
        raise ValueError(
            f"can't export to {suffix or 'no suffix'}; use one of {', '.join(FORMATS)}"
        )
