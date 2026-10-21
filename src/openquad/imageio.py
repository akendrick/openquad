"""Load and save 16-bit greyscale TIFFs, keeping resolution and ICC profile."""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import tifffile
from numpy.typing import NDArray

from openquad.quadfile import MAX_VALUE

_ICC_TAG = 34675
_CM_PER_INCH = 2.54


class ImageFormatError(ValueError):
    """The image can't be used for greyscale printing."""


@dataclass(frozen=True, eq=False)
class GreyImage:
    """A greyscale image: 0 = black, 65535 = white."""

    pixels: NDArray[np.uint16]
    dpi: tuple[float, float] | None = None
    icc_profile: bytes | None = None


def _dpi(page: tifffile.TiffPage) -> tuple[float, float] | None:
    tags = page.tags
    if "XResolution" not in tags or "YResolution" not in tags:
        return None
    xnum, xden = tags["XResolution"].value
    ynum, yden = tags["YResolution"].value
    if not (xnum and xden and ynum and yden):
        return None
    x, y = xnum / xden, ynum / yden
    unit = tags["ResolutionUnit"].value if "ResolutionUnit" in tags else 2
    if unit == 3:  # centimetres
        x, y = x * _CM_PER_INCH, y * _CM_PER_INCH
    elif unit != 2:  # no absolute unit
        return None
    return (float(x), float(y))


def load_grey(path: str | Path) -> GreyImage:
    """Load the first page of a TIFF as 16-bit greyscale.

    8-bit images are scaled to 16-bit (x257). Min-is-white images are inverted so
    0 is always black. Colour images are rejected rather than silently converted.
    """
    with tifffile.TiffFile(path) as tif:
        page = tif.pages.first
        if not isinstance(page, tifffile.TiffPage):  # pragma: no cover - defensive
            raise ImageFormatError(f"{path}: no readable image page")
        pixels = np.asarray(page.asarray())
        photometric = page.photometric
        dpi = _dpi(page)
        icc = page.tags[_ICC_TAG].value if _ICC_TAG in page.tags else None

    if pixels.ndim == 3 and pixels.shape[-1] == 1:
        pixels = pixels[..., 0]
    if pixels.ndim != 2:
        raise ImageFormatError(
            f"{path}: expected a single-channel greyscale image, got shape {pixels.shape}"
            " (convert colour images to greyscale first)"
        )
    if pixels.dtype == np.uint8:
        pixels = pixels.astype(np.uint16) * 257
    elif pixels.dtype != np.uint16:
        raise ImageFormatError(f"{path}: expected 8- or 16-bit pixels, got {pixels.dtype}")
    if photometric == tifffile.PHOTOMETRIC.MINISWHITE:
        pixels = MAX_VALUE - pixels
    return GreyImage(pixels=pixels, dpi=dpi, icc_profile=bytes(icc) if icc else None)


def save_grey(path: str | Path, image: GreyImage) -> None:
    """Save a 16-bit min-is-black TIFF with the image's resolution and ICC profile."""
    if image.pixels.dtype != np.uint16 or image.pixels.ndim != 2:
        raise ImageFormatError("pixels must be a 2-D uint16 array")
    tifffile.imwrite(
        path,
        image.pixels,
        photometric="minisblack",
        resolution=image.dpi,
        resolutionunit="INCH" if image.dpi else None,
        iccprofile=image.icc_profile,
    )


def save_rgb(
    path: str | Path,
    pixels: NDArray[np.uint16],
    dpi: tuple[float, float] | None = None,
    icc_profile: bytes | None = None,
) -> None:
    """Save a 16-bit RGB TIFF (zlib-compressed) with optional resolution and ICC profile."""
    if pixels.dtype != np.uint16 or pixels.ndim != 3 or pixels.shape[-1] != 3:
        raise ImageFormatError("pixels must be a (height, width, 3) uint16 array")
    tifffile.imwrite(
        path,
        pixels,
        photometric="rgb",
        compression="zlib",
        resolution=dpi,
        resolutionunit="INCH" if dpi else None,
        iccprofile=icc_profile,
    )


def save_channels(
    directory: str | Path,
    separation: NDArray[np.uint16],
    channels: Sequence[str],
    dpi: tuple[float, float] | None = None,
) -> list[Path]:
    """Save each ink channel as `<channel>.tif` for previewing.

    Previews show ink as darkness: no ink is white, full ink is black.
    """
    if separation.ndim != 3 or separation.shape[0] != len(channels):
        raise ValueError(
            f"separation shape {separation.shape} doesn't match {len(channels)} channels"
        )
    folder = Path(directory)
    folder.mkdir(parents=True, exist_ok=True)
    paths = []
    for name, ink in zip(channels, separation, strict=True):
        path = folder / f"{name}.tif"
        save_grey(path, GreyImage(pixels=MAX_VALUE - ink, dpi=dpi))
        paths.append(path)
    return paths
