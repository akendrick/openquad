"""Curve maths: 16-bit lookup tables, ink limits and parametric curve generation.

Input positions run from 0.0 (paper white) to 1.0 (maximum density), matching
the index order of a `.quad` channel (0 to 255).
"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass

import numpy as np
from numpy.typing import ArrayLike, NDArray

from openquad.quadfile import LEVELS, MAX_VALUE, STANDARD_CHANNELS, QuadCurve

LUT_SIZE = MAX_VALUE + 1
_NODES = np.linspace(0.0, MAX_VALUE, LEVELS)


def expand(values: ArrayLike) -> NDArray[np.uint16]:
    """Interpolate a 256-point curve to a 65,536-entry lookup table.

    Linear interpolation, so the table passes through every original point and a
    monotonic curve stays monotonic.
    """
    points = np.asarray(values, dtype=np.float64)
    if points.shape != (LEVELS,):
        raise ValueError(f"a curve has {LEVELS} points, got shape {points.shape}")
    table = np.interp(np.arange(LUT_SIZE, dtype=np.float64), _NODES, points)
    return np.rint(table).astype(np.uint16)


def curve_luts(curve: QuadCurve) -> NDArray[np.uint16]:
    """One 65,536-entry lookup table per channel, shape (channels, 65536)."""
    return np.stack([expand(row) for row in curve.values])


def scale_limit(values: ArrayLike, limit_percent: float) -> NDArray[np.uint16]:
    """Scale a curve so its full-density point uses `limit_percent` of the original ink."""
    if not 0.0 <= limit_percent <= 100.0:
        raise ValueError(f"ink limit must be 0-100%, got {limit_percent}")
    scaled = np.asarray(values, dtype=np.float64) * (limit_percent / 100.0)
    return np.rint(scaled).astype(np.uint16)


@dataclass(frozen=True)
class InkSpec:
    """How one ink contributes across the tonal range.

    The ink is absent below `start`, rises linearly to `limit` percent at `peak`,
    then fades linearly to nothing at `end`. Use `peak == end == 1.0` for the
    darkest ink, which keeps rising to maximum density.
    """

    channel: str
    limit: float
    start: float
    peak: float
    end: float = 1.0

    def __post_init__(self) -> None:
        if not 0.0 <= self.limit <= 100.0:
            raise ValueError(f"{self.channel}: limit must be 0-100%, got {self.limit}")
        if not 0.0 <= self.start < self.peak <= self.end <= 1.0:
            raise ValueError(
                f"{self.channel}: need 0 <= start < peak <= end <= 1, got "
                f"start={self.start}, peak={self.peak}, end={self.end}"
            )

    def ramp(self, positions: NDArray[np.float64]) -> NDArray[np.float64]:
        """Ink amount (0.0-1.0 of full ink) at each input position."""
        rise = (positions - self.start) / (self.peak - self.start)
        if self.end > self.peak:
            fall = (self.end - positions) / (self.end - self.peak)
        else:
            fall = np.ones_like(positions)
        shape = np.clip(np.minimum(rise, fall), 0.0, 1.0)
        result: NDArray[np.float64] = shape * (self.limit / 100.0)
        return result


def build_curve(
    inks: Sequence[InkSpec],
    channels: Sequence[str] = STANDARD_CHANNELS,
    gamma: float = 1.0,
) -> QuadCurve:
    """Generate a curve from ink specifications. Channels without a spec stay at zero.

    `gamma` reshapes the input axis (position ** gamma) before the ramps are applied:
    above 1.0 pushes ink towards the shadows, below 1.0 towards the highlights.
    """
    if gamma <= 0.0:
        raise ValueError(f"gamma must be positive, got {gamma}")
    names = tuple(channels)
    seen: set[str] = set()
    values = np.zeros((len(names), LEVELS), dtype=np.float64)
    positions = np.linspace(0.0, 1.0, LEVELS) ** gamma
    for ink in inks:
        if ink.channel not in names:
            raise ValueError(f"ink {ink.channel!r} is not one of the channels {names}")
        if ink.channel in seen:
            raise ValueError(f"ink {ink.channel!r} is specified twice")
        seen.add(ink.channel)
        values[names.index(ink.channel)] = ink.ramp(positions) * MAX_VALUE
    return QuadCurve.from_values(names, np.rint(values).astype(np.uint16))
