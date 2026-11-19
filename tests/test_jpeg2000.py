from pathlib import Path

import numpy as np
import pytest
from PIL import Image

from openquad import jpeg2000
from openquad.imageio import ImageFormatError
from openquad.jpeg2000 import _boxes, _per_inch, is_jpeg2000, openjpeg_version, read_jpeg2000, scale
from openquad.photo import load_photo

FIXTURES = Path(__file__).resolve().parents[1] / "fixtures" / "jpeg2000"


def test_the_same_openjpeg_as_the_mac_app() -> None:
    assert openjpeg_version() == "2.5.4"


def test_bright_16_bit_colour_stays_bright() -> None:
    # Pillow's own reader turns these black (and cuts the rest to 8 bits).
    pixels, dpi, profile = read_jpeg2000(FIXTURES / "rgb16.jp2")
    assert pixels.dtype == np.uint16 and pixels.shape == (32, 40, 3)
    assert pixels[0, :4].tolist() == [[65535] * 3, [65408] * 3, [65407] * 3, [65400, 30000, 100]]
    assert dpi is None and profile is None
    with Image.open(FIXTURES / "rgb16.jp2") as image:
        assert np.asarray(image)[0, 0].tolist() == [0, 0, 0]
    photo = load_photo(FIXTURES / "rgb16.jp2")
    assert (
        photo.converted and photo.colour is not None and photo.colour[0, 0].tolist() == [65535] * 3
    )


def test_12_bit_and_signed_grey_scale_to_16_bits() -> None:
    twelve, _, _ = read_jpeg2000(FIXTURES / "grey12.j2k")
    assert twelve.dtype == np.uint16 and twelve[0, 0, 0] == 0 and twelve[0, -1, 0] == 65535
    signed, _, _ = read_jpeg2000(FIXTURES / "grey16-signed.j2k")
    assert signed[0, 0, 0] == 0 and signed[0, -1, 0] == 65535
    assert scale(np.array([0, 2048, 4095]), 12, 16).tolist() == [0, 32776, 65535]
    assert scale(np.array([7]), 8, 8).tolist() == [7]


def test_8_bit_files_from_pillow_read_as_pillow_reads_them(tmp_path: Path) -> None:
    rng = np.random.default_rng(5)
    for mode, shape in (
        ("L", (32, 40)),
        ("LA", (32, 40, 2)),
        ("RGB", (32, 40, 3)),
        ("RGBA", (32, 40, 4)),
    ):
        pixels = rng.integers(0, 256, shape).astype(np.uint8)
        path = tmp_path / f"{mode}.jp2"
        Image.fromarray(pixels, mode).save(path)
        mine, _, _ = read_jpeg2000(path)
        assert mine.dtype == np.uint8 and np.array_equal(mine.reshape(shape), pixels)
    grey16 = np.tile(np.linspace(0, 65535, 40), (32, 1)).astype(np.uint16)
    path = tmp_path / "grey16.j2k"
    Image.fromarray(grey16).save(path)
    assert np.array_equal(read_jpeg2000(path)[0][..., 0], grey16)
    assert np.array_equal(load_photo(path).pixels, grey16)


def test_resolution_comes_from_the_capture_box() -> None:
    assert _per_inch(11811, 1, 0) == pytest.approx(299.9994)
    assert _per_inch(1181, 10, 1) == _per_inch(1181, 1, 0)
    assert _per_inch(0, 1, 0) is None and _per_inch(1, 0, 0) is None and _per_inch(1, 1, 7) is None
    # A long (XL) box and one that runs to the end, then one that doesn't fit.
    data = (b"\x00\x00\x00\x01free" + (20).to_bytes(8, "big") + b"abcd"
            + b"\x00\x00\x00\x00jp2c" + b"xyz")  # fmt: skip
    assert [(k, e - s) for k, s, e in _boxes(data, 0, len(data))] == [(b"free", 4), (b"jp2c", 3)]
    assert _boxes(b"\x00\x00\x00\x01free\x00", 0, 9) == []
    assert _boxes(b"\x00\x00\x00\x20free", 0, 8) == []


def test_not_jpeg_2000_or_broken(tmp_path: Path) -> None:
    assert is_jpeg2000((FIXTURES / "rgb16.jp2").read_bytes()) and not is_jpeg2000(b"gimp xcf ")
    png = tmp_path / "x.jp2"
    Image.new("L", (4, 4)).save(png, format="PNG")
    with pytest.raises(ImageFormatError, match="not a JPEG 2000 file"):
        read_jpeg2000(png)
    broken = tmp_path / "broken.jp2"
    broken.write_bytes((FIXTURES / "rgb16.jp2").read_bytes()[:200])
    with pytest.raises(ImageFormatError, match="not a readable JPEG 2000 image"):
        load_photo(broken)


def test_unsupported_images_are_refused() -> None:
    def image(count: int, colour_space: int, dx: int = 1) -> jpeg2000._Image:
        comps = (jpeg2000._Component * count)()
        for c in comps:
            c.dx, c.dy, c.w, c.h, c.prec = dx, 1, 2, 2, 8
        return jpeg2000._Image(numcomps=count, color_space=colour_space, comps=comps)

    path = Path("x.jp2")
    with pytest.raises(ImageFormatError, match="5 components"):
        jpeg2000._pixels(path, image(5, 0))
    with pytest.raises(ImageFormatError, match="subsampled"):
        jpeg2000._pixels(path, image(3, 0, dx=2))
    with pytest.raises(ImageFormatError, match="only grey and RGB"):
        jpeg2000._pixels(path, image(3, 3))  # YCC


def test_without_openjpeg(monkeypatch: pytest.MonkeyPatch) -> None:
    jpeg2000._library.cache_clear()
    monkeypatch.setattr(jpeg2000, "_candidates", lambda: [])
    monkeypatch.setattr(jpeg2000.ctypes.util, "find_library", lambda name: None)
    try:
        with pytest.raises(ImageFormatError, match="needs OpenJPEG"):
            read_jpeg2000(FIXTURES / "rgb16.jp2")
    finally:
        jpeg2000._library.cache_clear()
