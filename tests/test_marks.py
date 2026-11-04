"""Darkroom marks (a black guide line and registration marks) and test sheets fitted to a
preferred size."""

from pathlib import Path

import numpy as np
import pytest
import tifffile

from openquad.blocking import BlockingLayout, analyse, blocking_scale, blocking_sheet
from openquad.chart import (
    PAGE_EDGE,
    PAGE_GAP,
    ChartLayout,
    chart_page,
    chart_scale,
    page_scale,
    read_chart_page,
)
from openquad.cli import main
from openquad.marks import PRINT_BORDER, add_print_marks, line_width, mark_mask
from openquad.negative import NegativeSettings, fit_scale, make_negative
from openquad.photo import Photo
from openquad.session import PrintSession
from tests.simulation import contact_print
from tests.test_blocking import scanned

DPI = 100


def test_line_width_follows_the_band_up_to_a_limit() -> None:
    assert line_width(25, 100) == 3  # an eighth of a 0.25 in band
    assert line_width(100, 100) == 4  # capped at 0.04 in
    assert line_width(4, 100) == 1


def test_guide_line_rings_the_image() -> None:
    mask = mark_mask(60, 50, 10, 100, guide=True, registration=False)
    line = line_width(10, 100)
    assert not mask[10:40, 10:50].any()  # never on the image
    assert mask[10 - line : 10, 10:50].all() and mask[40 : 40 + line, 10:50].all()
    assert mask[10:40, 10 - line : 10].all() and mask[10:40, 50 : 50 + line].all()
    assert mask.sum() == (40 + 2 * line) * (30 + 2 * line) - 40 * 30
    assert not mark_mask(60, 50, 1, 100, guide=True, registration=True).any()  # no room


def test_registration_targets_and_crop_marks() -> None:
    band = 40
    mask = mark_mask(200, 160, band, 300, guide=False, registration=True)
    line = line_width(band, 300)
    assert not mask[band:-band, band:-band].any()
    for x, y in [(100, band // 2), (100, 159 - band // 2), (band // 2, 80), (199 - band // 2, 80)]:
        assert mask[y, x]  # a target's cross at each side's middle
    assert mask[: band // 2, band - line].all()  # top-left crop mark, up from the corner
    assert mask[band - line, : band // 2].all()
    assert not mask[band // 2 + 1 : band - line, band - line].any()  # stops short of the image
    for corner in (mask, mask[::-1], mask[:, ::-1], mask[::-1, ::-1]):  # every corner
        assert corner[: band // 2, band - line].all() and corner[band - line, : band // 2].all()


def test_negative_marks_are_black_in_the_safe_edge() -> None:
    photo = np.full((40, 60), 30000, dtype=np.uint16)
    plain = make_negative(photo, NegativeSettings("orange"), DPI)
    marked = make_negative(photo, NegativeSettings("orange", guide=True, registration=True), DPI)
    edge = 25
    assert np.array_equal(plain[edge:-edge, edge:-edge], marked[edge:-edge, edge:-edge])
    changed = (plain != marked).any(axis=-1)
    assert changed.any() and (marked[changed] == 0).all()  # black ink only
    assert (marked[2:7, 2:7] == plain[2:7, 2:7]).all()  # the F is still cut out
    mirrored = make_negative(photo, NegativeSettings("orange", True, guide=True), DPI)
    assert np.array_equal(mirrored[:, ::-1], make_negative(photo, NegativeSettings(
        "orange", guide=True), DPI))  # fmt: skip


def test_marks_never_reach_the_contact_print() -> None:
    photo = np.tile(np.linspace(0, 65535, 60).astype(np.uint16), (40, 1))
    plain = contact_print(make_negative(photo, NegativeSettings("orange"), DPI))
    marked = contact_print(
        make_negative(photo, NegativeSettings("orange", guide=True, registration=True), DPI)
    )
    # Black blocks UV at least as well as the orange safe edge: nothing prints darker.
    assert (marked >= plain - 0.005).all() and np.abs(plain - marked).max() < 0.05


def test_print_marks_add_a_white_border() -> None:
    image = np.full((30, 40, 3), 20000, dtype=np.uint16)
    assert add_print_marks(image, DPI, False, False) is image
    marked = add_print_marks(image, DPI, True, True)
    band = round(PRINT_BORDER * DPI)
    assert marked.shape == (30 + 2 * band, 40 + 2 * band, 3)
    assert np.array_equal(marked[band:-band, band:-band], image)
    border = marked.copy()
    border[band:-band, band:-band] = 1
    assert set(np.unique(border)) == {0, 1, 65535}  # white paper, black marks


def session(mode: str, **marks: bool) -> PrintSession:
    pixels = np.full((200, 300), 40000, dtype=np.uint16)
    s = PrintSession(photo=Photo(pixels=pixels, dpi=(100.0, 100.0)), mode=mode, fit=False)
    s.guide, s.registration = marks.get("guide", False), marks.get("registration", False)
    return s


def test_session_print_marks_grow_the_print() -> None:
    plain, marked = session("print"), session("print", guide=True)
    assert plain.size_inches() == (3.0, 2.0)
    assert marked.size_inches() == (3.5, 2.5)
    assert marked.render(marked.photo.pixels).shape == (250, 350, 3)  # type: ignore[union-attr]
    assert "Darkroom marks: guide line" in marked.summary()
    assert not any(line.startswith("Darkroom") for line in plain.summary())
    marked.fit = True
    assert marked.size_inches()[0] <= 8.5 - 1.0 + 1e-6  # still within Letter's margins
    both = session("negative", guide=True, registration=True)
    assert both.size_inches() == (3.5, 2.5)  # in the safe edge: no larger
    assert "Darkroom marks: guide line and registration marks" in both.summary()
    assert both.preview().shape[:2] == (250, 350)
    assert session("print", registration=True).preview().shape[:2] == (250, 350)


def test_fit_scale() -> None:
    assert fit_scale((4.0, 2.0), (0.5, 0.5), (10.0, 4.5)) == pytest.approx(2.0)
    assert fit_scale((4.0, 2.0), (0.5, 0.5), (4.5, 10.0)) == pytest.approx(2.0)  # turned
    assert fit_scale((2.0, 4.0), (0.0, 0.0), (1.0, 1.0)) == pytest.approx(0.25)
    with pytest.raises(ValueError, match="positive"):
        fit_scale((1.0, 1.0), (0.0, 0.0), (0.0, 5.0))
    with pytest.raises(ValueError, match="no room"):
        fit_scale((1.0, 1.0), (2.0, 2.0), (1.0, 1.0))


@pytest.mark.parametrize("box", [(8.0, 10.0), (4.0, 6.0)])
def test_sheets_fit_their_preferred_size(box: tuple[float, float]) -> None:
    long, short = max(box), min(box)
    scale = blocking_scale(box)
    sheet = blocking_sheet(dpi=50, scale=scale)
    w, h = sheet.shape[1] / 50, sheet.shape[0] / 50
    assert max(w, h) <= long + 0.03 and min(w, h) <= short + 0.03
    assert max(w, h) >= long - 0.03 or min(w, h) >= short - 0.03  # as large as fits
    assert sheet[6, 30:-30].max() == 0 and (sheet[12, 12] == 65535).all()  # 0.25 in edge
    layout = BlockingLayout()
    assert w == pytest.approx(layout.width * scale + 0.5, abs=0.03)
    for count in (1, 2):
        page = chart_page(["green", "orange"][:count], dpi=50, scale=page_scale(count, box))
        w, h = page.shape[1] / 50, page.shape[0] / 50
        assert max(w, h) <= long + 0.05 and min(w, h) <= short + 0.05
    compact = ChartLayout.compact()
    expected = 2 * (compact.height + 2 * PAGE_EDGE) + PAGE_GAP
    assert chart_page(["green", "orange"], dpi=50).shape[0] / 50 == pytest.approx(
        expected, abs=0.05
    )
    full = ChartLayout()
    assert chart_scale((full.width + 0.5, full.height + 0.5)) == pytest.approx(1.0)


def test_scaled_marked_sheets_read_like_plain_ones() -> None:
    plain = analyse(scanned(contact_print(blocking_sheet(dpi=DPI))))
    sheet = blocking_sheet(dpi=DPI, scale=0.8, guide=True, registration=True)
    marked = analyse(scanned(contact_print(sheet)))
    for a, b in zip(plain.results, marked.results, strict=True):
        assert a.name == b.name and abs(a.full - b.full) < 2.0
        assert np.abs(np.subtract(a.wedge, b.wedge)).max() < 3.0
    page = chart_page(["green", "orange"], dpi=DPI, scale=1.2, guide=True, registration=True)
    readings = read_chart_page(scanned(contact_print(page)), 2)
    reference = read_chart_page(scanned(contact_print(chart_page(["green", "orange"], dpi=DPI))), 2)
    for read, expected in zip(readings, reference, strict=True):
        assert np.abs(read.lightness - expected.lightness).mean() < 1.5


def test_commands(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    out = tmp_path / "sheet.tif"
    main(
        ["target", "--kind", "blocking", "--size", "4x6", "--guide", "--dpi", "50", "-o", str(out)]
    )
    assert "5.62 x 3.98 in" in capsys.readouterr().out
    main(["target", "--kind", "chart", "--colour", "green,orange", "--size", "8x10",
          "--registration", "--dpi", "50", "-o", str(out)])  # fmt: skip
    assert "9.9" in capsys.readouterr().out
    main(["target", "--kind", "chart", "--size", "4x4", "--dpi", "50", "-o", str(out)])
    assert "3.98 x 3.84 in" in capsys.readouterr().out
    photo = tmp_path / "photo.tif"
    tifffile.imwrite(photo, np.full((40, 60), 30000, dtype=np.uint16))
    main(["negative", str(photo), "-o", str(out), "--dpi", "100", "--colour", "orange",
          "--guide", "--registration"])  # fmt: skip
    negative = tifffile.imread(out)
    assert negative.shape == (90, 110, 3) and (negative == 0).all(axis=-1).any()
