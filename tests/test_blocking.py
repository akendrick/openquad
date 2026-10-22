"""Blocking-colour test: the sheet, and reading a (simulated) carbon print of it."""

import io
import itertools
from pathlib import Path

import numpy as np
import pytest
import tifffile
from PIL import Image

from openquad import blocking, negative
from openquad.blocking import STEPS, BlockingError, BlockingLayout, analyse, blocking_sheet
from openquad.cli import main
from openquad.colour import linear_to_srgb
from openquad.measure import load_scan
from tests.simulation import contact_print

DPI = 100


def scanned(print_rgb: np.ndarray, turn: str = "as scanned", seed: int = 0) -> np.ndarray:
    """Lay the print on white paper, turn it, add scanner noise and JPEG it."""
    rng = np.random.default_rng(seed)
    h, w = print_rgb.shape[:2]
    paper = float(linear_to_srgb(np.array(0.88)))  # the simulated print's paper white
    canvas = np.full((h + 80, w + 90, 3), paper)
    canvas[40 : 40 + h, 50 : 50 + w] = print_rgb
    turns = {
        "as scanned": canvas,
        "turned 180°": canvas[::-1, ::-1],
        "mirrored": canvas[:, ::-1],
        "mirrored and turned 180°": canvas[::-1],
    }
    canvas = turns[turn]
    noisy = np.clip(canvas + rng.normal(0, 1.5 / 255, canvas.shape), 0, 1)
    buffer = io.BytesIO()
    Image.fromarray(np.round(noisy * 255).astype(np.uint8)).save(buffer, "JPEG", quality=90)
    return np.asarray(Image.open(buffer), dtype=np.float64) / 255


def carbon_scan(sheet: np.ndarray, exposure: float = 1.0, turn: str = "as scanned") -> np.ndarray:
    return scanned(contact_print(sheet, exposure), turn)


# --- the sheet -----------------------------------------------------------------------


def test_sheet_size_safe_edge_and_marker() -> None:
    layout = BlockingLayout()
    sheet = blocking_sheet(dpi=DPI)
    edge = round(0.25 * DPI)
    assert sheet.shape == (
        round(layout.height * DPI) + 2 * edge,
        round(layout.width * DPI) + 2 * edge,
        3,
    )
    assert np.all(sheet[edge // 2, edge:-edge] == 0)  # opaque safe edge
    l, t, r, b = (round(v * DPI) + edge for v in layout.marker_box())  # noqa: E741
    assert np.all(sheet[t:b, l:r] == 0)  # opaque marker
    assert np.any(sheet[:edge, :edge] == 65535)  # orientation F cut into the edge


def test_each_row_runs_full_ink_to_clear_film() -> None:
    layout = BlockingLayout()
    sheet = blocking_sheet(dpi=DPI, safe_edge=0.0)
    for row, name in enumerate(layout.colours):
        values = []
        for step in range(STEPS):
            l, t, r, b = layout.step_box(row, step)  # noqa: E741
            values.append(
                sheet[round((t + b) / 2 * DPI), round((l + r) / 2 * DPI)].astype(int).sum()
            )
        assert values[-1] == 3 * 65535, name  # last step is clear film
        assert all(a <= b for a, b in itertools.pairwise(values)), name


def test_labels_are_inked() -> None:
    layout = BlockingLayout()
    sheet = blocking_sheet(dpi=DPI, safe_edge=0.0)
    t = round(layout.row_top(0) * DPI)
    label_area = sheet[t : t + round(layout.row_height * DPI), : round(layout.label_width * DPI)]
    assert np.any(label_area == 0) and np.any(label_area == 65535)


def test_mirrored_sheet() -> None:
    assert np.array_equal(blocking_sheet(dpi=DPI, mirror=True), blocking_sheet(dpi=DPI)[:, ::-1])


def test_unknown_colour_in_layout() -> None:
    with pytest.raises(BlockingError, match="unknown colour"):
        blocking_sheet(BlockingLayout(colours=("purple",)), dpi=DPI)


# --- reading the print ---------------------------------------------------------------


def test_reads_a_simulated_carbon_print() -> None:
    report = analyse(carbon_scan(blocking_sheet(dpi=DPI)))
    assert report.orientation == "as scanned"
    names = [r.name for r in report.results]
    assert names == list(BlockingLayout().colours)
    black = report.results[names.index("black")]
    assert black.blocks_fully
    assert black.tonal_range > 40
    assert black.usable_steps >= 8
    assert all(np.diff(black.wedge) > -1.0)  # more ink, lighter print
    assert report.best() is not None
    assert report.lines()[-1].startswith("Best:")


@pytest.mark.parametrize("turn", ["turned 180°", "mirrored", "mirrored and turned 180°"])
def test_any_orientation_is_read(turn: str) -> None:
    sheet = blocking_sheet(dpi=DPI)
    plain = analyse(carbon_scan(sheet))
    turned = analyse(carbon_scan(sheet, turn=turn))
    assert turned.orientation == turn
    for a, b in zip(plain.results, turned.results, strict=True):
        assert abs(a.full - b.full) < 1.5


def test_a_colour_that_lets_uv_through_is_flagged(monkeypatch: pytest.MonkeyPatch) -> None:
    colours = {**negative.NEGATIVE_COLOURS, "blue": (0.1, 0.3, 0.95)}
    monkeypatch.setattr(negative, "NEGATIVE_COLOURS", colours)
    monkeypatch.setattr(blocking, "NEGATIVE_COLOURS", colours)
    layout = BlockingLayout(colours=("black", "blue"))
    report = analyse(carbon_scan(blocking_sheet(layout, dpi=DPI)), layout)
    black, blue = report.results
    assert black.blocks_fully
    assert not blue.blocks_fully  # blue ink passes the near-UV that exposes carbon
    assert report.best() is black


def test_over_exposure_means_nothing_blocks() -> None:
    report = analyse(carbon_scan(blocking_sheet(dpi=DPI), exposure=40.0))
    assert report.best() is None
    assert "No colour blocked fully" in report.lines()[-1]


def test_blank_and_cropped_scans_are_refused() -> None:
    with pytest.raises(BlockingError, match="no exposed area"):
        analyse(np.ones((200, 300, 3)))
    scan = carbon_scan(blocking_sheet(dpi=DPI))
    with pytest.raises(BlockingError, match="shape doesn't match"):
        analyse(scan[:, : scan.shape[1] // 2])


def test_missing_marker_is_reported() -> None:
    sheet = blocking_sheet(dpi=DPI, safe_edge=0.0).copy()
    l, t, r, b = (round(v * DPI) for v in BlockingLayout().marker_box())  # noqa: E741
    sheet[t:b, l:r] = 65535  # marker printed as clear film
    with pytest.raises(BlockingError, match="marker"):
        analyse(carbon_scan(sheet))


def test_tiny_scan_is_refused() -> None:
    sheet = blocking_sheet(dpi=8, safe_edge=0.0)
    with pytest.raises(BlockingError, match="too small"):
        analyse(scanned(contact_print(sheet)))


# --- command line --------------------------------------------------------------------


def test_blocking_commands(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    sheet_path = tmp_path / "blocking.tif"
    assert main(["target", "--kind", "blocking", "-o", str(sheet_path), "--dpi", "100"]) == 0
    assert "openquad blocking SCAN" in capsys.readouterr().out
    sheet = tifffile.imread(sheet_path)
    scan_path = tmp_path / "carbon.jpg"
    Image.fromarray(np.round(carbon_scan(sheet) * 255).astype(np.uint8)).save(scan_path)
    assert main(["blocking", str(scan_path)]) == 0
    out = capsys.readouterr().out
    assert "Read the print as scanned." in out
    assert "Best:" in out
    blank = tmp_path / "blank.png"
    Image.fromarray(np.full((50, 50, 3), 255, dtype=np.uint8)).save(blank)
    assert main(["blocking", str(blank)]) == 1
    assert load_scan(scan_path).shape[-1] == 3
