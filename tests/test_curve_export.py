"""Smoothing, lost tones and exporting process curves for other software."""

import struct
from pathlib import Path

import numpy as np
import pytest
import tifffile

from openquad.chart import (
    CLIP_WARN,
    PATCHES,
    SMOOTHING,
    ChartReading,
    ProcessCurve,
    ascending_fit,
    build_process_curve,
    clipped_tones,
    clipping_advice,
    patch_level,
    save_process,
    smooth_response,
)
from openquad.cli import main
from openquad.curve_export import (
    ACV_POINTS,
    acv_bytes,
    acv_points,
    amp_bytes,
    csv_text,
    cube_text,
    export_curve,
    lut8,
    spline,
)
from openquad.imageio import GreyImage, save_grey

LEVELS = np.array([patch_level(n) for n in range(PATCHES)], dtype=np.uint16)


def reading(
    exponent: float = 0.6, noise: float = 0.0, seed: int = 1, top: float = 99.0
) -> ChartReading:
    lightness = 18.0 + 70.0 * (LEVELS / 65535.0) ** exponent
    lightness = np.minimum(lightness, top) + np.random.default_rng(seed).normal(0, noise, PATCHES)
    return ChartReading(LEVELS, lightness, np.zeros(21), "F", 90.0)


def bent() -> ProcessCurve:
    levels = np.rint(np.linspace(0, 65535, 257)).astype(np.uint16)
    return ProcessCurve(levels, np.rint(65535 * (levels / 65535.0) ** 1.6).astype(np.uint16))


# --- smoothing -----------------------------------------------------------------------


def test_smoothing_keeps_straight_lines_and_evens_out_noise() -> None:
    x = np.linspace(0, 65535, 101)
    line = 20 + x / 1000
    assert np.allclose(smooth_response(x, line, 5), line)
    assert np.array_equal(smooth_response(x, line, 0), line)
    noisy = line + np.random.default_rng(2).normal(0, 1, 101)
    assert np.std(smooth_response(x, noisy, 5) - line) < 0.6 * np.std(noisy - line)


def test_ascending_fit_pools_what_falls() -> None:
    assert ascending_fit(np.array([1.0, 3.0, 2.0, 4.0])).tolist() == [1.0, 2.5, 2.5, 4.0]
    assert ascending_fit(np.array([5.0, 1.0])).tolist() == [3.0, 3.0]


def test_smoothing_makes_a_smoother_curve_from_a_noisy_print() -> None:
    ideal = build_process_curve(reading(), smoothing=0).curve.astype(float)
    rough = {}
    for name, reach in SMOOTHING.items():
        curve = build_process_curve(reading(noise=0.6), smoothing=reach).curve.astype(float)
        rough[name] = np.abs(np.diff(curve, 2) - np.diff(ideal, 2)).mean()
        assert np.all(np.diff(curve) >= 0) and curve[0] == ideal[0] and curve[-1] == ideal[-1]
    assert rough["medium"] < rough["none"] / 10
    assert rough["strong"] < rough["light"] < rough["none"]


# --- lost tones ----------------------------------------------------------------------


def test_lost_highlights_and_shadows_are_counted() -> None:
    assert (
        clipped_tones(reading(noise=0.3)) == (0, 0)
        or max(clipped_tones(reading(noise=0.3))) < CLIP_WARN
    )
    light, dark = clipped_tones(reading(exponent=1.0, top=80.0))
    assert light >= 10 and dark == 0
    blocked = reading(exponent=1.0)
    blocked.lightness[60:] = blocked.lightness[60:].min()
    light, dark = clipped_tones(blocked)
    assert light == 0 and dark >= 30


def test_clipping_advice() -> None:
    assert clipping_advice(0, CLIP_WARN - 1) is None
    assert "more exposure" in (clipping_advice(8, 0) or "")
    assert "less exposure" in (clipping_advice(0, 8) or "")
    assert "range is longer" in (clipping_advice(5, 6) or "")


# --- export --------------------------------------------------------------------------


def test_amp_is_the_curve_at_256_levels() -> None:
    assert amp_bytes(ProcessCurve.identity()) == bytes(range(256))
    data = amp_bytes(bent())
    assert len(data) == 256 and data[0] == 0 and data[255] == 255
    assert data[128] == round(255 * (128 / 255) ** 1.6)


def test_spline_is_natural_and_passes_through_its_points() -> None:
    xs, ys = [0, 100, 200, 255], [0, 60, 180, 255]
    assert all(abs(spline(xs, ys, x) - y) < 1e-9 for x, y in zip(xs, ys, strict=True))
    assert spline([0, 255], [10, 200], 51) == pytest.approx(10 + 190 * 0.2)


def test_acv_points_follow_the_curve() -> None:
    assert acv_points(ProcessCurve.identity()) == [(0, 0), (255, 255)]
    points = acv_points(bent())
    assert 2 < len(points) <= ACV_POINTS and points[0] == (0, 0) and points[-1] == (255, 255)
    xs, ys = [p[0] for p in points], [p[1] for p in points]
    target = lut8(bent())
    assert max(abs(spline(xs, ys, i) - int(target[i])) for i in range(256)) <= 1.5


def test_acv_file_layout() -> None:
    data = acv_bytes(bent())
    version, count, n = struct.unpack(">HHH", data[:6])
    assert (version, count) == (1, 5)
    pairs = struct.unpack(f">{2 * n}H", data[6 : 6 + 4 * n])
    assert pairs[:2] == (0, 0) and pairs[-2:] == (255, 255)  # (output, input)
    assert data[6 + 4 * n :] == struct.pack(">HHHHH", 2, 0, 0, 255, 255) * 4


def test_cube_and_csv() -> None:
    lines = cube_text(bent(), size=3, title="t").splitlines()
    assert lines[:2] == ['TITLE "t"', "LUT_3D_SIZE 3"] and len(lines) == 2 + 27
    assert lines[2] == "0.000000 0.000000 0.000000" and lines[-1] == "1.000000 1.000000 1.000000"
    half = float(np.interp(0.5 * 65535, bent().levels, bent().curve)) / 65535
    assert lines[3] == f"{half:.6f} 0.000000 0.000000"  # red changes fastest
    rows = csv_text(bent()).splitlines()
    assert rows[0] == "input,output" and len(rows) == 258 and rows[-1] == "65535,65535"


def test_export_by_suffix(tmp_path: Path) -> None:
    for suffix in (".amp", ".acv", ".cube", ".csv"):
        export_curve(bent(), tmp_path / f"c{suffix}")
        assert (tmp_path / f"c{suffix}").stat().st_size > 50
    with pytest.raises(ValueError, match=r"can.t export to \.txt"):
        export_curve(bent(), tmp_path / "c.txt")


def test_curve_command(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    curve = tmp_path / "green.oqproc"
    save_process(bent(), curve)
    assert main(["curve", str(curve), str(tmp_path / "green.acv")]) == 0
    assert (tmp_path / "green.acv").read_bytes() == acv_bytes(bent())
    photo = tmp_path / "ramp.tif"
    ramp = np.tile(np.linspace(0, 65535, 64).astype(np.uint16), (8, 1))
    save_grey(photo, GreyImage(ramp, (100.0, 100.0)))
    assert main(["curve", str(curve), str(tmp_path / "out.tif"), "--image", str(photo)]) == 0
    assert np.array_equal(tifffile.imread(tmp_path / "out.tif"), bent().apply(ramp))
    assert main(["curve", str(curve), str(tmp_path / "out.tif")]) != 0
    assert main(["curve", str(curve), str(tmp_path / "x.acv"), "--image", str(photo)]) != 0
    assert "--image" in capsys.readouterr().err
