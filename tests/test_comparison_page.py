"""Tests for the two-target comparison page script."""

import importlib.util
from pathlib import Path
from types import ModuleType

import numpy as np
import pytest
import tifffile

from openquad.greybalance import Calibration, save_calibration
from openquad.measure import measure_scan
from openquad.targets import FramedLayout

ROOT = Path(__file__).resolve().parents[1]


def load_script() -> ModuleType:
    spec = importlib.util.spec_from_file_location(
        "make_comparison_page", ROOT / "scripts" / "make_comparison_page.py"
    )
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PAGE = load_script()
BLUER = Calibration(levels=np.array([0, 65535]), curves=np.array([[0, 65535]] * 2 + [[0, 60000]]))


def test_page_holds_plain_target_above_corrected_target() -> None:
    page = PAGE.build_page(BLUER, dpi=100)
    layout = FramedLayout()
    h = round(layout.height * 100)
    top, bottom = page[:h], page[h + 100 :]
    assert top.shape == bottom.shape
    lead = round(0.4 * 100)
    assert np.array_equal(top[:, lead:, 0], top[:, lead:, 2])  # neutral
    assert not np.array_equal(bottom[:, lead:, 0], bottom[:, lead:, 2])  # corrected


def test_each_half_measures_on_its_own() -> None:
    page = PAGE.build_page(Calibration.identity(), dpi=150).astype(np.float64) / 65535
    half = page.shape[0] // 2
    for part in (page[:half], page[half:]):
        assert measure_scan(part).worst_cast() < 0.5


def test_marks_tell_the_targets_apart() -> None:
    page = PAGE.build_page(Calibration.identity(), dpi=100)
    h = round(FramedLayout().height * 100)
    mark_column = page[:, 7:22, 0]
    top_marks = np.count_nonzero(np.diff((mark_column[:h, 7] == 0).astype(int)) == 1)
    bottom_marks = np.count_nonzero(np.diff((mark_column[h:, 7] == 0).astype(int)) == 1)
    assert (top_marks, bottom_marks) == (1, 2)


def test_main_writes_the_page(tmp_path: Path) -> None:
    cal = tmp_path / "c.oqcal"
    save_calibration(BLUER, cal)
    out = tmp_path / "page.tif"
    PAGE.main(["make_comparison_page.py", str(cal), str(out)])
    assert tifffile.imread(out).shape[-1] == 3


def test_main_needs_a_calibration() -> None:
    with pytest.raises(SystemExit):
        PAGE.main(["make_comparison_page.py"])
