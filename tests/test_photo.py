"""Loading real-world photo files, and fitting them to paper."""

from pathlib import Path

import numpy as np
import pytest
import tifffile
from PIL import Image

from openquad.imageio import ImageFormatError
from openquad.paper import PAPER_SIZES, fit_ppi, print_size
from openquad.photo import load_photo

GREY8 = np.tile(np.linspace(0, 255, 30).astype(np.uint8), (20, 1))  # 20 x 30


def test_plain_8_bit_greyscale_tiff(tmp_path: Path) -> None:
    path = tmp_path / "g.tif"
    tifffile.imwrite(path, GREY8, resolution=(300, 300), resolutionunit="INCH")
    photo = load_photo(path)
    assert photo.pixels.dtype == np.uint16
    assert photo.pixels[0, -1] == 65535 and photo.pixels[0, 0] == 0
    assert photo.dpi == pytest.approx((300, 300))
    assert photo.size == (30, 20)
    assert not photo.converted and not photo.cropped


def test_16_bit_greyscale_tiff(tmp_path: Path) -> None:
    path = tmp_path / "g16.tif"
    tifffile.imwrite(path, GREY8.astype(np.uint16) * 257)
    assert np.array_equal(load_photo(path).pixels, GREY8.astype(np.uint16) * 257)


def test_greyscale_saved_as_rgb_is_read_as_grey(tmp_path: Path) -> None:
    path = tmp_path / "rgb.tif"
    tifffile.imwrite(path, np.stack([GREY8] * 3, axis=-1), photometric="rgb")
    photo = load_photo(path)
    assert np.array_equal(photo.pixels, GREY8.astype(np.uint16) * 257)
    assert not photo.converted


def test_rgba_with_transparent_band_like_a_resized_canvas(tmp_path: Path) -> None:
    """The real case from 22 Oct: grey RGBA, premultiplied alpha, transparent bottom band."""
    rgba = np.zeros((26, 30, 4), dtype=np.uint8)
    rgba[:20, :, :3] = GREY8[..., np.newaxis]
    rgba[:20, :, 3] = 255  # opaque photo; bottom 6 rows fully transparent (and black)
    path = tmp_path / "rgba.tif"
    tifffile.imwrite(path, rgba, photometric="rgb", extrasamples=["assocalpha"])
    photo = load_photo(path)
    assert photo.cropped
    assert photo.size == (30, 20)  # transparent band gone
    assert np.array_equal(photo.pixels, GREY8.astype(np.uint16) * 257)


def test_partly_transparent_pixels_land_on_white_paper(tmp_path: Path) -> None:
    rgba = np.zeros((2, 2, 4), dtype=np.uint8)
    rgba[..., 3] = 255
    rgba[0, 0] = (0, 0, 0, 0)  # transparent corner: kept (not an edge row/column)...
    rgba[0, 1] = (0, 0, 0, 128)  # half-transparent black over white -> mid grey
    path = tmp_path / "unassoc.png"
    Image.fromarray(rgba, "RGBA").save(path)
    photo = load_photo(path)
    assert photo.pixels[0, 0] == 65535  # fully transparent -> paper white
    assert photo.pixels[0, 1] == pytest.approx(65535 * (1 - 128 / 255), abs=2)
    assert photo.pixels[1, 0] == 0


def test_premultiplied_alpha_is_handled(tmp_path: Path) -> None:
    rgba = np.zeros((1, 3, 4), dtype=np.uint8)
    rgba[0, 0] = (64, 64, 64, 128)  # premultiplied: true colour 128 at half opacity
    rgba[0, 1:] = (255, 255, 255, 255)
    path = tmp_path / "assoc.tif"
    tifffile.imwrite(path, rgba, photometric="rgb", extrasamples=["assocalpha"])
    expected = (64 + 127) / 255 * 65535
    assert load_photo(path).pixels[0, 0] == pytest.approx(expected, abs=2)


def test_colour_photo_is_converted_by_luminance(tmp_path: Path) -> None:
    rgb = np.zeros((1, 3, 3), dtype=np.uint8)
    rgb[0, 0] = (255, 0, 0)
    rgb[0, 1] = (0, 255, 0)
    rgb[0, 2] = (0, 0, 255)
    path = tmp_path / "colour.png"
    Image.fromarray(rgb).save(path)
    photo = load_photo(path)
    assert photo.converted
    red, green, blue = photo.pixels[0].astype(int)
    assert green > red > blue  # green is the brightest primary


def test_jpeg_noise_still_counts_as_grey(tmp_path: Path) -> None:
    path = tmp_path / "grey.jpg"
    Image.fromarray(np.stack([GREY8] * 3, axis=-1)).save(path, quality=80)
    assert not load_photo(path).converted


def test_png_dpi_and_16_bit(tmp_path: Path) -> None:
    path = tmp_path / "g16.png"
    Image.fromarray(GREY8.astype(np.uint16) * 257).save(path, dpi=(240, 240))
    photo = load_photo(path)
    assert photo.dpi == pytest.approx((240, 240), abs=0.1)
    assert photo.pixels.max() == 65535


def test_min_is_white_is_inverted(tmp_path: Path) -> None:
    path = tmp_path / "mw.tif"
    tifffile.imwrite(path, np.array([[0, 255]], dtype=np.uint8), photometric="miniswhite")
    assert load_photo(path).pixels.tolist() == [[65535, 0]]


def test_fully_transparent_image_is_refused(tmp_path: Path) -> None:
    path = tmp_path / "empty.png"
    Image.fromarray(np.zeros((4, 4, 4), dtype=np.uint8), "RGBA").save(path)
    with pytest.raises(ImageFormatError, match="fully transparent"):
        load_photo(path)


def test_float_images_are_refused(tmp_path: Path) -> None:
    path = tmp_path / "f.tif"
    tifffile.imwrite(path, np.zeros((2, 2), dtype=np.float32))
    with pytest.raises(ImageFormatError, match="8- or 16-bit"):
        load_photo(path)


def test_odd_channel_counts_are_refused(tmp_path: Path) -> None:
    path = tmp_path / "five.tif"
    tifffile.imwrite(path, np.zeros((2, 2, 5), dtype=np.uint8), photometric="minisblack",
                     planarconfig="contig")  # fmt: skip
    with pytest.raises(ImageFormatError, match="unsupported"):
        load_photo(path)


# --- paper ---------------------------------------------------------------------------


def test_fit_the_22_oct_portrait_on_letter() -> None:
    ppi = fit_ppi(3008, 4032, "Letter")
    width, height = print_size(3008, 4032, ppi)
    assert height == pytest.approx(10.0)  # height is the limit on Letter
    assert width < 7.5
    assert ppi == pytest.approx(403.2)


def test_fit_landscape_is_limited_by_width() -> None:
    width, height = print_size(4000, 2000, fit_ppi(4000, 2000, "A4"))
    assert width == pytest.approx(PAPER_SIZES["A4"][0] - 1.0)
    assert height < PAPER_SIZES["A4"][1] - 1.0


@pytest.mark.parametrize(
    ("args", "message"),
    [
        ((10, 10, "Tabloid"), "unknown paper"),
        ((0, 10, "Letter"), "no pixels"),
        ((10, 10, "4x6", 2.5), "no room"),
    ],
)
def test_fit_errors(args: tuple, message: str) -> None:  # type: ignore[type-arg]
    with pytest.raises(ValueError, match=message):
        fit_ppi(*args)
