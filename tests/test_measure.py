"""Tests for measuring scanned targets and for the colour maths."""

from pathlib import Path

import numpy as np
import pytest
import tifffile
from PIL import Image

from openquad.colour import linear_rgb_to_lab, luminance, srgb_to_linear
from openquad.measure import MeasureError, Measurement, find_frame, load_scan, measure_scan
from openquad.targets import FramedLayout, framed_target, wedge_levels
from tests.simulation import print_sheet, scan_sheet

DPI = 150


def neutral_scan(dpi: int = DPI) -> np.ndarray:
    """A perfectly neutral printer, scanned with paper around the target."""
    sheet = framed_target(dpi=dpi).astype(np.float64) / 65535
    canvas = np.ones((sheet.shape[0] + 80, sheet.shape[1] + 90, 3))
    canvas[40 : 40 + sheet.shape[0], 50 : 50 + sheet.shape[1]] = sheet
    return canvas


# --- colour maths --------------------------------------------------------------------


def test_lab_of_white_black_and_grey() -> None:
    assert linear_rgb_to_lab([1.0, 1.0, 1.0]) == pytest.approx([100.0, 0.0, 0.0], abs=1e-6)
    assert linear_rgb_to_lab([0.0, 0.0, 0.0]) == pytest.approx([0.0, 0.0, 0.0], abs=1e-6)
    l_star, a_star, b_star = linear_rgb_to_lab([0.18418, 0.18418, 0.18418])
    assert l_star == pytest.approx(50.0, abs=0.05)
    assert (a_star, b_star) == pytest.approx((0.0, 0.0), abs=1e-6)


def test_blue_has_negative_b() -> None:
    assert linear_rgb_to_lab([0.2, 0.2, 0.5])[2] < -10


def test_luminance_of_white() -> None:
    assert luminance([1.0, 1.0, 1.0]) == pytest.approx(1.0)


# --- finding and measuring -----------------------------------------------------------


def test_find_frame_locates_the_outer_edges() -> None:
    layout = FramedLayout()
    left, top, right, bottom = find_frame(neutral_scan())
    assert (left, top) == (50, 40)
    assert right - left == round(layout.width * DPI)
    assert bottom - top == round(layout.height * DPI)


def test_neutral_print_measures_neutral_and_on_tone() -> None:
    measured = measure_scan(neutral_scan())
    assert measured.worst_cast() < 0.5
    expected_l = linear_rgb_to_lab(
        np.repeat(srgb_to_linear(wedge_levels(21) / 65535.0)[:, None], 3, axis=1)
    )[:, 0]
    assert np.abs(measured.lab[:, 0] - expected_l).max() < 1.0
    assert measured.lab[0, 0] == pytest.approx(100.0, abs=0.5)  # first level is paper white


def test_dust_and_lid_shadow_are_ignored() -> None:
    scan = neutral_scan()
    scan[:3] = 0.0  # dark lid shadow along the top edge
    scan[10:13, 5:8] = 0.0  # dust outside the target
    scan[200:203, 400:403] = 0.0  # dust inside a patch
    assert measure_scan(scan).worst_cast() < 0.5


def test_jpeg_scan_round_trip(tmp_path: Path) -> None:
    from openquad.greybalance import Calibration

    sheet = Calibration.identity().apply(framed_target(dpi=DPI))
    scan = scan_sheet(print_sheet(sheet))
    path = tmp_path / "scan.jpg"
    Image.fromarray(np.round(scan * 255).astype(np.uint8)).save(path, quality=90)
    from_jpeg = measure_scan(load_scan(path))
    direct = measure_scan(scan)
    assert np.abs(from_jpeg.lab - direct.lab).max() < 1.5


def test_load_scan_reads_16_bit_tiff(tmp_path: Path) -> None:
    path = tmp_path / "scan.tif"
    tifffile.imwrite(path, np.full((4, 4, 3), 65535, dtype=np.uint16), photometric="rgb")
    assert load_scan(path).max() == pytest.approx(1.0)


def test_load_scan_rejects_greyscale_tiff(tmp_path: Path) -> None:
    path = tmp_path / "grey.tif"
    tifffile.imwrite(path, np.zeros((4, 4), dtype=np.uint8))
    with pytest.raises(MeasureError, match="colour scan"):
        load_scan(path)


def test_blank_scan_has_no_frame() -> None:
    with pytest.raises(MeasureError, match="no target frame"):
        measure_scan(np.ones((300, 400, 3)))


def test_cropped_target_is_reported() -> None:
    scan = neutral_scan()[:, :700]  # right side of the target cut off
    with pytest.raises(MeasureError, match="doesn't match"):
        measure_scan(scan)


def test_dark_paper_is_reported() -> None:
    scan = neutral_scan() * 0.15 + 0.0
    scan[scan > 0.1] = 0.12
    with pytest.raises(MeasureError):
        measure_scan(scan)


def test_low_resolution_scan_is_reported() -> None:
    with pytest.raises(MeasureError):
        measure_scan(neutral_scan(dpi=4))


def test_sent_shape_is_checked() -> None:
    with pytest.raises(MeasureError, match="sent must have shape"):
        measure_scan(neutral_scan(), sent=np.zeros((5, 3), dtype=np.uint16))


def test_measurement_json_round_trip() -> None:
    measured = measure_scan(neutral_scan())
    loaded = Measurement.from_json(measured.to_json())
    assert np.array_equal(loaded.levels, measured.levels)
    assert np.array_equal(loaded.sent, measured.sent)
    assert np.allclose(loaded.lab, measured.lab, atol=1e-3)


def test_measurement_json_must_be_ours() -> None:
    with pytest.raises(MeasureError, match="not an OpenQuad measurement"):
        Measurement.from_json('{"format": "x"}')


# --- the target itself ---------------------------------------------------------------


def test_framed_target_layout() -> None:
    layout = FramedLayout()
    sheet = framed_target(layout, dpi=100)
    assert sheet.shape == (round(layout.height * 100), round(layout.width * 100), 3)
    assert np.all(sheet[0] == 0)  # frame
    assert np.all(sheet[..., 0] == sheet[..., 1])  # neutral
    boxes = layout.patch_boxes()
    assert len(boxes) == 42
    assert sorted(level for level, *_ in boxes) == sorted(list(range(21)) * 2)
