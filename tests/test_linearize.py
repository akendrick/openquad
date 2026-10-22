"""Tone linearization: simulated printer end to end, plus the real Canon data."""

from pathlib import Path

import numpy as np
import pytest

from openquad.greybalance import Calibration, build_calibration, load_calibration
from openquad.linearize import (
    LinearizeError,
    linearize,
    srgb_lightness,
    target_lightness,
    tone_curve,
    tone_report,
)
from openquad.measure import Measurement
from tests.test_greybalance import round_trip

REAL = (
    Path(__file__).resolve().parents[1] / "calibration-data" / "canon-mg3600-plain" / "2026-10-20"
)


def grey_balanced() -> tuple[Calibration, Measurement]:
    """Two grey-balance passes on the simulated printer, then a measurement with the result."""
    calibration = Calibration.identity()
    for _ in range(2):
        calibration = build_calibration(round_trip(calibration))
    return calibration, round_trip(calibration)


def test_srgb_lightness_end_points() -> None:
    assert srgb_lightness(np.array([0.0, 65535.0])) == pytest.approx([0.0, 100.0], abs=1e-6)
    assert srgb_lightness(np.array([32768.0]))[0] == pytest.approx(53.4, abs=0.2)


def test_target_spans_paper_black_to_paper_white() -> None:
    assert target_lightness(np.array([0.0, 65535.0]), 98.0, 27.0) == pytest.approx([27.0, 98.0])


def test_simulated_printer_is_not_linear_before() -> None:
    _, measured = grey_balanced()
    assert tone_report(measured).worst() > 3


def test_linearized_print_hits_its_targets() -> None:
    calibration, measured = grey_balanced()
    after = round_trip(linearize(calibration, measured))
    assert tone_report(after).worst() < 1.5  # Phase 3 gate is 2
    assert after.worst_cast() < 3  # grey balance survives


def test_linearizing_an_already_linear_printer_changes_little() -> None:
    _, measured = grey_balanced()
    report = tone_report(measured)
    perfect = Measurement(
        levels=measured.levels,
        sent=measured.sent,
        rgb=measured.rgb,
        lab=np.column_stack(
            [np.interp(measured.levels, report.levels, report.target), measured.lab[:, 1:]]
        ),
    )
    curve = tone_curve(perfect, 21)
    assert np.abs(curve - np.linspace(0, 65535, 21)).max() < 300


def test_tone_curve_is_monotonic_and_keeps_its_ends() -> None:
    _, measured = grey_balanced()
    curve = tone_curve(measured)
    assert curve[0] == 0 and curve[-1] == 65535
    assert np.all(np.diff(curve) >= 0)


def test_measurement_must_match_the_calibration() -> None:
    calibration, measured = grey_balanced()
    with pytest.raises(LinearizeError, match="wasn't printed with this calibration"):
        linearize(Calibration.identity(), measured)
    del calibration


def test_flat_measurement_is_refused() -> None:
    _, measured = grey_balanced()
    flat = Measurement(measured.levels, measured.sent, measured.rgb, np.full((21, 3), 50.0))
    with pytest.raises(LinearizeError, match="barely differ"):
        tone_curve(flat)


def test_too_few_steps_are_refused() -> None:
    _, m = grey_balanced()
    short = Measurement(m.levels[:2], m.sent[:2], m.rgb[:2], m.lab[:2])
    with pytest.raises(LinearizeError, match="at least 3"):
        tone_curve(short)


# --- the real Canon MG3600 data ------------------------------------------------------


def test_real_canon_shadows_get_spread_out() -> None:
    v3 = load_calibration(REAL / "canon-plain-v3.oqcal")
    measured = Measurement.from_json((REAL / "m6-corrected.json").read_text())
    report = tone_report(measured)
    assert report.measured.min() == pytest.approx(27.0, abs=0.1)  # plain-paper black
    linear = linearize(v3, measured)
    tone = tone_curve(measured, 21)
    # Steps 19-21 printed at L* 27-27.5: the curve must lift the near-black steps.
    assert tone[1] > np.linspace(0, 65535, 21)[1] * 1.5
    assert np.all(np.diff(linear.curves.astype(int), axis=1) >= 0)
    assert linear.settings.endswith("tone linearized")
