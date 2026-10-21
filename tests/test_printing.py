"""Tests for the CUPS print wrapper. No real printer is ever used."""

import subprocess
from collections.abc import Sequence
from pathlib import Path

import pytest

from openquad.printing import PrintError, PrintJob, list_printers, run_command, send


class FakeRunner:
    """Records commands and answers like `lp`/`lpstat` would."""

    def __init__(self, stdout: str = "", returncode: int = 0, stderr: str = "") -> None:
        self.stdout, self.returncode, self.stderr = stdout, returncode, stderr
        self.commands: list[list[str]] = []

    def __call__(self, command: Sequence[str]) -> subprocess.CompletedProcess[str]:
        self.commands.append(list(command))
        return subprocess.CompletedProcess(command, self.returncode, self.stdout, self.stderr)


def job(tmp_path: Path, **kwargs: object) -> PrintJob:
    path = tmp_path / "sheet.tif"
    path.write_bytes(b"tiff")
    return PrintJob(path=path, printer="Canon_MG3600_series", **kwargs)  # type: ignore[arg-type]


def test_command_sets_page_size_and_real_size(tmp_path: Path) -> None:
    command = job(tmp_path, paper="A4", ppi=360.0, copies=2).command()
    assert command[:5] == ["lp", "-d", "Canon_MG3600_series", "-n", "2"]
    assert "PageSize=A4" in command
    assert "ppi=360" in command
    assert command[command.index("-t") + 1] == "sheet.tif"
    assert command[-1] == str(tmp_path / "sheet.tif")


def test_extra_options_and_title(tmp_path: Path) -> None:
    command = job(tmp_path, title="Test", options=(("CNIJMediaType", "0"),)).command()
    assert command[command.index("-t") + 1] == "Test"
    assert command[-3:-1] == ["-o", "CNIJMediaType=0"]


@pytest.mark.parametrize(
    ("kwargs", "message"),
    [
        ({"printer": ""}, "printer name"),
        ({"printer": "My Printer"}, "printer name"),
        ({"copies": 0}, "copies"),
        ({"ppi": 0.0}, "ppi"),
    ],
)
def test_invalid_jobs_are_rejected(kwargs: dict[str, object], message: str) -> None:
    args: dict[str, object] = {"path": Path("x.tif"), "printer": "P"}
    args.update(kwargs)
    with pytest.raises(ValueError, match=message):
        PrintJob(**args)  # type: ignore[arg-type]


def test_send_returns_the_job_id(tmp_path: Path) -> None:
    runner = FakeRunner("request id is Canon_MG3600_series-3144 (1 file(s))\n")
    assert send(job(tmp_path), runner) == "Canon_MG3600_series-3144"
    assert runner.commands[0][0] == "lp"


def test_send_reports_lp_errors(tmp_path: Path) -> None:
    runner = FakeRunner(returncode=1, stderr="lp: The printer or class does not exist.")
    with pytest.raises(PrintError, match="does not exist"):
        send(job(tmp_path), runner)


def test_send_requires_a_job_id(tmp_path: Path) -> None:
    with pytest.raises(PrintError, match="no job id"):
        send(job(tmp_path), FakeRunner("something else"))


def test_send_checks_the_file_exists(tmp_path: Path) -> None:
    runner = FakeRunner()
    with pytest.raises(PrintError, match="file not found"):
        send(PrintJob(path=tmp_path / "missing.tif", printer="P"), runner)
    assert runner.commands == []


def test_list_printers() -> None:
    runner = FakeRunner("Canon_MG3600_series\nOffice_Laser\n\n")
    assert list_printers(runner) == ["Canon_MG3600_series", "Office_Laser"]
    assert runner.commands == [["lpstat", "-e"]]


def test_list_printers_reports_errors() -> None:
    with pytest.raises(PrintError, match="lpstat failed"):
        list_printers(FakeRunner(returncode=1, stderr="scheduler not running"))


def test_run_command_captures_output() -> None:
    result = run_command(["echo", "hello"])
    assert result.returncode == 0
    assert result.stdout.strip() == "hello"


def test_run_command_missing_tool() -> None:
    with pytest.raises(PrintError, match="not found"):
        run_command(["openquad-no-such-command"])
