"""Converting a colour print through a printer's OpenQuad profile (colour calibration).

The photo's colours, in its own profile (sRGB if it has none), become the RGB to send to the
printer, which then goes sRGB-tagged, exactly as the colour target did. LittleCMS (Pillow's
ImageCms) does the conversion, perceptual intent, as ColorSync does in the Mac app.

Pillow transforms only 8-bit RGB, so a 16-bit photo goes through a table: the transform of a
52-level grid (every fifth 8-bit value), read between its nodes by trilinear interpolation.
"""

from __future__ import annotations

import io

import numpy as np
from numpy.typing import NDArray
from PIL import Image, ImageCms

from openquad.imageio import srgb_profile

GRID = 52  # nodes a channel: 0, 5, 10, ... 255
ROWS = 256  # image rows converted at a time (keeps the interpolation's memory small)


class ColourConvertError(ValueError):
    """A profile can't be used to convert a colour print."""


def is_rgb_output_profile(data: bytes | None) -> bool:
    """Whether ICC data is an RGB output (printer) profile, the kind OpenQuad makes."""
    return data is not None and data[12:16] == b"prtr" and data[16:20] == b"RGB "


def _profile(data: bytes | None) -> ImageCms.ImageCmsProfile:
    if data is None:
        data = srgb_profile()
        if data is None:  # pragma: no cover - macOS always has sRGB
            return ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB"))
    try:
        return ImageCms.ImageCmsProfile(io.BytesIO(data))
    except (OSError, ImageCms.PyCMSError) as exc:
        raise ColourConvertError(f"the colour profile can't be used: {exc}") from exc


def _printer(profile: bytes) -> ImageCms.ImageCmsProfile:
    if not is_rgb_output_profile(profile):
        raise ColourConvertError("the colour profile isn't an RGB printer profile")
    return _profile(profile)


def device_table(source: bytes | None, profile: bytes) -> NDArray[np.float64]:
    """The printer's device RGB (0-1) for a GRID³ lattice of `source` colours, perceptual."""
    transform = ImageCms.buildTransform(
        _profile(source), _printer(profile), "RGB", "RGB",
        renderingIntent=ImageCms.Intent.PERCEPTUAL,
    )  # fmt: skip
    levels = np.linspace(0, 255, GRID).round().astype(np.uint8)
    r, g, b = np.meshgrid(levels, levels, levels, indexing="ij")
    grid = np.stack([r, g, b], -1).reshape(1, -1, 3)
    out = ImageCms.applyTransform(Image.fromarray(grid, "RGB"), transform)
    assert out is not None
    return np.asarray(out, dtype=np.float64).reshape(GRID, GRID, GRID, 3) / 255.0


def _interpolate(table: NDArray[np.float64], rgb: NDArray[np.uint16]) -> NDArray[np.uint16]:
    x = rgb.astype(np.float64) * ((GRID - 1) / 65535.0)
    i = np.minimum(x.astype(np.intp), GRID - 2)
    f = x - i
    out = np.zeros((*rgb.shape[:-1], 3))
    for dr in (0, 1):
        wr = f[..., 0] if dr else 1 - f[..., 0]
        for dg in (0, 1):
            wg = f[..., 1] if dg else 1 - f[..., 1]
            for db in (0, 1):
                wb = f[..., 2] if db else 1 - f[..., 2]
                corner = table[i[..., 0] + dr, i[..., 1] + dg, i[..., 2] + db]
                out += (wr * wg * wb)[..., None] * corner
    return np.clip(np.round(out * 65535.0), 0, 65535).astype(np.uint16)


def to_device(rgb: NDArray[np.uint16], source: bytes | None, profile: bytes) -> NDArray[np.uint16]:
    """16-bit RGB pixels (H, W, 3) in `source`'s colours (sRGB if None) as the device RGB of
    the printer `profile` describes."""
    table = device_table(source, profile)
    out = np.empty_like(rgb, dtype=np.uint16)
    for top in range(0, rgb.shape[0], ROWS):
        out[top : top + ROWS] = _interpolate(table, rgb[top : top + ROWS])
    return out


def proof(rgb: NDArray[np.uint8], source: bytes | None, profile: bytes) -> NDArray[np.uint8]:
    """A soft proof for the screen: 8-bit RGB pixels as they will print through `profile`
    (perceptual into the printer, then relative colourimetric back to sRGB)."""
    transform = ImageCms.buildProofTransform(
        _profile(source), _profile(None), _printer(profile), "RGB", "RGB",
        renderingIntent=ImageCms.Intent.PERCEPTUAL,
        proofRenderingIntent=ImageCms.Intent.RELATIVE_COLORIMETRIC,
        flags=ImageCms.Flags.SOFTPROOFING,
    )  # fmt: skip
    out = ImageCms.applyTransform(Image.fromarray(np.ascontiguousarray(rgb), "RGB"), transform)
    assert out is not None
    return np.asarray(out, dtype=np.uint8)
