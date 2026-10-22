"""Multi-layer colour toning: layer coloured inks over a greyscale image.

Emulates printing from several stacked negatives (e.g. a black key layer plus a
red layer). Each layer's tone curve says how strongly its ink prints at each
tone; the layers combine subtractively, like stacked transparent pigments, and
the result is a 16-bit sRGB image for any colour printer (the composite path).

Conventions:
- Tone positions run from 0.0 (paper white) to 1.0 (full density), measured on
  the encoded greyscale value: position = 1 - pixel / 65535.
- A layer's ramp value is its *perceptual* strength: a black layer whose ramp
  equals the position reproduces the original greyscale image exactly.
- Mixing happens in linear light: each layer multiplies the reflected light by
  (1 - strength * (1 - ink colour)).
"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass

import numpy as np
from numpy.typing import NDArray

from openquad.colour import linear_to_srgb, srgb_to_linear
from openquad.curves import InkSpec, RampShape
from openquad.quadfile import MAX_VALUE


@dataclass(frozen=True)
class ColourLayer:
    """One toning layer: an ink colour and the tones it prints in.

    `colour` is the ink's sRGB colour (0-1 per channel) at full strength on white
    paper. `tone` sets where and how strongly it prints; its `channel` field is
    unused here and can be any label.
    """

    name: str
    colour: tuple[float, float, float]
    tone: InkSpec

    def __post_init__(self) -> None:
        if len(self.colour) != 3 or not all(0.0 <= c <= 1.0 for c in self.colour):
            raise ValueError(f"{self.name}: colour must be three values within 0-1")

    def strength(self, positions: NDArray[np.float64]) -> NDArray[np.float64]:
        """Linear-light ink coverage (0-1) at each tone position."""
        perceptual = self.tone.ramp(positions)
        return 1.0 - srgb_to_linear(1.0 - perceptual)


def _layer(
    name: str,
    colour: tuple[float, float, float],
    *,
    shape: RampShape = "smooth",
    **tone: float,
) -> ColourLayer:
    return ColourLayer(name, colour, InkSpec(name, shape=shape, **tone))


BLACK = (0.0, 0.0, 0.0)
# Colour toning is always an explicit choice; without one, prints stay neutral.
DEFAULT_PRESET = "neutral"
PRESETS: dict[str, tuple[ColourLayer, ...]] = {
    "neutral": (_layer("black", BLACK, shape="linear", limit=100.0, start=0.0, peak=1.0),),
    "black-red": (
        _layer("black", BLACK, limit=100.0, start=0.35, peak=1.0),
        _layer("red", (0.78, 0.12, 0.12), limit=75.0, start=0.0, peak=0.55, end=1.0),
    ),
    "red-only": (_layer("red", (0.78, 0.12, 0.12), limit=75.0, start=0.0, peak=0.55, end=1.0),),
    "warm-split": (
        _layer("black", BLACK, limit=100.0, start=0.2, peak=1.0),
        _layer("sepia", (0.62, 0.42, 0.24), limit=60.0, start=0.0, peak=0.5, end=0.9),
    ),
}


def composite(
    image: NDArray[np.uint16],
    layers: Sequence[ColourLayer],
    *,
    chunk_rows: int = 512,
) -> NDArray[np.uint16]:
    """Render the layers over a greyscale image as 16-bit sRGB, shape (height, width, 3)."""
    if image.dtype != np.uint16:
        raise TypeError(f"image must be uint16, got {image.dtype}")
    if image.ndim != 2:
        raise ValueError(f"image must be 2-D greyscale, got shape {image.shape}")
    if chunk_rows < 1:
        raise ValueError(f"chunk_rows must be at least 1, got {chunk_rows}")
    names = [layer.name for layer in layers]
    if len(set(names)) != len(names):
        raise ValueError(f"layer names must be unique, got {names}")

    absorb = [1.0 - srgb_to_linear(np.array(layer.colour, dtype=np.float64)) for layer in layers]
    height, width = image.shape
    out = np.empty((height, width, 3), dtype=np.uint16)
    for top in range(0, height, chunk_rows):
        positions = 1.0 - image[top : top + chunk_rows].astype(np.float64) / MAX_VALUE
        light = np.ones((*positions.shape, 3), dtype=np.float64)
        for layer, absorption in zip(layers, absorb, strict=True):
            light *= 1.0 - layer.strength(positions)[..., np.newaxis] * absorption
        out[top : top + chunk_rows] = np.rint(linear_to_srgb(light) * MAX_VALUE)
    return out
