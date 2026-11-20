from pathlib import Path

import numpy as np
import pytest
import tifffile

from openquad.quadfile import MAX_VALUE
from openquad.session import PrintSession, SessionError
from tests.test_session import photo_file


def negative(tmp_path: Path) -> PrintSession:
    """A 3 x 4 in photo at 100 ppi: 3.5 x 4.5 in with its 0.25 in safe edge, on Letter."""
    session = PrintSession(printer="Canon_MG3600_series", fit=False, ppi=100.0)
    session.open(photo_file(tmp_path))
    session.set_mode("negative")
    return session


def test_a_negative_is_centred_until_it_is_moved(tmp_path: Path) -> None:
    session = negative(tmp_path)
    assert session.size_inches() == (3.5, 4.5)
    assert session.page_position() == (2.5, 3.25)
    assert not session.placed
    assert session.render_print().shape == (450, 350, 3)  # just the negative, as before
    assert not any(line.startswith("Position") for line in session.summary())


def test_a_moved_negative_prints_on_the_page_inside_its_margins(tmp_path: Path) -> None:
    session = negative(tmp_path)
    alone = session.render_print()
    session.set_placement((1.0, 1.25))
    assert session.placed and session.page_position() == (1.0, 1.25)
    page = session.render_print()
    assert page.shape == (1000, 750, 3)  # the 7.5 x 10 in inside Letter's 0.5 in margins
    top, left = 75, 50  # (1.25 - 0.5) and (1.0 - 0.5) in at 100 ppi
    assert np.array_equal(page[top : top + 450, left : left + 350], alone)
    page[top : top + 450, left : left + 350] = MAX_VALUE
    assert (page == MAX_VALUE).all()  # clear film everywhere else
    assert "Position: 1 in from the left, 1.25 in from the top" in session.summary()


def test_the_position_is_kept_inside_the_margins(tmp_path: Path) -> None:
    session = negative(tmp_path)
    session.set_placement((-5.0, 100.0))
    assert session.page_position() == (0.5, 6.0)
    page = session.render_print()
    assert np.array_equal(page[550:, :350], negative(tmp_path).render_print())
    session.set_units("mm")
    assert "Position: 12.7 mm from the left, 152.4 mm from the top" in session.summary()


def test_a_negative_too_big_to_move_stays_centred(tmp_path: Path) -> None:
    session = negative(tmp_path)
    session.ppi = 40.0  # 7.5 x 10 in plus the safe edge: wider than the room inside the margins
    session.set_placement((1.0, 1.0))
    assert not session.placed
    assert session.page_position() == pytest.approx(((8.5 - 8.0) / 2, (11 - 10.5) / 2))
    assert session.render_print().shape == (420, 320, 3)
    assert "Position: centred (no room to move it inside the margins)" in session.summary()


def test_a_negative_that_fills_the_page_can_still_move_along(tmp_path: Path) -> None:
    session = negative(tmp_path)
    session.fit = True  # as wide as the margins allow: it can only move up and down
    session.set_paper("Legal")
    session.set_placement((3.0, 0.5))
    assert session.placed
    left, top = session.page_position()
    assert left == pytest.approx(0.5) and top == 0.5
    page = session.render_print()
    ppi = session.effective_ppi()
    assert page.shape[0] == round(13 * ppi)
    assert page.shape[1] - round(7.5 * ppi) in (0, 1)  # never cut: the negative may round up
    assert (page[-10:] == MAX_VALUE).all()  # clear film below it


def test_a_print_is_moved_too(tmp_path: Path) -> None:
    session = negative(tmp_path)
    session.set_mode("print")
    centred = session.render_print()
    session.set_placement((1.0, 1.0))
    assert session.placed
    page = session.render_print()  # the page inside its margins, the print where it was put
    assert page.shape[0] > centred.shape[0] and page.shape[1] > centred.shape[1]
    assert any(line.startswith("Position: 1") for line in session.summary())


def test_placement_is_checked_and_cleared(tmp_path: Path) -> None:
    session = negative(tmp_path)
    with pytest.raises(SessionError, match="not a position"):
        session.set_placement((float("nan"), 1.0))
    session.set_placement((1.0, 1.0))
    session.set_placement(None)
    assert not session.placed and session.page_position() == (2.5, 3.25)


def test_the_print_file_is_the_whole_page(tmp_path: Path) -> None:
    session = negative(tmp_path)
    session.set_placement((4.0, 6.0))
    path = session.write_print_file(tmp_path / "page.tif")
    assert tifffile.imread(path).shape == (1000, 750, 3)
    assert session.print_job(path).ppi == 100.0
