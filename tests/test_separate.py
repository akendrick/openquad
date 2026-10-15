"""Tests for greyscale-to-ink separation."""

import warnings

import numpy as np
import pytest
from hypothesis import given
from hypothesis import strategies as st
from hypothesis.extra.numpy import arrays

from openquad.curves import InkSpec, build_curve
from openquad.quadfile import LEVELS, MAX_VALUE, QuadCurve
from openquad.separate import InkLimitWarning, check_total_ink, max_total_ink, separate

CURVE = build_curve(
    [
        InkSpec("LK", limit=40.0, start=0.0, peak=0.5, end=1.0),
        InkSpec("K", limit=80.0, start=0.4, peak=1.0),
    ],
    channels=("K", "LK"),
)

images = arrays(np.uint16, st.tuples(st.integers(1, 20), st.integers(1, 20)))


def test_white_gets_no_ink_and_black_gets_the_last_curve_value() -> None:
    image = np.array([[MAX_VALUE, 0]], dtype=np.uint16)
    out = separate(image, CURVE)
    assert out.shape == (2, 1, 2)
    assert out.dtype == np.uint16
    assert out[:, 0, 0].tolist() == [0, 0]
    assert out[:, 0, 1].tolist() == CURVE.values[:, -1].tolist()


def test_curve_points_map_exactly() -> None:
    # Pixel 65535 - 257*i sits exactly on curve point i.
    image = (MAX_VALUE - 257 * np.arange(LEVELS, dtype=np.uint16)).reshape(1, -1)
    out = separate(image, CURVE)
    assert np.array_equal(out[:, 0, :], CURVE.values)


@given(images, st.integers(1, 25))
def test_chunk_size_never_changes_the_result(image: np.ndarray, chunk_rows: int) -> None:
    assert np.array_equal(separate(image, CURVE, chunk_rows=chunk_rows), separate(image, CURVE))


@given(images)
def test_output_never_exceeds_each_channels_maximum(image: np.ndarray) -> None:
    out = separate(image, CURVE)
    for channel, curve in zip(out, CURVE.values, strict=True):
        assert channel.max() <= curve.max()


@given(images)
def test_darker_pixels_never_get_less_ink_with_monotonic_curves(image: np.ndarray) -> None:
    curve = QuadCurve.from_values(("K",), np.rint(np.linspace(0, MAX_VALUE, LEVELS)).reshape(1, -1))
    flat = image.ravel()
    order = np.argsort(flat)[::-1]  # light to dark
    ink = separate(flat.reshape(1, -1), curve)[0, 0, order]
    assert np.all(np.diff(ink.astype(int)) >= 0)


def test_rejects_non_uint16_images() -> None:
    with pytest.raises(TypeError, match="uint16"):
        separate(np.zeros((2, 2), dtype=np.uint8), CURVE)  # type: ignore[arg-type]


def test_rejects_non_2d_images() -> None:
    with pytest.raises(ValueError, match="2-D"):
        separate(np.zeros((2, 2, 3), dtype=np.uint16), CURVE)


def test_rejects_bad_chunk_size() -> None:
    with pytest.raises(ValueError, match="chunk_rows"):
        separate(np.zeros((2, 2), dtype=np.uint16), CURVE, chunk_rows=0)


# --- total ink -----------------------------------------------------------------------


def test_max_total_ink() -> None:
    # At full density LK has faded to 0 and K is at 80%.
    assert max_total_ink(CURVE) == pytest.approx(80.0, abs=0.01)
    both_full = QuadCurve.from_values(("K", "LK"), np.full((2, LEVELS), MAX_VALUE))
    assert max_total_ink(both_full) == pytest.approx(200.0)


def test_total_ink_warning() -> None:
    with pytest.warns(InkLimitWarning, match="above the 50.0% limit"):
        assert check_total_ink(CURVE, 50.0) > 50.0


def test_no_warning_within_limit() -> None:
    with warnings.catch_warnings():
        warnings.simplefilter("error")
        separate(np.zeros((1, 1), dtype=np.uint16), CURVE, total_ink_limit=100.0)


def test_separate_warns_when_limit_exceeded() -> None:
    with pytest.warns(InkLimitWarning):
        separate(np.zeros((1, 1), dtype=np.uint16), CURVE, total_ink_limit=10.0)
