"""Building a printer's colour profile from measurements of the colour target (phase 2).

The printer is "sRGB-tagged RGB, sent this way, on this paper": the same path the
target took. From the target's measurements this builds

- a **forward model**, RGB sent to L*a*b* measured (relative to the paper): a lattice of
  9 x 9 x 9 points, interpolated trilinearly, fitted by least squares with a smoothing
  term so one bad patch can't put a dent in it. How much smoothing is chosen by leaving
  patches out and seeing which predicts them best;
- an **inverse**, L*a*b* wanted to RGB to send, found by searching the forward model:
  the nearest of a coarse grid of RGB, then refined. A colour the printer can't make is
  sent as the nearest one it can (relative colourimetric); the perceptual table first
  scales towards the printer's black (black-point compensation), so shadows keep their
  detail rather than all clipping to the same black;
- an **ICC v2 output profile** holding both (A2B0-2, B2A0-2) and a gamut tag, which
  OpenQuad, ColorSync and other apps can use.

L*a*b* here is under D50, relative to the paper (paper white is L* 100), as ICC profiles
use it.
"""

from __future__ import annotations

import json
import math
import struct
from collections.abc import Sequence
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path

import numpy as np
from numpy.typing import NDArray

from openquad.colour import D50_WHITE, delta_e_2000, lab_to_xyz, xyz_to_lab
from openquad.colour_target import ColourMeasurement
from openquad.quadfile import MAX_VALUE

LATTICE = 9  # forward model points along each RGB axis
SMOOTHING = (0.0001, 0.0003, 0.001, 0.003, 0.01, 0.03)  # tried, the best kept
FOLDS = 5
A2B_GRID = 17  # ICC table sizes
B2A_GRID = 33
SEARCH_GRID = 12  # coarse RGB grid the inverse starts from
GAMUT_LIMIT = 1.0  # ΔE76 beyond which a colour counts as out of gamut


class ProfileError(ValueError):
    """Measurements a profile can't be built from."""


# --- forward model ---------------------------------------------------------------------


def _cells(rgb: NDArray[np.float64], n: int) -> tuple[NDArray[np.intp], NDArray[np.float64]]:
    """Each point's lattice cell (lower corner index per axis) and position in it."""
    scaled = np.clip(rgb, 0.0, 1.0) * (n - 1)
    lower = np.minimum(np.floor(scaled).astype(np.intp), n - 2)
    return lower, scaled - lower


_CORNERS = np.array([[i, j, k] for i in (0, 1) for j in (0, 1) for k in (0, 1)])


def _weights(rgb: NDArray[np.float64], n: int) -> tuple[NDArray[np.intp], NDArray[np.float64]]:
    """(flat node index, weight) of each point's 8 surrounding lattice nodes."""
    lower, frac = _cells(rgb, n)
    corner = lower[:, None, :] + _CORNERS[None]  # (points, 8, 3)
    flat = (corner[..., 0] * n + corner[..., 1]) * n + corner[..., 2]
    w = np.where(_CORNERS[None] == 1, frac[:, None, :], 1 - frac[:, None, :]).prod(axis=-1)
    return flat, w


def _design(rgb: NDArray[np.float64], n: int) -> NDArray[np.float64]:
    flat, w = _weights(rgb, n)
    matrix = np.zeros((len(rgb), n**3))
    np.add.at(matrix, (np.arange(len(rgb))[:, None], flat), w)
    return matrix


def _roughness(n: int) -> NDArray[np.float64]:
    """Second differences along each axis of the lattice, one row per difference."""
    index = np.arange(n**3).reshape(n, n, n)
    rows = []
    for axis in range(3):
        a = np.moveaxis(index, axis, 0)
        for i in range(1, n - 1):
            for prev, here, nxt in zip(
                a[i - 1].ravel(), a[i].ravel(), a[i + 1].ravel(), strict=True
            ):
                row = np.zeros(n**3)
                row[[prev, here, nxt]] = (1.0, -2.0, 1.0)
                rows.append(row)
    return np.array(rows)


def _solve(
    design: NDArray[np.float64],
    lab: NDArray[np.float64],
    penalty: NDArray[np.float64],
    smoothing: float,
) -> NDArray[np.float64]:
    nodes: NDArray[np.float64] = np.linalg.solve(
        design.T @ design + smoothing * len(lab) * penalty, design.T @ lab
    )
    return nodes


@dataclass(frozen=True, eq=False)
class ForwardModel:
    """RGB sent (0-1) to L*a*b* measured, relative to the paper."""

    nodes: NDArray[np.float64]  # (n³, 3) L*a*b* at each lattice point
    smoothing: float = 0.0
    paper_xyz: NDArray[np.float64] = field(default_factory=lambda: D50_WHITE.copy())

    @property
    def size(self) -> int:
        return round(math.cbrt(len(self.nodes)))

    def lab(self, rgb: NDArray[np.float64]) -> NDArray[np.float64]:
        rgb = np.asarray(rgb, dtype=np.float64)
        flat, w = _weights(rgb.reshape(-1, 3), self.size)
        result: NDArray[np.float64] = (self.nodes[flat] * w[..., None]).sum(axis=1)
        return result.reshape(rgb.shape)

    def to_json(self) -> str:
        return json.dumps(
            {
                "kind": "openquad colour model",
                "version": 1,
                "smoothing": self.smoothing,
                "paper_xyz": self.paper_xyz.tolist(),
                "nodes": np.round(self.nodes, 4).tolist(),
            }
        )

    @classmethod
    def from_json(cls, text: str) -> ForwardModel:
        data = json.loads(text)
        if data.get("kind") != "openquad colour model":
            raise ProfileError("not an OpenQuad colour model")
        return cls(
            nodes=np.array(data["nodes"], dtype=np.float64),
            smoothing=float(data["smoothing"]),
            paper_xyz=np.array(data["paper_xyz"], dtype=np.float64),
        )


def _folds(count: int) -> list[NDArray[np.intp]]:
    order = np.random.default_rng(11).permutation(count)
    return [order[i::FOLDS] for i in range(FOLDS)]


def held_out_errors(
    rgb: NDArray[np.float64], lab: NDArray[np.float64], smoothing: float, n: int = LATTICE
) -> NDArray[np.float64]:
    """Each patch's ΔE00 when predicted by a model fitted without it (five folds)."""
    design, penalty = _design(rgb, n), _penalty(n)
    errors = np.zeros(len(rgb))
    for fold in _folds(len(rgb)):
        keep = np.ones(len(rgb), dtype=bool)
        keep[fold] = False
        nodes = _solve(design[keep], lab[keep], penalty, smoothing)
        errors[fold] = delta_e_2000(design[fold] @ nodes, lab[fold])
    return errors


_PENALTIES: dict[int, NDArray[np.float64]] = {}


def _penalty(n: int) -> NDArray[np.float64]:
    if n not in _PENALTIES:
        rough = _roughness(n)
        _PENALTIES[n] = rough.T @ rough
    return _PENALTIES[n]


def fit_forward(
    rgb: NDArray[np.float64],
    lab: NDArray[np.float64],
    smoothing: float | None = None,
    n: int = LATTICE,
    paper_xyz: NDArray[np.float64] | None = None,
) -> tuple[ForwardModel, NDArray[np.float64]]:
    """The forward model and each patch's held-out ΔE00.

    Without `smoothing`, each of `SMOOTHING` is tried and the one whose held-out
    predictions are best is kept."""
    rgb, lab = np.asarray(rgb, dtype=np.float64), np.asarray(lab, dtype=np.float64)
    if len(rgb) < 4 * n:
        raise ProfileError(f"need at least {4 * n} patches to fit the model, got {len(rgb)}")
    tried = (smoothing,) if smoothing is not None else SMOOTHING
    results = [(held_out_errors(rgb, lab, s, n), s) for s in tried]
    errors, best = min(results, key=lambda r: float(r[0].mean()))
    nodes = _solve(_design(rgb, n), lab, _penalty(n), best)
    paper = D50_WHITE.copy() if paper_xyz is None else np.asarray(paper_xyz, dtype=np.float64)
    return ForwardModel(nodes, best, paper), errors


# --- inverse ---------------------------------------------------------------------------


def black_point(model: ForwardModel) -> NDArray[np.float64]:
    """The deepest neutral the printer makes, as XYZ relative to the paper (D50 white)."""
    lightness = float(model.lab(np.zeros(3))[0])
    darkest = float(model.lab(np.linspace(0, 0.3, 31)[:, None].repeat(3, axis=1))[:, 0].min())
    y = float(lab_to_xyz(np.array([min(lightness, darkest), 0.0, 0.0]), D50_WHITE)[1])
    result: NDArray[np.float64] = y * D50_WHITE
    return result


def compensate_black(lab: NDArray[np.float64], black: NDArray[np.float64]) -> NDArray[np.float64]:
    """Scale colours towards the printer's black so L* 0 lands on it (black-point
    compensation, as Adobe's: linear in XYZ, white kept)."""
    xyz = lab_to_xyz(lab, D50_WHITE)
    return xyz_to_lab(xyz * (1 - black / D50_WHITE) + black, D50_WHITE)


def invert(model: ForwardModel, lab: NDArray[np.float64], steps: int = 8) -> NDArray[np.float64]:
    """The RGB (0-1) whose print comes closest to each L*a*b* (ΔE76): the best of a coarse
    grid, then refined by Gauss-Newton steps kept inside the RGB cube."""
    lab = np.asarray(lab, dtype=np.float64).reshape(-1, 3)
    levels = np.linspace(0, 1, SEARCH_GRID)
    grid = np.stack(np.meshgrid(levels, levels, levels, indexing="ij"), axis=-1).reshape(-1, 3)
    grid_lab = model.lab(grid)
    rgb = np.empty_like(lab)
    for start in range(0, len(lab), 4096):  # nearest grid point, a chunk at a time
        chunk = lab[start : start + 4096]
        d = (
            (chunk**2).sum(axis=1)[:, None]
            - 2 * chunk @ grid_lab.T
            + (grid_lab**2).sum(axis=1)[None]
        )
        rgb[start : start + 4096] = grid[np.argmin(d, axis=1)]
    h = 1e-3
    for _ in range(steps):
        here = model.lab(rgb)
        residual = lab - here
        jac = np.empty((len(rgb), 3, 3))
        for axis in range(3):
            step = np.zeros(3)
            step[axis] = h
            ahead = np.where(rgb[:, axis : axis + 1] + h <= 1, rgb + step, rgb - step)
            sign = np.where(rgb[:, axis] + h <= 1, 1.0, -1.0)
            jac[:, :, axis] = (model.lab(ahead) - here) / (h * sign[:, None])
        # Damped least squares (Levenberg-Marquardt) so flat spots don't blow up.
        jt = np.transpose(jac, (0, 2, 1))
        normal = jt @ jac + 1e-3 * np.eye(3)
        delta = np.linalg.solve(normal, (jt @ residual[..., None]))[..., 0]
        trial = np.clip(rgb + delta, 0.0, 1.0)
        better = ((lab - model.lab(trial)) ** 2).sum(axis=1) < (residual**2).sum(axis=1)
        rgb[better] = trial[better]
    return rgb


# --- ICC -------------------------------------------------------------------------------


def _s15(value: float) -> bytes:
    return struct.pack(">i", round(value * 65536))


def _xyz_tag(xyz: NDArray[np.float64]) -> bytes:
    return b"XYZ \0\0\0\0" + b"".join(_s15(float(v)) for v in xyz)


def _text_tag(text: str) -> bytes:
    return b"text\0\0\0\0" + text.encode("ascii", "replace") + b"\0"


def _desc_tag(text: str) -> bytes:
    ascii_text = text.encode("ascii", "replace") + b"\0"
    return (
        b"desc\0\0\0\0"
        + struct.pack(">I", len(ascii_text))
        + ascii_text
        + struct.pack(">II", 0, 0)  # no Unicode
        + struct.pack(">HB", 0, 0)
        + bytes(67)  # no ScriptCode
    )


def encode_lab(lab: NDArray[np.float64]) -> NDArray[np.uint16]:
    """L*a*b* as ICC v2 16-bit (L* 100 = 0xFF00, a*/b* 0 = 0x8000)."""
    l_star = np.clip(lab[..., 0], 0.0, 100.0) * 652.80
    ab = (np.clip(lab[..., 1:], -128.0, 255 / 256 + 127) + 128) * 256
    return np.rint(np.concatenate([l_star[..., None], ab], axis=-1)).astype(np.uint16)


def decode_lab(encoded: NDArray[np.float64]) -> NDArray[np.float64]:
    """ICC v2 16-bit L*a*b* back to L*a*b*."""
    encoded = np.asarray(encoded, dtype=np.float64)
    return np.concatenate([encoded[..., :1] / 652.80, encoded[..., 1:] / 256 - 128], axis=-1)


def _lut16(table: NDArray[np.uint16], inputs: int, grid: int) -> bytes:
    """An mft2 (lut16Type) tag with straight input and output curves."""
    outputs = int(table.shape[-1])
    identity = b"".join(_s15(v) for v in (1, 0, 0, 0, 1, 0, 0, 0, 1))
    straight = struct.pack(">HH", 0, 0xFFFF)
    return (
        b"mft2\0\0\0\0"
        + bytes([inputs, outputs, grid, 0])
        + identity
        + struct.pack(">HH", 2, 2)
        + straight * inputs
        + bytes(table.astype(">u2").tobytes())
        + straight * outputs
    )


def _lab_grid(grid: int) -> NDArray[np.float64]:
    """The L*a*b* at each point of a grid over the ICC v2 encoding, L* slowest."""
    codes = np.linspace(0, 65535, grid)
    l_code, a_code, b_code = np.meshgrid(codes, codes, codes, indexing="ij")
    return decode_lab(np.stack([l_code, a_code, b_code], axis=-1).reshape(-1, 3))


@dataclass(frozen=True, eq=False)
class ProfileTables:
    """What goes in the profile, as arrays (and what the report is worked out from)."""

    a2b: NDArray[np.float64]  # (A2B_GRID³, 3) L*a*b* for an RGB grid
    b2a_perceptual: NDArray[np.float64]  # (B2A_GRID³, 3) RGB 0-1 for a L*a*b* grid
    b2a_colourimetric: NDArray[np.float64]
    gamut: NDArray[np.float64]  # (B2A_GRID³,) ΔE76 of the nearest printable colour


def build_tables(model: ForwardModel) -> ProfileTables:
    levels = np.linspace(0, 1, A2B_GRID)
    rgb = np.stack(np.meshgrid(levels, levels, levels, indexing="ij"), axis=-1).reshape(-1, 3)
    wanted = _lab_grid(B2A_GRID)
    colourimetric = invert(model, wanted)
    gamut = np.sqrt(((model.lab(colourimetric) - wanted) ** 2).sum(axis=1))
    perceptual = invert(model, compensate_black(wanted, black_point(model)))
    return ProfileTables(model.lab(rgb), perceptual, colourimetric, gamut)


def icc_profile(
    model: ForwardModel,
    description: str,
    tables: ProfileTables | None = None,
    copyright_text: str = "No copyright; made with OpenQuad",
    created: datetime | None = None,
) -> bytes:
    """An ICC v2 output profile (RGB device, L*a*b* PCS) for the model."""
    tables = tables or build_tables(model)
    a2b = _lut16(encode_lab(tables.a2b), 3, A2B_GRID)

    def device(rgb: NDArray[np.float64]) -> NDArray[np.uint16]:
        return np.rint(np.clip(rgb, 0, 1) * MAX_VALUE).astype(np.uint16)

    perceptual = _lut16(device(tables.b2a_perceptual), 3, B2A_GRID)
    colourimetric = _lut16(device(tables.b2a_colourimetric), 3, B2A_GRID)
    out_of_gamut = np.clip((tables.gamut - GAMUT_LIMIT) / 9.0, 0.0, 1.0)
    gamut = _lut16(device(out_of_gamut[:, None]), 3, B2A_GRID)
    black = black_point(model) * model.paper_xyz / D50_WHITE  # absolute, as wtpt is
    tags = [
        (b"desc", _desc_tag(description)),
        (b"cprt", _text_tag(copyright_text)),
        (b"wtpt", _xyz_tag(model.paper_xyz)),
        (b"bkpt", _xyz_tag(black)),
        (b"A2B0", a2b),
        (b"A2B1", a2b),
        (b"A2B2", a2b),
        (b"B2A0", perceptual),
        (b"B2A1", colourimetric),
        (b"B2A2", perceptual),
        (b"gamt", gamut),
    ]
    # Tags that are the same bytes share one copy.
    offset = 128 + 4 + 12 * len(tags)
    body = b""
    placed: dict[bytes, tuple[int, int]] = {}
    table = struct.pack(">I", len(tags))
    for signature, data in tags:
        if data not in placed:
            placed[data] = (offset + len(body), len(data))
            body += data + bytes(-len(data) % 4)
        start, size = placed[data]
        table += signature + struct.pack(">II", start, size)
    when = created or datetime.now(UTC)
    size = 128 + len(table) + len(body)
    header = (
        struct.pack(">I", size)
        + b"\0\0\0\0"  # preferred CMM: none
        + struct.pack(">I", 0x02100000)  # version 2.1
        + b"prtrRGB Lab "
        + struct.pack(">6H", when.year, when.month, when.day, when.hour, when.minute, when.second)
        + b"acsp"
        + b"APPL"
        + bytes(4)  # flags
        + bytes(4)  # manufacturer
        + bytes(4)  # model
        + bytes(8)  # attributes: reflective, glossy
        + struct.pack(">I", 0)  # rendering intent: perceptual
        + _xyz_tag(D50_WHITE)[8:]  # PCS illuminant
        + b"OpQd"  # creator
    )
    header += bytes(128 - len(header))
    return header + table + body


# --- building, with a report -----------------------------------------------------------


def _average(
    measurements: Sequence[ColourMeasurement],
) -> tuple[
    NDArray[np.float64], NDArray[np.float64], NDArray[np.float64], NDArray[np.float64] | None
]:
    """(RGB sent 0-1, mean L*a*b*, mean paper XYZ, each print's ΔE00 from the mean)."""
    if not measurements:
        raise ProfileError("no measurements")
    sent = measurements[0].sent
    for m in measurements[1:]:
        if not np.array_equal(m.sent, sent):
            raise ProfileError("the measurements are of different targets")
    labs = np.array([m.lab for m in measurements])
    mean = labs.mean(axis=0)
    paper = np.array([m.paper_xyz for m in measurements]).mean(axis=0)
    spread = None
    if len(measurements) > 1:
        spread = np.array([delta_e_2000(lab, mean) for lab in labs])
    return sent / MAX_VALUE, mean, paper, spread


@dataclass(frozen=True, eq=False)
class ProfileReport:
    model: ForwardModel
    tables: ProfileTables
    fitted: NDArray[np.float64]  # each patch's ΔE00 against the model
    held_out: NDArray[np.float64]  # ... against a model fitted without it
    neutral_cast: NDArray[
        np.float64
    ]  # C* of the print of each grey L* (10-95), sent by the inverse
    spread: NDArray[np.float64] | None  # each print's ΔE00 from the mean, if several
    prints: int

    def summary(self) -> str:
        black = self.model.lab(np.zeros(3))
        corners = self.model.lab(
            np.array([[1, 0, 0], [0, 1, 0], [0, 0, 1], [0, 1, 1], [1, 0, 1], [1, 1, 0]], float)
        )
        chroma = np.hypot(corners[:, 1], corners[:, 2])
        lines = [
            f"Model from {len(self.fitted)} patches"
            f"{f', averaged over {self.prints} prints' if self.prints > 1 else ''} "
            f"(smoothing {self.model.smoothing:g}).",
            f"Fit: mean {self.fitted.mean():.2f}, 95% {np.percentile(self.fitted, 95):.2f} ΔE00.",
            f"Patches left out: mean {self.held_out.mean():.2f}, "
            f"95% {np.percentile(self.held_out, 95):.2f}, worst {self.held_out.max():.2f} ΔE00.",
            f"Black: L* {black[0]:.1f}, a* {black[1]:.1f}, b* {black[2]:.1f}; primaries reach "
            f"chroma {chroma.min():.0f} to {chroma.max():.0f}.",
            f"Greys through the profile: worst cast {self.neutral_cast.max():.2f} "
            f"(mean {self.neutral_cast.mean():.2f}).",
        ]
        if self.spread is not None:
            lines.append(
                f"Between prints: mean {self.spread.mean():.2f}, "
                f"worst {self.spread.max():.2f} ΔE00."
            )
        return "\n".join(lines)


def build_profile(
    measurements: Sequence[ColourMeasurement], smoothing: float | None = None
) -> ProfileReport:
    """Fit the forward model to one or more prints' measurements, and work out the
    profile's tables."""
    rgb, lab, paper, spread = _average(measurements)
    model, held_out = fit_forward(rgb, lab, smoothing, paper_xyz=paper)
    fitted = delta_e_2000(model.lab(rgb), lab)
    greys = np.stack([np.linspace(10, 95, 18), np.zeros(18), np.zeros(18)], axis=-1)
    printed = model.lab(invert(model, compensate_black(greys, black_point(model))))
    cast = np.hypot(printed[:, 1], printed[:, 2])
    return ProfileReport(
        model=model,
        tables=build_tables(model),
        fitted=fitted,
        held_out=held_out,
        neutral_cast=cast,
        spread=spread,
        prints=len(measurements),
    )


def save_profile(report: ProfileReport, path: str | Path, description: str) -> Path:
    """Write the ICC profile and, beside it, the forward model as JSON (for checking
    prints later). Returns the model's path."""
    path = Path(path)
    path.write_bytes(icc_profile(report.model, description, report.tables))
    model_path = path.with_suffix(".json")
    model_path.write_text(report.model.to_json() + "\n", encoding="utf-8")
    return model_path
