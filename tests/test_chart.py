"""ChartThrob-style process calibration against a simulated carbon process."""

from pathlib import Path

import numpy as np
import pytest
from PIL import Image

from openquad.blocking import BlockingError
from openquad.chart import (
    PATCHES,
    ChartLayout,
    ProcessCurve,
    build_process_curve,
    chart_negative,
    chart_photo,
    load_process,
    patch_level,
    read_chart,
    save_process,
    tone_errors,
)
from tests.simulation import contact_print
from tests.test_blocking import on_tissue, scanned

DPI = 100


def carbon(
    process: ProcessCurve | None = None, turn: str = "as scanned", **kwargs: float
) -> np.ndarray:
    """Print the chart negative (green), contact print it, scan it."""
    negative = chart_negative("green", process, dpi=DPI)
    return scanned(contact_print(negative, **kwargs), turn)


# --- the chart -----------------------------------------------------------------------


def test_chart_photo_has_101_tones_strip_gradient_and_marker() -> None:
    layout = ChartLayout()
    photo = chart_photo(layout, dpi=DPI)
    assert photo.shape == (round(layout.height * DPI), round(layout.width * DPI))
    for n in (0, 37, 100):
        l, t, r, b = layout.patch_box(n)  # noqa: E741
        assert photo[round((t + b) / 2 * DPI), round((l + r) / 2 * DPI)] == patch_level(n)
    l, t, r, b = layout.marker_box()  # noqa: E741
    assert photo[round((t + b) / 2 * DPI), round((l + r) / 2 * DPI)] == 65535
    assert photo[0, 0] == 0  # background prints black (clear film)
    l, t, r, b = layout.gradient_box()  # noqa: E741
    column = photo[round(t * DPI) : round(b * DPI), round((l + r) / 2 * DPI)].astype(int)
    assert column[0] > column[-1] and np.all(np.diff(column) <= 0)


def test_patch_levels() -> None:
    assert patch_level(0) == 65535 and patch_level(100) == 0 and patch_level(50) == 32768


def test_chart_negative_is_green_with_a_green_safe_edge() -> None:
    negative = chart_negative("green", dpi=DPI)
    edge = round(0.25 * DPI)
    assert np.abs(negative[edge // 2, edge * 2] / 65535 - np.array([0.10, 0.45, 0.20])).max() < 0.01
    assert np.array_equal(chart_negative("green", mirror=True, dpi=DPI), negative[:, ::-1])


# --- reading and calibrating ---------------------------------------------------------


def test_reads_all_101_patches_in_order() -> None:
    reading = read_chart(carbon())
    assert reading.lightness.shape == (PATCHES,)
    assert reading.lightness[0] > reading.lightness[50] > reading.lightness[100]
    assert reading.strip[0] > reading.strip[-1]
    assert reading.orientation == "as scanned"


@pytest.mark.parametrize("turn", ["turned 180°", "mirrored", "mirrored and turned 180°"])
def test_any_orientation(turn: str) -> None:
    plain, turned = read_chart(carbon()), read_chart(carbon(turn=turn))
    assert turned.orientation == turn
    assert np.abs(plain.lightness - turned.lightness).max() < 2.0


def test_sideways_and_on_a_tissue_field() -> None:
    printed = contact_print(chart_negative("green", dpi=DPI))
    sideways = np.ascontiguousarray(np.rot90(on_tissue(printed)))
    reading = read_chart(scanned(sideways))
    assert reading.orientation.startswith("sideways")
    assert np.abs(reading.lightness - read_chart(carbon()).lightness).max() < 2.0


def test_uncalibrated_carbon_is_far_off_target() -> None:
    assert np.abs(tone_errors(read_chart(carbon()))).max() > 8


def test_one_pass_puts_tones_on_target() -> None:
    first = read_chart(carbon())
    curve = build_process_curve(first, film="sim office film", printing="sim")
    second = read_chart(carbon(curve))
    assert np.abs(tone_errors(second)).max() < 3.0  # the Phase 7 exit gate
    assert np.abs(tone_errors(second)).mean() < np.abs(tone_errors(first)).mean() / 3


def test_second_pass_refines() -> None:
    curve = build_process_curve(read_chart(carbon()))
    refined = build_process_curve(read_chart(carbon(curve)), previous=curve)
    assert np.abs(tone_errors(read_chart(carbon(refined)))).mean() < 1.0


def test_curve_keeps_its_ends_and_is_monotonic() -> None:
    curve = build_process_curve(read_chart(carbon()))
    assert curve.curve[0] == 0 and curve.curve[-1] == 65535
    assert np.all(np.diff(curve.curve.astype(int)) >= 0)


def test_flat_print_is_refused() -> None:
    reading = read_chart(carbon())
    flat = type(reading)(reading.levels, np.full(PATCHES, 50.0), reading.strip, "", 90.0)
    with pytest.raises(ValueError, match="barely differ"):
        build_process_curve(flat)


def test_missing_marker_and_blank_scans() -> None:
    with pytest.raises(BlockingError):
        read_chart(np.ones((300, 300, 3)))
    negative = chart_negative("green", dpi=DPI, layout=ChartLayout()).copy()
    edge = round(0.25 * DPI)
    l, t, r, b = (round(v * DPI) + edge for v in ChartLayout().marker_box())  # noqa: E741
    negative[t:b, l:r] = 65535  # marker printed as clear film
    with pytest.raises(BlockingError, match="marker"):
        read_chart(scanned(contact_print(negative)))


# --- process curve files -------------------------------------------------------------


def test_process_file_round_trip(tmp_path: Path) -> None:
    curve = build_process_curve(read_chart(carbon()), film="office film", printing="Fine glossy")
    path = tmp_path / "carbon.oqproc"
    save_process(curve, path)
    loaded = load_process(path)
    assert np.array_equal(loaded.curve, curve.curve)
    assert (loaded.colour, loaded.process, loaded.film, loaded.printing) == (
        "green",
        "carbon",
        "office film",
        "Fine glossy",
    )


def test_identity_changes_nothing() -> None:
    photo = np.random.default_rng(0).integers(0, 65536, (5, 5)).astype(np.uint16)
    assert np.abs(ProcessCurve.identity().apply(photo).astype(int) - photo).max() <= 1


@pytest.mark.parametrize(
    ("text", "message"),
    [("nope", "not valid JSON"), ('{"format": "x"}', "not an OpenQuad process curve")],
)
def test_bad_process_files(text: str, message: str) -> None:
    with pytest.raises(ValueError, match=message):
        ProcessCurve.from_json(text)


def test_invalid_curves() -> None:
    levels = np.array([0, 65535], dtype=np.uint16)
    with pytest.raises(ValueError, match="colour"):
        ProcessCurve(levels, levels, colour="purple")
    with pytest.raises(ValueError, match="same length"):
        ProcessCurve(levels, levels[:1])
    with pytest.raises(ValueError, match="ascending"):
        ProcessCurve(levels[::-1].copy(), levels)


def test_preview_image_for_humans(tmp_path: Path) -> None:
    out = tmp_path / "neg.png"
    Image.fromarray((chart_negative("green", dpi=50) >> 8).astype(np.uint8)).save(out)
    assert out.stat().st_size > 0


# --- command line --------------------------------------------------------------------


def test_chart_commands_end_to_end(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    import tifffile

    from openquad.cli import main

    chart = tmp_path / "chart.tif"
    assert main(["target", "--kind", "chart", "-o", str(chart), "--dpi", "100"]) == 0
    assert "openquad chart SCAN" in capsys.readouterr().out

    def print_and_scan(path: Path, scan_path: Path) -> None:
        scan = scanned(contact_print(tifffile.imread(path)))
        Image.fromarray(np.round(scan * 255).astype(np.uint8)).save(scan_path, quality=92)

    scan1 = tmp_path / "carbon1.jpg"
    print_and_scan(chart, scan1)
    curve = tmp_path / "carbon.oqproc"
    argv = ["chart", str(scan1), "-o", str(curve), "--film", "office", "--printing", "Fine glossy"]
    assert main(argv) == 0
    out = capsys.readouterr().out
    assert "tone error: worst" in out and "wrote" in out
    assert load_process(curve).film == "office"

    chart2 = tmp_path / "chart2.tif"
    argv = ["target", "--kind", "chart", "-o", str(chart2), "--dpi", "100"]
    assert main([*argv, "--process", str(curve)]) == 0
    scan2 = tmp_path / "carbon2.jpg"
    print_and_scan(chart2, scan2)
    assert main(["chart", str(scan2), "--process", str(curve)]) == 0
    worst = float(capsys.readouterr().out.split("worst ")[1].split(" L*")[0])
    assert worst < 3.0

    photo = tmp_path / "photo.tif"
    tifffile.imwrite(photo, np.tile(np.linspace(0, 65535, 50).astype(np.uint16), (40, 1)))
    neg = tmp_path / "neg.tif"
    assert (
        main(["negative", str(photo), "-o", str(neg), "--dpi", "100", "--process", str(curve)]) == 0
    )
    assert "green" in capsys.readouterr().out  # the curve's colour is used
    argv = ["negative", str(photo), "-o", str(neg), "--process", str(curve), "--colour", "orange"]
    assert main(argv) == 1  # a curve made for green negatives can't be used for orange


# --- several charts on one page (green over orange) ----------------------------------


def page_scan(colours: list[str], processes=None, turn: str = "as scanned") -> np.ndarray:  # type: ignore[no-untyped-def]
    from openquad.chart import chart_page

    return scanned(contact_print(chart_page(colours, processes, dpi=DPI)), turn)


def test_page_stacks_compact_charts_with_id_marks() -> None:
    from openquad.chart import PAGE_GAP, chart_page

    layout = ChartLayout.compact()
    page = chart_page(["green", "orange"], dpi=DPI)
    one = chart_negative("green", dpi=DPI, layout=layout)
    assert page.shape == (2 * one.shape[0] + round(PAGE_GAP * DPI), one.shape[1], 3)
    assert page.shape[0] / DPI <= 9.95  # fits a Letter page with 0.5 in margins
    assert np.array_equal(page[: one.shape[0]], one)  # green on top, no id square
    assert not np.array_equal(
        page[-one.shape[0] :], chart_negative("orange", dpi=DPI, layout=layout)
    )


@pytest.mark.parametrize("turn", ["as scanned", "turned 180°", "mirrored"])
def test_reads_both_charts_and_knows_which_is_which(turn: str) -> None:
    from openquad.chart import read_chart_page

    # Print the orange chart through a curve that halves the ink, so it reads clearly
    # darker: then we can check each reading comes back under the right colour.
    levels = np.array([0, 65535], dtype=np.uint16)
    darker = ProcessCurve(levels, np.array([0, 32768], dtype=np.uint16), colour="orange")
    green, orange = read_chart_page(page_scan(["green", "orange"], [None, darker], turn=turn), 2)
    assert orange.lightness[:50].mean() < green.lightness[:50].mean() - 10
    plain = read_chart_page(page_scan(["green", "orange"], [None, darker]), 2)
    assert np.abs(green.lightness - plain[0].lightness).max() < 2.0
    assert np.abs(orange.lightness - plain[1].lightness).max() < 2.0


def test_both_colours_calibrate_from_one_page() -> None:
    from openquad.chart import read_chart_page

    first = read_chart_page(page_scan(["green", "orange"]), 2)
    curves = [build_process_curve(r) for r in first]
    second = read_chart_page(page_scan(["green", "orange"], curves), 2)
    for reading in second:
        assert np.abs(tone_errors(reading)).max() < 3.0


def test_page_errors() -> None:
    from openquad.chart import chart_page, read_chart_page

    with pytest.raises(ValueError, match="1-5 charts"):
        chart_page([], dpi=DPI)
    with pytest.raises(ValueError, match="one process curve"):
        chart_page(["green"], [None, None], dpi=DPI)
    with pytest.raises(BlockingError, match="expected 3 sheets"):
        read_chart_page(page_scan(["green", "orange"]), 3)
    with pytest.raises(ValueError, match="chart index"):
        chart_photo(index=9)


def test_page_commands(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    import tifffile

    from openquad.cli import main

    page = tmp_path / "page.tif"
    argv = [
        "target",
        "--kind",
        "chart",
        "--colour",
        "green,orange",
        "-o",
        str(page),
        "--dpi",
        "100",
    ]
    assert main(argv) == 0
    assert "green over orange" in capsys.readouterr().out
    scan = tmp_path / "page.jpg"
    pixels = scanned(contact_print(tifffile.imread(page)))
    Image.fromarray(np.round(pixels * 255).astype(np.uint8)).save(scan, quality=92)
    out = tmp_path / "carbon.oqproc"
    assert main(["chart", str(scan), "--colours", "green,orange", "-o", str(out)]) == 0
    printed = capsys.readouterr().out
    assert "Chart 1 (green)" in printed and "Chart 2 (orange)" in printed
    assert load_process(tmp_path / "carbon-green.oqproc").colour == "green"
    assert load_process(tmp_path / "carbon-orange.oqproc").colour == "orange"
    with pytest.raises(SystemExit):
        main(["target", "--kind", "chart", "--colour", "green,purple", "-o", str(page)])
