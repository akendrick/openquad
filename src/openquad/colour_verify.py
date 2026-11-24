"""Checking a colour profile by printing through it, and improving it (phase 3).

Like the grey wizard's rounds: each round prints a verification page through the
current profile, scans it, measures how close each colour came to what was wanted
(CIEDE2000), and either stops (the goals are met) or folds what it measured back into
the forward model and builds the next profile.

The verification page holds colours the profile wasn't built from: the 24 colours of
a colour-checker chart (as published L*a*b*), skin tones, a neutral wedge, and photo
colours picked at random from sRGB. Each is sent as the profile's relative colourimetric
inverse, so a colour the printer can make should print as wanted. The averages count
only those; colours outside the printer's gamut are reported apart, since no profile
could print them exactly.

Every file of a run (profiles, models, pages, layouts, scans, measurements, reports) is
kept in the run's folder with a `run.json` log, as grey calibration runs are.
"""

from __future__ import annotations

import json
import shutil
from collections.abc import Sequence
from dataclasses import asdict, dataclass, field
from pathlib import Path

import numpy as np
from numpy.typing import NDArray

from openquad.colour import (
    D50_WHITE,
    d65_to_d50,
    delta_e_2000,
    linear_rgb_to_xyz,
    srgb_to_linear,
    xyz_to_lab,
)
from openquad.colour_profile import (
    GAMUT_LIMIT,
    ForwardModel,
    ProfileError,
    build_profile,
    fit_lattice,
    icc_profile,
    invert,
)
from openquad.colour_target import (
    ColourMeasurement,
    ColourTarget,
    layout_target,
    measure_target,
    save_measurement,
    target_page,
)
from openquad.imageio import save_rgb, srgb_profile
from openquad.measure import load_scan
from openquad.quadfile import MAX_VALUE
from openquad.scanner_profile import ScannerModel

MEAN_GOAL = 3.0  # ΔE00, printable colours
P95_GOAL = 6.0
CAST_GOAL = 3.0  # largest C* of a neutral, as for grey
TONE_GOAL = 2.0  # largest L* error of a neutral
DAMPING = 0.5  # share of each round's measured error folded back in
CORRECTION_SMOOTHING = 0.03
RANDOM_COLOURS = 100
SHUFFLE_SEED = 17

#: A colour-checker chart's 24 colours, as commonly published (L*a*b*, D50).
CHECKER = (
    ("dark skin", 37.54, 14.37, 14.92),
    ("light skin", 64.66, 19.27, 17.50),
    ("blue sky", 49.32, -3.82, -22.54),
    ("foliage", 43.46, -12.74, 22.72),
    ("blue flower", 54.94, 9.61, -24.79),
    ("bluish green", 70.48, -32.26, -0.37),
    ("orange", 62.73, 35.83, 56.50),
    ("purplish blue", 39.43, 10.75, -45.17),
    ("moderate red", 50.57, 48.64, 16.67),
    ("purple", 30.10, 22.54, -20.87),
    ("yellow green", 71.77, -24.13, 58.19),
    ("orange yellow", 71.51, 18.24, 67.37),
    ("blue", 28.37, 15.42, -49.80),
    ("green", 54.38, -39.72, 32.27),
    ("red", 42.43, 51.05, 28.62),
    ("yellow", 81.80, 2.67, 80.41),
    ("magenta", 50.63, 51.28, -14.12),
    ("cyan", 49.57, -29.71, -28.32),
    ("white", 95.19, -1.03, 2.93),
    ("neutral 8", 81.29, -0.57, 0.44),
    ("neutral 6.5", 66.89, -0.75, -0.06),
    ("neutral 5", 50.76, -0.13, 0.14),
    ("neutral 3.5", 35.63, -0.46, -0.48),
    ("black", 20.64, 0.07, -0.46),
)
#: Skin tones from deep to fair (L*a*b*, D50).
SKIN = (
    ("skin 1", 30.0, 12.0, 14.0),
    ("skin 2", 38.0, 14.0, 17.0),
    ("skin 3", 46.0, 15.0, 19.0),
    ("skin 4", 54.0, 15.0, 20.0),
    ("skin 5", 62.0, 14.0, 19.0),
    ("skin 6", 69.0, 12.0, 17.0),
    ("skin 7", 75.0, 10.0, 15.0),
    ("skin 8", 81.0, 8.0, 13.0),
)
NEUTRALS = tuple(float(v) for v in np.linspace(15, 95, 12))
GROUPS = ("checker", "skin", "neutral", "photo")


def verification_colours(
    count: int = RANDOM_COLOURS,
) -> tuple[list[str], list[str], NDArray[np.float64]]:
    """(names, groups, wanted L*a*b*) of the verification page, unshuffled."""
    names = [c[0] for c in CHECKER] + [s[0] for s in SKIN]
    groups = ["checker"] * len(CHECKER) + ["skin"] * len(SKIN)
    labs = [c[1:] for c in CHECKER] + [s[1:] for s in SKIN]
    for l_star in NEUTRALS:
        names.append(f"grey L* {l_star:.0f}")
        groups.append("neutral")
        labs.append((l_star, 0.0, 0.0))
    srgb = np.random.default_rng(13).uniform(0.03, 0.97, (count, 3))
    photo = xyz_to_lab(d65_to_d50(linear_rgb_to_xyz(srgb_to_linear(srgb))), D50_WHITE)
    for i, rgb in enumerate(srgb):
        names.append(f"photo {i + 1} (sRGB {' '.join(str(round(255 * v)) for v in rgb)})")
        groups.append("photo")
    wanted = np.concatenate([np.array(labs, dtype=np.float64).reshape(-1, 3), photo])
    return names, groups, wanted


@dataclass(frozen=True, eq=False)
class VerificationTarget:
    """The verification page: what each patch sent, and what it should measure."""

    target: ColourTarget
    names: list[str]
    groups: list[str]
    wanted: NDArray[np.float64]
    printable: NDArray[np.bool_]  # the model expects the printer can make it

    def to_json(self) -> str:
        return json.dumps(
            {
                "kind": "openquad colour verification",
                "version": 1,
                "target": json.loads(self.target.to_json()),
                "names": self.names,
                "groups": self.groups,
                "wanted": np.round(self.wanted, 4).tolist(),
                "printable": self.printable.tolist(),
            }
        )

    @classmethod
    def from_json(cls, text: str) -> VerificationTarget:
        data = json.loads(text)
        if data.get("kind") != "openquad colour verification":
            raise ProfileError("not an OpenQuad colour verification layout")
        return cls(
            target=ColourTarget.from_json(json.dumps(data["target"])),
            names=list(data["names"]),
            groups=list(data["groups"]),
            wanted=np.array(data["wanted"], dtype=np.float64),
            printable=np.array(data["printable"], dtype=bool),
        )


def make_verification(model: ForwardModel, count: int = RANDOM_COLOURS) -> VerificationTarget:
    """The verification page for a profile's model: each colour sent as its inverse."""
    names, groups, wanted = verification_colours(count)
    rgb = invert(model, wanted)
    printable = np.sqrt(((model.lab(rgb) - wanted) ** 2).sum(axis=1)) <= GAMUT_LIMIT
    order = np.random.default_rng(SHUFFLE_SEED).permutation(len(wanted))
    sent = np.rint(rgb * MAX_VALUE).astype(np.uint16)
    return VerificationTarget(
        target=layout_target(sent[order]),
        names=[names[i] for i in order],
        groups=[groups[i] for i in order],
        wanted=wanted[order],
        printable=printable[order],
    )


@dataclass(frozen=True, eq=False)
class VerificationReport:
    """How close each verification colour printed to what was wanted."""

    verification: VerificationTarget
    measured: NDArray[np.float64]  # L*a*b* relative to the paper
    delta_e: NDArray[np.float64]

    def _group(self, group: str) -> NDArray[np.bool_]:
        result: NDArray[np.bool_] = np.array([g == group for g in self.verification.groups])
        return result

    @property
    def printable(self) -> NDArray[np.bool_]:
        return self.verification.printable

    @property
    def mean(self) -> float:
        return float(self.delta_e[self.printable].mean())

    @property
    def p95(self) -> float:
        return float(np.percentile(self.delta_e[self.printable], 95))

    def group_mean(self, group: str) -> float:
        chosen = self._group(group) & self.printable
        return float(self.delta_e[chosen].mean()) if chosen.any() else float("nan")

    @property
    def worst_cast(self) -> float:
        neutral = self._group("neutral") & self.printable
        return float(np.hypot(self.measured[neutral, 1], self.measured[neutral, 2]).max())

    @property
    def worst_tone(self) -> float:
        neutral = self._group("neutral") & self.printable
        return float(np.abs(self.measured[neutral, 0] - self.verification.wanted[neutral, 0]).max())

    @property
    def passed(self) -> bool:
        return (
            self.mean < MEAN_GOAL
            and self.p95 < P95_GOAL
            and self.worst_cast < CAST_GOAL
            and self.worst_tone < TONE_GOAL
        )

    def assessment(self) -> dict[str, float]:
        return {
            "mean": round(self.mean, 3),
            "p95": round(self.p95, 3),
            "checker": round(self.group_mean("checker"), 3),
            "skin": round(self.group_mean("skin"), 3),
            "photo": round(self.group_mean("photo"), 3),
            "worst_cast": round(self.worst_cast, 3),
            "worst_tone": round(self.worst_tone, 3),
            "printable": int(self.printable.sum()),
            "patches": len(self.delta_e),
        }

    def summary(self) -> str:
        def mark(ok: bool) -> str:
            return "ok" if ok else "not yet"

        a = self.assessment()
        outside = a["patches"] - a["printable"]
        worst = np.argsort(np.where(self.printable, self.delta_e, -1.0))[::-1][:3]
        lines = [
            f"{a['printable']} of {a['patches']} colours printable"
            f"{f' ({outside} outside the gamut, left out of the averages)' if outside else ''}.",
            f"ΔE00: mean {a['mean']:.2f} "
            f"(goal under {MEAN_GOAL:g}, {mark(self.mean < MEAN_GOAL)}), "
            f"95% {a['p95']:.2f} (goal under {P95_GOAL:g}, {mark(self.p95 < P95_GOAL)}).",
            f"Colour checker {a['checker']:.2f}, skin {a['skin']:.2f}, photo colours "
            f"{a['photo']:.2f} (means).",
            f"Greys: worst cast {a['worst_cast']:.1f} (goal under {CAST_GOAL:g}, "
            f"{mark(self.worst_cast < CAST_GOAL)}), worst tone {a['worst_tone']:.1f} L* "
            f"(goal under {TONE_GOAL:g}, {mark(self.worst_tone < TONE_GOAL)}).",
            "Furthest off: "
            + "; ".join(f"{self.verification.names[i]} {self.delta_e[i]:.1f}" for i in worst)
            + ".",
            "Goals met: done." if self.passed else "Goals not met: refine the profile.",
        ]
        return "\n".join(lines)

    def to_json(self) -> str:
        return json.dumps(
            {
                "kind": "openquad colour verification report",
                "version": 1,
                "assessment": self.assessment(),
                "passed": self.passed,
                "patches": [
                    {
                        "name": name,
                        "group": group,
                        "printable": bool(ok),
                        "wanted": np.round(want, 2).tolist(),
                        "measured": np.round(got, 2).tolist(),
                        "delta_e": round(float(de), 3),
                    }
                    for name, group, ok, want, got, de in zip(
                        self.verification.names,
                        self.verification.groups,
                        self.printable,
                        self.verification.wanted,
                        self.measured,
                        self.delta_e,
                        strict=True,
                    )
                ],
            },
            indent=1,
        )


def verify(measurement: ColourMeasurement, verification: VerificationTarget) -> VerificationReport:
    if not np.array_equal(measurement.sent, verification.target.sent):
        raise ProfileError("the measurement isn't of this verification page")
    return VerificationReport(
        verification=verification,
        measured=measurement.lab,
        delta_e=delta_e_2000(measurement.lab, verification.wanted),
    )


def refine(
    model: ForwardModel,
    measurement: ColourMeasurement,
    damping: float = DAMPING,
    smoothing: float = CORRECTION_SMOOTHING,
) -> ForwardModel:
    """The model, corrected towards what the verification page measured.

    The difference between measured and predicted at each RGB sent is fitted with a
    smooth lattice of its own, and `damping` of it is added, so one round can't
    overshoot and a stray patch can't put a dent in the model."""
    if not 0 < damping <= 1:
        raise ProfileError(f"damping must be over 0 and at most 1, got {damping:g}")
    rgb = measurement.sent / MAX_VALUE
    residual = measurement.lab - model.lab(rgb)
    correction = fit_lattice(rgb, residual, smoothing, model.size)
    return ForwardModel(model.nodes + damping * correction, model.smoothing, model.paper_xyz)


# --- a run of rounds -------------------------------------------------------------------


class ColourRunError(RuntimeError):
    """A step was taken out of order."""


@dataclass
class ColourRound:
    version: int
    profile: str
    model: str
    pages: list[str] = field(default_factory=list)
    layout: str | None = None
    scans: list[str] = field(default_factory=list)
    measurement: str | None = None
    report: str | None = None
    assessment: dict[str, float] | None = None
    action: str | None = None  # "done" or "refine"


@dataclass
class ColourRun:
    folder: Path
    name: str
    description: str
    rounds: list[ColourRound] = field(default_factory=list)

    @classmethod
    def start(
        cls,
        folder: str | Path,
        name: str,
        measurements: Sequence[ColourMeasurement],
        description: str = "",
    ) -> tuple[ColourRun, str]:
        """A new run in `folder` with a first profile built from the colour target's
        measurements. Returns the run and the profile's report."""
        if not name.strip() or any(c in name for c in "/\\"):
            raise ColourRunError(f"invalid profile name {name!r}")
        run = cls(Path(folder), name.strip(), description.strip() or name.strip())
        run.folder.mkdir(parents=True, exist_ok=True)
        report = build_profile(measurements)
        run._new_round(report.model)
        return run, report.summary()

    @classmethod
    def resume(cls, folder: str | Path) -> ColourRun:
        data = json.loads((Path(folder) / "run.json").read_text(encoding="utf-8"))
        if data.get("kind") != "openquad colour run":
            raise ColourRunError(f"{folder} isn't a colour calibration run")
        rounds = [ColourRound(**r) for r in data["rounds"]]
        return cls(Path(folder), data["name"], data["description"], rounds)

    def _save_log(self) -> None:
        data = {
            "kind": "openquad colour run",
            "name": self.name,
            "description": self.description,
            "rounds": [asdict(r) for r in self.rounds],
        }
        (self.folder / "run.json").write_text(json.dumps(data, indent=1) + "\n", encoding="utf-8")

    def _new_round(self, model: ForwardModel) -> None:
        version = len(self.rounds)
        stem = f"{self.name}-v{version}"
        (self.folder / f"{stem}.json").write_text(model.to_json() + "\n", encoding="utf-8")
        description = f"{self.description} (OpenQuad v{version})"
        (self.folder / f"{stem}.icc").write_bytes(icc_profile(model, description))
        self.rounds.append(ColourRound(version, f"{stem}.icc", f"{stem}.json"))
        self._save_log()

    @property
    def current(self) -> ColourRound:
        return self.rounds[-1]

    def model(self) -> ForwardModel:
        return ForwardModel.from_json((self.folder / self.current.model).read_text("utf-8"))

    def make_pages(self, dpi: float = 300.0) -> list[Path]:
        """Write this round's verification page(s), to print the way the target was."""
        verification = make_verification(self.model())
        stem = f"{self.name}-v{self.current.version}-verify"
        layout = self.folder / f"{stem}.json"
        layout.write_text(verification.to_json() + "\n", encoding="utf-8")
        pages = len(verification.target.pages)
        paths = []
        for page in range(pages):
            suffix = "" if pages == 1 else f"-{page + 1}of{pages}"
            path = self.folder / f"{stem}{suffix}.tif"
            save_rgb(path, target_page(verification.target, page, dpi), (dpi, dpi), srgb_profile())
            paths.append(path)
        self.current.layout = layout.name
        self.current.pages = [p.name for p in paths]
        self._save_log()
        return paths

    def verification(self) -> VerificationTarget:
        if not self.current.layout:
            raise ColourRunError("make this round's verification page first")
        text = (self.folder / self.current.layout).read_text(encoding="utf-8")
        return VerificationTarget.from_json(text)

    def measure(
        self, scans: Sequence[str | Path], scanner: ScannerModel | None = None
    ) -> VerificationReport:
        """Measure scans of this round's verification page, judge them against the goals
        and record the result. The scans are copied into the run's folder."""
        verification = self.verification()
        stem = f"{self.name}-v{self.current.version}"
        kept = []
        for i, scan in enumerate(scans):
            source = Path(scan)
            copy = self.folder / f"{stem}-scan{i + 1}{source.suffix}"
            if source.resolve() != copy.resolve():
                shutil.copyfile(source, copy)
            kept.append(copy)
        measurement = measure_target([load_scan(p) for p in kept], verification.target, scanner)
        save_measurement(measurement, self.folder / f"{stem}-measured.json")
        report = verify(measurement, verification)
        (self.folder / f"{stem}-report.json").write_text(report.to_json() + "\n", "utf-8")
        self.current.scans = [p.name for p in kept]
        self.current.measurement = f"{stem}-measured.json"
        self.current.report = f"{stem}-report.json"
        self.current.assessment = report.assessment()
        self.current.action = "done" if report.passed else "refine"
        self._save_log()
        return report

    def refine(self, damping: float = DAMPING) -> ColourRound:
        """Build the next round's profile from this round's measurements."""
        if not self.current.measurement:
            raise ColourRunError("measure this round's verification page first")
        text = (self.folder / self.current.measurement).read_text(encoding="utf-8")
        self._new_round(refine(self.model(), ColourMeasurement.from_json(text), damping))
        return self.current
