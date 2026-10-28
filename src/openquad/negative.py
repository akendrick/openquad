"""Digital negatives for contact printing (first target: carbon transfer).

A negative is the photo inverted (light tones get the most ink, so they block
the most UV), optionally mirrored, printed in black or a UV-blocking colour,
inside an opaque safe edge. An orientation mark ("F") is cut out of the safe
edge: it lets light through, so it shows up in the contact print and tells you
whether the mirror setting was right (it reads correctly when it is).

Values here are encoded sRGB 16-bit RGB sent to the printer's normal driver
(the composite path). Process calibration (step 3) will reshape tones first.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
from numpy.typing import NDArray

from openquad.colour import linear_to_srgb, srgb_to_linear
from openquad.quadfile import MAX_VALUE

# Candidate negative colours (sRGB 0-1). UV blocking matters, not how dark they look:
# yellow, orange and green inks usually block the near-UV that exposes carbon tissue.
NEGATIVE_COLOURS: dict[str, tuple[float, float, float]] = {
    "black": (0.0, 0.0, 0.0),
    "green": (0.10, 0.45, 0.20),
    "orange": (0.95, 0.45, 0.05),
    "yellow": (1.0, 0.85, 0.0),
    "red": (0.85, 0.10, 0.10),
    "olive": (0.40, 0.40, 0.0),
    # Single printer inks and simple two-ink mixes, for the ink-mixture chart.
    "magenta": (0.90, 0.10, 0.52),
    "blue": (0.0, 0.06, 0.47),
    "cyan": (0.0, 0.62, 0.90),
    "yellow-green": (0.50, 0.75, 0.05),
}
DEFAULT_COLOUR = "black"
# The blocking test's usual six colours, and the ink-mixture chart's ten (printable colours
# made from single inks and simple two-ink mixes).
STANDARD_COLOURS: tuple[str, ...] = ("black", "green", "orange", "yellow", "red", "olive")
MIXTURE_COLOURS: tuple[str, ...] = (
    "yellow", "orange", "red", "magenta", "blue", "cyan", "green", "yellow-green", "olive", "black",
)  # fmt: skip

# 5 x 7 cell bitmap of the letter F: asymmetric both ways, so a mirror flip shows.
F_GLYPH = np.array(
    [
        [1, 1, 1, 1, 1],
        [1, 0, 0, 0, 0],
        [1, 0, 0, 0, 0],
        [1, 1, 1, 1, 0],
        [1, 0, 0, 0, 0],
        [1, 0, 0, 0, 0],
        [1, 0, 0, 0, 0],
    ],
    dtype=bool,
)


@dataclass(frozen=True)
class NegativeSettings:
    colour: str = DEFAULT_COLOUR
    mirror: bool = False
    safe_edge: float = 0.25  # inches of opaque border; 0 for none
    mark: bool = True  # cut an orientation "F" into the safe edge

    def __post_init__(self) -> None:
        if self.colour not in NEGATIVE_COLOURS:
            raise ValueError(
                f"unknown negative colour {self.colour!r}; "
                f"choose from {', '.join(NEGATIVE_COLOURS)}"
            )
        if not 0.0 <= self.safe_edge <= 2.0:
            raise ValueError(f"safe edge must be 0-2 in, got {self.safe_edge}")


def ink_to_rgb(
    coverage: NDArray[np.float64], colour: tuple[float, float, float]
) -> NDArray[np.uint16]:
    """Ink coverage 0-1 (perceptual, like a colour layer) in `colour`, as 16-bit sRGB."""
    linear_ink = srgb_to_linear(np.asarray(colour, dtype=np.float64))
    strength = 1.0 - srgb_to_linear(1.0 - np.clip(coverage, 0.0, 1.0))
    light = 1.0 - strength[..., np.newaxis] * (1.0 - linear_ink)
    result: NDArray[np.uint16] = np.rint(linear_to_srgb(light) * MAX_VALUE).astype(np.uint16)
    return result


def make_negative(
    photo: NDArray[np.uint16], settings: NegativeSettings, dpi: float
) -> NDArray[np.uint16]:
    """Render a greyscale photo (0 black, 65535 white) as a negative, (H, W, 3) uint16 sRGB."""
    if photo.dtype != np.uint16 or photo.ndim != 2:
        raise ValueError("photo must be a 2-D uint16 greyscale array")
    coverage = photo.astype(np.float64) / MAX_VALUE  # white in the print = most ink
    image = ink_to_rgb(coverage, NEGATIVE_COLOURS[settings.colour])
    return add_safe_edge(image, settings, dpi)


def add_safe_edge(
    image: NDArray[np.uint16], settings: NegativeSettings, dpi: float
) -> NDArray[np.uint16]:
    """Surround with the opaque border (and orientation mark), then mirror if asked.

    The mark is added before mirroring, so on the film it reads backwards exactly
    when the image does; in the contact print it reads correctly when mirroring
    was right for the process.
    """
    edge = round(settings.safe_edge * dpi)
    if edge > 0:
        h, w = image.shape[:2]
        # The safe edge uses the negative's own colour: on coated office film, black
        # blocked less UV than the coloured inks (first carbon test, 23 Oct 2026).
        ink = ink_to_rgb(np.ones(1), NEGATIVE_COLOURS[settings.colour])[0]
        framed = np.empty((h + 2 * edge, w + 2 * edge, 3), dtype=np.uint16)
        framed[:] = ink
        framed[edge : edge + h, edge : edge + w] = image
        if settings.mark:
            cell = max(1, edge * 6 // 10 // F_GLYPH.shape[0])
            glyph = np.kron(F_GLYPH, np.ones((cell, cell), dtype=bool))
            top = left = (edge - glyph.shape[0]) // 2
            if glyph.shape[0] < edge and glyph.shape[1] < edge:
                region = framed[top : top + glyph.shape[0], left : left + glyph.shape[1]]
                region[glyph] = MAX_VALUE  # clear film: light gets through
        image = framed
    if settings.mirror:
        image = image[:, ::-1]
    return np.ascontiguousarray(image)


def negative_ppi(
    width_px: int, height_px: int, paper: str, safe_edge: float, margin: float
) -> float:
    """Resolution at which the photo plus its safe edge fit within the page's margins."""
    from openquad.paper import PAPER_SIZES

    if paper not in PAPER_SIZES:
        raise ValueError(f"unknown paper {paper!r}")
    paper_w, paper_h = PAPER_SIZES[paper]
    room_w, room_h = paper_w - 2 * margin - 2 * safe_edge, paper_h - 2 * margin - 2 * safe_edge
    if room_w <= 0 or room_h <= 0:
        raise ValueError(f"no room for the photo on {paper} with these margins and safe edge")
    return max(width_px / room_w, height_px / room_h)
