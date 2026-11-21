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
    if side not in ("top", "bottom", "left", "right") or not _number(gap):
        return None
    steps, width, style = value.get("steps"), value.get("width"), value.get("style")
    return {"grey": value.get("grey") is True, "colour": value.get("colour") is True,
            "side": side, "gap": min(max(float(gap), 0.0), 2.0),  # type: ignore[arg-type]
            "separate": value.get("separate") is True,
            "steps": steps if steps in (11, 21, 31, 51) and not isinstance(steps, bool) else 31,
            "width": min(max(float(width), 0.2), 1.0) if _number(width) else 0.4,  # type: ignore[arg-type]
            "style": style if style in ("strip", "calibration") else "strip",
            "labels": value.get("labels") is True,
            "background": value.get("background")
            if value.get("background") in ("colour", "black", "white") else "colour"}  # fmt: skip


def _number(value: object) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)
