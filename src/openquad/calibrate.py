"""A calibration run: the print, scan, measure, improve loop, without any Qt.

Each round prints a comparison page (uncorrected and current calibration on one
sheet), scans it in Document mode, measures both targets, judges the result
against the Phase 3 goals and suggests the next step:

- grey balance while any step's colour cast is 3 or more (or the mean is over 1);
- otherwise linearize while any step's tone is 2 L* or more from its target;
- otherwise done.

Every file (pages, scans, measurements, calibrations) is kept in the run's
folder with a `run.json` log, so a run can be inspected or continued later.
"""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field
from pathlib import Path

import numpy as np

from openquad.escl import Fetch, ScanSettings, http_fetch, scan
from openquad.greybalance import (
    Calibration,
    build_calibration,
    comparison_page,
    load_calibration,
    save_calibration,
)
from openquad.imageio import save_rgb, srgb_profile
from openquad.linearize import linearize, tone_report
from openquad.measure import Measurement, load_scan, measure_pair
from openquad.printing import PrintJob, Runner, run_command, send
from openquad.targets import wedge_levels

CAST_GOAL = 3.0  # largest |a*| or |b*|
MEAN_CAST_GOAL = 1.0
TONE_GOAL = 2.0  # largest L* error
PAGE_PPI = 300.0


class CalibrationError(RuntimeError):
    """A step was taken out of order or failed."""


@dataclass(frozen=True)
class Assessment:
    worst_cast: float
    mean_cast: float
    worst_tone: float
    mean_tone: float
    uncorrected_cast: float

    @property
    def next_step(self) -> str:
        """'grey balance', 'linearize' or 'done'."""
        if self.worst_cast >= CAST_GOAL or self.mean_cast > MEAN_CAST_GOAL:
            return "grey balance"
        if self.worst_tone >= TONE_GOAL:
            return "linearize"
        return "done"

    def summary(self) -> str:
        return (
            f"Colour cast: worst {self.worst_cast:.1f}, mean {self.mean_cast:.2f} "
            f"(goal under {CAST_GOAL:g}). Tone: worst {self.worst_tone:.1f} L*, "
            f"mean {self.mean_tone:.2f} (goal under {TONE_GOAL:g}). "
            f"Uncorrected cast on the same page: {self.uncorrected_cast:.1f}."
        )


def assess(uncorrected: Measurement, corrected: Measurement) -> Assessment:
    tone = tone_report(corrected)
    casts = np.abs(corrected.lab[:, 1:])
    return Assessment(
        worst_cast=float(casts.max()),
        mean_cast=float(casts.mean()),
        worst_tone=tone.worst(),
        mean_tone=float(np.abs(tone.errors).mean()),
        uncorrected_cast=uncorrected.worst_cast(),
    )


@dataclass
class Round:
    version: int
    calibration: str
    page: str | None = None
    job: str | None = None
    scan: str | None = None
    measurements: list[str] = field(default_factory=list)
    assessment: dict[str, float] | None = None
    action: str | None = None


@dataclass
class CalibrationRun:
    folder: Path
    name: str
    printer: str
    paper: str = "Letter"
    scanner_host: str = ""
    rounds: list[Round] = field(default_factory=list)

    # --- starting and resuming ------------------------------------------------------

    @classmethod
    def start(
        cls,
        folder: str | Path,
        name: str,
        printer: str,
        paper: str = "Letter",
        scanner_host: str = "",
        starting: Calibration | None = None,
    ) -> CalibrationRun:
        """A new run in `folder`, starting from `starting` (default: no correction)."""
        if not name.strip() or any(c in name for c in "/\\"):
            raise CalibrationError(f"invalid calibration name {name!r}")
        run = cls(Path(folder), name.strip(), printer, paper, scanner_host)
        run.folder.mkdir(parents=True, exist_ok=True)
        calibration = starting or Calibration.identity()
        calibration = Calibration(
            levels=calibration.levels,
            curves=calibration.curves,
            printer=printer,
            paper=paper,
            settings=calibration.settings or "default quality; eSCL Document intent",
        )
        run._new_round(calibration)
        return run

    @classmethod
    def resume(cls, folder: str | Path) -> CalibrationRun:
        data = json.loads((Path(folder) / "run.json").read_text(encoding="utf-8"))
        rounds = [Round(**r) for r in data.pop("rounds")]
        return cls(folder=Path(folder), rounds=rounds, **data)

    def _save_log(self) -> None:
        data = {
            "name": self.name,
            "printer": self.printer,
            "paper": self.paper,
            "scanner_host": self.scanner_host,
            "rounds": [asdict(r) for r in self.rounds],
        }
        (self.folder / "run.json").write_text(json.dumps(data, indent=1) + "\n", encoding="utf-8")

    def _new_round(self, calibration: Calibration) -> None:
        version = len(self.rounds)
        path = self.folder / f"{self.name}-v{version}.oqcal"
        save_calibration(calibration, path)
        self.rounds.append(Round(version=version, calibration=path.name))
        self._save_log()

    # --- the current round ----------------------------------------------------------

    @property
    def current(self) -> Round:
        return self.rounds[-1]

    @property
    def calibration_path(self) -> Path:
        return self.folder / self.current.calibration

    @property
    def calibration(self) -> Calibration:
        return load_calibration(self.calibration_path)

    def _file(self, kind: str, suffix: str) -> Path:
        return self.folder / f"{self.name}-v{self.current.version}-{kind}{suffix}"

    def make_page(self) -> Path:
        """The comparison page for this round: uncorrected above, current calibration below."""
        path = self._file("page", ".tif")
        save_rgb(
            path, comparison_page(self.calibration, PAGE_PPI), (PAGE_PPI, PAGE_PPI), srgb_profile()
        )
        self.current.page = path.name
        self._save_log()
        return path

    def print_page(self, runner: Runner = run_command) -> str:
        page = self.folder / self.current.page if self.current.page else self.make_page()
        job = PrintJob(
            path=page,
            printer=self.printer,
            paper=self.paper,
            ppi=PAGE_PPI,
            title=f"OpenQuad calibration: {self.name} v{self.current.version}",
        )
        self.current.job = send(job, runner)
        self._save_log()
        return self.current.job

    def scan_page(self, fetch: Fetch = http_fetch) -> Path:
        if not self.scanner_host:
            raise CalibrationError("no scanner chosen")
        path = scan(self.scanner_host, self._file("scan", ".jpg"), ScanSettings(), fetch=fetch)
        self.current.scan = path.name
        self._save_log()
        return path

    def measure(self) -> tuple[Measurement, Measurement, Assessment]:
        if not self.current.scan:
            raise CalibrationError("scan the printed page first")
        sent = self.calibration.sent_for(wedge_levels(21))
        plain, corrected = measure_pair(load_scan(self.folder / self.current.scan), sent)
        names = []
        for kind, measurement in (("uncorrected", plain), ("corrected", corrected)):
            path = self._file(kind, ".json")
            path.write_text(measurement.to_json() + "\n", encoding="utf-8")
            names.append(path.name)
        result = assess(plain, corrected)
        self.current.measurements = names
        self.current.assessment = {k: v for k, v in asdict(result).items() if isinstance(v, float)}
        self._save_log()
        return plain, corrected, result

    def corrected_measurement(self) -> Measurement:
        if len(self.current.measurements) != 2:
            raise CalibrationError("measure the scan first")
        text = (self.folder / self.current.measurements[1]).read_text(encoding="utf-8")
        return Measurement.from_json(text)

    # --- improving ------------------------------------------------------------------

    def improve(
        self, action: str, damping: float = 1.0, shadow_damping: float | None = 0.5
    ) -> Path:
        """Build the next calibration ('grey balance' or 'linearize'); returns its path."""
        measurement = self.corrected_measurement()
        current = self.calibration
        if action == "grey balance":
            new = build_calibration(
                measurement,
                damping=damping,
                shadow_damping=shadow_damping,
                printer=self.printer,
                paper=self.paper,
                settings=current.settings,
            )
        elif action == "linearize":
            new = linearize(current, measurement)
        else:
            raise CalibrationError(f"unknown action {action!r}")
        self.current.action = action
        self._new_round(new)
        return self.calibration_path
