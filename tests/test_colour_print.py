"""Printing in colour through an OpenQuad printer profile (colour calibration, phase 5):
the library of profiles, converting a photo, the print session and the command line.

The profiles are made for the simulated printer of the colour verification tests."""

from __future__ import annotations

import io
import json
from pathlib import Path

import numpy as np
import pytest
import tifffile
from PIL import Image, ImageCms

from openquad.cli import main
from openquad.colour_convert import (
    ColourConvertError,
    _profile,
    device_table,
    is_rgb_output_profile,
    proof,
    to_device,
)
from openquad.colour_target import make_target
from openquad.colour_verify import (
    ColourRun,
    colour_profiles,
    match_colour_profile,
    printer_name,
)
from openquad.imageio import srgb_profile
from openquad.session import SessionError
from tests.test_colour_verify import measured
from tests.test_session import RGB_PROFILE, colour_file, colour_session


def make_library(base: Path) -> Path:
    """A library folder with two runs: the Canon's (straight to the printer, two rounds, the
    first checked) and the Epson's (through the print panel), and a folder that isn't a run."""
    measurement = base / "m.json"
    measurement.write_text(measured(make_target()).to_json())
    canon = ["--printer", "Canon_MG3600_series", "--paper", "Letter plain",
             "--settings", "straight to the printer (lp)"]  # fmt: skip
    assert main(["profile", "start", str(base / "canon"), str(measurement), "--name", "plain",
                 *canon]) == 0  # fmt: skip
    run = ColourRun.resume(base / "canon")
    run.current.assessment, run.current.action = {"mean": 1.42}, "done"
    run.save()
    run._new_round(run.model())
    assert main(["profile", "start", str(base / "epson"), str(measurement), "--name", "glossy",
                 "--printer", "EPSON_ET_2900", "--settings", "print panel"]) == 0  # fmt: skip
    (base / "notes").mkdir()
    (base / "broken").mkdir()
    (base / "broken" / "run.json").write_text("{")
    return base


@pytest.fixture(scope="module")
def library(tmp_path_factory: pytest.TempPathFactory) -> Path:
    return make_library(tmp_path_factory.mktemp("library"))


def canon_profile(library: Path) -> Path:
    return library / "canon" / "plain-v0.icc"


def test_library_lists_labels_and_matches(library: Path) -> None:
    entries = colour_profiles(library)
    assert sorted((e.run, e.version) for e in entries) == [
        ("glossy", 0),
        ("plain", 0),
        ("plain", 1),
    ]
    first = next(e for e in entries if e.run == "plain" and e.version == 0)
    assert first.label.startswith("Canon MG3600 · Letter plain · v0 · ΔE 1.4 ✓ · ")
    assert not first.via_panel and first.passed and first.mean == 1.42
    newer = next(e for e in entries if e.run == "plain" and e.version == 1)
    assert newer.mean is None and newer.passed is None and "ΔE" not in newer.label
    epson = next(e for e in entries if e.run == "glossy")
    assert epson.via_panel and "print panel" in epson.label and epson.paper == ""
    assert epson.fits("EPSON_ET_2900", "A4")  # no paper recorded: any size
    assert first.fits("Canon_MG3600_series", "Letter") and not first.fits(
        "Canon_MG3600_series", "A4"
    )
    match = match_colour_profile(entries, "Canon_MG3600_series", "Letter")
    assert match is not None and match.run == "plain"
    assert match_colour_profile(entries, "Office_Laser", "Letter") is None
    assert match_colour_profile(entries, "EPSON_ET_2900", "Letter", via_panel=False) == epson
    assert colour_profiles(library / "missing") == []
    assert (
        printer_name("Canon_MG3600_series") == "Canon MG3600"
        and printer_name("_") == "Unknown printer"
    )


def test_cli_lists_profiles(
    library: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    assert main(["profile", "list", str(library)]) == 0
    out = capsys.readouterr().out
    assert "Canon MG3600 · Letter plain · v0" in out and str(canon_profile(library)) in out
    assert main(["profile", "list", str(tmp_path)]) == 0
    assert "no colour profiles" in capsys.readouterr().out
    log = json.loads((library / "canon" / "run.json").read_text())
    assert log["printer"] == "Canon_MG3600_series" and log["paper_label"] == "Letter plain"


def test_to_device_follows_littlecms(library: Path) -> None:
    profile = canon_profile(library).read_bytes()
    assert is_rgb_output_profile(profile)
    assert not is_rgb_output_profile(None) and not is_rgb_output_profile(RGB_PROFILE)
    # On the table's nodes, the same as LittleCMS converting 8-bit pixels directly.
    nodes = np.array([[[0, 0, 0], [255, 255, 255], [125, 60, 200], [5, 250, 35]]], np.uint8)
    transform = ImageCms.buildTransform(
        _profile(None), ImageCms.ImageCmsProfile(io.BytesIO(profile)), "RGB", "RGB",
    )  # fmt: skip
    direct = np.asarray(ImageCms.applyTransform(Image.fromarray(nodes), transform), np.int64)
    device = to_device(nodes.astype(np.uint16) * 257, None, profile).astype(np.int64)
    assert np.abs(device - direct * 257).max() <= 1
    # Between nodes it is smooth: a grey ramp prints darker step by step.
    ramp = np.repeat(np.linspace(0, 65535, 300).astype(np.uint16)[None, :, None], 3, -1)
    grey = to_device(ramp, None, profile)[0].astype(np.int64).sum(axis=-1)
    assert (np.diff(grey) >= 0).all() and grey[-1] > grey[0] + 150000
    assert device_table(None, profile).shape == (52, 52, 52, 3)


def test_to_device_works_in_bands(library: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    import openquad.colour_convert as convert

    profile = canon_profile(library).read_bytes()
    rgb = np.random.default_rng(3).integers(0, 65536, (7, 5, 3)).astype(np.uint16)
    whole = to_device(rgb, None, profile)
    monkeypatch.setattr(convert, "ROWS", 2)
    assert np.array_equal(to_device(rgb, None, profile), whole)


def test_proof_and_bad_profiles(library: Path) -> None:
    profile = canon_profile(library).read_bytes()
    rgb = np.array([[[255, 255, 255], [0, 0, 255], [30, 30, 30]]], np.uint8)
    shown = proof(rgb, None, profile)
    assert shown.shape == rgb.shape and shown.dtype == np.uint8
    assert shown[0, 0].min() > 200  # paper white shows white (relative colourimetric)
    assert not np.array_equal(shown, rgb)
    with pytest.raises(ColourConvertError, match="isn't an RGB printer profile"):
        to_device(rgb.astype(np.uint16), None, srgb_profile() or b"")
    with pytest.raises(ColourConvertError, match="can't be used"):
        to_device(rgb.astype(np.uint16), b"not a profile", profile)


def test_session_converts_through_the_profile(library: Path, tmp_path: Path) -> None:
    session = colour_session(tmp_path, profile=None)
    plain = session.render_print()
    plain_preview = session.preview(max_side=900)
    assert not session.converts_colour
    session.set_colour_profile(canon_profile(library))
    assert session.converts_colour and session.colour_profile_path == canon_profile(library)
    converted = session.render_print()
    assert converted.shape == plain.shape and not np.array_equal(converted, plain)
    assert session.photo is not None and session.photo.colour is not None
    expected = to_device(session.photo.colour, None, canon_profile(library).read_bytes())
    assert np.array_equal(converted, expected)
    assert session.print_profile() == srgb_profile()  # sent as sRGB, as the target was
    summary = session.summary()
    assert "Output: colour print through the printer profile plain-v0.icc" in summary
    assert "Colour profile: none (read as sRGB)" in summary
    assert not np.array_equal(session.preview(max_side=900), plain_preview)  # soft-proofed
    # A negative or a greyscale print isn't converted.
    session.set_colour_print(False)
    assert not session.converts_colour
    session.set_colour_profile(None)
    assert session.colour_profile is None and session.colour_profile_path is None


def test_session_keeps_the_photos_profile_unless_converting(library: Path, tmp_path: Path) -> None:
    session = colour_session(tmp_path)
    assert session.print_profile() == RGB_PROFILE
    with pytest.raises(SessionError, match="isn't an RGB printer profile"):
        session.set_colour_profile(colour_file(tmp_path))
    assert session.colour_profile is None
    session.set_colour_profile(canon_profile(library))
    assert session.print_profile() == srgb_profile()


def test_cli_prints_through_a_profile(
    library: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    photo = colour_file(tmp_path, profile=None)
    args = ["print", str(photo), "--printer", "Canon_MG3600_series", "--dry-run",
            "--colour-profile", str(canon_profile(library))]  # fmt: skip
    assert main(args) == 0
    assert "colour-profiled.tif" in capsys.readouterr().out
    assert main([*args, "--preset", "neutral"]) == 1
    assert "leave out --preset" in capsys.readouterr().err
    grey = tmp_path / "grey.tif"
    tifffile.imwrite(grey, np.zeros((4, 4), np.uint16))
    assert main(["print", str(grey), "--printer", "x", "--dry-run",
                 "--colour-profile", str(canon_profile(library))]) == 1  # fmt: skip
    assert "isn't a colour photo" in capsys.readouterr().err
