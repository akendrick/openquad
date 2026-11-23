"""Tests for measuring a scanner with an IT8.7/2 target (colour calibration, phase 0).

The scans are simulated: a made-up target (reference L*a*b* under D50) is drawn as a
scanner with its own primaries, per-channel response and noise would report it."""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest
import tifffile
from PIL import Image

from openquad.cli import main
from openquad.colour import D50_WHITE, delta_e_2000, lab_to_xyz, xyz_to_lab
from openquad.scanner_profile import (
    GO_MEAN,
    Corners,
    Reference,
    ScannerModel,
    ScannerProfileError,
    draw_boxes,
    fit_model,
    grey_ids,
    grid_ids,
    load_model,
    normalise_id,
    parse_reference,
    profile_scanner,
    sample_scan,
    save_report,
)

PITCH = 24  # pixels between patch centres
ORIGIN = (40.0, 30.0)  # A1's centre
# Reflective primaries (XYZ of full red, green and blue, white = D50).
PRIMARIES = np.array([[0.4361, 0.2225, 0.0139], [0.3851, 0.7169, 0.0971], [0.1431, 0.0606, 0.7139]])


def make_reference(seed: int = 1) -> Reference:
    """A plausible target: 264 colours from a reflective gamut, and 24 greys."""
    rng = np.random.default_rng(seed)
    linear = rng.uniform(0.02, 0.88, size=(264, 3)) ** 1.6
    lab = xyz_to_lab(linear @ PRIMARIES, D50_WHITE)
    grey_l = np.linspace(93.0, 4.0, 24)
    grey = np.stack([grey_l, rng.normal(0, 0.4, 24), rng.normal(0, 0.6, 24)], axis=-1)
    ids = grid_ids() + grey_ids()
    return Reference(lab=dict(zip(ids, np.concatenate([lab, grey]), strict=True)))


def cgats(reference: Reference, fields: str = "lab") -> str:
    """The reference as a CGATS file, in the zero-padded spelling some vendors use."""
    names = "LAB_L LAB_A LAB_B" if fields == "lab" else "XYZ_X XYZ_Y XYZ_Z"
    rows = []
    for patch, lab in reference.lab.items():
        values = lab if fields == "lab" else lab_to_xyz(lab, D50_WHITE) * 100
        spelt = (
            f"GS{int(patch[2:]):02d}"
            if patch.startswith("GS")
            else f"{patch[0]}{int(patch[1:]):02d}"
        )
        rows.append(f"{spelt} " + " ".join(f"{v:.4f}" for v in values))
    return "\n".join(
        [
            "IT8.7/2",
            'ORIGINATOR "test"',
            'DESCRIPTOR "Simulated target"',
            "NUMBER_OF_FIELDS 4",
            "BEGIN_DATA_FORMAT",
            f"SAMPLE_ID {names}",
            "END_DATA_FORMAT",
            f"NUMBER_OF_SETS {len(rows)}",
            "BEGIN_DATA",
            *rows,
            "END_DATA",
        ]
    )


def corners(dx: float = 0.0, dy: float = 0.0) -> Corners:
    x, y = ORIGIN[0] + dx, ORIGIN[1] + dy
    grey_y = y + 13 * PITCH
    return Corners(
        a1=(x, y), a22=(x + 21 * PITCH, y), l1=(x, y + 11 * PITCH),
        gs0=(x, grey_y), gs23=(x + 23 * PITCH * 21 / 23, grey_y),
    )  # fmt: skip


def scanner_rgb(lab: np.ndarray, crosstalk: float = 0.0, cast: float = 0.0) -> np.ndarray:
    """What a simulated scanner reports (0-1, encoded) for colours `lab` (D50)."""
    xyz = lab_to_xyz(lab, D50_WHITE)
    sensors = np.array([[0.6, 0.35, 0.05], [0.2, 0.75, 0.05], [0.05, 0.15, 0.8]])
    seen = xyz @ np.linalg.inv(PRIMARIES) @ sensors.T
    seen = seen + crosstalk * seen[..., [1, 2, 0]] * seen[..., [2, 0, 1]]
    seen = seen * np.array([1.0 + cast, 1.0, 1.0 - cast])
    gammas = np.array([1 / 2.1, 1 / 2.3, 1 / 2.0])
    return 0.02 + 0.95 * np.clip(seen, 0, None) ** gammas


def scan_image(
    reference: Reference, noise: float = 0.002, seed: int = 0, dx: float = 0.0, dy: float = 0.0,
    **scanner: float,
) -> np.ndarray:  # fmt: skip
    """A scan of the simulated target, 0-1 floats."""
    rng = np.random.default_rng(seed)
    image = np.full((420, 640, 3), 0.55)
    found = corners(dx, dy).centres()
    for patch, lab in reference.lab.items():
        x, y = found[patch]
        size = PITCH if not patch.startswith("GS") else PITCH * 21 / 23
        left, top = round(x - size / 2), round(y - PITCH / 2)
        image[top : top + PITCH, left : left + round(size)] = scanner_rgb(lab[None], **scanner)[0]
    return np.clip(image + rng.normal(0, noise, image.shape), 0, 1)


# --- reference files -------------------------------------------------------------------


def test_ids_are_read_in_any_spelling() -> None:
    assert [normalise_id(i) for i in ("A01", "a1", "L22", "GS00", "gs5", '"B07"')] == [
        "A1", "A1", "L22", "GS0", "GS5", "B7",
    ]  # fmt: skip


def test_reads_lab_and_xyz_reference_files() -> None:
    reference = make_reference()
    from_lab = parse_reference(cgats(reference))
    from_xyz = parse_reference(cgats(reference, "xyz"))
    assert from_lab.description == "Simulated target"
    assert set(from_lab.lab) == set(grid_ids() + grey_ids())
    for patch in ("A1", "L22", "GS0", "GS23"):
        assert from_lab.lab[patch] == pytest.approx(reference.lab[patch], abs=1e-3)
        assert from_xyz.lab[patch] == pytest.approx(reference.lab[patch], abs=1e-2)


def test_bad_reference_files_are_refused() -> None:
    with pytest.raises(ScannerProfileError, match="not a CGATS"):
        parse_reference("hello")
    no_fields = cgats(make_reference()).replace("LAB_L LAB_A LAB_B", "RGB_R RGB_G RGB_B")
    with pytest.raises(ScannerProfileError, match="neither"):
        parse_reference(no_fields)
    partial = Reference(lab={"A1": np.zeros(3)})
    with pytest.raises(ScannerProfileError, match="no data for A2"):
        partial.lab_of(grid_ids())


def test_reference_file_details() -> None:
    text = cgats(make_reference())
    named = parse_reference(
        text.replace("SAMPLE_ID", "SAMPLE_NAME").replace("BEGIN_DATA\n", "BEGIN_DATA\n# note\n\n")
    )
    assert len(named.lab) == 288
    with pytest.raises(ScannerProfileError, match="no SAMPLE_ID"):
        parse_reference(text.replace("SAMPLE_ID", "PATCH"))
    with pytest.raises(ScannerProfileError, match="short data line"):
        parse_reference(text.replace("A01 ", "A01\n", 1))
    start, end = text.index("BEGIN_DATA\n") + len("BEGIN_DATA\n"), text.rindex("END_DATA")
    with pytest.raises(ScannerProfileError, match="no data"):
        parse_reference(text[:start] + text[end:])
    xyz_unit = cgats(make_reference(), "xyz")
    scaled = parse_reference(xyz_unit)
    assert scaled.lab["GS0"][0] == pytest.approx(93.0, abs=0.01)


# --- finding the patches ---------------------------------------------------------------


def test_corners_place_every_patch() -> None:
    found = corners().centres()
    assert len(found) == 12 * 22 + 24
    assert found["A1"] == pytest.approx(ORIGIN)
    assert found["L22"] == pytest.approx((ORIGIN[0] + 21 * PITCH, ORIGIN[1] + 11 * PITCH))
    assert found["GS23"] == pytest.approx((ORIGIN[0] + 21 * PITCH, ORIGIN[1] + 13 * PITCH))
    assert Corners.parse("40,30 544,30 40,294 40,342 544,342").a22 == (544.0, 30.0)
    with pytest.raises(ScannerProfileError, match="five x,y points"):
        Corners.parse("1,2 3,4")
    with pytest.raises(ScannerProfileError, match="five x,y points"):
        Corners.parse("a,b c,d e,f g,h i,j")


def test_samples_each_patch_and_refuses_corners_off_the_scan() -> None:
    reference = make_reference()
    scan = scan_image(reference, noise=0.0)
    sampled = sample_scan(scan, corners())
    assert sampled["C5"] == pytest.approx(scanner_rgb(reference.lab["C5"][None])[0], abs=1e-9)
    with pytest.raises(ScannerProfileError, match="off the scan"):
        sample_scan(scan, corners(dx=200))
    tiny = Corners(a1=(10, 10), a22=(31, 10), l1=(10, 21), gs0=(10, 23), gs23=(31, 23))
    with pytest.raises(ScannerProfileError, match="too small"):
        sample_scan(scan, tiny)


def test_check_image_outlines_the_sampled_boxes() -> None:
    image = draw_boxes(scan_image(make_reference()), corners())
    assert image.dtype == np.uint8
    red = (image[..., 0] == 255) & (image[..., 1] == 0) & (image[..., 2] == 0)
    assert red.sum() > 288 * 4 * 6


# --- the model -------------------------------------------------------------------------


def test_matrix_model_reads_a_linear_scanner_closely() -> None:
    report = profile_scanner(
        [scan_image(make_reference())], [corners()], make_reference(), "matrix"
    )
    assert report.model.kind == "matrix"
    assert report.fitted.mean < 0.5
    assert report.held_out.mean < 0.6
    assert report.repeat is None
    assert report.go
    assert "Verdict: GO" in report.summary()


def test_poly_model_is_chosen_when_the_scanner_is_not_linear() -> None:
    reference = make_reference()
    report = profile_scanner([scan_image(reference, crosstalk=1.5)], [corners()], reference)
    assert report.model.kind == "poly"
    matrix = profile_scanner(
        [scan_image(reference, crosstalk=1.5)], [corners()], reference, "matrix"
    )
    assert report.held_out.mean < matrix.held_out.mean
    assert "using poly" in report.summary()


def test_a_poor_scanner_is_a_no_go() -> None:
    reference = make_reference()
    rng = np.random.default_rng(5)
    scan = scan_image(reference, noise=0.0)
    # Each patch read with its own random error: no model can fix that.
    for x, y in corners().centres().values():
        scan[round(y) - 10 : round(y) + 10, round(x) - 10 : round(x) + 10] += rng.normal(0, 0.04, 3)
    report = profile_scanner([np.clip(scan, 0, 1)], [corners()], reference, "matrix")
    assert report.held_out.mean > GO_MEAN
    assert not report.go
    assert "Verdict: NO-GO" in report.summary()


def test_repeatability_between_scans() -> None:
    reference = make_reference()
    steady = [scan_image(reference, seed=s, dx=s * 3, dy=s) for s in range(3)]
    positions = [corners(s * 3, s) for s in range(3)]
    report = profile_scanner(steady, positions, reference, "matrix")
    assert report.repeat is not None and report.repeat.mean < 0.3
    assert report.go
    drifting = [scan_image(reference), scan_image(reference, seed=1, cast=0.12)]
    drift = profile_scanner(drifting, [corners()], reference, "matrix")
    assert drift.repeat is not None and drift.repeat.mean > 1.0
    assert not drift.go


def test_one_set_of_corners_or_one_per_scan() -> None:
    reference = make_reference()
    with pytest.raises(ScannerProfileError, match="2 scans but 3 sets"):
        profile_scanner([scan_image(reference)] * 2, [corners()] * 3, reference)
    with pytest.raises(ScannerProfileError, match="unknown model"):
        profile_scanner([scan_image(reference)], [corners()], reference, "cubic")
    with pytest.raises(ScannerProfileError, match="no scans"):
        profile_scanner([], [corners()], reference)
    lab = reference.lab_of(grid_ids())
    greys = reference.lab_of(grey_ids())
    with pytest.raises(ScannerProfileError, match="unknown model"):
        fit_model(scanner_rgb(lab), lab, scanner_rgb(greys), greys, "cubic")


def test_model_round_trips_through_json(tmp_path: Path) -> None:
    reference = make_reference()
    report = profile_scanner([scan_image(reference)], [corners()], reference, scanner="Test")
    path = tmp_path / "scanner.json"
    save_report(report, path)
    model = load_model(path)
    assert model.kind == report.model.kind and model.scanner == "Test"
    rgb = np.array([[0.2, 0.5, 0.7], [0.9, 0.9, 0.9]])
    assert model.to_lab(rgb) == pytest.approx(report.model.to_lab(rgb), abs=1e-4)
    data = json.loads(path.read_text())
    assert data["report"]["go"] is True and len(data["report"]["held_out_by_patch"]) == 264
    with pytest.raises(ScannerProfileError, match="unknown scanner model"):
        ScannerModel.from_json('{"kind": "cubic"}')


def test_fit_needs_a_grey_row_that_changes() -> None:
    reference = make_reference()
    lab = reference.lab_of(grid_ids())
    flat = np.full((24, 3), 0.5)
    with pytest.raises(ScannerProfileError, match="grey row"):
        fit_model(scanner_rgb(lab), lab, flat, reference.lab_of(grey_ids()))


def test_model_reads_the_greys_close_to_their_reference() -> None:
    """The greys have a little colour of their own, which the curves average out."""
    reference = make_reference()
    report = profile_scanner([scan_image(reference, noise=0.0)], [corners()], reference, "matrix")
    greys = reference.lab_of(grey_ids())
    seen = report.model.to_lab(scanner_rgb(greys))
    assert float(delta_e_2000(greys, seen).mean()) < 1.0


# --- command line ----------------------------------------------------------------------


def test_cli_profiles_a_scanner(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    reference = make_reference()
    ref_path = tmp_path / "R190808.txt"
    ref_path.write_text(cgats(reference))
    scans = []
    for s in range(2):
        path = tmp_path / f"scan{s}.tif"
        tifffile.imwrite(path, (scan_image(reference, seed=s) * 65535).round().astype(np.uint16))
        scans.append(str(path))
    c = corners()
    text = " ".join(f"{x:g},{y:g}" for x, y in (c.a1, c.a22, c.l1, c.gs0, c.gs23))
    out, check = tmp_path / "scanner.json", tmp_path / "check.png"
    code = main(
        ["scanner-profile", *scans, "--reference", str(ref_path), "--corners", text,
         "-o", str(out), "--check-image", str(check), "--scanner", "Simulated"]
    )  # fmt: skip
    assert code == 0
    printed = capsys.readouterr().out
    assert "Verdict: GO" in printed and "Repeatability between scans" in printed
    assert load_model(out).scanner == "Simulated"
    assert load_model(out).reference == "R190808.txt"
    with Image.open(check) as image:
        assert image.size == (640, 420)


def test_cli_reports_bad_corners(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    ref_path = tmp_path / "ref.txt"
    ref_path.write_text(cgats(make_reference()))
    scan = tmp_path / "scan.tif"
    tifffile.imwrite(scan, (scan_image(make_reference()) * 65535).astype(np.uint16))
    code = main(
        ["scanner-profile", str(scan), "--reference", str(ref_path), "--corners", "1,2",
         "-o", str(tmp_path / "out.json")]
    )  # fmt: skip
    assert code == 1
    assert "five x,y points" in capsys.readouterr().err
