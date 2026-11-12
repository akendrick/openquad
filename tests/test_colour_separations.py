from pathlib import Path

import numpy as np
import pytest
import tifffile

from openquad.colour_separations import (
    DEFAULT_COATS,
    PIGMENTS,
    ColourSeparation,
    _inverse,
    coat_image,
    hex_colour,
    parse_hex,
    proof,
    solve,
    strength_lut,
)
from openquad.quadfile import MAX_VALUE
from openquad.session import PrintSession, SessionError
from tests.test_session import colour_file, photo_file

CYAN, MAGENTA, YELLOW = (PIGMENTS[name] for name in DEFAULT_COATS)


def test_default_is_cyanotype_under_two_gum_coats() -> None:
    sep = ColourSeparation.default()
    assert sep.coats == (CYAN, MAGENTA, YELLOW) and sep.saturation == 1.0 and sep.count == 3
    assert sep.describe() == "3 coats (#224A8C, #B0306A, #F2C230), saturation 1"


def test_bad_separations_are_refused() -> None:
    with pytest.raises(ValueError, match="2-4 coats"):
        ColourSeparation((CYAN,))
    with pytest.raises(ValueError, match="2-4 coats"):
        ColourSeparation((CYAN,) * 5)
    with pytest.raises(ValueError, match="three values 0-255"):
        ColourSeparation((CYAN, (300, 0, 0)))
    with pytest.raises(ValueError, match="too pale"):
        ColourSeparation((CYAN, (255, 254, 255)))
    with pytest.raises(ValueError, match="saturation must be 0-2"):
        ColourSeparation((CYAN, MAGENTA), saturation=2.5)


def test_hex_colours() -> None:
    assert hex_colour((176, 48, 106)) == "#B0306A"
    assert parse_hex("#b0306a") == parse_hex(" B0306A ") == (176, 48, 106)
    for bad in ("#B0306", "B0306AZ", "#GG306A"):
        with pytest.raises(ValueError, match="not a colour"):
            parse_hex(bad)


def test_inverse_of_a_small_matrix() -> None:
    m = [[4.0, 1.0, 0.5], [1.0, 3.0, 0.2], [0.5, 0.2, 2.0]]
    assert np.allclose(np.array(_inverse(m)) @ np.array(m), np.eye(3))


def test_paper_white_prints_nothing_and_black_every_coat() -> None:
    sep = ColourSeparation.default()
    assert np.allclose(solve(sep, np.array([1.0, 1.0, 1.0])), 0.0)
    assert np.allclose(solve(sep, np.array([0.0, 0.0, 0.0])), 1.0)


def test_each_pigment_is_made_by_its_own_coat() -> None:
    sep = ColourSeparation.default()
    for k, coat in enumerate(sep.coats):
        strengths = solve(sep, np.array(coat) / 255.0)
        assert strengths[k] > 0.95
        assert np.delete(strengths, k).max() < 0.05


def test_strengths_stay_within_0_and_1() -> None:
    sep = ColourSeparation((CYAN, MAGENTA, YELLOW, PIGMENTS["Lamp black"]), 2.0)
    colours = np.random.default_rng(3).random((500, 3))
    strengths = solve(sep, colours)
    assert strengths.shape == (500, 4)
    assert strengths.min() >= 0.0 and strengths.max() <= 1.0


def test_saturation_separates_the_coats_more() -> None:
    brick = np.array([0.6, 0.4, 0.3])
    spread = [
        np.ptp(solve(ColourSeparation((CYAN, MAGENTA, YELLOW), s), brick)) for s in (0, 1, 1.8)
    ]
    assert spread[0] < spread[1] < spread[2]


def test_the_lut_is_the_split_at_its_grid() -> None:
    sep = ColourSeparation((CYAN, YELLOW), 1.4)
    lut = strength_lut(sep, 5)
    assert lut.shape == (5, 5, 5, 2)
    assert np.array_equal(lut[1, 3, 4], solve(sep, np.array([0.25, 0.75, 1.0])))
    with pytest.raises(ValueError, match="at least 2"):
        strength_lut(sep, 1)


def test_coat_images_match_the_split_and_read_grey_as_neutral() -> None:
    sep = ColourSeparation.default()
    rgb = np.zeros((2, 3, 3), dtype=np.uint16)
    rgb[0, 0] = [MAX_VALUE] * 3  # white
    rgb[1, 2] = [round(c / 255 * MAX_VALUE) for c in MAGENTA]
    for k in range(3):
        image = coat_image(rgb, sep, k, chunk_rows=1)
        assert image.shape == (2, 3) and image.dtype == np.uint16
        assert image[0, 0] == MAX_VALUE  # nothing on paper white
        assert image[0, 1] == 0  # black: every coat at full strength
    assert coat_image(rgb, sep, 1)[1, 2] < 3000 < coat_image(rgb, sep, 0)[1, 2]
    grey = np.full((2, 2), 30000, dtype=np.uint16)
    neutral = np.repeat(grey[..., np.newaxis], 3, axis=-1)
    assert np.array_equal(coat_image(grey, sep, 2), coat_image(neutral, sep, 2))
    with pytest.raises(TypeError, match="uint16"):
        coat_image(grey.astype(np.float64), sep, 0)
    with pytest.raises(ValueError, match="coat 4 of 3"):
        coat_image(grey, sep, 3)


def test_proof_of_a_pigment_is_that_pigment() -> None:
    sep = ColourSeparation.default()
    rgb = np.array([[[round(c / 255 * MAX_VALUE) for c in coat] for coat in sep.coats]],
                   dtype=np.uint16)  # fmt: skip
    shown = proof(rgb, sep).astype(np.float64) / MAX_VALUE * 255
    assert np.abs(shown - np.array([sep.coats])).max() < 12
    grey = proof(np.full((1, 1), MAX_VALUE, dtype=np.uint16), sep)
    assert grey.shape == (1, 1, 3) and (grey == MAX_VALUE).all()


# --- the session --------------------------------------------------------------------------


def colour_negative(tmp_path: Path) -> PrintSession:
    session = PrintSession(printer="Canon_MG3600_series", fit=False)
    session.open(colour_file(tmp_path))
    session.set_mode("negative")
    session.set_colour_separation(ColourSeparation.default())
    return session


def test_one_separation_at_a_time(tmp_path: Path) -> None:
    from openquad.separations import SeparationPlan

    session = colour_negative(tmp_path)
    assert session.negative_count == 3 and session.separated
    session.set_layer(2)
    session.set_separation(SeparationPlan.even(2))
    assert session.colour_separation is None and session.negative_count == 2 and session.layer == 1
    session.set_colour_separation(ColourSeparation((CYAN, YELLOW)))
    assert session.separation is None and session.negative_count == 2
    session.set_colour_separation(None)
    assert session.negative_count == 1 and not session.separated and session.layer == 0


def test_colour_negatives_are_made_from_the_photos_colour(tmp_path: Path) -> None:
    session = colour_negative(tmp_path)
    assert session.photo is not None and session.photo.colour is not None
    session.set_layer(1)
    negative = session.render_print()
    by_hand = session.render_layer(session.photo.colour, 1)
    assert np.array_equal(negative, by_hand)
    assert not np.array_equal(negative, session.render_layer(session.photo.colour, 0))
    preview = session.preview(max_side=20)
    assert preview.dtype == np.uint8 and max(preview.shape[:2]) <= 40


def test_colour_separation_summary_and_job_title(tmp_path: Path) -> None:
    session = colour_negative(tmp_path)
    session.set_layer(2)
    summary = session.summary()
    assert "Colour separation: 3 coats (#224A8C, #B0306A, #F2C230), saturation 1" in summary
    assert "This negative: coat 3 of 3 (#F2C230)" in summary
    assert "Process curve: none (uncalibrated)" in summary
    assert session.print_job(tmp_path / "x.tif").title == "OpenQuad: colour.tif (negative 3 of 3)"


def test_colour_separations_are_written_one_file_per_coat(tmp_path: Path) -> None:
    session = colour_negative(tmp_path)
    paths = session.write_separations(tmp_path, "sep")
    assert [p.name for p in paths] == ["sep-1of3.tif", "sep-2of3.tif", "sep-3of3.tif"]
    assert tifffile.imread(paths[0]).ndim == 3


def test_a_greyscale_photo_splits_as_neutral(tmp_path: Path) -> None:
    session = PrintSession(fit=False)
    session.open(photo_file(tmp_path, (20, 30)))
    session.set_mode("negative")
    session.set_colour_separation(ColourSeparation.default())
    assert session.render_print().ndim == 3


def test_colour_pixels_need_a_colour_separation(tmp_path: Path) -> None:
    session = colour_negative(tmp_path)
    session.set_colour_separation(None)
    assert session.photo is not None and session.photo.colour is not None
    with pytest.raises(SessionError, match="only for a colour separation"):
        session.render_layer(session.photo.colour, 0)
