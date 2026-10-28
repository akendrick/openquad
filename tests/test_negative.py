"""Digital negatives: inversion, colour, mirror, safe edge and the orientation mark."""

from pathlib import Path

import numpy as np
import pytest
import tifffile

from openquad.cli import main
from openquad.imageio import read_dpi
from openquad.negative import (
    F_GLYPH,
    NEGATIVE_COLOURS,
    NegativeSettings,
    add_safe_edge,
    make_negative,
    negative_ppi,
)

RAMP = np.tile(np.linspace(0, 65535, 40).astype(np.uint16), (30, 1))  # black left, white right
NO_EDGE = NegativeSettings(safe_edge=0.0)


def test_light_tones_get_the_most_ink() -> None:
    neg = make_negative(RAMP, NO_EDGE, dpi=100)
    assert neg.shape == (30, 40, 3)
    assert neg[0, 0].tolist() == [65535] * 3  # photo black -> clear film
    assert neg[0, -1].tolist() == [0] * 3  # photo white -> full black ink
    assert np.all(np.diff(neg[0, :, 0].astype(int)) <= 0)  # monotonic


def test_black_negative_is_the_exact_inverse() -> None:
    neg = make_negative(RAMP, NO_EDGE, dpi=100).astype(int)
    assert np.abs(neg[..., 0] - (65535 - RAMP.astype(int))).max() <= 1


@pytest.mark.parametrize("colour", sorted(NEGATIVE_COLOURS))
def test_coloured_negatives_use_their_colour(colour: str) -> None:
    neg = make_negative(RAMP, NegativeSettings(colour=colour, safe_edge=0.0), dpi=100)
    full = neg[0, -1] / 65535
    expected = np.array(NEGATIVE_COLOURS[colour])
    assert np.abs(full - expected).max() < 0.01
    assert neg[0, 0].tolist() == [65535] * 3  # clear where the print is black


def test_mirror_flips_left_to_right() -> None:
    plain = make_negative(RAMP, NO_EDGE, dpi=100)
    flipped = make_negative(RAMP, NegativeSettings(mirror=True, safe_edge=0.0), dpi=100)
    assert np.array_equal(flipped, plain[:, ::-1])


def test_safe_edge_is_opaque_and_sized_in_inches() -> None:
    neg = make_negative(RAMP, NegativeSettings(safe_edge=0.5, mark=False), dpi=100)
    assert neg.shape == (130, 140, 3)  # 50 px border all round
    border = np.concatenate([neg[:50].reshape(-1, 3), neg[-50:].reshape(-1, 3)])
    assert np.all(border == 0)
    assert np.array_equal(neg[50:80, 50:90], make_negative(RAMP, NO_EDGE, dpi=100))


def find_mark(neg: np.ndarray) -> np.ndarray:
    """The clear pixels in the top-left corner of the safe edge (where the F is cut)."""
    return neg[:50, :50, 0] == 65535


def test_orientation_mark_is_an_f_that_flips_with_the_image() -> None:
    settings = NegativeSettings(safe_edge=0.5)
    mark = find_mark(make_negative(RAMP, settings, dpi=100))
    rows, cols = np.flatnonzero(mark.any(axis=1)), np.flatnonzero(mark.any(axis=0))
    glyph = mark[rows[0] : rows[-1] + 1, cols[0] : cols[-1] + 1]
    cell = glyph.shape[0] // F_GLYPH.shape[0]
    assert np.array_equal(glyph[::cell, ::cell], F_GLYPH)  # reads as F
    mirrored = make_negative(RAMP, NegativeSettings(safe_edge=0.5, mirror=True), dpi=100)
    assert np.array_equal(mirrored[:50, -50:, 0] == 65535, mark[:, ::-1])  # F flipped too


def test_mark_is_skipped_when_the_edge_is_too_thin() -> None:
    neg = make_negative(RAMP, NegativeSettings(safe_edge=0.02), dpi=100)  # 2 px edge
    assert not np.any(neg[:2] == 65535)


def test_add_safe_edge_without_edge_only_mirrors() -> None:
    image = np.zeros((2, 3, 3), dtype=np.uint16)
    image[0, 0] = 7
    out = add_safe_edge(image, NegativeSettings(safe_edge=0.0, mirror=True), dpi=100)
    assert out[0, 2].tolist() == [7, 7, 7]


@pytest.mark.parametrize(
    ("kwargs", "message"),
    [({"colour": "purple"}, "unknown negative colour"), ({"safe_edge": 3.0}, "safe edge")],
)
def test_settings_are_checked(kwargs: dict[str, object], message: str) -> None:
    with pytest.raises(ValueError, match=message):
        NegativeSettings(**kwargs)  # type: ignore[arg-type]


def test_make_negative_needs_greyscale() -> None:
    with pytest.raises(ValueError, match="2-D uint16"):
        make_negative(np.zeros((2, 2, 3), dtype=np.uint16), NO_EDGE, dpi=100)


def test_negative_ppi_leaves_room_for_the_safe_edge() -> None:
    ppi = negative_ppi(3008, 4032, "Letter", safe_edge=0.25, margin=0.5)
    width, height = 3008 / ppi + 0.5, 4032 / ppi + 0.5  # photo + 0.25 in edge each side
    assert width == pytest.approx(7.5)  # width limits: 8.5 in minus 0.5 in margins
    assert height < 10.0
    with pytest.raises(ValueError, match="no room"):
        negative_ppi(10, 10, "4x6", safe_edge=1.5, margin=0.5)
    with pytest.raises(ValueError, match="unknown paper"):
        negative_ppi(10, 10, "Tabloid", safe_edge=0.25, margin=0.5)


# --- command line --------------------------------------------------------------------


def photo(tmp_path: Path) -> Path:
    path = tmp_path / "p.tif"
    tifffile.imwrite(path, RAMP, resolution=(100, 100), resolutionunit="INCH")
    return path


def test_negative_command(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    out = tmp_path / "neg.tif"
    argv = ["negative", str(photo(tmp_path)), "-o", str(out), "--colour", "green", "--mirror"]
    assert main(argv) == 0
    neg = tifffile.imread(out)
    assert neg.shape == (80, 90, 3)  # 0.25 in edge at the photo's 100 dpi
    assert read_dpi(out) == pytest.approx((100, 100))
    assert "green, mirrored" in capsys.readouterr().out


def test_negative_command_fit_and_dpi(tmp_path: Path) -> None:
    out = tmp_path / "neg.tif"
    assert main(["negative", str(photo(tmp_path)), "-o", str(out), "--fit", "Letter"]) == 0
    dpi = read_dpi(out)
    assert dpi is not None and 40 / dpi[0] + 0.5 == pytest.approx(7.5)  # width limits
    argv = ["negative", str(photo(tmp_path)), "-o", str(out), "--dpi", "50"]
    assert main([*argv, "--safe-edge", "0", "--no-mark"]) == 0
    assert tifffile.imread(out).shape == (30, 40, 3)
    assert main(["negative", str(photo(tmp_path)), "-o", str(out), "--fit", "Tabloid"]) == 1


def test_safe_edge_is_printed_in_the_negative_colour() -> None:
    neg = make_negative(RAMP, NegativeSettings(colour="green", safe_edge=0.5, mark=False), dpi=100)
    edge = neg[:50].reshape(-1, 3) / 65535
    assert np.abs(edge - np.array(NEGATIVE_COLOURS["green"])).max() < 0.01


def test_box_ppi_turns_the_box_to_match_the_photo() -> None:
    from openquad.paper import box_ppi, oriented

    assert oriented((8.0, 10.0), 300, 400) == (8.0, 10.0)
    assert oriented((8.0, 10.0), 400, 300) == (10.0, 8.0)
    assert box_ppi(300, 400, (10.0, 8.0), 0.25) == pytest.approx(max(300 / 7.5, 400 / 9.5))
    with pytest.raises(ValueError, match="no room"):
        box_ppi(300, 400, (0.4, 0.4), 0.25)
    with pytest.raises(ValueError, match="positive"):
        box_ppi(300, 400, (0.0, 4.0))
    with pytest.raises(ValueError, match="no pixels"):
        box_ppi(0, 400, (4.0, 5.0))


def test_negative_command_max_size(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    out = tmp_path / "neg.tif"
    base = ["negative", str(photo(tmp_path)), "-o", str(out)]
    assert main([*base, "--fit", "Letter", "--max-size", "4x5"]) == 0
    dpi = read_dpi(out)
    assert dpi is not None and 40 / dpi[0] + 0.5 == pytest.approx(5.0)  # landscape: 5 x 4 in box
    assert "5.00 x" in capsys.readouterr().out
    assert main([*base, "--max-size", "4x5"]) == 1  # needs --fit
    with pytest.raises(SystemExit):
        main([*base, "--fit", "Letter", "--max-size", "big"])
