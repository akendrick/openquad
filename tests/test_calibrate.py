"""The calibration loop, end to end against a simulated printer and scanner."""

import time
from pathlib import Path

import numpy as np
import pytest

from openquad.calibrate import Assessment, CalibrationError, CalibrationRun
from openquad.escl import discover, parse_avahi, parse_dns_sd_browse, parse_dns_sd_resolve
from openquad.greybalance import Calibration
from tests.simulation import SimulatedLab


def new_run(tmp_path: Path, **kwargs: object) -> CalibrationRun:
    args: dict[str, object] = {
        "folder": tmp_path / "run",
        "name": "sim-plain",
        "printer": "Sim",
        "scanner_host": "scanner.local",
    }
    args.update(kwargs)
    return CalibrationRun.start(**args)  # type: ignore[arg-type]


def one_round(run: CalibrationRun, lab: SimulatedLab) -> Assessment:
    run.print_page(lab.runner)
    run.scan_page(lab.fetch)
    _, _, result = run.measure()
    return result


def test_full_loop_reaches_both_goals(tmp_path: Path) -> None:
    lab, run = SimulatedLab(), new_run(tmp_path)
    steps, results = [], []
    for _ in range(6):
        result = one_round(run, lab)
        results.append(result)
        steps.append(result.next_step)
        if result.next_step == "done":
            break
        run.improve(result.next_step)
    assert steps[0] == "grey balance"  # the simulated printer starts blue
    assert "linearize" in steps
    assert steps[-1] == "done"
    assert results[-1].worst_cast < 3 and results[-1].worst_tone < 2
    assert results[0].worst_cast > 5


def test_files_and_log_are_kept(tmp_path: Path) -> None:
    lab, run = SimulatedLab(), new_run(tmp_path)
    one_round(run, lab)
    run.improve("grey balance")
    names = sorted(p.name for p in run.folder.iterdir())
    for expected in (
        "run.json",
        "sim-plain-v0.oqcal",
        "sim-plain-v0-page.tif",
        "sim-plain-v0-scan.jpg",
        "sim-plain-v0-uncorrected.json",
        "sim-plain-v0-corrected.json",
        "sim-plain-v1.oqcal",
    ):
        assert expected in names
    resumed = CalibrationRun.resume(run.folder)
    assert len(resumed.rounds) == 2
    assert resumed.rounds[0].action == "grey balance"
    assert resumed.rounds[0].assessment and resumed.rounds[0].assessment["worst_cast"] > 3
    assert resumed.current.calibration == "sim-plain-v1.oqcal"
    assert lab.commands[0][lab.commands[0].index("-t") + 1] == "OpenQuad calibration: sim-plain v0"


def test_starting_from_an_existing_calibration(tmp_path: Path) -> None:
    from openquad.greybalance import load_calibration

    lab = SimulatedLab()
    first = new_run(tmp_path)
    before = one_round(first, lab)
    improved = first.improve("grey balance")
    second = new_run(tmp_path, folder=tmp_path / "again", starting=load_calibration(improved))
    assert not np.array_equal(second.calibration.curves, Calibration.identity().curves)
    after = one_round(second, lab)
    # One pass with half-strength shadow corrections: clearly better, not yet done.
    assert after.mean_cast < before.mean_cast / 2
    assert after.worst_cast < before.worst_cast


def test_calibrations_record_printer_and_paper(tmp_path: Path) -> None:
    run = new_run(tmp_path, paper="A4")
    assert (run.calibration.printer, run.calibration.paper) == ("Sim", "A4")


def test_steps_out_of_order(tmp_path: Path) -> None:
    run = new_run(tmp_path)
    with pytest.raises(CalibrationError, match="scan the printed page"):
        run.measure()
    with pytest.raises(CalibrationError, match="measure the scan"):
        run.improve("grey balance")
    no_scanner = new_run(tmp_path, folder=tmp_path / "x", scanner_host="")
    with pytest.raises(CalibrationError, match="no scanner"):
        no_scanner.scan_page(SimulatedLab().fetch)


def test_unknown_action_and_bad_names(tmp_path: Path) -> None:
    lab, run = SimulatedLab(), new_run(tmp_path)
    one_round(run, lab)
    with pytest.raises(CalibrationError, match="unknown action"):
        run.improve("sharpen")
    for bad in ("", "  ", "a/b"):
        with pytest.raises(CalibrationError, match="invalid"):
            new_run(tmp_path, name=bad)


@pytest.mark.parametrize(
    ("cast", "mean", "tone", "expected"),
    [
        (3.5, 0.5, 1.0, "grey balance"),
        (2.0, 1.2, 1.0, "grey balance"),
        (2.0, 0.5, 2.5, "linearize"),
        (2.0, 0.5, 1.4, "done"),
    ],
)
def test_next_step_rules(cast: float, mean: float, tone: float, expected: str) -> None:
    result = Assessment(cast, mean, tone, 0.5, 5.0)
    assert result.next_step == expected
    assert "goal under 3" in result.summary()


def test_identity_start_records_no_change() -> None:
    assert np.array_equal(Calibration.identity().curves[0], Calibration.identity().levels)


# --- scanner discovery ---------------------------------------------------------------

DNS_SD_BROWSE = """Browsing for _uscan._tcp.local.
DATE: ---Tue 20 Oct 2026---
20:29:23.020  ...STARTING...
Timestamp     A/R    Flags  if Domain               Service Type         Instance Name
20:29:23.021  Add        2  11 local.               _uscan._tcp.         Canon MG3600 series
20:29:23.021  Add        2  11 local.               _uscan._tcp.         Canon MG3600 series
"""
DNS_SD_RESOLVE = (
    "20:29:43.311  Canon\\032MG3600\\032series._uscan._tcp.local. can be reached at "
    "876298000000.local.:80 (interface 11)\n"
)
AVAHI = (
    "+;en0;IPv4;Canon\\032MG3600\\032series;_uscan._tcp;local\n"
    "=;en0;IPv4;Canon\\032MG3600\\032series;_uscan._tcp;local;876298000000.local;"
    '192.168.1.20;80;"rs=eSCL"\n'
)


def test_parsers() -> None:
    assert parse_dns_sd_browse(DNS_SD_BROWSE) == ["Canon MG3600 series"] * 2
    assert parse_dns_sd_resolve(DNS_SD_RESOLVE) == "876298000000.local:80"
    assert parse_dns_sd_resolve("nothing") is None
    assert parse_avahi(AVAHI) == [("Canon MG3600 series", "876298000000.local:80")]


def test_discover_with_dns_sd(monkeypatch: pytest.MonkeyPatch) -> None:
    import shutil

    monkeypatch.setattr(shutil, "which", lambda name: None)  # no avahi: use dns-sd

    def browse(command: list[str], seconds: float) -> str:
        return DNS_SD_BROWSE if "-B" in command else DNS_SD_RESOLVE

    assert discover(browse) == [("Canon MG3600 series", "876298000000.local:80")]


def test_discover_with_avahi(monkeypatch: pytest.MonkeyPatch) -> None:
    import shutil

    monkeypatch.setattr(shutil, "which", lambda name: "/usr/bin/avahi-browse")
    assert discover(lambda command, seconds: AVAHI) == [
        ("Canon MG3600 series", "876298000000.local:80")
    ]


def test_run_for_handles_missing_and_endless_commands() -> None:
    from openquad.escl import run_for

    assert run_for(["openquad-no-such-tool"], 0.1) == ""
    started = time.monotonic()
    assert run_for(["sh", "-c", "echo hi; sleep 30"], 2.0).strip() == "hi"
    assert time.monotonic() - started < 10  # stopped at the time limit, child included
    assert run_for(["echo", "done"], 2).strip() == "done"
