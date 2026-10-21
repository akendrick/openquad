"""Tests for curve interpolation, ink limits and curve generation."""

import numpy as np
import pytest
from hypothesis import given
from hypothesis import strategies as st
from hypothesis.extra.numpy import arrays

from openquad.curves import LUT_SIZE, InkSpec, build_curve, curve_luts, expand, scale_limit
from openquad.quadfile import LEVELS, MAX_VALUE, QuadCurve

uint16_curves = arrays(np.uint16, (LEVELS,))


# --- expand --------------------------------------------------------------------------


def test_expand_identity_ramp_is_identity() -> None:
    ramp = np.linspace(0, MAX_VALUE, LEVELS)
    table = expand(ramp)
    assert table.shape == (LUT_SIZE,)
    assert table.dtype == np.uint16
    assert np.array_equal(table, np.arange(LUT_SIZE, dtype=np.uint16))


@given(uint16_curves)
def test_expand_passes_through_every_original_point(points: np.ndarray) -> None:
    table = expand(points)
    nodes = np.rint(np.linspace(0, MAX_VALUE, LEVELS)).astype(int)
    assert np.array_equal(table[nodes], points)


@given(uint16_curves)
def test_expand_stays_within_neighbouring_points(points: np.ndarray) -> None:
    table = expand(points).astype(int)
    assert table.min() >= int(points.min())
    assert table.max() <= int(points.max())


@given(uint16_curves)
def test_expand_keeps_monotonic_curves_monotonic(points: np.ndarray) -> None:
    table = expand(np.sort(points))
    assert np.all(np.diff(table.astype(int)) >= 0)


def test_expand_rejects_wrong_length() -> None:
    with pytest.raises(ValueError, match="256 points"):
        expand(np.zeros(255))


def test_curve_luts_has_one_table_per_channel() -> None:
    curve = QuadCurve.from_values(("K", "LK"), np.zeros((2, LEVELS), dtype=np.uint16))
    assert curve_luts(curve).shape == (2, LUT_SIZE)


# --- ink limits ----------------------------------------------------------------------


def test_scale_limit_halves_full_ink() -> None:
    assert scale_limit([0, 65535], 50.0).tolist() == [0, 32768]


@given(uint16_curves, st.floats(0.0, 100.0))
def test_scale_limit_never_increases_ink(points: np.ndarray, limit: float) -> None:
    assert np.all(scale_limit(points, limit) <= points)


@pytest.mark.parametrize("limit", [-0.1, 100.1])
def test_scale_limit_rejects_out_of_range(limit: float) -> None:
    with pytest.raises(ValueError, match="0-100%"):
        scale_limit([1], limit)


# --- InkSpec -------------------------------------------------------------------------


def test_ramp_shape() -> None:
    ink = InkSpec("LK", limit=40.0, start=0.2, peak=0.5, end=0.8)
    amounts = ink.ramp(np.array([0.0, 0.2, 0.35, 0.5, 0.65, 0.8, 1.0]))
    assert np.allclose(amounts, [0.0, 0.0, 0.2, 0.4, 0.2, 0.0, 0.0])


def test_darkest_ink_rises_to_the_end() -> None:
    ink = InkSpec("K", limit=100.0, start=0.5, peak=1.0)
    assert np.allclose(ink.ramp(np.array([0.5, 0.75, 1.0])), [0.0, 0.5, 1.0])


@pytest.mark.parametrize(
    ("kwargs", "message"),
    [
        ({"limit": 101.0}, "limit"),
        ({"limit": -1.0}, "limit"),
        ({"start": 0.5, "peak": 0.5}, "start < peak"),
        ({"peak": 0.9, "end": 0.8}, "peak <= end"),
        ({"start": -0.1}, "0 <= start"),
        ({"end": 1.1}, "end <= 1"),
    ],
)
def test_invalid_ink_specs_are_rejected(kwargs: dict[str, float], message: str) -> None:
    args = {"limit": 50.0, "start": 0.0, "peak": 0.5, "end": 1.0}
    args.update(kwargs)
    with pytest.raises(ValueError, match=message):
        InkSpec("K", **args)


# --- build_curve ---------------------------------------------------------------------


def three_ink_curve(gamma: float = 1.0) -> QuadCurve:
    return build_curve(
        [
            InkSpec("LLK", limit=30.0, start=0.0, peak=0.33, end=0.66),
            InkSpec("LK", limit=40.0, start=0.2, peak=0.66, end=1.0),
            InkSpec("K", limit=60.0, start=0.5, peak=1.0),
        ],
        gamma=gamma,
    )


def test_build_curve_fills_named_channels_only() -> None:
    curve = three_ink_curve()
    assert curve.values.shape == (8, LEVELS)
    for unused in ("C", "M", "Y", "LC", "LM"):
        assert not curve.channel(unused).any()
    assert curve.channel("K")[-1] == round(0.6 * MAX_VALUE)
    assert curve.channel("LLK").max() <= round(0.3 * MAX_VALUE)


def test_build_curve_starts_at_paper_white() -> None:
    assert not three_ink_curve().values[:, 0].any()


def test_gamma_moves_ink_towards_the_shadows() -> None:
    linear = three_ink_curve().channel("K")
    darker = three_ink_curve(gamma=2.0).channel("K")
    assert darker.sum() < linear.sum()
    assert darker[-1] == linear[-1]


def test_custom_channel_list() -> None:
    curve = build_curve([InkSpec("K", 100.0, 0.0, 1.0)], channels=("K",))
    assert curve.channels == ("K",)
    assert np.array_equal(curve.channel("K"), np.rint(np.linspace(0, MAX_VALUE, LEVELS)))


@pytest.mark.parametrize(
    ("inks", "gamma", "message"),
    [
        ([InkSpec("Z", 50.0, 0.0, 1.0)], 1.0, "not one of the channels"),
        ([InkSpec("K", 50.0, 0.0, 1.0), InkSpec("K", 60.0, 0.0, 1.0)], 1.0, "twice"),
        ([], 0.0, "gamma"),
    ],
)
def test_build_curve_rejects_bad_input(inks: list[InkSpec], gamma: float, message: str) -> None:
    with pytest.raises(ValueError, match=message):
        build_curve(inks, gamma=gamma)


# --- smooth ramps --------------------------------------------------------------------


def smooth_ink() -> InkSpec:
    return InkSpec("LK", limit=40.0, start=0.2, peak=0.5, end=0.8, shape="smooth")


def test_smooth_ramp_matches_linear_at_start_peak_and_end() -> None:
    linear = InkSpec("LK", limit=40.0, start=0.2, peak=0.5, end=0.8)
    points = np.array([0.0, 0.2, 0.5, 0.8, 1.0])
    assert np.allclose(smooth_ink().ramp(points), linear.ramp(points))


def test_smooth_ramp_halfway_point_is_half() -> None:
    assert smooth_ink().ramp(np.array([0.35]))[0] == pytest.approx(0.2)


def test_smooth_ramp_has_no_corner_at_the_peak() -> None:
    x = np.linspace(0.0, 1.0, 100_001)
    step = x[1] - x[0]
    slope = np.diff(smooth_ink().ramp(x)) / step
    linear_slope = np.diff(InkSpec("LK", 40.0, 0.2, 0.5, 0.8).ramp(x)) / step
    # The linear ramp's slope jumps by 2.67 per unit at the peak; the smooth one is continuous.
    assert np.abs(np.diff(linear_slope)).max() > 2.0
    assert np.abs(np.diff(slope)).max() < 0.01


@given(st.floats(0.0, 1.0), st.floats(0.0, 1.0))
def test_smooth_ramp_rises_monotonically_before_the_peak(a: float, b: float) -> None:
    low, high = sorted((a * 0.5, b * 0.5))
    values = smooth_ink().ramp(np.array([low, high]))
    assert values[0] <= values[1] + 1e-12


def test_unknown_shape_is_rejected() -> None:
    with pytest.raises(ValueError, match="shape"):
        InkSpec("K", 50.0, 0.0, 1.0, shape="cubic")  # type: ignore[arg-type]


def test_smooth_darkest_ink_eases_in_but_keeps_rising_in_the_shadows() -> None:
    ink = InkSpec("K", limit=100.0, start=0.4, peak=1.0, shape="smooth")
    x = np.array([0.4, 0.4001, 0.9999, 1.0])
    values = ink.ramp(x)
    start_slope = (values[1] - values[0]) / 0.0001
    end_slope = (values[3] - values[2]) / 0.0001
    assert values[0] == 0.0
    assert values[3] == pytest.approx(1.0)
    assert start_slope < 0.01
    assert end_slope > 2.0  # 1.5 per unit of ramp, over a 0.6-wide ramp
