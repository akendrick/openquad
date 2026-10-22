"""Load a photo for printing: any greyscale image, whatever it was saved as.

Real files come in many forms: 8- or 16-bit, greyscale saved as RGB, with an
alpha channel, with a transparent band left from canvas resizing. `load_photo`
turns all of these into 16-bit greyscale (0 black, 65535 white):

- fully transparent edges are cropped off;
- partly transparent pixels are placed on paper white (not black);
- greyscale stored as RGB is read as greyscale;
- a true colour image is converted by luminance, and `converted` says so.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import numpy as np
import tifffile
from numpy.typing import NDArray
from PIL import Image

from openquad.colour import linear_to_srgb, luminance, srgb_to_linear
from openquad.imageio import ImageFormatError, read_dpi
from openquad.quadfile import MAX_VALUE

GREY_TOLERANCE = 2 / 255  # channels within this count as grey (JPEG noise)


@dataclass(frozen=True, eq=False)
class Photo:
    """A photo ready for toning and printing."""

    pixels: NDArray[np.uint16]
    dpi: tuple[float, float] | None
    converted: bool = False  # was a colour image, converted by luminance
    cropped: bool = False  # transparent edges were removed

    @property
    def size(self) -> tuple[int, int]:
        """(width, height) in pixels."""
        return (int(self.pixels.shape[1]), int(self.pixels.shape[0]))


def _read(path: Path) -> tuple[NDArray[np.float64], bool, bool, tuple[float, float] | None]:
    """Pixels as floats 0-1 (H, W, C), whether alpha is premultiplied, min-is-white, dpi."""
    if path.suffix.lower() in (".tif", ".tiff"):
        with tifffile.TiffFile(path) as tif:
            page = tif.pages.first
            if not isinstance(page, tifffile.TiffPage):  # pragma: no cover - defensive
                raise ImageFormatError(f"{path}: no readable image page")
            raw = np.asarray(page.asarray())
            premultiplied = tifffile.EXTRASAMPLE.ASSOCALPHA in tuple(page.extrasamples or ())
            min_is_white = page.photometric == tifffile.PHOTOMETRIC.MINISWHITE
        dpi = read_dpi(path)
    else:
        with Image.open(path) as image:
            info_dpi = image.info.get("dpi")
            if image.mode in ("I;16", "I;16B", "I"):
                raw = np.asarray(image).astype(np.uint16)
            else:
                mode = "LA" if image.mode in ("L", "LA", "P", "1") else "RGBA"
                raw = np.asarray(image.convert(mode))
        premultiplied, min_is_white = False, False
        dpi = (float(info_dpi[0]), float(info_dpi[1])) if info_dpi else None
    if raw.dtype == np.uint8:
        scale = 255.0
    elif raw.dtype == np.uint16:
        scale = 65535.0
    else:
        raise ImageFormatError(f"{path}: expected 8- or 16-bit pixels, got {raw.dtype}")
    pixels = raw.astype(np.float64) / scale
    if pixels.ndim == 2:
        pixels = pixels[..., np.newaxis]
    if pixels.ndim != 3 or pixels.shape[-1] not in (1, 2, 3, 4):
        raise ImageFormatError(f"{path}: unsupported image shape {raw.shape}")
    return pixels, premultiplied, min_is_white, dpi


def load_photo(path: str | Path) -> Photo:
    """Load a photo as 16-bit greyscale; see the module docstring for what's handled."""
    path = Path(path)
    pixels, premultiplied, min_is_white, dpi = _read(path)
    channels = pixels.shape[-1]
    has_alpha = channels in (2, 4)
    colour = pixels[..., : channels - 1] if has_alpha else pixels
    alpha = pixels[..., -1] if has_alpha else None

    cropped = False
    if alpha is not None:
        rows = np.flatnonzero(alpha.max(axis=1) > 0)
        cols = np.flatnonzero(alpha.max(axis=0) > 0)
        if len(rows) == 0:
            raise ImageFormatError(f"{path}: the image is fully transparent")
        if len(rows) < alpha.shape[0] or len(cols) < alpha.shape[1]:
            cropped = True
            window = (slice(rows[0], rows[-1] + 1), slice(cols[0], cols[-1] + 1))
            colour, alpha = colour[window], alpha[window]

    converted = False
    if colour.shape[-1] == 3:
        spread = colour.max(axis=-1) - colour.min(axis=-1)
        if spread.max() > GREY_TOLERANCE:
            converted = True
            grey = linear_to_srgb(luminance(srgb_to_linear(colour)))
        else:
            grey = colour.mean(axis=-1)
    else:
        grey = colour[..., 0]

    if min_is_white:
        grey = 1.0 - grey
    if alpha is not None:
        # Place on white paper: premultiplied colour + (1 - alpha), else blend.
        grey = grey + (1.0 - alpha) if premultiplied else grey * alpha + (1.0 - alpha)
    out = np.rint(np.clip(grey, 0.0, 1.0) * MAX_VALUE).astype(np.uint16)
    return Photo(pixels=out, dpi=dpi, converted=converted, cropped=cropped)
