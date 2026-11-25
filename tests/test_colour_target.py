"""Tests for the colour target and measuring scans of it (colour calibration, phase 1).

The prints are simulated: each colour sent goes through a made-up printer (dull
primaries, a warm cast, paper that isn't quite white), then the page is "scanned" with
a margin round it, at another resolution, with a little noise."""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest
import tifffile
from PIL import Image

from openquad.cli import main
from openquad.colour import (
    D50_WHITE,
    D65_WHITE,
    d65_to_d50,
    delta_e_2000,
    linear_rgb_to_xyz,
    linear_to_srgb,
    srgb_to_linear,
    xyz_to_lab,
)
from openquad.colour_target import (
    HUES,
    ColourMeasurement,
    ColourTarget,
    colour_patches,
    load_target,
    make_target,
    measure_target,
    straightened,
    target_page,
)
from openquad.measure import MeasureError
from openquad.quadfile import MAX_VALUE
from openquad.scanner_profile import fit_model

DPI = 100.0  # low, to keep the tests quick; the patches are still 32 pixels or more


def printer(encoded: np.ndarray) -> np.ndarray:
    """What a made-up printer puts on paper for sRGB-encoded colours (0-1), as the
    scanner (an sRGB one) sees it: duller, warmer, with paper a little grey."""
    linear = srgb_to_linear(encoded)
    mixed = 0.8 * linear + 0.2 * linear.mean(axis=-1, keepdims=True)  # less saturated
    tinted = mixed * np.array([0.92, 0.9, 0.84]) + np.array([0.01, 0.009, 0.008])
    return np.asarray(linear_to_srgb(np.clip(tinted, 0.0, 1.0)))


def expected_lab(target: ColourTarget) -> np.ndarray:
    """L*a*b* relative to the paper that the simulated printer should measure at."""

    def xyz(encoded: np.ndarray) -> np.ndarray:
        return d65_to_d50(linear_rgb_to_xyz(srgb_to_linear(printer(encoded))))

    paper = xyz(np.ones(3))
    return xyz_to_lab(xyz(target.sent / MAX_VALUE), paper)


def scan(
    target: ColourTarget,
    page: int = 0,
    turned: bool = False,
    margin: int = 40,
    noise: float = 0.003,
    seed: int = 0,
    paper: float = 1.0,
) -> np.ndarray:
    """A scan of a printed page (0-1 RGB), with paper round it."""
    image = printer(target_page(target, page, DPI) / MAX_VALUE) * paper
    image = np.pad(image, ((margin, margin), (margin, margin), (0, 0)), constant_values=0)
    pad = np.ones(image.shape[:2], dtype=bool)
    pad[margin:-margin, margin:-margin] = False
    image[pad] = printer(np.ones(3)) * paper
    image = image + np.random.default_rng(seed).normal(0, noise, image.shape)
    image = np.clip(image, 0.0, 1.0)
    return image[::-1, ::-1] if turned else image


def test_d65_white_adapts_to_d50() -> None:
    assert np.allclose(d65_to_d50(D65_WHITE), D50_WHITE, atol=1e-3)


def test_patch_set() -> None:
    patches = colour_patches()
    assert len(patches) == 6**3 + 21 + 6 * 3 == 255
    assert len(colour_patches(9)) == 9**3 + 21 + 18 == 768
    assert patches.min() == 0 and patches.max() == MAX_VALUE
    grey = (patches[:, 0] == patches[:, 1]) & (patches[:, 1] == patches[:, 2])
    assert grey.sum() >= 21
    red_tints = [p for p in patches.tolist() if p[0] == MAX_VALUE and p[1] == p[2] < MAX_VALUE]
    assert len(red_tints) >= 3
    with pytest.raises(ValueError, match="grid"):
        colour_patches(7)


def test_layout_fits_a_letter_page_and_places_every_patch() -> None:
    standard = make_target()
    assert len(standard.pages) == 1 and len(standard.sent) == 255
    fine = make_target(9)
    assert len(fine.pages) == 2 and len(fine.sent) == 768
    for target in (standard, fine):
        for page in range(len(target.pages)):
            width, height = target.page_size(page)
            assert width <= 7.5 + 1e-9 and height <= 10.0 + 1e-9
            boxes = target.patch_boxes(page)
            assert len(boxes) == len(target.pages[page])
            frame_w, frame_h = target.frame_size(page)
            assert all(b[0] > 0 and b[2] < frame_w and b[1] > 0 and b[3] < frame_h for b in boxes)
    # Shuffled, but the same way every time.
    assert not np.array_equal(standard.sent, colour_patches())
    assert np.array_equal(standard.sent, make_target().sent)
    assert sorted(map(tuple, standard.sent.tolist())) == sorted(
        map(tuple, colour_patches().tolist())
    )
    with pytest.raises(ValueError, match="don't fit"):
        make_target(patch=3.0)


def test_rendered_page_has_frame_marks_and_patches() -> None:
    target = make_target(9)
    for page in (0, 1):
        image = target_page(target, page, DPI)
        width, height = target.page_size(page)
        assert image.shape == (round(height * DPI), round(width * DPI), 3)
        assert image.dtype == np.uint16
        # The first patch is drawn where its box says.
        left, top, right, bottom = target.patch_boxes(page)[0]
        x = round(target.lead * DPI + (left + right) / 2 * DPI)
        y = round((top + bottom) / 2 * DPI)
        assert np.array_equal(image[y, x], target.pages[page][0])
        # Page marks: page + 1 black squares at the left.
        column = image[:, round((target.pad + target.mark / 2) * DPI), 0] == 0
        assert np.count_nonzero(np.diff(np.r_[0, column.astype(int)]) == 1) == page + 1


def test_target_round_trips_through_json() -> None:
    target = make_target(9)
    again = ColourTarget.from_json(target.to_json())
    assert again.columns == target.columns and again.patch == target.patch
    assert all(np.array_equal(a, b) for a, b in zip(again.pages, target.pages, strict=True))
    with pytest.raises(ValueError, match="colour target"):
        ColourTarget.from_json(json.dumps({"kind": "something else"}))


def test_measures_a_simulated_print() -> None:
    target = make_target()
    measurement = measure_target([scan(target)], target)
    assert np.array_equal(measurement.sent, target.sent)
    errors = delta_e_2000(measurement.lab, expected_lab(target))
    assert errors.mean() < 0.3 and errors.max() < 1.5
    # Paper is L* 100 by definition; the paper's own colour is kept in paper_xyz.
    paper = d65_to_d50(linear_rgb_to_xyz(srgb_to_linear(printer(np.ones(3)))))
    assert np.allclose(measurement.paper_xyz, paper, atol=0.005)
    summary = measurement.summary()
    assert "255 patches" in summary and "Full red" in summary and "sRGB" in summary


def test_pages_in_any_order_and_either_way_up() -> None:
    target = make_target(9)
    measurement = measure_target(
        [scan(target, 1, seed=1), scan(target, 0, turned=True, seed=2)], target
    )
    errors = delta_e_2000(measurement.lab, expected_lab(target))
    assert errors.mean() < 0.3 and errors.max() < 1.5
    assert not measurement.notes


def test_a_scan_cropped_tight_to_the_target() -> None:
    target = make_target()
    image = printer(target_page(target, 0, DPI) / MAX_VALUE)
    measurement = measure_target([image], target)
    assert delta_e_2000(measurement.lab, expected_lab(target)).max() < 0.5


def tilted(image: np.ndarray, degrees: float) -> np.ndarray:
    """The scan with the page turned a little on the glass (anticlockwise), paper filling in."""
    paper = image[0, 0]
    return np.stack(
        [
            np.asarray(
                Image.fromarray(image[..., c].astype(np.float32), "F").rotate(
                    degrees, Image.Resampling.BILINEAR, fillcolor=float(paper[c])
                )
            )
            for c in range(3)
        ],
        axis=-1,
    ).astype(np.float64)


def test_tilted_scans_are_straightened_and_very_tilted_ones_refused() -> None:
    """A tilt brings the frame's line beside the page marks; they are still counted right. A
    tilted page is straightened before it's read; one tilted past 3° is refused, saying so."""
    target = make_target(9)
    expected = expected_lab(target)
    for one, two in ((0.15, -0.2), (-0.8, 0.8), (2.5, -1.5)):
        tilted_pair = [tilted(scan(target, 0), one), tilted(scan(target, 1, turned=True), two)]
        measurement = measure_target(tilted_pair, target)
        errors = delta_e_2000(measurement.lab, expected)
        assert errors.mean() < 0.5 and errors.max() < 3, (one, two)
    with pytest.raises(MeasureError, match=r"the page is tilted 4\.0° .* square against the edge"):
        measure_target([tilted(scan(target, 0), -4.0), scan(target, 1)], target)


def test_straightening_turns_about_the_pivot() -> None:
    image = np.ones((40, 60, 3))
    image[10:30, 29:31] = 0.0  # an upright bar
    leaning = straightened(image, -5.0, (30.0, 20.0))  # turned so it leans right going down
    assert leaning[20, 29:31].max() < 0.5  # the pivot stays put
    assert straightened(image, 0.0, (30.0, 20.0)).tolist() == image.tolist()
    assert (straightened(image, 30.0, (30.0, 20.0))[0, 0] == 1.0).all()  # beyond: white


def test_notes_pages_scanned_differently() -> None:
    target = make_target(9)
    measurement = measure_target([scan(target, 0), scan(target, 1, paper=0.9)], target)
    assert any("paper white differs" in note for note in measurement.notes)


def test_refuses_missing_extra_and_unreadable_pages() -> None:
    target = make_target(9)
    with pytest.raises(MeasureError, match="no scan of page 2"):
        measure_target([scan(target, 0)], target)
    with pytest.raises(MeasureError, match="two scans of page 1"):
        measure_target([scan(target, 0), scan(target, 0, seed=3)], target)
    # A one-page target's scan with a second page mark drawn on it.
    marked = scan(make_target())  # 40 pixels of paper round the page
    y, x, size = 40 + round(0.29 * DPI), 40 + round(0.07 * DPI), round(0.15 * DPI)
    marked[y : y + size, x : x + size] = 0.0
    with pytest.raises(MeasureError, match="found 2 page marks"):
        measure_target([marked], make_target())
    with pytest.raises(MeasureError, match="no target frame"):
        measure_target([np.ones((300, 300, 3))], target)
    cropped = scan(make_target())[:, :-200]
    with pytest.raises(MeasureError, match="check the whole page"):
        measure_target([cropped], make_target())
    dark = scan(make_target(), paper=0.45)  # paper reads as mid grey
    with pytest.raises(MeasureError, match="too dark"):
        measure_target([dark], make_target())


def test_patches_too_small_to_sample() -> None:
    target = make_target()
    tiny = printer(target_page(target, 0, 4.0) / MAX_VALUE)
    with pytest.raises(MeasureError):
        measure_target([tiny], target)


def test_with_a_scanner_model() -> None:
    """A scanner model fitted to an sRGB scanner reads the print as taking the scan as sRGB."""
    rng = np.random.default_rng(5)
    encoded = rng.uniform(0.02, 0.98, (300, 3))
    lab = xyz_to_lab(d65_to_d50(linear_rgb_to_xyz(srgb_to_linear(encoded))), D50_WHITE)
    greys = np.repeat(np.linspace(0.02, 0.98, 24)[:, None], 3, axis=1)
    grey_lab = xyz_to_lab(d65_to_d50(linear_rgb_to_xyz(srgb_to_linear(greys))), D50_WHITE)
    model = fit_model(encoded, lab, greys, grey_lab, "poly")
    model = type(model)(model.kind, model.curves, model.coefficients, scanner="Test scanner")
    target = make_target()
    measured = measure_target([scan(target)], target, model)
    plain = measure_target([scan(target)], target)
    assert measured.scanner == "Test scanner" and "scanner model" in measured.colourimetry
    assert delta_e_2000(measured.lab, plain.lab).mean() < 1.5


def test_measurement_round_trips_through_json() -> None:
    target = make_target()
    measurement = measure_target([scan(target)], target, scanner="Epson")
    again = ColourMeasurement.from_json(measurement.to_json())
    assert np.array_equal(again.sent, measurement.sent)
    assert np.allclose(again.lab, measurement.lab, atol=1e-3)
    assert np.allclose(again.paper_xyz, measurement.paper_xyz)
    assert again.scanner == "Epson"
    with pytest.raises(ValueError, match="colour measurement"):
        ColourMeasurement.from_json("{}")


def test_neutrals_and_hues() -> None:
    measurement = measure_target([scan(make_target())], make_target())
    grey = measurement.neutrals()
    assert grey.sum() >= 21
    assert len(HUES) == 6


def test_cli_makes_and_measures_a_colour_target(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    out = tmp_path / "colour.tif"
    assert main(["target", "--kind", "colour", "-o", str(out), "--dpi", str(DPI)]) == 0
    layout = tmp_path / "colour.json"
    assert out.exists() and layout.exists()
    assert "255 patches" in capsys.readouterr().out
    target = load_target(layout)
    page = (scan(target) * 65535).round().astype(np.uint16)
    scanned = tmp_path / "scan.tif"
    tifffile.imwrite(scanned, page, photometric="rgb")
    result = tmp_path / "m.json"
    assert main(["measure-colour", str(scanned), "--target", str(layout), "-o", str(result)]) == 0
    assert "Full red" in capsys.readouterr().out
    measurement = ColourMeasurement.from_json(result.read_text())
    assert len(measurement.sent) == 255


def test_cli_fine_target_writes_two_pages(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    out = tmp_path / "fine.tif"
    assert main(["target", "--kind", "colour", "--fine", "-o", str(out), "--dpi", "50"]) == 0
    assert (tmp_path / "fine-1of2.tif").exists() and (tmp_path / "fine-2of2.tif").exists()
    assert not out.exists()
    with Image.open(tmp_path / "fine-2of2.tif") as image:
        assert image.size[0] == round(7.5 * 50)
    assert "768 patches" in capsys.readouterr().out


def test_cli_measure_colour_with_a_scanner_model_and_errors(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    target = make_target()
    layout = tmp_path / "colour.json"
    layout.write_text(target.to_json())
    scanned = tmp_path / "scan.tif"
    tifffile.imwrite(scanned, (scan(target) * 65535).round().astype(np.uint16), photometric="rgb")
    encoded = np.random.default_rng(2).uniform(0.02, 0.98, (200, 3))
    lab = xyz_to_lab(d65_to_d50(linear_rgb_to_xyz(srgb_to_linear(encoded))), D50_WHITE)
    greys = np.repeat(np.linspace(0.02, 0.98, 24)[:, None], 3, axis=1)
    grey_lab = xyz_to_lab(d65_to_d50(linear_rgb_to_xyz(srgb_to_linear(greys))), D50_WHITE)
    model_path = tmp_path / "scanner.json"
    model_path.write_text(fit_model(encoded, lab, greys, grey_lab).to_json())
    result = tmp_path / "m.json"
    argv = ["measure-colour", str(scanned), "--target", str(layout), "-o", str(result)]
    assert main([*argv, "--scanner-model", str(model_path)]) == 0
    assert "scanner model" in capsys.readouterr().out
    assert main([argv[0], str(scanned), *argv[1:]]) == 1
    assert "two scans of page 1" in capsys.readouterr().err
