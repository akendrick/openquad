"""Tests for step-wedge targets."""

import numpy as np
import pytest
from hypothesis import given
from hypothesis import strategies as st

from openquad.targets import step_wedge, wedge_levels


def test_21_step_levels() -> None:
    levels = wedge_levels(21)
    assert levels[0] == 65535
    assert levels[-1] == 0
    assert len(levels) == 21
    assert levels.dtype == np.uint16


@given(st.integers(2, 512))
def test_levels_strictly_darken(steps: int) -> None:
    assert np.all(np.diff(wedge_levels(steps).astype(int)) < 0)


def test_horizontal_wedge_layout() -> None:
    wedge = step_wedge(steps=3, patch_width=4, patch_height=2)
    assert wedge.shape == (2, 12)
    assert wedge[:, :4].tolist() == [[65535] * 4] * 2
    assert np.all(wedge[:, 4:8] == wedge_levels(3)[1])
    assert np.all(wedge[:, 8:] == 0)


def test_vertical_wedge_layout() -> None:
    wedge = step_wedge(steps=3, patch_width=4, patch_height=2, vertical=True)
    assert wedge.shape == (6, 4)
    assert np.all(wedge[:2] == 65535)
    assert np.all(wedge[4:] == 0)


@pytest.mark.parametrize("steps", [0, 1])
def test_too_few_steps(steps: int) -> None:
    with pytest.raises(ValueError, match="at least 2"):
        wedge_levels(steps)


def test_bad_patch_size() -> None:
    with pytest.raises(ValueError, match="patch size"):
        step_wedge(patch_width=0)
