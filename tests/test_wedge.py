"""Step wedges beside the print: the 31-step grey wedge, and the colour gamut wedge."""

from pathlib import Path

import numpy as np
import pytest
import tifffile

from openquad import wedge
from openquad.quadfile import MAX_VALUE
from openquad.session import PrintSession, SessionError


def test_the_grey_wedge_runs_white_to_black_in_31_steps() -> None:
    w = wedge.grey_wedge(62, 3, horizontal=True)
    assert w.shape == (3, 62) and w.dtype == np.uint16
    steps = w[0, ::2]
    assert steps[0] == MAX_VALUE and steps[-1] == 0 and len(set(steps.tolist())) == 31
    assert (np.diff(steps.astype(int)) < 0).all()
    assert wedge.grey_wedge(62, 3, horizontal=False).shape == (62, 3)
    uneven = wedge.grey_wedge(40, 1, horizontal=True)[0]  # patches of 1 or 2 pixels
    assert len(set(uneven.tolist())) == 31
    with pytest.raises(ValueError):
        wedge.grey_wedge(0, 3, horizontal=True)


def test_the_colour_wedge_has_a_tint_the_colour_and_a_shade() -> None:
    w = wedge.colour_wedge(31, 2, horizontal=True)
    assert w.shape == (6, 31, 3)
    assert w[2, 0].tolist() == [MAX_VALUE, 0, 0]  # full red first
    assert w[0, 0].tolist() == [MAX_VALUE, 32768, 32768]  # a tint
    assert w[4, 0].tolist() == [32768, 0, 0]  # a shade
    assert len({tuple(p) for p in w[2].tolist()}) == 31
    assert wedge.colour_wedge(31, 2, horizontal=False).shape == (31, 6, 3)
    assert wedge.hsv_to_rgb(0.5, 0.0, 0.25) == (0.25, 0.25, 0.25)
    with pytest.raises(ValueError):
        wedge.colour_wedge(31, 0, horizontal=True)


def test_wedges_are_attached_on_any_side_centred() -> None:
    image = np.zeros((4, 6, 3), np.uint16)
    grey = np.full((2, 4, 3), 7, np.uint16)
    below = wedge.attach(image, [grey], "bottom", 1)
    assert below.shape == (7, 6, 3)
    assert (below[5:, 1:5] == 7).all() and (below[4] == MAX_VALUE).all()
    assert (below[5:, 0] == MAX_VALUE).all()
    above = wedge.attach(image, [grey, grey], "top", 1)
    assert above.shape == (10, 6, 3) and (above[6:] == 0).all() and (above[:2, 1:5] == 7).all()
    side = np.full((4, 2, 3), 7, np.uint16)
    assert wedge.attach(image, [side], "right", 2).shape == (4, 10, 3)
    assert (wedge.attach(image, [side], "left", 2)[:, :2] == 7).all()
    assert wedge.attach(image, [], "left", 2) is image
    with pytest.raises(ValueError, match="unknown side"):
        wedge.attach(image, [side], "middle", 2)
    expected = 0.25 * 2 + (0.4 + 0.2) + (0.6 + 0.2)
    assert wedge.extra(["grey", "colour"], "left", 0.25, 0.1) == pytest.approx((expected, 0))
    assert wedge.extra([], "top", 0.25) == (0.0, 0.0)


def photo(tmp_path: Path) -> Path:
    path = tmp_path / "ramp.tif"
    ramp = np.tile(np.linspace(0, 65535, 300), (200, 1)).astype(np.uint16)
    tifffile.imwrite(path, ramp, resolution=(100, 100), resolutionunit="INCH")
    return path


def test_a_print_carries_its_wedge_toned_like_the_photo(tmp_path: Path) -> None:
    session = PrintSession()
    session.open(photo(tmp_path))
    plain = session.render_print()
    session.wedge = True
    assert session.size_inches() == pytest.approx((7.5, 5.0 + 0.4))  # joined: no gap
    joined = session.render_print()
    assert joined.shape == (200 + round(0.4 * session.effective_ppi()), 300, 3)
    assert "Step wedge: 31 steps, 0.4 in wide, below the print, joined to it" in session.summary()
    session.set_wedge_gap(0.25)  # the space between is white paper
    assert session.size_inches() == pytest.approx((7.5, 5.0 + 0.25 + 0.4))
    printed = session.render_print()
    ppi = session.effective_ppi()
    gap, across = round(0.25 * ppi), round(0.4 * ppi)
    assert printed.shape == (200 + gap + across, 300, 3)
    assert np.array_equal(printed[:200], plain)
    assert (printed[200 : 200 + gap] == MAX_VALUE).all()
    strip = printed[-1, :, 0]
    assert strip[0] == MAX_VALUE and strip[-1] == 0
    assert "Step wedge: 31 steps, 0.4 in wide, below the print, 0.25 in away" in session.summary()
    session.set_preset("black-red")
    toned = session.render_print()[-1]
    assert not np.array_equal(toned, printed[-1])  # the wedge is toned too
    preview = session.preview()
    assert preview.shape[0] > 200


def test_the_wedge_side_and_gap_are_checked(tmp_path: Path) -> None:
    session = PrintSession()
    session.open(photo(tmp_path))
    session.wedge = True
    session.wedge_separate = True
    session.set_wedge_side("right")
    session.set_wedge_gap(0.5)
    width, height = session.size_inches()
    assert width == pytest.approx(7.5) and height < 5
    assert "Step wedge: 31 steps, 0.4 in wide, right of the print, 0.5 in away" in session.summary()
    for bad in (-1.0, 3.0, float("nan")):
        with pytest.raises(SessionError, match="gap"):
            session.set_wedge_gap(bad)
    with pytest.raises(SessionError, match="unknown side"):
        session.set_wedge_side("middle")
    session.set_paper("4x6")
    session.set_wedge_gap(2.0)
    session.wedge_side = "bottom"
    session.margin = 1.9  # 6 in tall: no room for 2.4 in of gap and wedge
    with pytest.raises(SessionError, match="no room"):
        session.effective_ppi()


def test_a_negative_carries_its_wedge_through_the_process(tmp_path: Path) -> None:
    session = PrintSession(mode="negative", fit=False, ppi=40.0)
    session.open(photo(tmp_path))
    session.outline, session.guide = 0.1, True
    bare = session.render_print()
    session.wedge = True
    session.wedge_separate = True
    session.set_wedge_gap(0.25)
    session.set_wedge_side("left")
    ppi = session.effective_ppi()
    negative = session.render_print()
    edge, gap, across = round(0.25 * ppi), round(0.25 * ppi), round(0.4 * ppi)
    assert negative.shape[1] == bare.shape[1] + gap + across + 2 * edge
    assert np.array_equal(negative[:, -bare.shape[1] :], bare)
    assert session.size_inches()[0] == pytest.approx(300 / 40 + 0.7 + 0.25 + 0.9)
    session.mirror = True  # laid out on the right, so it prints on the left once mirrored
    assert session._wedge_side() == "right"
    mirrored = session.render_print()
    assert np.array_equal(
        mirrored[:, : bare.shape[1]],
        session._negative_layer(session._source(), 0, ppi, session._negative_settings()),
    )
    assert (
        "Step wedge: 31 steps, 0.4 in wide, left of the negative, 0.25 in away, made separately"
        in session.summary()
    )


def test_the_colour_wedge_is_only_for_colour_prints(tmp_path: Path) -> None:
    from PIL import Image

    path = tmp_path / "colour.png"
    rng = np.random.default_rng(3)
    Image.fromarray(rng.integers(0, 256, (40, 60, 3)).astype(np.uint8)).save(path, dpi=(20, 20))
    session = PrintSession()
    session.open(path)
    session.colour_wedge = True
    session.set_wedge_gap(0.25)
    assert session.wedge_kinds == []  # printed in grey
    session.set_colour_print(True)
    session.wedge = True
    assert session.wedge_kinds == ["grey", "colour"]
    printed = session.render_print()
    ppi = session.effective_ppi()
    assert printed.shape[0] == 40 + 2 * round(0.25 * ppi) + round(0.4 * ppi) + 3 * round(0.2 * ppi)
    assert printed[-1, 0].tolist()[1:] == [0, 0]  # the shade row starts with dark red
    summary = session.summary()
    assert "Colour wedge: 31 hues, below the print, 0.25 in away" in summary
    assert session.preview().shape[0] > 40


def test_a_joined_wedge_sits_inside_the_negatives_safe_edge(tmp_path: Path) -> None:
    session = PrintSession(mode="negative", fit=False, ppi=40.0)
    session.open(photo(tmp_path))
    session.outline = 0.1
    bare = session.render_print()
    session.wedge = True  # joined (the default): no clear film between
    negative = session.render_print()
    edge, band, across = round(0.25 * 40), round(0.1 * 40), round(0.4 * 40)
    assert negative.shape == (bare.shape[0] + across + edge, bare.shape[1], 3)
    assert np.array_equal(negative[: bare.shape[0]], bare)
    safe = negative[0, 0]
    wedge = negative[bare.shape[0] :]
    assert (wedge[-edge:] == safe).all() and (wedge[:, :edge] == safe).all()
    assert not (wedge[0, edge : edge + 2 * band + 300] == safe).all()  # the wedge itself
    assert session.size_inches()[1] == pytest.approx(200 / 40 + 0.7 + 0.4 + 0.25)
    assert any("joined to it" in line for line in session.summary())


def test_a_print_can_be_mirrored(tmp_path: Path) -> None:
    session = PrintSession()
    session.open(photo(tmp_path))
    session.wedge = True
    plain = session.render_print()
    session.mirror = True
    mirrored = session.render_print()
    assert np.array_equal(mirrored[:200], plain[:200, ::-1])  # the photo flips
    assert np.array_equal(mirrored[200:], plain[200:])  # its wedge doesn't
    assert session.preview()[0, 0, 0] > session.preview()[0, -1, 0]  # white now on the left
    assert "Mirrored: yes" in session.summary()


def test_a_joined_gap_is_opaque_like_the_safe_edge(tmp_path: Path) -> None:
    session = PrintSession(mode="negative", fit=False, ppi=40.0)
    session.open(photo(tmp_path))
    bare = session.render_print()
    session.wedge = True
    session.set_wedge_gap(0.5)
    negative = session.render_print()
    edge, gap, across = 10, 20, 16
    assert negative.shape[0] == bare.shape[0] + gap + across + edge
    between = negative[bare.shape[0] : bare.shape[0] + gap]
    assert (between == bare[0, 0]).all()  # the safe edge's colour, not clear film
    assert session.size_inches()[1] == pytest.approx(5 + 0.5 + 0.5 + 0.4 + 0.25)


def test_wedge_options_steps_width_style_and_numbers() -> None:
    strip = wedge.grey_wedge(110, 8, horizontal=True, steps=11)
    assert len(np.unique(strip[0])) == 11
    framed = wedge.grey_wedge(110, 20, horizontal=True, steps=11, calibration=True, frame=2)
    assert (framed[:2] == 0).all() and (framed[:, :2] == 0).all()  # the black frame
    assert framed[4, 5] == MAX_VALUE and framed[-5, 5] == 0  # white first, then reversed
    numbered = wedge.grey_wedge(110, 8, horizontal=True, steps=11, band=24)
    assert numbered.shape == (32, 110) and (numbered[8:] == 0).any()
    first = wedge.grey_wedge(110, 8, horizontal=True, steps=11, band=24, band_first=True)
    assert np.array_equal(first[24:], numbered[:8])
    tall = wedge.grey_wedge(110, 8, horizontal=False, steps=11, band=24)
    assert tall.shape == (110, 32) and (tall[:, 8:] == 0).any()
    assert wedge.thickness("grey", 0.1, 0.6, labels=True) == pytest.approx(0.6 + 0.15 + 0.2)
    with pytest.raises(ValueError, match="2 steps"):
        wedge.grey_wedge(10, 2, horizontal=True, steps=1)


def test_wedge_options_are_checked_and_summarised(tmp_path: Path) -> None:
    session = PrintSession()
    session.open(photo(tmp_path))
    session.wedge = True
    session.set_wedge_steps(21)
    session.set_wedge_width(0.6)
    session.set_wedge_style("calibration")
    session.wedge_labels = True
    assert session.size_inches()[1] == pytest.approx(5 + 0.6 + 0.15)
    assert session.render_print().shape[0] == 200 + round(0.75 * session.effective_ppi())
    line = "Step wedge: 21 steps, 0.6 in wide (calibration style, numbered), below the print"
    assert any(row.startswith(line) for row in session.summary())
    for call, bad in ((session.set_wedge_steps, 7), (session.set_wedge_width, 1.5),
                      (session.set_wedge_style, "zigzag")):  # fmt: skip
        with pytest.raises(SessionError):
            call(bad)  # type: ignore[operator]


def test_marks_can_lie_outside_the_printable_area(tmp_path: Path) -> None:
    session = PrintSession()
    session.open(photo(tmp_path))
    plain = session.effective_ppi()
    session.guide = True
    assert session.effective_ppi() > plain  # the photo shrinks to fit its border
    session.marks_in_fit = False
    assert session.effective_ppi() == plain  # the photo is unaffected; the border lies outside
    assert any(line.startswith("Fit: the photo alone") for line in session.summary())
    negative = PrintSession(mode="negative")
    negative.open(photo(tmp_path))
    negative.marks_in_fit = False
    assert negative.effective_ppi() == plain


def test_the_space_round_a_wedge_can_be_black_or_white(tmp_path: Path) -> None:
    session = PrintSession(mode="negative", fit=False, ppi=40.0)
    session.open(photo(tmp_path))
    bare = session.render_print()
    session.wedge = True
    session.set_wedge_gap(0.5)
    coloured = session.render_print()
    assert (coloured[bare.shape[0] : bare.shape[0] + 20] == bare[0, 0]).all()  # the ink colour
    session.set_wedge_background("white")
    clear = session.render_print()
    assert clear.shape == coloured.shape
    assert (clear[bare.shape[0] : bare.shape[0] + 20] == MAX_VALUE).all()  # clear film
    session.set_wedge_background("black")
    black = session.render_print()
    assert (black[bare.shape[0] : bare.shape[0] + 20] == 0).all()
    assert any(line.endswith("0.5 in away, on black") for line in session.summary())
    session.set_mode("print")
    printed = session.render_print()
    assert (printed[200 : 200 + round(0.5 * session.effective_ppi())] == 0).all()
    with pytest.raises(SessionError, match="unknown background"):
        session.set_wedge_background("grey")
