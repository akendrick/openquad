"""Grey balance for the composite path: per-channel R, G, B correction curves.

A printer that builds grey from coloured inks often prints neutral RGB with a
cast. From a measured neutral wedge, `build_calibration` finds, for each step,
the R, G and B values that make the print neutral at the lightness it measured
(tone is left alone; linearization is a separate step). Repeat print, scan,
measure, build to refine: each pass uses what was actually sent.

A calibration is only valid for the printer, paper and driver settings it was
made with, so the file records them.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path

import numpy as np
from numpy.typing import NDArray

from openquad.colour import luminance
from openquad.measure import Measurement
from openquad.quadfile import MAX_VALUE
from openquad.targets import framed_target, wedge_levels

CHANNELS = ("R", "G", "B")
FORMAT = "openquad-calibration"


class CalibrationError(ValueError):
    """A calibration file is malformed or doesn't fit the data."""


@dataclass(frozen=True, eq=False)
class Calibration:
    """Per-channel curves: grey level in (0-65535) to the value to send, per channel.

    `levels` are ascending input levels; `curves[c][i]` is what channel c sends
    for input `levels[i]`. Values in between are interpolated linearly.
    """

    levels: NDArray[np.uint16]
    curves: NDArray[np.uint16]
    printer: str = ""
    paper: str = ""
    settings: str = ""
    created: str = field(default_factory=lambda: datetime.now(UTC).isoformat(timespec="seconds"))

    def __post_init__(self) -> None:
        levels = np.asarray(self.levels)
        curves = np.asarray(self.curves)
        if levels.ndim != 1 or len(levels) < 2 or np.any(np.diff(levels.astype(int)) <= 0):
            raise CalibrationError("levels must be at least 2 strictly ascending values")
        if curves.shape != (3, len(levels)):
            raise CalibrationError(f"curves must have shape (3, {len(levels)}), got {curves.shape}")
        if curves.min() < 0 or curves.max() > MAX_VALUE:
            raise CalibrationError(f"curve values must be within 0-{MAX_VALUE}")
        object.__setattr__(self, "levels", levels.astype(np.uint16))
        object.__setattr__(self, "curves", curves.astype(np.uint16))

    @classmethod
    def identity(cls, steps: int = 21) -> Calibration:
        levels = wedge_levels(steps)[::-1].copy()
        return cls(levels=levels, curves=np.tile(levels, (3, 1)))

    def luts(self) -> NDArray[np.uint16]:
        """(3, 65536) lookup tables."""
        x = np.arange(MAX_VALUE + 1, dtype=np.float64)
        rows = [np.interp(x, self.levels, curve) for curve in self.curves.astype(np.float64)]
        return np.rint(np.stack(rows)).astype(np.uint16)

    def apply(self, rgb: NDArray[np.uint16]) -> NDArray[np.uint16]:
        """Correct a 16-bit RGB image (..., 3)."""
        if rgb.dtype != np.uint16 or rgb.shape[-1] != 3:
            raise CalibrationError("apply needs a uint16 array with 3 channels last")
        luts = self.luts()
        out = np.empty_like(rgb)
        for c in range(3):
            out[..., c] = luts[c][rgb[..., c]]
        return out

    def sent_for(self, levels: NDArray[np.uint16]) -> NDArray[np.uint16]:
        """The RGB sent for each neutral input level, shape (n, 3)."""
        grey = np.repeat(np.asarray(levels, dtype=np.uint16)[:, np.newaxis], 3, axis=1)
        return self.apply(grey)

    def to_json(self) -> str:
        return json.dumps(
            {
                "format": FORMAT,
                "version": 1,
                "printer": self.printer,
                "paper": self.paper,
                "settings": self.settings,
                "created": self.created,
                "levels": self.levels.tolist(),
                "curves": dict(zip(CHANNELS, self.curves.tolist(), strict=True)),
            },
            indent=1,
        )

    @classmethod
    def from_json(cls, text: str) -> Calibration:
        try:
            data = json.loads(text)
        except json.JSONDecodeError as exc:
            raise CalibrationError(f"not valid JSON: {exc}") from None
        if not isinstance(data, dict) or data.get("format") != FORMAT:
            raise CalibrationError("not an OpenQuad calibration file")
        if data.get("version") != 1:
            raise CalibrationError(f"unsupported calibration version {data.get('version')}")
        return cls(
            levels=np.array(data["levels"], dtype=np.int64).astype(np.uint16),
            curves=np.array([data["curves"][c] for c in CHANNELS], dtype=np.int64),
            printer=data.get("printer", ""),
            paper=data.get("paper", ""),
            settings=data.get("settings", ""),
            created=data.get("created", ""),
        )


def load_calibration(path: str | Path) -> Calibration:
    return Calibration.from_json(Path(path).read_text(encoding="utf-8"))


def save_calibration(calibration: Calibration, path: str | Path) -> None:
    Path(path).write_text(calibration.to_json() + "\n", encoding="utf-8")


SHADOW_LEVEL = 13107  # step 17 of 21 and darker: where the Canon switches to pigment black


def build_calibration(
    measurement: Measurement,
    *,
    damping: float = 1.0,
    shadow_damping: float | None = None,
    shadow_level: int = SHADOW_LEVEL,
    printer: str = "",
    paper: str = "",
    settings: str = "",
) -> Calibration:
    """Per-channel curves that make each measured step neutral at its own lightness.

    Each channel's response (value sent -> linear light measured) is treated as
    monotonic and inverted at the target, which is the step's measured luminance
    on all three channels. Paper white and the deepest black are kept as sent.

    `damping` (0-1) applies only that fraction of the proposed change to what was
    sent, so a pass can't overshoot where the printer responds unevenly.
    `shadow_damping`, if given, replaces it for levels at or below `shadow_level`.
    """
    for name, value in (("damping", damping), ("shadow_damping", shadow_damping)):
        if value is not None and not 0.0 <= value <= 1.0:
            raise CalibrationError(f"{name} must be within 0-1, got {value}")
    order = np.argsort(measurement.levels)
    levels = measurement.levels[order]
    sent = measurement.sent[order].astype(np.float64)
    measured = measurement.rgb[order]
    target = np.clip(luminance(measured), 0.0, None)

    curves = np.empty((3, len(levels)), dtype=np.float64)
    for c in range(3):
        by_sent = np.argsort(sent[:, c], kind="stable")
        x = sent[by_sent, c]
        response = np.maximum.accumulate(measured[by_sent, c])
        response = response + np.arange(len(response)) * 1e-9  # strictly increasing
        curves[c] = np.interp(target, response, x)
    strength = np.where(
        levels <= shadow_level, damping if shadow_damping is None else shadow_damping, damping
    )
    curves = sent.T + strength * (curves - sent.T)
    curves[:, -1] = MAX_VALUE  # paper white stays paper
    curves[:, 0] = sent[0]  # deepest black stays as sent
    curves = np.maximum.accumulate(np.clip(curves, 0, MAX_VALUE), axis=1)
    return Calibration(
        levels=levels,
        curves=np.rint(curves).astype(np.uint16),
        printer=printer,
        paper=paper,
        settings=settings,
    )


def comparison_page(calibration: Calibration, dpi: float = 300.0) -> NDArray[np.uint16]:
    """One page: the uncorrected target above, the corrected one below.

    Scanned together, both get identical scanner processing. The uncorrected
    target is marked with one black square at its left, the corrected with two.
    """
    plain = framed_target(dpi=dpi)
    corrected = calibration.apply(plain)
    h, w = plain.shape[:2]
    gap, mark, lead, pad = (round(inches * dpi) for inches in (1.0, 0.15, 0.4, 0.07))
    page = np.full((2 * h + gap, w + lead, 3), MAX_VALUE, dtype=np.uint16)
    page[:h, lead:] = plain
    page[h + gap :, lead:] = corrected
    for count, top in ((1, 0), (2, h + gap)):
        for i in range(count):
            y = top + pad + i * (mark + pad)
            page[y : y + mark, pad : pad + mark] = 0
    return page
