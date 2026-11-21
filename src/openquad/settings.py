"""Remembered app settings (printer, paper, calibration, last folder).

The colour preset is deliberately not remembered: every session starts neutral,
so black + red (or any toning) is always a fresh, explicit choice.
"""

from __future__ import annotations

import json
import os
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path

from openquad import wedge as wedges


def default_path() -> Path:
    override = os.environ.get("OPENQUAD_SETTINGS")
    if override:
        return Path(override)
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "OpenQuad" / "settings.json"
    return Path.home() / ".config" / "openquad" / "settings.json"


def data_dir() -> Path:
    """Where the app keeps its own files (calibrations, scans), next to the settings."""
    return default_path().parent


@dataclass
class Settings:
    printer: str | None = None
    scanner_host: str | None = None
    paper: str = "Letter"
    calibration: str | None = None
    last_folder: str | None = None
    process: str | None = None  # digital negative process curve
    negative_colour: str = "green"
    max_size: list[float] | None = None  # fit within (width, height) inches, e.g. the tissue
    units: str = "in"  # lengths shown in the app: "in" or "mm"
    # The Mac app's Negative tab keeps its own printer and paper (None: as above).
    negative_printer: str | None = None
    negative_paper: str | None = None
    # Each tab's page turned on its side (landscape).
    landscape: bool = False
    negative_landscape: bool = False
    # The test sheets' preferred size (blocking test, process charts): fit within (width,
    # height) inches; None for their own size.
    chart_size: list[float] | None = None
    # The ICC profile the Mac app soft-proofs colour prints with (None: no soft-proof).
    proof_profile: str | None = None
    # Driver options (media type, quality) chosen for each printer when printing straight to
    # it, for prints and for negatives: {printer: {option: value}}.
    printer_options: dict[str, dict[str, str]] = field(default_factory=dict)
    negative_printer_options: dict[str, dict[str, str]] = field(default_factory=dict)
    # The step wedges each tab prints beside the photo: {"grey": bool, "colour": bool,
    # "side": "top" | "bottom" | "left" | "right", "gap": inches}; None for none chosen yet.
    print_wedge: dict[str, object] | None = None
    negative_wedge: dict[str, object] | None = None
    # Whether each tab fits the darkroom marks' border within the printable area with the
    # photo (False: the photo alone fits; the border lies outside it).
    marks_in_fit: bool = True
    negative_marks_in_fit: bool = True

    @classmethod
    def load(cls, path: Path | None = None) -> Settings:
        path = path or default_path()
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return cls()
        if not isinstance(data, dict):
            return cls()
        known = {k: v for k, v in data.items() if k in cls.__dataclass_fields__}
        for key in ("printer_options", "negative_printer_options"):
            known[key] = _options(known.get(key))
        for key in ("print_wedge", "negative_wedge"):
            known[key] = _wedge(known.get(key))
        for key in ("marks_in_fit", "negative_marks_in_fit"):
            known[key] = known.get(key) is not False
        for key in ("landscape", "negative_landscape"):
            known[key] = known.get(key) is True
        return cls(**known)

    def save(self, path: Path | None = None) -> None:
        path = path or default_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(asdict(self), indent=1) + "\n", encoding="utf-8")


def _options(value: object) -> dict[str, dict[str, str]]:
    """Printer options as saved, keeping only {printer: {option: value}} strings."""
    if not isinstance(value, dict):
        return {}
    return {
        printer: {k: v for k, v in chosen.items() if isinstance(k, str) and isinstance(v, str)}
        for printer, chosen in value.items()
        if isinstance(printer, str) and isinstance(chosen, dict)
    }


def _wedge(value: object) -> dict[str, object] | None:
    """A tab's step wedges as saved, or None if they aren't readable."""
    if not isinstance(value, dict):
        return None
    side, gap = value.get("side"), value.get("gap")
    if side not in wedges.SIDES or not _number(gap):
        return None
    steps, width = value.get("steps"), value.get("width")
    return {
        "grey": value.get("grey") is True,
        "colour": value.get("colour") is True,
        "side": side,
        "gap": _clamp(gap, 0.0, wedges.MAX_GAP),
        "separate": value.get("separate") is True,
        "steps": steps if _number(steps) and steps in wedges.STEP_CHOICES else wedges.WEDGE_STEPS,
        "width": _clamp(width, wedges.MIN_WIDTH, wedges.MAX_WIDTH)
        if _number(width)
        else wedges.WEDGE_WIDTH,
        "style": _choice(value.get("style"), wedges.STYLES),
        "labels": value.get("labels") is True,
        "background": _choice(value.get("background"), wedges.BACKGROUNDS),
    }


def _choice(value: object, choices: tuple[str, ...]) -> str:
    """`value` if it is one of `choices`, else the first (the default)."""
    return value if isinstance(value, str) and value in choices else choices[0]


def _clamp(value: object, low: float, high: float) -> float:
    return min(max(float(value), low), high)  # type: ignore[arg-type]  # checked by _number


def _number(value: object) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)
