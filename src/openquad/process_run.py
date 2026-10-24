"""A process calibration run: chart page, contact print, scan, read, refine. No Qt.

Each round prints one page of compact charts (one per negative colour, through
that colour's current process curve), the page is contact printed (carbon), the
print is scanned and every chart is read. Each colour is judged against the goal
(every patch within 3 L* of its target) and its curve can be refined from what
was measured. Every file and a `run.json` log are kept in the run's folder.

The film can be printed by OpenQuad (through CUPS) or elsewhere, e.g. from GIMP
with the recorded print settings: `mark_printed` records that instead.
"""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field
from pathlib import Path

import numpy as np

from openquad.chart import (
    ProcessCurve,
    build_process_curve,
    chart_page,
    load_process,
    read_chart_page,
    reading_from_json,
    reading_to_json,
    save_process,
    tone_errors,
)
from openquad.escl import Fetch, ScanSettings, http_fetch, scan
from openquad.imageio import save_rgb, srgb_profile
from openquad.measure import load_scan
from openquad.negative import NEGATIVE_COLOURS
from openquad.printing import PrintJob, Runner, run_command, send

TONE_GOAL = 3.0  # every patch within this many L* of its target
PAGE_PPI = 300.0


class ProcessRunError(RuntimeError):
    """A step was taken out of order or failed."""


@dataclass
class ColourResult:
    worst: float
    mean: float
    white: float
    black: float

    @property
    def done(self) -> bool:
        return self.worst < TONE_GOAL


@dataclass
class ProcessRound:
    version: int
    curves: dict[str, str]  # colour -> curve file
    page: str | None = None
    job: str | None = None
    scan: str | None = None
    readings: dict[str, str] = field(default_factory=dict)  # colour -> reading file
    results: dict[str, dict[str, float]] = field(default_factory=dict)
    refined: bool = False


@dataclass
class ProcessRun:
    folder: Path
    name: str
    colours: list[str]
    printer: str = ""
    paper: str = "Letter"
    scanner_host: str = ""
    mirror: bool = False
    film: str = ""
    printing: str = ""
    rounds: list[ProcessRound] = field(default_factory=list)

    @classmethod
    def start(
        cls,
        folder: str | Path,
        name: str,
        colours: list[str],
        *,
        printer: str = "",
        paper: str = "Letter",
        scanner_host: str = "",
        mirror: bool = False,
        film: str = "",
        printing: str = "",
        starting: dict[str, ProcessCurve] | None = None,
    ) -> ProcessRun:
        if not name.strip() or any(c in name for c in "/\\"):
            raise ProcessRunError(f"invalid name {name!r}")
        if not 1 <= len(colours) <= 5 or any(c not in NEGATIVE_COLOURS for c in colours):
            raise ProcessRunError(f"choose 1-5 colours from {', '.join(NEGATIVE_COLOURS)}")
        run = cls(
            Path(folder), name.strip(), list(colours), printer, paper, scanner_host,
            mirror, film, printing,
        )  # fmt: skip
        run.folder.mkdir(parents=True, exist_ok=True)
        starting = starting or {}
        curves = {c: starting.get(c) or ProcessCurve.identity(c) for c in colours}
        run._new_round(curves)
        return run

    @classmethod
    def resume(cls, folder: str | Path) -> ProcessRun:
        data = json.loads((Path(folder) / "run.json").read_text(encoding="utf-8"))
        rounds = [ProcessRound(**r) for r in data.pop("rounds")]
        return cls(folder=Path(folder), rounds=rounds, **data)

    def _save_log(self) -> None:
        data = {k: v for k, v in asdict(self).items() if k not in ("folder", "rounds")}
        data["rounds"] = [asdict(r) for r in self.rounds]
        (self.folder / "run.json").write_text(json.dumps(data, indent=1) + "\n", encoding="utf-8")

    def _new_round(self, curves: dict[str, ProcessCurve]) -> None:
        version = len(self.rounds)
        names = {}
        for colour, curve in curves.items():
            path = self.folder / f"{self.name}-{colour}-v{version}.oqproc"
            save_process(curve, path)
            names[colour] = path.name
        self.rounds.append(ProcessRound(version=version, curves=names))
        self._save_log()

    @property
    def current(self) -> ProcessRound:
        return self.rounds[-1]

    def curve(self, colour: str) -> ProcessCurve:
        return load_process(self.folder / self.current.curves[colour])

    def curve_path(self, colour: str) -> Path:
        return self.folder / self.current.curves[colour]

    def _file(self, kind: str, suffix: str) -> Path:
        return self.folder / f"{self.name}-v{self.current.version}-{kind}{suffix}"

    # --- steps ----------------------------------------------------------------------

    def make_page(self) -> Path:
        """This round's page of charts (to print here or from GIMP at 300 ppi)."""
        path = self._file("page", ".tif")
        curves: list[ProcessCurve | None] = [self.curve(c) for c in self.colours]
        page = chart_page(self.colours, curves, mirror=self.mirror, dpi=PAGE_PPI)
        save_rgb(path, page, (PAGE_PPI, PAGE_PPI), srgb_profile())
        self.current.page = path.name
        self._save_log()
        return path

    def print_page(self, runner: Runner = run_command) -> str:
        if not self.printer:
            raise ProcessRunError("no printer chosen")
        page = self.folder / self.current.page if self.current.page else self.make_page()
        job = PrintJob(
            path=page,
            printer=self.printer,
            paper=self.paper,
            ppi=PAGE_PPI,
            title=f"OpenQuad process chart: {self.name} v{self.current.version}",
        )
        self.current.job = send(job, runner)
        self._save_log()
        return self.current.job

    def mark_printed(self, note: str = "printed elsewhere") -> None:
        """Record that the page was printed outside OpenQuad (e.g. from GIMP)."""
        if not self.current.page:
            self.make_page()
        self.current.job = note
        self._save_log()

    def scan_page(self, fetch: Fetch = http_fetch) -> Path:
        if not self.scanner_host:
            raise ProcessRunError("no scanner chosen")
        path = scan(self.scanner_host, self._file("scan", ".jpg"), ScanSettings(), fetch=fetch)
        self.current.scan = path.name
        self._save_log()
        return path

    def use_scan(self, path: str | Path) -> None:
        """Use a scan made some other way (copied into the run's folder)."""
        target = self._file("scan", Path(path).suffix or ".jpg")
        target.write_bytes(Path(path).read_bytes())
        self.current.scan = target.name
        self._save_log()

    def measure(self) -> dict[str, ColourResult]:
        if not self.current.scan:
            raise ProcessRunError("scan the contact print first")
        readings = read_chart_page(load_scan(self.folder / self.current.scan), len(self.colours))
        results = {}
        for colour, reading in zip(self.colours, readings, strict=True):
            path = self._file(f"{colour}-reading", ".json")
            path.write_text(reading_to_json(reading) + "\n", encoding="utf-8")
            self.current.readings[colour] = path.name
            errors = np.abs(tone_errors(reading))
            result = ColourResult(
                float(errors.max()), float(errors.mean()), reading.white, reading.black
            )
            self.current.results[colour] = asdict(result)
            results[colour] = result
        self._save_log()
        return results

    def results(self) -> dict[str, ColourResult]:
        return {c: ColourResult(**r) for c, r in self.current.results.items()}

    def best_colour(self) -> str | None:
        """The colour closest to target (smallest worst error) in this round."""
        results = self.results()
        return min(results, key=lambda c: results[c].worst) if results else None

    def refine(self) -> dict[str, Path]:
        """Build the next curve for every colour from this round's readings."""
        if len(self.current.readings) != len(self.colours):
            raise ProcessRunError("measure the scan first")
        curves = {}
        for colour in self.colours:
            text = (self.folder / self.current.readings[colour]).read_text(encoding="utf-8")
            curves[colour] = build_process_curve(
                reading_from_json(text), self.curve(colour), film=self.film, printing=self.printing
            )
        self.current.refined = True
        self._new_round(curves)
        return {c: self.curve_path(c) for c in self.colours}
