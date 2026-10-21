"""Send finished images to a printer through CUPS (`lp`).

This is the composite path: the image is already rendered (greyscale or sRGB)
and goes through the printer's normal driver.
"""

from __future__ import annotations

import re
import subprocess
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path

Runner = Callable[[Sequence[str]], "subprocess.CompletedProcess[str]"]

_JOB_ID = re.compile(r"request id is (\S+)")


class PrintError(RuntimeError):
    """CUPS refused the job or isn't available."""


def run_command(command: Sequence[str]) -> subprocess.CompletedProcess[str]:
    """Run a CUPS command, capturing its output."""
    try:
        return subprocess.run(list(command), capture_output=True, text=True, check=False)
    except FileNotFoundError:
        raise PrintError(f"{command[0]!r} not found; CUPS printing tools are required") from None


@dataclass(frozen=True)
class PrintJob:
    """One print request: a file, a CUPS printer name, and page settings.

    `ppi` makes the image print at its real size (pixels / ppi inches).
    `options` are extra `lp -o name=value` driver options.
    """

    path: Path
    printer: str
    paper: str = "Letter"
    ppi: float = 300.0
    copies: int = 1
    title: str | None = None
    options: tuple[tuple[str, str], ...] = ()

    def __post_init__(self) -> None:
        if not self.printer or any(c.isspace() for c in self.printer):
            raise ValueError(f"invalid printer name: {self.printer!r}")
        if self.copies < 1:
            raise ValueError(f"copies must be at least 1, got {self.copies}")
        if self.ppi <= 0:
            raise ValueError(f"ppi must be positive, got {self.ppi}")

    def command(self) -> list[str]:
        """The `lp` command line for this job."""
        command = [
            "lp",
            "-d",
            self.printer,
            "-n",
            str(self.copies),
            "-o",
            f"PageSize={self.paper}",
            "-o",
            f"ppi={round(self.ppi)}",
            "-t",
            self.title or self.path.name,
        ]
        for name, value in self.options:
            command += ["-o", f"{name}={value}"]
        command.append(str(self.path))
        return command


def send(job: PrintJob, runner: Runner = run_command) -> str:
    """Submit the job and return the CUPS job id (e.g. 'Canon_MG3600_series-3144')."""
    if not job.path.is_file():
        raise PrintError(f"file not found: {job.path}")
    result = runner(job.command())
    if result.returncode != 0:
        raise PrintError(f"lp failed: {(result.stderr or result.stdout).strip()}")
    match = _JOB_ID.search(result.stdout)
    if not match:
        raise PrintError(f"lp gave no job id: {result.stdout.strip()!r}")
    return match.group(1)


def list_printers(runner: Runner = run_command) -> list[str]:
    """Names of the CUPS printers set up on this computer."""
    result = runner(["lpstat", "-e"])
    if result.returncode != 0:
        raise PrintError(f"lpstat failed: {(result.stderr or result.stdout).strip()}")
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]
