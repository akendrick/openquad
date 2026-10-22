"""Paper sizes and fitting an image to the page."""

from __future__ import annotations

# (width, height) in inches, portrait. Names match the CUPS PageSize names.
PAPER_SIZES: dict[str, tuple[float, float]] = {
    "Letter": (8.5, 11.0),
    "Legal": (8.5, 14.0),
    "A4": (8.27, 11.69),
    "A5": (5.83, 8.27),
    "4x6": (4.0, 6.0),
    "5x7": (5.0, 7.0),
    "8x10": (8.0, 10.0),
}
DEFAULT_MARGIN = 0.5  # inches on every side


def fit_ppi(width_px: int, height_px: int, paper: str, margin: float = DEFAULT_MARGIN) -> float:
    """The resolution that makes the image as large as fits within the page's margins."""
    if paper not in PAPER_SIZES:
        raise ValueError(f"unknown paper {paper!r}; choose from {', '.join(PAPER_SIZES)}")
    if width_px < 1 or height_px < 1:
        raise ValueError("image has no pixels")
    paper_w, paper_h = PAPER_SIZES[paper]
    usable_w, usable_h = paper_w - 2 * margin, paper_h - 2 * margin
    if usable_w <= 0 or usable_h <= 0:
        raise ValueError(f"a {margin} in margin leaves no room on {paper}")
    return max(width_px / usable_w, height_px / usable_h)


def print_size(width_px: int, height_px: int, ppi: float) -> tuple[float, float]:
    """(width, height) in inches at `ppi`."""
    return (width_px / ppi, height_px / ppi)
