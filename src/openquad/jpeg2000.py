"""Read JPEG 2000 photos (.jp2, .j2k, .jpx) at their full bit depth.

Pillow's own JPEG 2000 reader cuts colour to 8 bits, and for 16-bit colour it turns the
brightest values (65408 and up) black. So the pixels are decoded here, straight through
OpenJPEG: the copy Pillow ships with (2.5.4), the same version the Mac app builds in, so
both read the same values (Swift: JPEG2000.swift).

What comes out, for `photo.load_photo`:

- 1 component is grey, 2 grey and alpha, 3 RGB, 4 RGB and alpha (the last is alpha);
- 8-bit when every component is 8 bits or fewer, otherwise 16-bit; each component is
  scaled to that, rounding: round(v x (2^bits - 1) / (2^precision - 1));
- signed components are moved up by half their range first;
- the ICC profile is the file's own (a JP2 'colr' box), if any;
- the resolution is the capture resolution (a JP2 'resc' box), in dots per inch.

Subsampled components and YCC or CMYK colour are refused: save those as TIFF.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import struct
from fractions import Fraction
from functools import cache
from pathlib import Path

import numpy as np
from numpy.typing import NDArray

from openquad.imageio import ImageFormatError

J2K_SIGNATURE = b"\xff\x4f\xff\x51"
JP2_SIGNATURE = b"\x00\x00\x00\x0cjP  \r\n\x87\n"
_CODEC_J2K, _CODEC_JP2 = 0, 2
_UNKNOWN, _UNSPECIFIED, _SRGB, _GREY = -1, 0, 1, 2
_MAX_EXPONENT = 6  # resolutions beyond 10^6 are ignored (both sides compute them exactly)


def is_jpeg2000(head: bytes) -> bool:
    """Do these first bytes of a file start a JPEG 2000 codestream or JP2 file?"""
    return head.startswith(J2K_SIGNATURE) or head.startswith(JP2_SIGNATURE)


class _Component(ctypes.Structure):
    _fields_ = [
        ("dx", ctypes.c_uint32), ("dy", ctypes.c_uint32),
        ("w", ctypes.c_uint32), ("h", ctypes.c_uint32),
        ("x0", ctypes.c_uint32), ("y0", ctypes.c_uint32),
        ("prec", ctypes.c_uint32), ("bpp", ctypes.c_uint32), ("sgnd", ctypes.c_uint32),
        ("resno_decoded", ctypes.c_uint32), ("factor", ctypes.c_uint32),
        ("data", ctypes.POINTER(ctypes.c_int32)), ("alpha", ctypes.c_uint16),
    ]  # fmt: skip


class _Image(ctypes.Structure):
    _fields_ = [
        ("x0", ctypes.c_uint32), ("y0", ctypes.c_uint32),
        ("x1", ctypes.c_uint32), ("y1", ctypes.c_uint32),
        ("numcomps", ctypes.c_uint32), ("color_space", ctypes.c_int),
        ("comps", ctypes.POINTER(_Component)),
        ("icc_profile_buf", ctypes.POINTER(ctypes.c_ubyte)), ("icc_profile_len", ctypes.c_uint32),
    ]  # fmt: skip


_MESSAGE = ctypes.CFUNCTYPE(None, ctypes.c_char_p, ctypes.c_void_p)
_PARAMETERS_SIZE = 1 << 15  # opj_dparameters_t is about 8 KB; this is ample


def _candidates() -> list[Path]:
    """Where Pillow keeps its OpenJPEG (macOS wheels, then Linux and Windows wheels)."""
    import PIL

    package = Path(PIL.__file__).parent
    found = sorted((package / ".dylibs").glob("libopenjp2*.dylib"))
    for folder in (package.parent / "pillow.libs", package.parent / "Pillow.libs"):
        found += sorted(folder.glob("libopenjp2*.so*")) + sorted(folder.glob("openjp2*.dll"))
    return found


@cache
def _library() -> ctypes.CDLL:
    paths: list[str] = [str(p) for p in _candidates()]
    system = ctypes.util.find_library("openjp2")
    if system:
        paths.append(system)
    for path in paths:
        try:
            lib = ctypes.CDLL(path)
        except OSError:  # pragma: no cover - a broken install
            continue
        _declare(lib)
        return lib
    raise ImageFormatError("reading JPEG 2000 needs OpenJPEG, which Pillow normally includes")


def _declare(lib: ctypes.CDLL) -> None:
    pointer, boolean = ctypes.c_void_p, ctypes.c_int
    lib.opj_version.restype = ctypes.c_char_p
    lib.opj_stream_create_default_file_stream.argtypes = [ctypes.c_char_p, boolean]
    lib.opj_stream_create_default_file_stream.restype = pointer
    lib.opj_stream_destroy.argtypes = [pointer]
    lib.opj_create_decompress.argtypes = [ctypes.c_int]
    lib.opj_create_decompress.restype = pointer
    lib.opj_destroy_codec.argtypes = [pointer]
    lib.opj_set_default_decoder_parameters.argtypes = [pointer]
    lib.opj_setup_decoder.argtypes = [pointer, pointer]
    lib.opj_setup_decoder.restype = boolean
    lib.opj_set_error_handler.argtypes = [pointer, _MESSAGE, pointer]
    lib.opj_set_error_handler.restype = boolean
    lib.opj_read_header.argtypes = [pointer, pointer, ctypes.POINTER(ctypes.POINTER(_Image))]
    lib.opj_read_header.restype = boolean
    lib.opj_decode.argtypes = [pointer, pointer, ctypes.POINTER(_Image)]
    lib.opj_decode.restype = boolean
    lib.opj_end_decompress.argtypes = [pointer, pointer]
    lib.opj_end_decompress.restype = boolean
    lib.opj_image_destroy.argtypes = [ctypes.POINTER(_Image)]


def openjpeg_version() -> str:
    """The OpenJPEG version in use, e.g. '2.5.4'."""
    return str(_library().opj_version().decode())


def scale(values: NDArray[np.int64], precision: int, bits: int) -> NDArray[np.int64]:
    """Unsigned `precision`-bit values to `bits` bits, rounding to nearest."""
    top, full = (1 << precision) - 1, (1 << bits) - 1
    if precision == bits:
        return values
    return (values * full + top // 2) // top


def read_jpeg2000(
    path: Path,
) -> tuple[NDArray[np.uint8] | NDArray[np.uint16], tuple[float, float] | None, bytes | None]:
    """Pixels (H, W, C), 8- or 16-bit; the resolution in dpi; and the ICC profile."""
    head = path.read_bytes()[:12]
    if not is_jpeg2000(head):
        raise ImageFormatError(f"{path}: not a JPEG 2000 file")
    lib = _library()
    errors: list[str] = []
    handler = _MESSAGE(lambda message, _data: errors.append(message.decode().strip()))
    stream = lib.opj_stream_create_default_file_stream(str(path).encode(), 1)
    if not stream:  # pragma: no cover - the file was just read
        raise ImageFormatError(f"{path}: could not open the file")
    codec = lib.opj_create_decompress(_CODEC_J2K if head.startswith(J2K_SIGNATURE) else _CODEC_JP2)
    image = ctypes.POINTER(_Image)()
    try:
        parameters = ctypes.create_string_buffer(_PARAMETERS_SIZE)
        lib.opj_set_default_decoder_parameters(parameters)
        lib.opj_setup_decoder(codec, parameters)
        lib.opj_set_error_handler(codec, handler, None)
        ok = bool(lib.opj_read_header(stream, codec, ctypes.byref(image)))
        ok = ok and bool(lib.opj_decode(codec, stream, image))
        ok = ok and bool(lib.opj_end_decompress(codec, stream))
        if not ok:
            reason = errors[0] if errors else "could not be decoded"
            raise ImageFormatError(f"{path}: not a readable JPEG 2000 image ({reason})")
        pixels = _pixels(path, image.contents)
        info = image.contents
        profile = (
            bytes(info.icc_profile_buf[: info.icc_profile_len]) if info.icc_profile_len else None
        )
    finally:
        if image:
            lib.opj_image_destroy(image)
        lib.opj_destroy_codec(codec)
        lib.opj_stream_destroy(stream)
    return pixels, _jp2_dpi(path), profile


def _pixels(path: Path, image: _Image) -> NDArray[np.uint8] | NDArray[np.uint16]:
    count = image.numcomps
    if not 1 <= count <= 4:
        raise ImageFormatError(f"{path}: unsupported JPEG 2000 image ({count} components)")
    comps = [image.comps[k] for k in range(count)]
    width, height = comps[0].w, comps[0].h
    if any(c.dx != 1 or c.dy != 1 or c.w != width or c.h != height for c in comps):
        raise ImageFormatError(f"{path}: unsupported JPEG 2000 image (subsampled colour)")
    allowed = (_UNKNOWN, _UNSPECIFIED, _GREY if count <= 2 else _SRGB)
    if image.color_space not in allowed:
        raise ImageFormatError(f"{path}: unsupported JPEG 2000 colour (only grey and RGB are read)")
    bits = 16 if any(c.prec > 8 for c in comps) else 8
    planes = []
    for c in comps:
        values = np.ctypeslib.as_array(c.data, shape=(height * width,)).astype(np.int64)
        if c.sgnd:
            values += 1 << (c.prec - 1)
        values = scale(np.clip(values, 0, (1 << c.prec) - 1), c.prec, bits)
        planes.append(values.reshape(height, width))
    stacked = np.stack(planes, axis=-1)
    return stacked.astype(np.uint16) if bits == 16 else stacked.astype(np.uint8)


def _boxes(data: bytes, start: int, end: int) -> list[tuple[bytes, int, int]]:
    """The (type, content start, content end) of each box in data[start:end]."""
    boxes = []
    while start + 8 <= end:
        length, kind = struct.unpack_from(">I4s", data, start)
        header = 8
        if length == 1:
            if start + 16 > end:
                break
            length, header = struct.unpack_from(">Q", data, start + 8)[0], 16
        elif length == 0:
            length = end - start
        if length < header or start + length > end:
            break
        boxes.append((kind, start + header, start + length))
        start += length
    return boxes


def _jp2_dpi(path: Path) -> tuple[float, float] | None:
    """The capture resolution of a JP2 file ('jp2h' > 'res ' > 'resc'), in dots per inch."""
    data = path.read_bytes()
    for kind, start, end in _boxes(data, 0, len(data)):
        if kind != b"jp2h":
            continue
        for sub, s, e in _boxes(data, start, end):
            if sub != b"res ":
                continue
            for res, r, re_ in _boxes(data, s, e):
                if res == b"resc" and re_ - r >= 10:
                    vn, vd, hn, hd, ve, he = struct.unpack_from(">HHHHbb", data, r)
                    horizontal, vertical = _per_inch(hn, hd, he), _per_inch(vn, vd, ve)
                    if horizontal is not None and vertical is not None:
                        return (horizontal, vertical)
    return None


def _per_inch(numerator: int, denominator: int, exponent: int) -> float | None:
    """Dots per metre (numerator / denominator x 10^exponent) as dots per inch."""
    if numerator == 0 or denominator == 0 or abs(exponent) > _MAX_EXPONENT:
        return None
    return float(Fraction(254 * numerator, 10000 * denominator) * Fraction(10) ** exponent)
