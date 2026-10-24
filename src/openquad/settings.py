"""Remembered app settings (printer, paper, calibration, last folder).

The colour preset is deliberately not remembered: every session starts neutral,
so black + red (or any toning) is always a fresh, explicit choice.
"""

from __future__ import annotations

import json
import os
import sys
from dataclasses import asdict, dataclass
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
        return cls(**known)

    def save(self, path: Path | None = None) -> None:
        path = path or default_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(asdict(self), indent=1) + "\n", encoding="utf-8")
