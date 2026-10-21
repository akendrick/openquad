"""Tone linearization for the composite path.

After grey balance, a printer's steps are neutral but not evenly spaced: on
plain paper the deepest shadows run together. Linearization reshapes the input
so each grey level prints at the lightness it should, scaled into what the
paper can reach:

    target L*(g) = L*black + (L*paper - L*black) * L*sRGB(g) / 100

where L*sRGB(g) is the lightness an sRGB grey g has on screen (0 black, 100
white). That keeps the image's tonality and maps its black to the paper's
deepest black (black-point compensation).

The tone curve is folded into the calibration, so `apply` and printing are
unchanged: new curve_c(g) = old curve_c(tone(g)).
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
from numpy.typing import NDArray

from openquad.colour import linear_rgb_to_lab, srgb_to_linear
from openquad.greybalance import Calibration
from openquad.measure import Measurement
from openquad.quadfile import MAX_VALUE

FINE_LEVELS = 257  # resolution of the folded calibration curves


class LinearizeError(ValueError):
    """The measurement can't be linearized."""


def srgb_lightness(levels: NDArray[np.float64]) -> NDArray[np.float64]:
    """L* (0-100) of neutral sRGB greys given as 16-bit levels."""
    grey = srgb_to_linear(np.asarray(levels, dtype=np.float64) / MAX_VALUE)
    result: NDArray[np.float64] = linear_rgb_to_lab(np.stack([grey] * 3, axis=-1))[..., 0]
    return result


def target_lightness(
    levels: NDArray[np.float64], paper: float, black: float
) -> NDArray[np.float64]:
    """The L* each level should print at, between the paper's black and white."""
    result: NDArray[np.float64] = black + (paper - black) * srgb_lightness(levels) / 100.0
    return result


@dataclass(frozen=True)
class ToneReport:
    """Measured vs target lightness for each step of the measurement."""

    levels: NDArray[np.uint16]
    measured: NDArray[np.float64]
    target: NDArray[np.float64]

    @property
    def errors(self) -> NDArray[np.float64]:
        result: NDArray[np.float64] = self.measured - self.target
        return result

    def worst(self) -> float:
        return float(np.abs(self.errors).max())


def tone_report(measurement: Measurement) -> ToneReport:
    order = np.argsort(measurement.levels)
    measured = measurement.lab[order, 0]
    levels = measurement.levels[order]
    target = target_lightness(
        levels.astype(np.float64), float(measured.max()), float(measured.min())
    )
    return ToneReport(levels=levels, measured=measured, target=target)


def tone_curve(measurement: Measurement, points: int = FINE_LEVELS) -> NDArray[np.float64]:
    """Input level -> level to use instead, sampled at `points` evenly spaced levels.

    The measured lightness is made monotonic (darker input never prints lighter)
    and inverted at each level's target lightness.
    """
    report = tone_report(measurement)
    levels = report.levels.astype(np.float64)
    if len(levels) < 3:
        raise LinearizeError("need at least 3 measured steps")
    # Enforce: lightness rises with level; tiny ramp keeps it strictly increasing.
    response = np.maximum.accumulate(report.measured) + np.arange(len(levels)) * 1e-6
    if response[-1] - response[0] < 10:
        raise LinearizeError("the measured steps barely differ in lightness; check the scan")
    grid = np.linspace(0.0, MAX_VALUE, points)
    wanted = target_lightness(grid, float(report.measured.max()), float(report.measured.min()))
    curve: NDArray[np.float64] = np.interp(wanted, response, levels)
    curve[0], curve[-1] = levels[0], levels[-1]  # keep the black and white ends
    return np.maximum.accumulate(curve)


def linearize(calibration: Calibration, measurement: Measurement) -> Calibration:
    """Fold a tone curve into `calibration`, which must be what the target was printed with.

    The measurement's levels are the target's input levels (before calibration),
    so the tone curve is in input terms and composes in front of the calibration.
    """
    expected = calibration.sent_for(measurement.levels)
    if not np.array_equal(expected, measurement.sent):
        raise LinearizeError(
            "this measurement wasn't printed with this calibration (sent values differ)"
        )
    grid = np.rint(np.linspace(0, MAX_VALUE, FINE_LEVELS)).astype(np.uint16)
    tone = np.rint(tone_curve(measurement, FINE_LEVELS)).astype(np.uint16)
    luts = calibration.luts()
    curves = np.stack([luts[c][tone] for c in range(3)])
    return Calibration(
        levels=grid,
        curves=curves,
        printer=calibration.printer,
        paper=calibration.paper,
        settings=(calibration.settings + "; tone linearized").lstrip("; "),
    )
