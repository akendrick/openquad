from pathlib import Path

import numpy as np
import pytest
import tifffile

from openquad.cli import main
from openquad.contactsheet import (
    MAX_PHOTOS,
    Cell,
    SheetLayout,
    cells,
    grid,
    make_sheet,
    resize,
    thumbnail,
)
from openquad.imageio import read_dpi


def photo(width: int, height: int, value: int = 30000) -> np.ndarray:
    return np.full((height, width), value, dtype=np.uint16)


def test_resize_is_an_exact_box_average() -> None:
    a = (np.arange(12, dtype=np.uint16) * 1000).reshape(3, 4)
    assert resize(a, (0, 0, 4, 3), (2, 1)).tolist() == [[4500, 6500]]
    assert resize(a, (1, 1, 2, 2), (1, 1)).tolist() == [[7500]]  # a region
    assert resize(a, (0, 0, 4, 3), (8, 6))[0].tolist() == [0, 0, 1000, 1000, 2000, 2000, 3000, 3000]
    assert np.array_equal(resize(a, (0, 0, 4, 3), (4, 3)), a)


def test_grid_suits_the_photos_shape() -> None:
    assert grid(4, 1.5, (1000, 1000), 0, 0) == (2, 2)
    assert grid(3, 3.0, (300, 1000), 0, 0) == (1, 3)  # wide photos stack on a tall sheet
    assert grid(16, 1.0, (1000, 1000), 10, 0) == (4, 4)


def test_cells_fill_the_sheet_inside_the_gap() -> None:
    layout = SheetLayout(width=4.0, height=4.0, gap=0.1)
    boxes, wedge = cells([(30, 20)] * 4, layout, dpi=100)
    assert wedge is None and len(boxes) == 4
    assert boxes[0] == Cell(10, 10, 185, 185) and boxes[3] == Cell(205, 205, 185, 185)
    boxes, wedge = cells(
        [(30, 20)] * 4, SheetLayout(width=4.0, height=4.0, gap=0.1, wedge=True), 100
    )
    assert wedge is not None and wedge[1] + wedge[3] == 390  # along the bottom, inside the gap
    assert max(b.top + b.height for b in boxes) <= wedge[1] - 10
    with pytest.raises(ValueError, match="1-16 photos"):
        cells([(10, 10)] * (MAX_PHOTOS + 1), layout, 100)
    with pytest.raises(ValueError, match="no room"):
        cells([(10, 10)], SheetLayout(width=0.2, height=0.2, gap=0.1), 100)


def test_thumbnails_fit_whole_or_crop_to_fill() -> None:
    wide = photo(300, 100)
    cell = Cell(0, 0, 100, 100)
    whole, left, top = thumbnail(wide, cell, crop=False)
    assert whole.shape == (33, 100) and (left, top) == (0, 33)
    filled, left, top = thumbnail(wide, cell, crop=True)
    assert filled.shape == (100, 100) and (left, top) == (0, 0)


def test_sheet_background_wedge_and_photos() -> None:
    layout = SheetLayout(width=3.0, height=4.0, gap=0.1, wedge=True)
    sheet = make_sheet([photo(30, 20, 40000), photo(20, 30, 20000)], layout=layout, dpi=50)
    assert sheet.shape == (200, 150) and sheet[0, 0] == 0  # black background
    assert {40000, 20000} <= set(np.unique(sheet).tolist())
    _, wedge = cells([(30, 20), (20, 30)], layout, 50)
    assert wedge is not None
    left, top, step, _ = wedge
    assert sheet[top, left] == 0 and sheet[top, left + 20 * step] == 65535  # black to white
    white = make_sheet(
        [photo(30, 20)], layout=SheetLayout(width=3.0, height=4.0, background="white"), dpi=50
    )
    assert white[0, 0] == 65535


def test_labels_are_drawn_in_the_opposite_tone() -> None:
    layout = SheetLayout(width=3.0, height=3.0, labels=True)
    plain = make_sheet([photo(30, 20)], ["a.tif"], SheetLayout(width=3.0, height=3.0), dpi=100)
    named = make_sheet([photo(30, 20)], ["frame-01.tif"], layout, dpi=100)
    assert np.any(named == 65535) and not np.any(plain == 65535)
    long_name = make_sheet(
        [photo(30, 20)] * 16, ["x" * 200] * 16, layout, dpi=100
    )  # trimmed to fit
    assert long_name.shape == (300, 300)


@pytest.mark.parametrize(
    ("kwargs", "message"),
    [({"background": "grey"}, "background"), ({"width": 0.0}, "positive"), ({"gap": 2.0}, "gap")],
)
def test_layout_is_checked(kwargs: dict[str, object], message: str) -> None:
    with pytest.raises(ValueError, match=message):
        SheetLayout(**kwargs)  # type: ignore[arg-type]


def test_needs_greyscale() -> None:
    with pytest.raises(ValueError, match="greyscale"):
        make_sheet([np.zeros((4, 4, 3), dtype=np.uint16)])


def test_contact_sheet_command(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    paths = []
    for i in range(3):
        path = tmp_path / f"p{i}.tif"
        tifffile.imwrite(path, photo(60, 40, 10000 * (i + 1)))
        paths.append(str(path))
    out = tmp_path / "sheet.tif"
    args = ["contact-sheet", *paths, "-o", str(out), "--size", "4x5", "--dpi", "100"]
    assert main([*args, "--background", "white", "--wedge", "--crop"]) == 0
    sheet = tifffile.imread(out)
    assert sheet.shape == (500, 400) and sheet[0, 0] == 65535
    assert read_dpi(out) == pytest.approx((100.0, 100.0))
    assert "3 photos" in capsys.readouterr().out
    with pytest.raises(SystemExit):
        main([*args[:-4], "-o", str(out), "--size", "big"])
    assert main(["contact-sheet", *([paths[0]] * 17), "-o", str(out)]) == 1
