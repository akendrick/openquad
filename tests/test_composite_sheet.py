"""Tests for the composite test-sheet script."""

import importlib.util
from pathlib import Path
from types import ModuleType

import numpy as np
import tifffile

ROOT = Path(__file__).resolve().parents[1]


def load_script() -> ModuleType:
    spec = importlib.util.spec_from_file_location(
        "make_composite_test", ROOT / "scripts" / "make_composite_test.py"
    )
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


SHEET = load_script()


def test_sheet_size_and_white_margins() -> None:
    sheet = SHEET.build_sheet(dpi=40)
    assert sheet.shape == (200, 300, 3)
    assert sheet.dtype == np.uint16
    assert np.all(sheet[:5] == 65535)  # top margin is paper white


def test_rows_have_expected_content() -> None:
    dpi = 40
    sheet = SHEET.build_sheet(dpi=dpi).astype(int)
    margin, row_h, gap = round(0.25 * dpi), round(0.9 * dpi), round(0.3 * dpi)
    centre_x = sheet.shape[1] // 2
    rows = [sheet[margin + i * (row_h + gap) + row_h // 2] for i in range(4)]
    neutral, duotone, _, red_only = (row[centre_x] for row in rows)
    assert neutral[0] == neutral[1] == neutral[2]  # neutral row is grey
    assert duotone[0] > duotone[1] + 5000  # duotone mid-tone is red-tinted
    assert red_only[0] > red_only[1]


def test_main_writes_a_300_dpi_tiff(tmp_path: Path) -> None:
    SHEET.main(["make_composite_test.py", str(tmp_path)])
    with tifffile.TiffFile(tmp_path / "composite-test-sheet.tif") as tif:
        page = tif.pages.first
        assert page.shape == (1500, 2250, 3)
        assert page.tags["XResolution"].value == (300, 1)
