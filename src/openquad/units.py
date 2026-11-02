"""Lengths shown in inches or millimetres.

OpenQuad works in inches throughout (files, settings, the command line); the unit only
changes what people see and type in the app and in a session's summary.
"""

from __future__ import annotations

UNITS = ("in", "mm")
MM_PER_INCH = 25.4


def check(units: str) -> str:
    if units not in UNITS:
        raise ValueError(f"units must be one of {', '.join(UNITS)}, got {units!r}")
    return units


def to_unit(inches: float, units: str) -> float:
    """Inches as a number in `units`."""
    return inches * MM_PER_INCH if check(units) == "mm" else inches


def from_unit(value: float, units: str) -> float:
    """A number in `units` as inches."""
    return value / MM_PER_INCH if check(units) == "mm" else value


def _trim(text: str) -> str:
    return text.rstrip("0").rstrip(".")


def length(inches: float, units: str) -> str:
    """A short length such as an edge: "0.25 in" or "6.35 mm" (to 0.01 mm)."""
    if check(units) == "mm":
        return f"{_trim(f'{inches * MM_PER_INCH:.2f}')} mm"
    return f"{inches:g} in"


def box(width: float, height: float, units: str) -> str:
    """A set size: "8 x 10 in" or "203.2 x 254 mm"."""
    if check(units) == "mm":
        w, h = (_trim(f"{v * MM_PER_INCH:.2f}") for v in (width, height))
        return f"{w} x {h} mm"
    return f"{width:g} x {height:g} in"


def size(width: float, height: float, units: str) -> str:
    """A printed size: "7.50 x 5.00 in" or "190.5 x 127.0 mm"."""
    if check(units) == "mm":
        return f"{width * MM_PER_INCH:.1f} x {height * MM_PER_INCH:.1f} mm"
    return f"{width:.2f} x {height:.2f} in"
