"""Tests for TIFF loading and saving."""

from pathlib import Path

import numpy as np
import pytest
import tifffile

from openquad.imageio import GreyImage, ImageFormatError, load_grey, save_channels, save_grey

GRADIENT = np.linspace(0, 65535, 4 * 6).astype(np.uint16).reshape(4, 6)


def test_round_trip_keeps_pixels_dpi_and_profile(tmp_path: Path) -> None:
    path = tmp_path / "a.tif"
    save_grey(path, GreyImage(GRADIENT, dpi=(720.0, 360.0), icc_profile=b"fake-icc-profile"))
    loaded = load_grey(path)
    assert np.array_equal(loaded.pixels, GRADIENT)
    assert loaded.pixels.dtype == np.uint16
    assert loaded.dpi == pytest.approx((720.0, 360.0))
    assert loaded.icc_profile == b"fake-icc-profile"


def test_missing_metadata_is_none(tmp_path: Path) -> None:
    path = tmp_path / "plain.tif"
    tifffile.imwrite(path, GRADIENT)
    loaded = load_grey(path)
    assert loaded.dpi is None
    assert loaded.icc_profile is None


def test_centimetre_resolution_is_converted_to_dpi(tmp_path: Path) -> None:
    path = tmp_path / "cm.tif"
    tifffile.imwrite(path, GRADIENT, resolution=(100.0, 100.0), resolutionunit="CENTIMETER")
    assert load_grey(path).dpi == pytest.approx((254.0, 254.0))


def test_unitless_resolution_is_ignored(tmp_path: Path) -> None:
    path = tmp_path / "nounit.tif"
    tifffile.imwrite(path, GRADIENT, resolution=(300.0, 300.0), resolutionunit="NONE")
    assert load_grey(path).dpi is None


def test_8_bit_is_scaled_to_16_bit(tmp_path: Path) -> None:
    path = tmp_path / "8bit.tif"
    tifffile.imwrite(path, np.array([[0, 128, 255]], dtype=np.uint8))
    assert load_grey(path).pixels.tolist() == [[0, 128 * 257, 65535]]


def test_min_is_white_is_inverted(tmp_path: Path) -> None:
    path = tmp_path / "miniswhite.tif"
    tifffile.imwrite(path, np.array([[0, 65535]], dtype=np.uint16), photometric="miniswhite")
    assert load_grey(path).pixels.tolist() == [[65535, 0]]


def test_single_channel_3d_is_accepted(tmp_path: Path) -> None:
    path = tmp_path / "hw1.tif"
    tifffile.imwrite(
        path, GRADIENT[..., np.newaxis], photometric="minisblack", planarconfig="contig"
    )
    assert load_grey(path).pixels.shape == GRADIENT.shape


def test_colour_images_are_rejected(tmp_path: Path) -> None:
    path = tmp_path / "rgb.tif"
    tifffile.imwrite(path, np.zeros((4, 4, 3), dtype=np.uint16), photometric="rgb")
    with pytest.raises(ImageFormatError, match="convert colour images"):
        load_grey(path)


def test_float_images_are_rejected(tmp_path: Path) -> None:
    path = tmp_path / "float.tif"
    tifffile.imwrite(path, np.zeros((4, 4), dtype=np.float32))
    with pytest.raises(ImageFormatError, match="8- or 16-bit"):
        load_grey(path)


def test_save_rejects_wrong_pixels(tmp_path: Path) -> None:
    with pytest.raises(ImageFormatError, match="2-D uint16"):
        save_grey(tmp_path / "x.tif", GreyImage(np.zeros((2, 2), dtype=np.uint8)))  # type: ignore[arg-type]


def test_save_channels_writes_one_preview_per_ink(tmp_path: Path) -> None:
    separation = np.stack([np.zeros((2, 3)), np.full((2, 3), 65535)]).astype(np.uint16)
    paths = save_channels(tmp_path / "out", separation, ["K", "LK"], dpi=(360.0, 360.0))
    assert [p.name for p in paths] == ["K.tif", "LK.tif"]
    assert np.all(load_grey(paths[0]).pixels == 65535)  # no ink -> white
    assert np.all(load_grey(paths[1]).pixels == 0)  # full ink -> black
    assert load_grey(paths[0]).dpi == pytest.approx((360.0, 360.0))


def test_save_channels_checks_channel_count(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="doesn't match"):
        save_channels(tmp_path, np.zeros((2, 2, 2), dtype=np.uint16), ["K"])
