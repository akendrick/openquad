"""Tests for building a printer's colour profile (colour calibration, phase 2).

The printer is simulated, as in the colour target's tests: duller primaries, a warm cast
and paper that isn't quite white. Its measurements are worked out directly (no scan),
and the profile is checked against that printer, against itself, and with LittleCMS
(through Pillow) so the ICC file isn't only checked by the code that wrote it."""

from __future__ import annotations

import io
import json
import struct
from pathlib import Path

import numpy as np
import pytest
from PIL import Image, ImageCms

from openquad.cli import main
from openquad.colour import (
    D50_WHITE,
    d65_to_d50,
    delta_e_2000,
    linear_rgb_to_xyz,
    srgb_to_linear,
    xyz_to_lab,
)
from openquad.colour_profile import (
    GAMUT_LIMIT,
    ForwardModel,
    ProfileError,
    ProfileReport,
    black_point,
    build_profile,
    compensate_black,
    decode_lab,
    encode_lab,
    fit_forward,
    icc_profile,
    invert,
)
from openquad.colour_target import ColourMeasurement, make_target
from openquad.quadfile import MAX_VALUE


def printer_xyz(encoded: np.ndarray) -> np.ndarray:
    """D50 XYZ of what the simulated printer prints for RGB sent (0-1)."""
    linear = srgb_to_linear(encoded)
    mixed = 0.8 * linear + 0.2 * linear.mean(axis=-1, keepdims=True)
    tinted = mixed * np.array([0.92, 0.9, 0.84]) + np.array([0.01, 0.009, 0.008])
    return d65_to_d50(linear_rgb_to_xyz(tinted))


PAPER = printer_xyz(np.ones(3))


def printer_lab(encoded: np.ndarray) -> np.ndarray:
    return xyz_to_lab(printer_xyz(encoded), PAPER)


def measurement(noise: float = 0.0, seed: int = 0, fine: bool = False) -> ColourMeasurement:
    target = make_target(9 if fine else 6)
    lab = printer_lab(target.sent / MAX_VALUE)
    lab = lab + np.random.default_rng(seed).normal(0, noise, lab.shape)
    return ColourMeasurement(
        sent=target.sent, xyz=printer_xyz(target.sent / MAX_VALUE), lab=lab, paper_xyz=PAPER
    )


@pytest.fixture(scope="module")
def report() -> ProfileReport:
    return build_profile([measurement()])


@pytest.fixture(scope="module")
def profile(report: ProfileReport) -> bytes:
    return icc_profile(report.model, "Simulated printer", report.tables)


def test_lab_encoding_round_trips() -> None:
    lab = np.array([[0, 0, 0], [100, 0, 0], [50, -128, 127], [73.2, 12.5, -40.25]])
    encoded = encode_lab(lab)
    assert encoded[1, 0] == 0xFF00 and encoded[0, 1] == 0x8000
    assert np.allclose(decode_lab(encoded), lab, atol=0.01)


def test_forward_model_predicts_colours_it_was_not_fitted_to(report: ProfileReport) -> None:
    new = np.random.default_rng(3).uniform(0, 1, (400, 3))
    errors = delta_e_2000(report.model.lab(new), printer_lab(new))
    assert errors.mean() < 0.5 and errors.max() < 3
    assert report.fitted.mean() < 0.3
    assert report.held_out.mean() < 1.0
    assert report.prints == 1 and report.spread is None


def test_noisy_measurements_are_smoothed_more() -> None:
    m = measurement(noise=1.5, seed=4)
    rgb, lab = m.sent / MAX_VALUE, m.lab
    noisy, _ = fit_forward(rgb, lab)
    assert noisy.smoothing > 0.0001
    rough, errors = fit_forward(rgb, lab, smoothing=0.0001)
    assert rough.smoothing == 0.0001 and len(errors) == len(rgb)
    new = np.random.default_rng(5).uniform(0, 1, (300, 3))
    smoothed_error = delta_e_2000(noisy.lab(new), printer_lab(new)).mean()
    rough_error = delta_e_2000(rough.lab(new), printer_lab(new)).mean()
    assert smoothed_error < rough_error


def test_too_few_patches() -> None:
    with pytest.raises(ProfileError, match="at least"):
        fit_forward(np.zeros((10, 3)), np.zeros((10, 3)))


def test_model_round_trips_through_json(report: ProfileReport) -> None:
    again = ForwardModel.from_json(report.model.to_json())
    rgb = np.random.default_rng(1).uniform(0, 1, (50, 3))
    assert np.allclose(again.lab(rgb), report.model.lab(rgb), atol=1e-3)
    assert again.smoothing == report.model.smoothing and again.size == 9
    assert np.allclose(again.paper_xyz, PAPER)
    with pytest.raises(ProfileError, match="colour model"):
        ForwardModel.from_json(json.dumps({"kind": "other"}))


def test_inverse_finds_the_rgb_for_printable_colours(report: ProfileReport) -> None:
    rgb = np.random.default_rng(6).uniform(0.02, 0.98, (300, 3))
    wanted = printer_lab(rgb)
    found = invert(report.model, wanted)
    assert delta_e_2000(printer_lab(found), wanted).mean() < 0.5
    assert np.abs(found - rgb).max() < 0.08


def test_unprintable_colours_go_to_the_nearest_printable(report: ProfileReport) -> None:
    wanted = np.array([[50.0, 120.0, 0.0], [95.0, -100.0, 100.0], [2.0, 0.0, 0.0]])
    found = invert(report.model, wanted)
    assert found.min() >= 0 and found.max() <= 1
    printed = report.model.lab(found)
    # Nothing printable is nearer than what was found.
    grid = np.random.default_rng(7).uniform(0, 1, (20000, 3))
    reachable = report.model.lab(grid)
    for want, got in zip(wanted, printed, strict=True):
        nearest = np.sqrt(((reachable - want) ** 2).sum(axis=1)).min()
        assert np.sqrt(((got - want) ** 2).sum()) <= nearest + 0.5
    assert (report.tables.gamut > GAMUT_LIMIT).any() and (report.tables.gamut <= GAMUT_LIMIT).any()


def test_black_point_compensation(report: ProfileReport) -> None:
    black = black_point(report.model)
    black_lab = xyz_to_lab(black, D50_WHITE)
    assert abs(black_lab[0] - printer_lab(np.zeros(3))[0]) < 1.0
    assert abs(black_lab[1]) < 1e-6 and abs(black_lab[2]) < 1e-6
    mapped = compensate_black(np.array([[0.0, 0, 0], [100, 0, 0], [50, 20, -20]]), black)
    assert np.allclose(mapped[0], black_lab, atol=1e-6)
    assert np.allclose(mapped[1], [100, 0, 0], atol=1e-6)
    assert mapped[2, 0] > 50


def test_greys_stay_grey(report: ProfileReport) -> None:
    assert report.neutral_cast.max() < 0.5
    summary = report.summary()
    assert "255 patches" in summary and "worst cast" in summary and "left out" in summary


def test_averages_several_prints() -> None:
    built = build_profile([measurement(0.3, seed=1), measurement(0.3, seed=2)])
    assert built.prints == 2 and built.spread is not None and built.spread.shape == (2, 255)
    assert "Between prints" in built.summary() and "averaged over 2 prints" in built.summary()
    with pytest.raises(ProfileError, match="different targets"):
        build_profile([measurement(), measurement(fine=True)])
    with pytest.raises(ProfileError, match="no measurements"):
        build_profile([])


def test_icc_header_and_tags(profile: bytes) -> None:
    (size,) = struct.unpack(">I", profile[:4])
    assert size == len(profile)
    assert profile[8:12] == bytes([2, 0x10, 0, 0])
    assert profile[12:24] == b"prtrRGB Lab " and profile[36:40] == b"acsp"
    (count,) = struct.unpack(">I", profile[128:132])
    tags = {}
    for i in range(count):
        sig, offset, length = struct.unpack(">4sII", profile[132 + 12 * i : 144 + 12 * i])
        assert offset % 4 == 0 and offset + length <= size
        tags[sig] = profile[offset : offset + length]
    for sig in (b"desc", b"cprt", b"wtpt", b"A2B0", b"A2B1", b"B2A0", b"B2A1", b"B2A2", b"gamt"):
        assert sig in tags
    assert tags[b"A2B0"] == tags[b"A2B1"] and tags[b"B2A0"] != tags[b"B2A1"]
    assert tags[b"A2B0"][:4] == b"mft2" and tags[b"A2B0"][10] == 17
    assert tags[b"B2A1"][10] == 33
    white = np.array(struct.unpack(">3i", tags[b"wtpt"][8:20])) / 65536
    assert np.allclose(white, PAPER, atol=1e-4)


def _lab8(image: Image.Image) -> np.ndarray:
    """Pillow's 8-bit LAB as L*a*b*."""
    raw = np.asarray(image)
    return np.stack(
        [
            raw[..., 0].astype(np.float64) * 100 / 255,
            raw[..., 1].view(np.int8),
            raw[..., 2].view(np.int8),
        ],
        axis=-1,
    ).astype(np.float64)


def test_littlecms_reads_the_profile_as_the_model(report: ProfileReport, profile: bytes) -> None:
    ours = ImageCms.getOpenProfile(io.BytesIO(profile))
    assert ImageCms.getProfileDescription(ours).strip() == "Simulated printer"
    lab = ImageCms.createProfile("LAB")
    rgb8 = np.random.default_rng(8).integers(0, 256, (1, 200, 3)).astype(np.uint8)
    to_lab = ImageCms.buildTransform(ours, lab, "RGB", "LAB", renderingIntent=1)
    measured = _lab8(ImageCms.applyTransform(Image.fromarray(rgb8), to_lab))[0]
    expected = report.model.lab(rgb8[0] / 255)
    assert delta_e_2000(measured, expected).mean() < 1.0
    # And back: L*a*b* to RGB through B2A1 matches the inverse.
    back = ImageCms.buildTransform(lab, ours, "LAB", "RGB", renderingIntent=1)
    sent = np.asarray(
        ImageCms.applyTransform(ImageCms.applyTransform(Image.fromarray(rgb8), to_lab), back)
    )
    printed = report.model.lab(sent[0] / 255)
    assert delta_e_2000(printed, expected).mean() < 1.5


def test_cli_builds_a_profile(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    measured = tmp_path / "m.json"
    measured.write_text(measurement().to_json())
    out = tmp_path / "plain.icc"
    assert main(["profile", "build", str(measured), "-o", str(out), "--smoothing", "0.001"]) == 0
    text = capsys.readouterr().out
    assert "smoothing 0.001" in text and "plain.json" in text
    assert out.read_bytes()[36:40] == b"acsp"
    assert b"plain" in out.read_bytes()[:2000]
    assert ForwardModel.from_json((tmp_path / "plain.json").read_text()).smoothing == 0.001


def test_cli_profile_help_and_errors(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    with pytest.raises(SystemExit):
        main(["profile"])
    assert "build" in capsys.readouterr().out
    bad = tmp_path / "bad.json"
    bad.write_text("{}")
    assert main(["profile", "build", str(bad), "-o", str(tmp_path / "x.icc")]) == 1
    assert "colour measurement" in capsys.readouterr().err
