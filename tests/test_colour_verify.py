"""Tests for checking a colour profile and refining it (colour calibration, phase 3).

The printer is the simulated one from the colour target's tests. For the refining tests
it has drifted since the target was printed (darker mid-tones, less blue), so the first
profile misses and the rounds have something to correct."""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest
import tifffile

from openquad.cli import main
from openquad.colour import d65_to_d50, linear_rgb_to_xyz, srgb_to_linear, xyz_to_lab
from openquad.colour_profile import ForwardModel, ProfileError, build_profile
from openquad.colour_target import ColourMeasurement, ColourTarget, make_target
from openquad.colour_verify import (
    CHECKER,
    MEAN_GOAL,
    NEUTRALS,
    SKIN,
    ColourRun,
    ColourRunError,
    VerificationTarget,
    driver_verification,
    make_verification,
    refine,
    verification_colours,
    verify,
)
from openquad.quadfile import MAX_VALUE
from tests.test_colour_target import scan

DRIFT = 0.15


def printer_xyz(encoded: np.ndarray, drift: float = 0.0) -> np.ndarray:
    """D50 XYZ of the colour target tests' printer, after `drift`."""
    linear = srgb_to_linear(encoded)
    mixed = (0.8 * linear + 0.2 * linear.mean(axis=-1, keepdims=True)) ** (1 + drift)
    tinted = mixed * np.array([0.92, 0.9, 0.84 - drift]) + np.array([0.01, 0.009, 0.008])
    return d65_to_d50(linear_rgb_to_xyz(tinted))


def measured(target: ColourTarget, drift: float = 0.0) -> ColourMeasurement:
    paper = printer_xyz(np.ones(3), drift)
    xyz = printer_xyz(target.sent / MAX_VALUE, drift)
    return ColourMeasurement(target.sent, xyz, xyz_to_lab(xyz, paper), paper)


@pytest.fixture(scope="module")
def model() -> ForwardModel:
    return build_profile([measured(make_target())]).model


def test_verification_colours() -> None:
    names, groups, wanted = verification_colours(50)
    assert len(names) == len(groups) == len(wanted) == len(CHECKER) + len(SKIN) + len(NEUTRALS) + 50
    assert groups.count("neutral") == 12 and groups.count("checker") == 24
    neutral = np.array(groups) == "neutral"
    assert np.allclose(wanted[neutral, 1:], 0)
    assert names[0] == "dark skin" and "sRGB" in names[-1]
    # The same colours every time.
    assert np.array_equal(wanted, verification_colours(50)[2])


def test_verification_page_sends_each_colour_through_the_model(model: ForwardModel) -> None:
    verification = make_verification(model)
    sent = verification.target.sent / MAX_VALUE
    printable = verification.printable
    assert 0.3 < printable.mean() < 1
    error = np.sqrt(
        ((model.lab(sent[printable]) - verification.wanted[printable]) ** 2).sum(axis=1)
    )
    assert error.max() < 1.1  # rounding to 16 bits included
    assert len(verification.target.pages) == 1
    assert verification.names[:3] != ["dark skin", "light skin", "blue sky"]  # shuffled


def test_verification_round_trips_through_json(model: ForwardModel) -> None:
    verification = make_verification(model, 20)
    again = VerificationTarget.from_json(verification.to_json())
    assert again.names == verification.names and again.groups == verification.groups
    assert np.array_equal(again.target.sent, verification.target.sent)
    assert np.allclose(again.wanted, verification.wanted, atol=1e-3)
    assert np.array_equal(again.printable, verification.printable)
    with pytest.raises(ProfileError, match="verification layout"):
        VerificationTarget.from_json(json.dumps({"kind": "nope"}))


def test_a_good_profile_meets_the_goals(model: ForwardModel) -> None:
    verification = make_verification(model)
    report = verify(measured(verification.target), verification)
    assert report.passed and report.mean < 0.5 and report.worst_tone < 1
    assessment = report.assessment()
    assert assessment["patches"] == 144 and assessment["printable"] == report.printable.sum()
    assert "Goals met" in report.summary() and "Furthest off" in report.summary()
    data = json.loads(report.to_json())
    assert data["passed"] and len(data["patches"]) == 144
    with pytest.raises(ProfileError, match="isn't of this verification page"):
        verify(measured(make_target()), verification)


def test_a_drifted_printer_misses_and_refining_brings_it_back(model: ForwardModel) -> None:
    current = model
    means = []
    for _ in range(3):
        verification = make_verification(current)
        measurement = measured(verification.target, DRIFT)
        report = verify(measurement, verification)
        means.append(report.mean)
        current = refine(current, measurement)
    assert means[0] > MEAN_GOAL
    assert means[1] < means[0] * 0.7 and means[2] < means[1]
    assert not verify(
        measured(make_verification(model).target, DRIFT), make_verification(model)
    ).passed
    assert (
        "not yet"
        in verify(
            measured(make_verification(model).target, DRIFT), make_verification(model)
        ).summary()
    )


def test_refine_checks_damping(model: ForwardModel) -> None:
    measurement = measured(make_verification(model).target)
    with pytest.raises(ProfileError, match="damping"):
        refine(model, measurement, damping=0)
    full = refine(model, measurement, damping=1.0)
    assert full.size == model.size and np.allclose(full.paper_xyz, model.paper_xyz)


def test_a_run_keeps_every_round_in_its_folder(tmp_path: Path) -> None:
    folder = tmp_path / "run"
    run, summary = ColourRun.start(folder, "plain", [measured(make_target())], "MG3600 plain")
    assert "patches" in summary and (folder / "plain-v0.icc").exists()
    assert b"MG3600 plain (OpenQuad v0)" in (folder / "plain-v0.icc").read_bytes()
    with pytest.raises(ColourRunError, match="verification page first"):
        run.verification()
    with pytest.raises(ColourRunError, match="measure"):
        run.refine()
    pages = run.make_pages(dpi=100)
    assert [p.name for p in pages] == ["plain-v0-verify.tif"]
    # "Print" the page and scan it.
    verification = run.verification()
    scanned = tmp_path / "scan.tif"
    image = scan(verification.target)
    tifffile.imwrite(scanned, np.rint(image * 65535).astype(np.uint16), photometric="rgb")
    report = ColourRun.resume(folder).measure([scanned])
    assert report.passed
    again = ColourRun.resume(folder)
    assert again.current.action == "done" and again.current.scans == ["plain-v0-scan1.tif"]
    assert again.current.assessment is not None and again.current.assessment["mean"] < 1
    assert (folder / "plain-v0-report.json").exists()
    assert (folder / "plain-v0-measured.json").exists()
    nxt = again.refine()
    assert nxt.version == 1 and (folder / "plain-v1.icc").exists()
    assert len(ColourRun.resume(folder).rounds) == 2
    with pytest.raises(ColourRunError, match="invalid profile name"):
        ColourRun.start(tmp_path / "other", "a/b", [measured(make_target())])
    (tmp_path / "notrun").mkdir()
    (tmp_path / "notrun" / "run.json").write_text("{}")
    with pytest.raises(ColourRunError, match="isn't a colour calibration run"):
        ColourRun.resume(tmp_path / "notrun")


def test_cli_run(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    measurement = tmp_path / "m.json"
    measurement.write_text(measured(make_target()).to_json())
    folder = tmp_path / "run"
    assert main(["profile", "start", str(folder), str(measurement), "--name", "plain"]) == 0
    assert "profile page" in capsys.readouterr().out
    assert main(["profile", "page", str(folder), "--dpi", "100"]) == 0
    assert "plain-v0-verify.tif" in capsys.readouterr().out
    verification = ColourRun.resume(folder).verification()
    scanned = tmp_path / "scan.tif"
    tifffile.imwrite(
        scanned, np.rint(scan(verification.target) * 65535).astype(np.uint16), photometric="rgb"
    )
    assert main(["profile", "verify", str(folder), str(scanned)]) == 0
    assert "Goals met" in capsys.readouterr().out
    assert main(["profile", "refine", str(folder), "--damping", "0.3"]) == 0
    assert "round 1" in capsys.readouterr().out
    assert main(["profile", "verify", str(folder), str(scanned)]) == 1
    assert "verification page first" in capsys.readouterr().err


def test_the_driver_comparison_sends_the_same_colours_as_srgb(model: ForwardModel) -> None:
    verification = make_verification(model)
    driver = driver_verification(verification)
    assert driver.names == verification.names and driver.groups == verification.groups
    assert np.array_equal(driver.wanted, verification.wanted)
    assert np.array_equal(driver.printable, verification.printable)
    # The photo colours were picked in sRGB, so they go back to what they were picked as.
    names, _, _ = verification_colours()
    sent = dict(zip(driver.names, driver.target.sent.tolist(), strict=True))
    first = next(n for n in names if n.startswith("photo 1 "))
    picked = [int(v) for v in first.split("sRGB ")[1].rstrip(")").split()]
    assert np.abs(np.array(sent[first]) / 257 - picked).max() <= 0.6
    grey = sent["grey L* 95"]
    assert max(grey) - min(grey) <= 32  # neutral within an eighth of an 8-bit level


def test_a_run_judges_the_driver_comparison(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    folder = tmp_path / "run"
    run, _ = ColourRun.start(folder, "plain", [measured(make_target())])
    with pytest.raises(ColourRunError, match="verification page first"):
        run.make_driver_pages(dpi=100)
    with pytest.raises(ColourRunError, match="driver comparison page first"):
        run.measure_driver([tmp_path / "x.tif"])
    run.make_pages(dpi=100)
    assert main(["profile", "page", "--driver", str(folder), "--dpi", "100"]) == 0
    assert "plain-v0-driver.tif" in capsys.readouterr().out
    again = ColourRun.resume(folder)
    layout = folder / again.extra["driver"]["layout"]
    driver = VerificationTarget.from_json(layout.read_text())
    scanned = tmp_path / "scan.tif"
    image = scan(driver.target)  # the simulated printer: duller and warmer than sRGB
    tifffile.imwrite(scanned, np.rint(image * 65535).astype(np.uint16), photometric="rgb")
    assert main(["profile", "verify", "--driver", str(folder), str(scanned)]) == 0
    out = capsys.readouterr().out
    assert "driver's own colour management" in out and "Goals not met" in out
    kept = ColourRun.resume(folder)
    assert kept.extra["driver"]["assessment"]["mean"] > MEAN_GOAL
    assert kept.extra["driver"]["scans"] == ["plain-v0-driver-scan1.tif"]
    assert kept.current.action is None  # the profile's own round is untouched


def test_cli_verify_reports_a_miss(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    folder = tmp_path / "run"
    run, _ = ColourRun.start(folder, "drift", [measured(make_target(), DRIFT)])
    run.make_pages(dpi=100)
    scanned = tmp_path / "scan.tif"
    # The page printed on the undrifted printer the scan helper simulates, read against
    # a profile made for the drifted one: it misses.
    image = scan(run.verification().target)
    tifffile.imwrite(scanned, np.rint(image * 65535).astype(np.uint16), photometric="rgb")
    assert main(["profile", "verify", str(folder), str(scanned)]) == 0
    out = capsys.readouterr().out
    assert "Goals not met" in out and "profile refine" in out
    assert ColourRun.resume(folder).current.action == "refine"


def test_a_run_started_in_the_app_keeps_its_extra_details(tmp_path: Path) -> None:
    """The Mac app's runs start from the target and record more; Python keeps it all."""
    folder = tmp_path / "run"
    ColourRun.start(folder, "plain", [measured(make_target())])
    log = json.loads((folder / "run.json").read_text())
    log["printer"], log["page_ppi"] = "Canon_MG3600_series", 300.0
    log["target"] = {"grid": 6, "layout": "plain-target.json", "scans": ["plain-target-scan1.jpg"]}
    log["rounds"][0]["job"] = "Canon-12"
    log["rounds"][0]["something_newer"] = True
    (folder / "run.json").write_text(json.dumps(log))
    again = ColourRun.resume(folder)
    assert again.current.job == "Canon-12" and again.extra["printer"] == "Canon_MG3600_series"
    again.make_pages(dpi=60)
    kept = json.loads((folder / "run.json").read_text())
    assert kept["target"]["scans"] == ["plain-target-scan1.jpg"] and kept["page_ppi"] == 300.0
    assert kept["rounds"][0]["job"] == "Canon-12"
    # A run the app hasn't built a profile in yet.
    log["rounds"] = []
    (folder / "run.json").write_text(json.dumps(log))
    with pytest.raises(ColourRunError, match="colour target first"):
        ColourRun.resume(folder).verification()


def test_a_run_reads_scans_through_its_scanner_model(tmp_path: Path) -> None:
    from openquad.scanner_profile import CURVE_POINTS, ScannerModel

    folder = tmp_path / "run"
    ColourRun.start(folder, "plain", [measured(make_target())])
    grid = np.linspace(0, 1, CURVE_POINTS)
    matrix = np.array([[0.4, 0.2, 0.02], [0.35, 0.7, 0.1], [0.2, 0.08, 0.7], [0, 0, 0]])
    model = ScannerModel("matrix", np.stack([grid, grid, grid]), matrix, scanner="Flatbed")
    (folder / "scanner-model.json").write_text(model.to_json())
    log = json.loads((folder / "run.json").read_text())
    log["scanner_model"] = "scanner-model.json"
    (folder / "run.json").write_text(json.dumps(log))
    again = ColourRun.resume(folder)
    again.make_pages(dpi=100)
    scanned = tmp_path / "scan.tif"
    image = scan(again.verification().target)
    tifffile.imwrite(scanned, np.rint(image * 65535).astype(np.uint16), photometric="rgb")
    again.measure([scanned])
    measured_file = folder / str(ColourRun.resume(folder).current.measurement)
    assert "Flatbed" in json.loads(measured_file.read_text())["colourimetry"]
