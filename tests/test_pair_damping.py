"""Comparison-page measurement and damped grey-balance updates.

Includes regression tests on real scans from the Canon MG3600 (20 Oct 2026).
"""

from pathlib import Path

import numpy as np
import pytest

from openquad.greybalance import (
    Calibration,
    CalibrationError,
    build_calibration,
    comparison_page,
    load_calibration,
)
from openquad.measure import MeasureError, load_scan, measure_pair, measure_scan
from openquad.targets import wedge_levels
from tests.simulation import print_sheet, scan_sheet

DPI = 150
REAL = (
    Path(__file__).resolve().parents[1] / "calibration-data" / "canon-mg3600-plain" / "2026-10-20"
)


def simulated_page_scan(calibration: Calibration, rotate: bool = False) -> np.ndarray:
    scan = scan_sheet(print_sheet(comparison_page(calibration, dpi=DPI)), margin=60)
    return scan[::-1, ::-1] if rotate else scan


def first_pass() -> Calibration:
    identity = Calibration.identity()
    plain, _ = measure_pair(simulated_page_scan(identity), identity.sent_for(wedge_levels(21)))
    return build_calibration(plain)


# --- measure_pair --------------------------------------------------------------------


@pytest.mark.parametrize("rotate", [False, True])
def test_pair_identifies_both_targets_either_way_up(rotate: bool) -> None:
    calibration = first_pass()
    plain, corrected = measure_pair(
        simulated_page_scan(calibration, rotate), calibration.sent_for(wedge_levels(21))
    )
    assert plain.worst_cast() > 5
    assert corrected.worst_cast() < 3
    assert np.array_equal(corrected.sent, calibration.sent_for(wedge_levels(21)))
    assert np.array_equal(plain.sent[:, 0], plain.levels)  # uncorrected sent as neutral


def test_pair_needs_two_targets() -> None:
    page = simulated_page_scan(Calibration.identity())
    single = page[: page.shape[0] // 2]
    with pytest.raises(MeasureError, match="found one"):
        measure_pair(single, Calibration.identity().sent_for(wedge_levels(21)))


def test_pair_on_blank_scan() -> None:
    with pytest.raises(MeasureError, match="no targets"):
        measure_pair(np.ones((400, 300, 3)), Calibration.identity().sent_for(wedge_levels(21)))


def test_pair_without_marks_is_refused() -> None:
    page = simulated_page_scan(Calibration.identity()).copy()
    page[:, :115] = 0.97  # paint over the marks (they sit left of the frames)
    with pytest.raises(MeasureError, match="marks"):
        measure_pair(page, Calibration.identity().sent_for(wedge_levels(21)))


# --- real Canon MG3600 scans ---------------------------------------------------------


@pytest.mark.parametrize(
    ("scan", "calibration", "uncorrected", "corrected"),
    [
        ("scan4-document.jpg", "canon-plain.oqcal", 5.4, 2.5),
        ("scan5-v2.jpg", "canon-plain-v2.oqcal", 5.4, 2.9),
    ],
)
def test_real_canon_comparison_scans(
    scan: str, calibration: str, uncorrected: float, corrected: float
) -> None:
    cal = load_calibration(REAL / calibration)
    plain, fixed = measure_pair(load_scan(REAL / scan), cal.sent_for(wedge_levels(21)))
    assert plain.worst_cast() == pytest.approx(uncorrected, abs=0.1)
    assert fixed.worst_cast() == pytest.approx(corrected, abs=0.1)


def test_real_photo_intent_scan_still_measures() -> None:
    """The first, tightly auto-cropped Photo-intent scan."""
    measurement = measure_scan(load_scan(REAL / "scan1.jpg"))
    assert measurement.worst_cast() == pytest.approx(6.7, abs=0.1)


# --- damping -------------------------------------------------------------------------


def a_measurement():  # type: ignore[no-untyped-def]
    page = simulated_page_scan(Calibration.identity())
    plain, _ = measure_pair(page, Calibration.identity().sent_for(wedge_levels(21)))
    return plain


def test_zero_damping_changes_nothing() -> None:
    measured = a_measurement()
    calibration = build_calibration(measured, damping=0.0)
    assert np.array_equal(calibration.curves, Calibration.identity().curves)


def test_half_damping_goes_halfway() -> None:
    measured = a_measurement()
    full = build_calibration(measured).curves.astype(float)
    half = build_calibration(measured, damping=0.5).curves.astype(float)
    neutral = Calibration.identity().curves.astype(float)
    assert np.abs(half - (neutral + full) / 2).max() <= 1.0


def test_shadow_damping_only_touches_the_shadows() -> None:
    measured = a_measurement()
    full = build_calibration(measured)
    held = build_calibration(measured, shadow_damping=0.0)
    dark = full.levels <= 13107
    light = full.levels > 26214  # clear of the boundary, where monotonicity may lift a step
    assert np.array_equal(held.curves[:, light], full.curves[:, light])
    assert np.array_equal(held.curves[:, dark], Calibration.identity().curves[:, dark])


def test_damped_pass_improves_without_overshooting() -> None:
    measured = a_measurement()
    for damping in (0.5, 1.0):
        calibration = build_calibration(measured, damping=damping)
        _, corrected = measure_pair(
            simulated_page_scan(calibration), calibration.sent_for(wedge_levels(21))
        )
        assert corrected.worst_cast() < measured.worst_cast()
        if damping == 0.5:
            # Half a step: the cast keeps its original direction (blue = negative b*).
            assert np.median(corrected.lab[2:16, 2]) < 0


@pytest.mark.parametrize("kwargs", [{"damping": 1.5}, {"damping": -0.1}, {"shadow_damping": 2.0}])
def test_damping_range_is_checked(kwargs: dict[str, float]) -> None:
    with pytest.raises(CalibrationError, match="within 0-1"):
        build_calibration(a_measurement(), **kwargs)
