"""How a flatbed scanner sees colour, measured from an IT8.7/2 target (colour calibration,
phase 0).

Grey calibration only needs a scanner to see near-neutral greys consistently. Colour
calibration needs it to see colour correctly, and a flatbed isn't a colorimeter. This
module measures how far off it is, using an IT8.7/2 reflective target and the reference
file that comes with it (CGATS text: each patch's L*a*b* under D50).

The target has 12 rows (A-L) of 22 patches and a row of 24 greys (GS0-GS23). The scan is
located from five patch centres picked on it: A1, A22 and L1 for the grid, GS0 and GS23
for the greys. Each patch is sampled over its central half (median, as `measure` does).

The scanner model has two parts:

- one curve per channel, from the grey row, that turns what the scanner reports into the
  reference lightness (Y) of a grey of that value; and
- a fit from those three values to CIE XYZ (D50): a 3x3 matrix with an offset ("matrix"),
  or with second-order terms ("poly") if the matrix leaves too much error.

The fit is judged by CIEDE2000 against the reference, on the patches it was fitted to and,
more honestly, column by column on patches it wasn't fitted to (held out). Scans of the same
target made at different times give the scanner's repeatability. Phase 0 is a go/no-go: the
rest of colour calibration is only worth building if the held-out error and the
repeatability meet `GO_MEAN` and `GO_REPEAT`.
"""

from __future__ import annotations

import json
import re
from collections.abc import Sequence
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
from numpy.typing import NDArray

from openquad.colour import D50_WHITE, delta_e_2000, lab_to_xyz, xyz_to_lab

ROWS = "ABCDEFGHIJKL"
COLUMNS = 22
GREYS = 24
SAMPLE = 0.5  # fraction of each patch sampled
CURVE_POINTS = 256
KINDS = ("matrix", "poly")
GO_MEAN = 2.0  # held-out mean CIEDE2000
GO_REPEAT = 1.0  # mean CIEDE2000 between scans

Point = tuple[float, float]


class ScannerProfileError(ValueError):
    """The reference file, scan or corners can't be used."""


def grid_ids() -> list[str]:
    """The grid patches' ids, row by row: A1 ... L22."""
    return [f"{row}{column}" for row in ROWS for column in range(1, COLUMNS + 1)]


def grey_ids() -> list[str]:
    """The grey row's ids, lightest first: GS0 ... GS23."""
    return [f"GS{i}" for i in range(GREYS)]


def normalise_id(sample_id: str) -> str:
    """A patch id in one spelling: "A01" -> "A1", "GS00" -> "GS0", "gs5" -> "GS5"."""
    text = sample_id.strip().strip('"').upper()
    match = re.fullmatch(r"(GS|[A-L])0*(\d+)", text)
    return f"{match.group(1)}{int(match.group(2))}" if match else text


# --- the reference file ----------------------------------------------------------------


@dataclass(frozen=True)
class Reference:
    """A target's reference data: L*a*b* (D50) for each patch id."""

    lab: dict[str, NDArray[np.float64]]
    description: str = ""

    def lab_of(self, ids: Sequence[str]) -> NDArray[np.float64]:
        missing = [i for i in ids if i not in self.lab]
        if missing:
            raise ScannerProfileError(
                f"the reference file has no data for {', '.join(missing[:5])}"
                + (f" and {len(missing) - 5} more" if len(missing) > 5 else "")
            )
        return np.array([self.lab[i] for i in ids])


def parse_reference(text: str) -> Reference:
    """Read CGATS reference data (the IT8.7/2 file sold with the target).

    Uses the LAB_L, LAB_A and LAB_B fields if there are any, else XYZ_X, XYZ_Y and XYZ_Z
    (0-100 or 0-1), converted under D50."""
    lines = [line.strip() for line in text.splitlines()]
    try:
        start = lines.index("BEGIN_DATA_FORMAT")
        end = lines.index("END_DATA_FORMAT", start)
        data_start = lines.index("BEGIN_DATA", end)
        data_end = lines.index("END_DATA", data_start)
    except ValueError:
        raise ScannerProfileError("not a CGATS reference file (no data format or data)") from None
    fields = " ".join(lines[start + 1 : end]).split()
    header = dict(line.split(None, 1) for line in lines[:start] if " " in line)
    description = header.get("DESCRIPTOR", header.get("ORIGINATOR", "")).strip('"')
    if "SAMPLE_ID" in fields:
        id_field = fields.index("SAMPLE_ID")
    elif "SAMPLE_NAME" in fields:
        id_field = fields.index("SAMPLE_NAME")
    else:
        raise ScannerProfileError("the reference file has no SAMPLE_ID field")
    if {"LAB_L", "LAB_A", "LAB_B"} <= set(fields):
        columns, use_lab = [fields.index(f) for f in ("LAB_L", "LAB_A", "LAB_B")], True
    elif {"XYZ_X", "XYZ_Y", "XYZ_Z"} <= set(fields):
        columns, use_lab = [fields.index(f) for f in ("XYZ_X", "XYZ_Y", "XYZ_Z")], False
    else:
        raise ScannerProfileError("the reference file has neither L*a*b* nor XYZ fields")
    ids: list[str] = []
    values: list[list[float]] = []
    for line in lines[data_start + 1 : data_end]:
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < len(fields):
            raise ScannerProfileError(f"short data line in the reference file: {line!r}")
        ids.append(normalise_id(parts[id_field]))
        values.append([float(parts[c]) for c in columns])
    if not ids:
        raise ScannerProfileError("the reference file has no data")
    array = np.array(values)
    if not use_lab:
        xyz = array / 100.0 if array[:, 1].max() > 1.5 else array
        array = xyz_to_lab(xyz, D50_WHITE)
    return Reference(lab=dict(zip(ids, array, strict=True)), description=description)


def read_reference(path: str | Path) -> Reference:
    return parse_reference(Path(path).read_text(encoding="utf-8", errors="replace"))


# --- finding and sampling the patches --------------------------------------------------


@dataclass(frozen=True)
class Corners:
    """Patch centres picked on a scan, in pixels (x right, y down)."""

    a1: Point
    a22: Point
    l1: Point
    gs0: Point
    gs23: Point

    @classmethod
    def parse(cls, text: str) -> Corners:
        """From "x,y x,y x,y x,y x,y": A1, A22, L1, GS0, GS23."""
        try:
            points = [tuple(float(v) for v in pair.split(",")) for pair in text.split()]
        except ValueError:
            points = []
        if len(points) != 5 or any(len(p) != 2 for p in points):
            raise ScannerProfileError(
                f"corners must be five x,y points (A1 A22 L1 GS0 GS23), got {text!r}"
            )
        return cls(*points)  # type: ignore[arg-type]

    def centres(self) -> dict[str, Point]:
        """Every patch's centre."""
        a1, a22, l1 = (np.array(p) for p in (self.a1, self.a22, self.l1))
        across, down = (a22 - a1) / (COLUMNS - 1), (l1 - a1) / (len(ROWS) - 1)
        found: dict[str, Point] = {}
        for r, row in enumerate(ROWS):
            for c in range(COLUMNS):
                x, y = a1 + c * across + r * down
                found[f"{row}{c + 1}"] = (float(x), float(y))
        gs0, gs23 = np.array(self.gs0), np.array(self.gs23)
        step = (gs23 - gs0) / (GREYS - 1)
        for i in range(GREYS):
            x, y = gs0 + i * step
            found[f"GS{i}"] = (float(x), float(y))
        return found

    def half_sizes(self) -> dict[str, Point]:
        """Half the sampled box's width and height for each patch."""
        pitch_x = float(np.hypot(*np.subtract(self.a22, self.a1))) / (COLUMNS - 1)
        pitch_y = float(np.hypot(*np.subtract(self.l1, self.a1))) / (len(ROWS) - 1)
        grey_x = float(np.hypot(*np.subtract(self.gs23, self.gs0))) / (GREYS - 1)
        grid = (pitch_x * SAMPLE / 2, pitch_y * SAMPLE / 2)
        grey = (grey_x * SAMPLE / 2, pitch_y * SAMPLE / 2)
        return {i: grid for i in grid_ids()} | {i: grey for i in grey_ids()}


def sample_scan(scan: NDArray[np.float64], corners: Corners) -> dict[str, NDArray[np.float64]]:
    """The median scanner RGB (as the scanner encoded it, 0-1) of every patch."""
    height, width = scan.shape[:2]
    half = corners.half_sizes()
    samples: dict[str, NDArray[np.float64]] = {}
    for patch, (x, y) in corners.centres().items():
        hw, hh = half[patch]
        left, right = round(x - hw), round(x + hw)
        top, bottom = round(y - hh), round(y + hh)
        if left < 0 or top < 0 or right > width or bottom > height:
            raise ScannerProfileError(f"patch {patch} is off the scan; check the corners")
        region = scan[top:bottom, left:right, :3]
        if region.shape[0] < 2 or region.shape[1] < 2:
            raise ScannerProfileError(
                "the patches are too small to sample; scan at 300 ppi or more"
            )
        samples[patch] = np.median(region.reshape(-1, 3), axis=0)
    return samples


def draw_boxes(scan: NDArray[np.float64], corners: Corners) -> NDArray[np.uint8]:
    """The scan (8-bit) with each sampled box outlined in red, to check the corners."""
    image = (np.clip(scan[..., :3], 0, 1) * 255).round().astype(np.uint8)
    height, width = image.shape[:2]
    half = corners.half_sizes()
    for patch, (x, y) in corners.centres().items():
        hw, hh = half[patch]
        left, right = max(round(x - hw), 0), min(round(x + hw), width - 1)
        top, bottom = max(round(y - hh), 0), min(round(y + hh), height - 1)
        for row in (top, bottom):
            image[row, left : right + 1] = (255, 0, 0)
        for column in (left, right):
            image[top : bottom + 1, column] = (255, 0, 0)
    return image


# --- the scanner model -----------------------------------------------------------------


def _terms(values: NDArray[np.float64], kind: str) -> NDArray[np.float64]:
    r, g, b = values[..., 0], values[..., 1], values[..., 2]
    ones = np.ones_like(r)
    if kind == "matrix":
        return np.stack([r, g, b, ones], axis=-1)
    return np.stack([r, g, b, r * g, r * b, g * b, r * r, g * g, b * b, r * g * b, ones], axis=-1)


def _grey_curves(
    grey_rgb: NDArray[np.float64], grey_lab: NDArray[np.float64]
) -> NDArray[np.float64]:
    """Per-channel curves (3, CURVE_POINTS) from scanner value (0-1) to reference Y."""
    target = lab_to_xyz(grey_lab, D50_WHITE)[:, 1]
    grid = np.linspace(0.0, 1.0, CURVE_POINTS)
    curves = np.empty((3, CURVE_POINTS))
    for c in range(3):
        order = np.argsort(grey_rgb[:, c], kind="stable")
        x, y = grey_rgb[order, c], np.maximum.accumulate(target[order])
        keep = np.concatenate([[True], np.diff(x) > 1e-6])
        x, y = x[keep], y[keep]
        if len(x) < 2:
            raise ScannerProfileError("the grey row doesn't change on the scan; check the corners")
        # Straight on past the darkest and lightest greys, from their two nearest points.
        low = y[0] - (y[1] - y[0]) / (x[1] - x[0]) * x[0]
        high = y[-1] + (y[-1] - y[-2]) / (x[-1] - x[-2]) * (1.0 - x[-1])
        if x[0] > 0:
            x, y = np.concatenate([[0.0], x]), np.concatenate([[max(low, 0.0)], y])
        if x[-1] < 1:
            x, y = np.concatenate([x, [1.0]]), np.concatenate([y, [high]])
        curves[c] = np.maximum.accumulate(np.interp(grid, x, y))
    return curves


@dataclass(frozen=True)
class ScannerModel:
    """Scanner RGB (0-1, as encoded) to CIE XYZ and L*a*b* under D50."""

    kind: str
    curves: NDArray[np.float64]  # (3, CURVE_POINTS)
    coefficients: NDArray[np.float64]  # (terms, 3)
    scanner: str = ""
    reference: str = ""

    def linear(self, rgb: NDArray[np.float64]) -> NDArray[np.float64]:
        grid = np.linspace(0.0, 1.0, CURVE_POINTS)
        values = np.asarray(rgb, dtype=np.float64)
        return np.stack([np.interp(values[..., c], grid, self.curves[c]) for c in range(3)], -1)

    def to_xyz(self, rgb: NDArray[np.float64]) -> NDArray[np.float64]:
        result: NDArray[np.float64] = _terms(self.linear(rgb), self.kind) @ self.coefficients
        return result

    def to_lab(self, rgb: NDArray[np.float64]) -> NDArray[np.float64]:
        return xyz_to_lab(np.maximum(self.to_xyz(rgb), 0.0), D50_WHITE)

    def to_json(self) -> str:
        return json.dumps(
            {
                "kind": self.kind,
                "scanner": self.scanner,
                "reference": self.reference,
                "curves": np.round(self.curves, 7).tolist(),
                "coefficients": self.coefficients.tolist(),
            },
            indent=1,
        )

    @classmethod
    def from_json(cls, text: str) -> ScannerModel:
        data = json.loads(text)
        if data.get("kind") not in KINDS:
            raise ScannerProfileError(f"unknown scanner model kind {data.get('kind')!r}")
        return cls(
            kind=data["kind"],
            curves=np.array(data["curves"], dtype=np.float64),
            coefficients=np.array(data["coefficients"], dtype=np.float64),
            scanner=data.get("scanner", ""),
            reference=data.get("reference", ""),
        )


def fit_model(
    rgb: NDArray[np.float64],
    lab: NDArray[np.float64],
    grey_rgb: NDArray[np.float64],
    grey_lab: NDArray[np.float64],
    kind: str = "matrix",
) -> ScannerModel:
    """Fit a scanner model to patches with known L*a*b* (D50).

    Least squares in XYZ, weighted so a dark patch counts as much as a light one does in
    L*a*b* (L* changes as the cube root of Y)."""
    if kind not in KINDS:
        raise ScannerProfileError(f"unknown model {kind!r}; choose from {', '.join(KINDS)}")
    curves = _grey_curves(grey_rgb, grey_lab)
    shell = ScannerModel(kind, curves, np.zeros((_terms(np.zeros(3), kind).size, 3)))
    all_rgb, all_lab = np.concatenate([rgb, grey_rgb]), np.concatenate([lab, grey_lab])
    xyz = lab_to_xyz(all_lab, D50_WHITE)
    terms = _terms(shell.linear(all_rgb), kind)
    weights = 1.0 / np.maximum(xyz[:, 1], 0.01) ** (2.0 / 3.0)
    coefficients, *_ = np.linalg.lstsq(terms * weights[:, None], xyz * weights[:, None], rcond=None)
    return ScannerModel(kind, curves, coefficients)


# --- judging it ------------------------------------------------------------------------


@dataclass(frozen=True)
class Errors:
    """CIEDE2000 errors, one per patch."""

    ids: tuple[str, ...]
    delta_e: NDArray[np.float64]

    @property
    def mean(self) -> float:
        return float(self.delta_e.mean())

    @property
    def p95(self) -> float:
        return float(np.percentile(self.delta_e, 95))

    @property
    def worst(self) -> tuple[str, float]:
        i = int(np.argmax(self.delta_e))
        return self.ids[i], float(self.delta_e[i])

    def summary(self) -> str:
        worst_id, worst = self.worst
        return f"mean {self.mean:.2f}, 95% {self.p95:.2f}, worst {worst:.2f} ({worst_id})"


@dataclass(frozen=True)
class Report:
    """How well a scanner model reads the target, and the go/no-go verdict."""

    model: ScannerModel
    fitted: Errors
    held_out: Errors
    repeat: Errors | None = None
    scans: int = 1
    notes: list[str] = field(default_factory=list)

    @property
    def go(self) -> bool:
        repeat_ok = self.repeat is None or self.repeat.mean <= GO_REPEAT
        return self.held_out.mean <= GO_MEAN and repeat_ok

    def summary(self) -> str:
        lines = [
            f"Model: {self.model.kind}, from {self.scans} scan{'s' if self.scans != 1 else ''}.",
            f"Fitted patches (CIEDE2000): {self.fitted.summary()}.",
            f"Held-out patches (CIEDE2000): {self.held_out.summary()} "
            f"(goal: mean {GO_MEAN:g} or less).",
        ]
        if self.repeat is None:
            lines.append("Repeatability: not measured (needs two or more scans).")
        else:
            lines.append(
                f"Repeatability between scans: {self.repeat.summary()} "
                f"(goal: mean {GO_REPEAT:g} or less)."
            )
        lines += self.notes
        if self.go:
            lines.append(
                "Verdict: GO. This scanner can measure colour well enough to calibrate with."
            )
        else:
            lines.append(
                "Verdict: NO-GO. Colour calibration with this scanner would be guesswork; "
                "it can still check prints for consistency."
            )
        return "\n".join(lines)


def _held_out(
    ids: list[str],
    rgb: NDArray[np.float64],
    lab: NDArray[np.float64],
    grey_rgb: NDArray[np.float64],
    grey_lab: NDArray[np.float64],
    kind: str,
) -> Errors:
    """Each grid column predicted by a model fitted without it."""
    columns = np.array([int(i[1:]) for i in ids])
    predicted = np.empty_like(lab)
    for column in np.unique(columns):
        out = columns == column
        model = fit_model(rgb[~out], lab[~out], grey_rgb, grey_lab, kind)
        predicted[out] = model.to_lab(rgb[out])
    return Errors(tuple(ids), delta_e_2000(lab, predicted))


def repeatability(
    samples: Sequence[NDArray[np.float64]], model: ScannerModel, ids: Sequence[str]
) -> Errors:
    """How far each scan's reading of each patch is from the average of all the scans."""
    labs = np.array([model.to_lab(s) for s in samples])
    mean = labs.mean(axis=0)
    spread = np.array([delta_e_2000(lab, mean) for lab in labs]).max(axis=0)
    return Errors(tuple(ids), spread.astype(np.float64))


def profile_scanner(
    scans: Sequence[NDArray[np.float64]],
    corners: Sequence[Corners],
    reference: Reference,
    kind: str = "auto",
    scanner: str = "",
    reference_name: str = "",
) -> Report:
    """Fit a scanner model to one or more scans of the target and judge it.

    The model is fitted to the average of the scans; `kind` "auto" tries both models and
    keeps the polynomial only if it does clearly better on held-out patches."""
    if not scans:
        raise ScannerProfileError("no scans")
    if len(corners) == 1:
        corners = list(corners) * len(scans)
    if len(corners) != len(scans):
        raise ScannerProfileError(
            f"{len(scans)} scans but {len(corners)} sets of corners; give one set, or one per scan"
        )
    grid, greys = grid_ids(), grey_ids()
    lab, grey_lab = reference.lab_of(grid), reference.lab_of(greys)
    sampled = [sample_scan(scan, c) for scan, c in zip(scans, corners, strict=True)]
    each_rgb = [np.array([s[i] for i in grid]) for s in sampled]
    each_grey = [np.array([s[i] for i in greys]) for s in sampled]
    rgb, grey_rgb = np.mean(each_rgb, axis=0), np.mean(each_grey, axis=0)

    kinds = KINDS if kind == "auto" else (kind,)
    if kind != "auto" and kind not in KINDS:
        raise ScannerProfileError(f"unknown model {kind!r}; choose from auto, {', '.join(KINDS)}")
    held = {k: _held_out(grid, rgb, lab, grey_rgb, grey_lab, k) for k in kinds}
    chosen = kinds[0]
    if kind == "auto" and held["poly"].mean < 0.9 * held["matrix"].mean:
        chosen = "poly"
    notes = []
    if kind == "auto":
        notes.append(
            "Held-out mean: matrix "
            + f"{held['matrix'].mean:.2f}, poly {held['poly'].mean:.2f}; using {chosen}."
        )
    fitted_model = fit_model(rgb, lab, grey_rgb, grey_lab, chosen)
    model = ScannerModel(
        chosen, fitted_model.curves, fitted_model.coefficients, scanner, reference_name
    )
    fitted = Errors(tuple(grid), delta_e_2000(lab, model.to_lab(rgb)))
    repeat = (
        repeatability(
            [np.concatenate([r, g]) for r, g in zip(each_rgb, each_grey, strict=True)],
            model,
            grid + greys,
        )
        if len(scans) > 1
        else None
    )
    return Report(model, fitted, held[chosen], repeat, len(scans), notes)


def save_report(report: Report, path: str | Path) -> None:
    """The model and its report as JSON."""
    data = json.loads(report.model.to_json())
    data["report"] = {
        "scans": report.scans,
        "go": report.go,
        "fitted": {"mean": report.fitted.mean, "p95": report.fitted.p95},
        "held_out": {"mean": report.held_out.mean, "p95": report.held_out.p95},
        "repeat": None
        if report.repeat is None
        else {"mean": report.repeat.mean, "p95": report.repeat.p95},
        "held_out_by_patch": dict(
            zip(report.held_out.ids, np.round(report.held_out.delta_e, 3).tolist(), strict=True)
        ),
    }
    Path(path).write_text(json.dumps(data, indent=1) + "\n", encoding="utf-8")


def load_model(path: str | Path) -> ScannerModel:
    return ScannerModel.from_json(Path(path).read_text(encoding="utf-8"))
