"""The process calibration loop and the app's digital negative mode, simulated."""

from pathlib import Path

import numpy as np
import pytest
import tifffile

from openquad.chart import ProcessCurve, save_process
from openquad.process_run import ProcessRun, ProcessRunError
from openquad.session import PrintSession, SessionError
from tests.simulation import CarbonLab

# --- the run model -------------------------------------------------------------------


def start(tmp_path: Path, **kwargs) -> ProcessRun:  # type: ignore[no-untyped-def]
    args = {
        "printer": "Sim",
        "scanner_host": "scanner.local",
        "film": "office",
        "printing": "Fine glossy",
    }
    args.update(kwargs)
    return ProcessRun.start(tmp_path / "run", "carbon-sim", ["green", "orange"], **args)


def test_loop_reaches_the_goal_for_both_colours(tmp_path: Path) -> None:
    lab, run = CarbonLab(scan_dpi=100), start(tmp_path)
    run.print_page(lab.runner)
    run.scan_page(lab.fetch)
    first = run.measure()
    assert all(not r.done for r in first.values())  # uncalibrated carbon is off target
    run.refine()
    run.print_page(lab.runner)
    run.scan_page(lab.fetch)
    second = run.measure()
    assert all(r.done for r in second.values())
    assert run.best_colour() in ("green", "orange")
    assert run.curve("green").colour == "green" and run.curve("orange").colour == "orange"


def test_printed_elsewhere_and_a_scan_file(tmp_path: Path) -> None:
    lab, run = CarbonLab(scan_dpi=100), start(tmp_path, printer="")
    run.mark_printed("printed from GIMP")
    lab.contact_print_file(str(run.folder / run.current.page))
    _, _, jpeg = lab.fetch("GET", "x", None)
    scan = tmp_path / "my-scan.jpg"
    scan.write_bytes(jpeg)
    run.use_scan(scan)
    results = run.measure()
    assert set(results) == {"green", "orange"}
    assert run.current.job == "printed from GIMP"


def test_log_and_resume(tmp_path: Path) -> None:
    lab, run = CarbonLab(scan_dpi=100), start(tmp_path)
    run.print_page(lab.runner)
    run.scan_page(lab.fetch)
    run.measure()
    run.refine()
    resumed = ProcessRun.resume(run.folder)
    assert len(resumed.rounds) == 2 and resumed.rounds[0].refined
    assert set(resumed.rounds[0].results) == {"green", "orange"}
    assert resumed.current.curves["green"] == "carbon-sim-green-v1.oqproc"
    assert resumed.film == "office" and resumed.printing == "Fine glossy"


def test_steps_out_of_order_and_bad_input(tmp_path: Path) -> None:
    run = start(tmp_path)
    with pytest.raises(ProcessRunError, match="scan the contact print"):
        run.measure()
    with pytest.raises(ProcessRunError, match="measure the scan"):
        run.refine()
    assert run.best_colour() is None
    no_printer = start(tmp_path / "b", printer="", scanner_host="")
    with pytest.raises(ProcessRunError, match="no printer"):
        no_printer.print_page(CarbonLab().runner)
    with pytest.raises(ProcessRunError, match="no scanner"):
        no_printer.scan_page(CarbonLab().fetch)
    with pytest.raises(ProcessRunError, match="invalid name"):
        ProcessRun.start(tmp_path, "a/b", ["green"])
    with pytest.raises(ProcessRunError, match="choose 1-5 colours"):
        ProcessRun.start(tmp_path, "x", ["purple"])


def test_starting_curves_are_used(tmp_path: Path) -> None:
    levels = np.array([0, 65535], dtype=np.uint16)
    darker = ProcessCurve(levels, np.array([0, 30000], dtype=np.uint16), colour="green")
    run = start(tmp_path, starting={"green": darker})
    assert run.curve("green").curve[-1] == 30000
    assert run.curve("orange").curve[-1] == 65535


# --- the app's digital negative mode (Qt-free session) -------------------------------


def photo_file(tmp_path: Path) -> Path:
    path = tmp_path / "photo.tif"
    tifffile.imwrite(path, np.tile(np.linspace(0, 65535, 300).astype(np.uint16), (400, 1)),
                     resolution=(72, 72), resolutionunit="INCH")  # fmt: skip
    return path


def negative_session(tmp_path: Path) -> PrintSession:
    session = PrintSession()
    session.open(photo_file(tmp_path))
    session.set_mode("negative")
    return session


def test_negative_preview_is_green_with_a_safe_edge(tmp_path: Path) -> None:
    session = negative_session(tmp_path)
    preview = session.preview(max_side=300).astype(int)
    assert (
        preview[1, preview.shape[1] // 2, 1] > preview[1, preview.shape[1] // 2, 0] + 40
    )  # green edge
    middle = preview[preview.shape[0] // 2]
    assert middle[-preview.shape[1] // 5].sum() < middle[preview.shape[1] // 5].sum()  # inverted


def test_negative_size_includes_the_safe_edge(tmp_path: Path) -> None:
    session = negative_session(tmp_path)
    width, height = session.size_inches()
    assert width == pytest.approx(7.5)  # width limits on Letter (margins), edge included
    assert height < 10.0
    session.safe_edge = 0.5
    assert session.size_inches()[0] == pytest.approx(7.5)
    session.fit, session.ppi = False, 100.0
    assert session.size_inches() == pytest.approx((4.0, 5.0))


def test_process_curve_sets_colour_and_changes_the_negative(tmp_path: Path) -> None:
    session = negative_session(tmp_path)
    plain = session.render(session.photo.pixels, dpi=72)  # type: ignore[union-attr]
    levels = np.array([0, 65535], dtype=np.uint16)
    curve = tmp_path / "o.oqproc"
    save_process(
        ProcessCurve(levels, np.array([0, 40000], dtype=np.uint16), colour="orange"), curve
    )
    session.set_process(curve)
    assert session.negative_colour == "orange"
    with pytest.raises(SessionError, match="for orange negatives"):
        session.set_negative_colour("green")
    curved = session.render(session.photo.pixels, dpi=72)  # type: ignore[union-attr]
    assert not np.array_equal(plain, curved)
    assert "Process curve: o.oqproc" in session.summary()
    session.set_process(None)
    session.set_negative_colour("green")
    assert session.negative_colour == "green"


def test_negative_summary_and_file(tmp_path: Path) -> None:
    session = negative_session(tmp_path)
    session.mirror = True
    lines = session.summary()
    assert "Output: digital negative" in lines and "Mirrored: yes" in lines
    assert any(line.startswith("Colour: green") for line in lines)
    out = session.write_print_file(tmp_path / "neg.tif")
    assert tifffile.imread(out).shape[-1] == 3


def test_mode_and_colour_are_checked(tmp_path: Path) -> None:
    session = PrintSession()
    with pytest.raises(SessionError, match="mode"):
        session.set_mode("film")
    with pytest.raises(SessionError, match="negative colour"):
        session.set_negative_colour("purple")
