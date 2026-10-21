"""End-to-end grey balance against a simulated printer and scanner."""

from pathlib import Path

import numpy as np
import pytest

from openquad.greybalance import (
    Calibration,
    CalibrationError,
    build_calibration,
    load_calibration,
    save_calibration,
)
from openquad.measure import Measurement, measure_scan
from openquad.targets import framed_target, wedge_levels
from tests.simulation import print_sheet, scan_sheet

DPI = 150


def round_trip(calibration: Calibration) -> Measurement:
    """Print the framed target through the calibration, scan it, and measure it."""
    sheet = calibration.apply(framed_target(dpi=DPI))
    scan = scan_sheet(print_sheet(sheet))
    return measure_scan(scan, sent=calibration.sent_for(wedge_levels(21)))


def test_uncorrected_simulated_print_has_a_blue_cast() -> None:
    measured = round_trip(Calibration.identity())
    assert measured.worst_cast() > 5
    assert np.median(measured.lab[1:-1, 2]) < -3  # b* negative = blue


def test_one_pass_removes_most_of_the_cast() -> None:
    first = round_trip(Calibration.identity())
    corrected = round_trip(build_calibration(first))
    assert corrected.worst_cast() < 3  # the exit gate
    assert corrected.worst_cast() < first.worst_cast() / 3


def test_repeated_passes_converge() -> None:
    calibration = Calibration.identity()
    casts = []
    for _ in range(3):
        measured = round_trip(calibration)
        casts.append(measured.worst_cast())
        calibration = build_calibration(measured)
    final = round_trip(calibration).worst_cast()
    assert final < 1.5
    assert final <= casts[0]


def test_correction_keeps_lightness() -> None:
    first = round_trip(Calibration.identity())
    corrected = round_trip(build_calibration(first))
    assert np.abs(corrected.lab[:, 0] - first.lab[:, 0]).max() < 3


def test_paper_white_and_black_are_kept() -> None:
    calibration = build_calibration(round_trip(Calibration.identity()))
    assert calibration.curves[:, -1].tolist() == [65535] * 3
    assert calibration.curves[:, 0].tolist() == [0] * 3
    assert np.all(np.diff(calibration.curves.astype(int), axis=1) >= 0)  # monotonic


def test_already_neutral_printer_gets_a_near_identity_correction() -> None:
    levels = wedge_levels(21)
    from openquad.colour import srgb_to_linear

    grey = srgb_to_linear(levels / 65535.0)
    neutral = Measurement(
        levels=levels,
        sent=np.repeat(levels[:, None], 3, axis=1),
        rgb=np.repeat(grey[:, None], 3, axis=1),
        lab=np.zeros((21, 3)),
    )
    calibration = build_calibration(neutral)
    assert np.abs(calibration.curves.astype(int) - calibration.levels.astype(int)).max() <= 2


# --- the Calibration object ----------------------------------------------------------


def test_identity_changes_nothing() -> None:
    rgb = np.random.default_rng(1).integers(0, 65536, (5, 7, 3)).astype(np.uint16)
    assert np.array_equal(Calibration.identity().apply(rgb), rgb)


def test_file_round_trip(tmp_path: Path) -> None:
    calibration = build_calibration(
        round_trip(Calibration.identity()),
        printer="Canon_MG3600_series",
        paper="Letter plain",
        settings="default quality",
    )
    path = tmp_path / "canon.oqcal"
    save_calibration(calibration, path)
    loaded = load_calibration(path)
    assert np.array_equal(loaded.curves, calibration.curves)
    assert np.array_equal(loaded.levels, calibration.levels)
    assert (loaded.printer, loaded.paper, loaded.settings) == (
        "Canon_MG3600_series",
        "Letter plain",
        "default quality",
    )
    assert loaded.created == calibration.created


@pytest.mark.parametrize(
    ("text", "message"),
    [
        ("not json", "not valid JSON"),
        ('{"format": "other"}', "not an OpenQuad calibration"),
        ('{"format": "openquad-calibration", "version": 9}', "unsupported"),
    ],
)
def test_bad_files_are_rejected(text: str, message: str) -> None:
    with pytest.raises(CalibrationError, match=message):
        Calibration.from_json(text)


@pytest.mark.parametrize(
    ("levels", "curves", "message"),
    [
        ([0], [[0], [0], [0]], "ascending"),
        ([5, 1], [[0, 1]] * 3, "ascending"),
        ([0, 65535], [[0, 1]] * 2, "shape"),
        ([0, 65535], [[0, 70000]] * 3, "within"),
    ],
)
def test_invalid_calibrations(levels: list[int], curves: list[list[int]], message: str) -> None:
    with pytest.raises(CalibrationError, match=message):
        Calibration(levels=np.array(levels), curves=np.array(curves))


def test_apply_needs_rgb_uint16() -> None:
    with pytest.raises(CalibrationError, match="uint16"):
        Calibration.identity().apply(np.zeros((2, 2), dtype=np.uint16))
