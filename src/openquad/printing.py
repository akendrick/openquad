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

#: Where CUPS keeps each printer's PPD (its driver options and their names).
PPD_FOLDER = Path("/etc/cups/ppd")

#: The driver options for the media (paper) type and the print quality, by keyword, most
#: likely first: IPP Everywhere / AirPrint, Canon, Epson, HP, Brother. A printer whose
#: options use none of these is matched by the option's name instead.
MEDIA_KEYWORDS = ("MediaType", "CNIJMediaType", "EPIJ_Medi", "HPMediaType", "BRMediaType")
QUALITY_KEYWORDS = ("cupsPrintQuality", "CNIJPrintQuality", "EPIJ_Qual", "HPPrintQuality",
                    "OutputMode", "BRPrintQuality")  # fmt: skip

#: Names for the standard IPP media types, which AirPrint and IPP Everywhere PPDs list
#: without names of their own.
IPP_MEDIA_NAMES = {
    "any": "Any",
    "stationery": "Plain paper",
    "stationery-coated": "Coated paper",
    "stationery-inkjet": "Inkjet paper",
    "stationery-heavyweight": "Heavyweight paper",
    "stationery-lightweight": "Lightweight paper",
    "photographic": "Photo paper",
    "photographic-glossy": "Glossy photo paper",
    "photographic-high-gloss": "High-gloss photo paper",
    "photographic-semi-gloss": "Semi-gloss photo paper",
    "photographic-satin": "Satin photo paper",
    "photographic-matte": "Matte photo paper",
    "transparency": "Transparency",
    "envelope": "Envelope",
    "labels": "Labels",
    "cardstock": "Card stock",
}

_OPEN_UI = re.compile(r"^\*OpenUI \*([^\s/:]+)(?:/([^:]*))?:\s*(\S+)")
_DEFAULT = re.compile(r"^\*Default([^\s:]+):\s*(\S+)")


class PrintError(RuntimeError):
    """CUPS refused the job or isn't available."""


def run_command(command: Sequence[str]) -> subprocess.CompletedProcess[str]:
    """Run a CUPS command, capturing its output."""
    try:
        return subprocess.run(list(command), capture_output=True, text=True, check=False)
    except FileNotFoundError:
        raise PrintError(f"{command[0]!r} not found; CUPS printing tools are required") from None


@dataclass(frozen=True)
class PrinterOption:
    """One of a printer's driver options from its PPD, e.g. CNIJMediaType "Media Type".

    `choices` are (value, name) pairs; `default` is the driver's own choice.
    """

    keyword: str
    label: str
    choices: tuple[tuple[str, str], ...]
    default: str | None = None

    def name_of(self, value: str) -> str:
        """The name shown for a value, e.g. "28" -> "Matte Photo Paper"."""
        return next((name for v, name in self.choices if v == value), value)


def parse_ppd(text: str) -> list[PrinterOption]:
    """The pick-one options in a PPD, in order, with their choices and defaults."""
    options: list[PrinterOption] = []
    defaults: dict[str, str] = {}
    current: tuple[str, str] | None = None
    choices: list[tuple[str, str]] = []
    for line in text.splitlines():
        if match := _DEFAULT.match(line):
            defaults[match.group(1)] = match.group(2)
        if current is None:
            match = _OPEN_UI.match(line)
            if match and match.group(3) == "PickOne":
                keyword = match.group(1)
                current, choices = (keyword, (match.group(2) or keyword).strip()), []
            continue
        if line.startswith("*CloseUI"):
            options.append(PrinterOption(current[0], current[1], tuple(choices)))
            current = None
            continue
        prefix = f"*{current[0]} "
        if line.startswith(prefix) and ":" in line:
            head = line[len(prefix) :].split(":", 1)[0]
            value, _, name = head.partition("/")
            value, name = value.strip(), name.strip()
            if value:
                choices.append((value, name or IPP_MEDIA_NAMES.get(value, value)))
    return [
        PrinterOption(o.keyword, o.label, o.choices, defaults.get(o.keyword))
        for o in options
        if o.choices
    ]


def _find(options: Sequence[PrinterOption], keywords: Sequence[str],
          words: Sequence[str]) -> PrinterOption | None:  # fmt: skip
    by_keyword = {o.keyword: o for o in options}
    for keyword in keywords:
        if keyword in by_keyword:
            return by_keyword[keyword]
    return next((o for o in options if any(w in o.label.lower() for w in words)), None)


def media_and_quality(
    options: Sequence[PrinterOption],
) -> tuple[PrinterOption | None, PrinterOption | None]:
    """The printer's media type and print quality options (None where it has none)."""
    media = _find(options, MEDIA_KEYWORDS, ("media type", "paper type"))
    rest = [o for o in options if o is not media]
    return media, _find(rest, QUALITY_KEYWORDS, ("quality",))


def printer_options(printer: str, folder: Path = PPD_FOLDER) -> list[PrinterOption]:
    """A CUPS printer's driver options, from its PPD; none if it has no PPD to read."""
    if not printer or "/" in printer or any(c.isspace() for c in printer):
        raise ValueError(f"invalid printer name: {printer!r}")
    try:
        text = (folder / f"{printer}.ppd").read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    return parse_ppd(text)


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
    landscape: bool = False  # the page turned on its side: the image prints rotated onto it
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
        if self.landscape:
            command += ["-o", "landscape"]
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
