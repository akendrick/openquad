"""Tests for multi-layer colour compositing."""

from pathlib import Path

import numpy as np
import pytest
import tifffile
from hypothesis import given
from hypothesis import strategies as st
from hypothesis.extra.numpy import arrays

from openquad.composite import (
    PRESETS,
    ColourLayer,
    composite,
    linear_to_srgb,
    srgb_to_linear,
)
from openquad.curves import InkSpec
from openquad.imageio import ImageFormatError, save_rgb

images = arrays(np.uint16, st.tuples(st.integers(1, 12), st.integers(1, 12)))
RED = PRESETS["red-only"][0]
BLACK_RED = PRESETS["black-red"]


def layer(name: str, colour: tuple[float, float, float], limit: float = 100.0) -> ColourLayer:
    return ColourLayer(name, colour, InkSpec(name, limit=limit, start=0.0, peak=1.0))


def test_srgb_transfer_round_trips() -> None:
    values = np.linspace(0.0, 1.0, 1001)
    assert np.allclose(linear_to_srgb(srgb_to_linear(values)), values, atol=1e-12)


@given(images)
def test_neutral_black_layer_reproduces_the_greyscale_image(image: np.ndarray) -> None:
    out = composite(image, PRESETS["neutral"]).astype(int)
    for channel in range(3):
        assert np.abs(out[..., channel] - image.astype(int)).max() <= 1


@given(images)
def test_paper_white_stays_white(image: np.ndarray) -> None:
    image = image.copy()
    image[0, 0] = 65535
    assert composite(image, BLACK_RED)[0, 0].tolist() == [65535, 65535, 65535]


@given(images)
def test_zero_strength_layers_change_nothing(image: np.ndarray) -> None:
    base = composite(image, PRESETS["neutral"])
    extra = (*PRESETS["neutral"], layer("ghost", (0.0, 0.5, 1.0), limit=0.0))
    assert np.array_equal(composite(image, extra), base)


@given(images)
def test_adding_a_layer_never_lightens(image: np.ndarray) -> None:
    without = composite(image, PRESETS["neutral"]).astype(int)
    with_red = composite(image, (*BLACK_RED[:1], RED)).astype(int)
    assert np.all(with_red <= composite(image, BLACK_RED[:1]).astype(int))
    assert np.all(composite(image, (*PRESETS["neutral"], RED)).astype(int) <= without)


@given(images)
def test_layer_order_does_not_matter(image: np.ndarray) -> None:
    forward = composite(image, BLACK_RED).astype(int)
    backward = composite(image, BLACK_RED[::-1]).astype(int)
    assert np.abs(forward - backward).max() <= 1


@given(images, st.integers(1, 12))
def test_chunk_size_never_changes_the_result(image: np.ndarray, chunk_rows: int) -> None:
    assert np.array_equal(
        composite(image, BLACK_RED, chunk_rows=chunk_rows), composite(image, BLACK_RED)
    )


def test_red_layer_tints_the_mid_tones_red() -> None:
    mid = np.full((1, 1), 32768, dtype=np.uint16)
    r, g, b = composite(mid, BLACK_RED)[0, 0].astype(int)
    assert r > g + 5000
    assert abs(g - b) < 1000


def test_black_red_reaches_near_black_in_the_shadows() -> None:
    black = np.zeros((1, 1), dtype=np.uint16)
    assert composite(black, BLACK_RED).max() < 1000


def test_output_shape_and_type() -> None:
    out = composite(np.zeros((3, 5), dtype=np.uint16), BLACK_RED)
    assert out.shape == (3, 5, 3)
    assert out.dtype == np.uint16


def test_no_layers_gives_blank_paper() -> None:
    assert np.all(composite(np.zeros((2, 2), dtype=np.uint16), []) == 65535)


@pytest.mark.parametrize("name", sorted(PRESETS))
def test_every_preset_renders(name: str) -> None:
    gradient = np.linspace(0, 65535, 64).astype(np.uint16).reshape(1, -1)
    out = composite(gradient, PRESETS[name])
    assert out[0, -1].tolist() == [65535, 65535, 65535]  # white end untouched


def test_rejects_bad_images_and_options() -> None:
    with pytest.raises(TypeError, match="uint16"):
        composite(np.zeros((2, 2), dtype=np.uint8), BLACK_RED)  # type: ignore[arg-type]
    with pytest.raises(ValueError, match="2-D"):
        composite(np.zeros((2, 2, 2), dtype=np.uint16), BLACK_RED)
    with pytest.raises(ValueError, match="chunk_rows"):
        composite(np.zeros((2, 2), dtype=np.uint16), BLACK_RED, chunk_rows=0)
    with pytest.raises(ValueError, match="unique"):
        composite(np.zeros((2, 2), dtype=np.uint16), (RED, RED))


@pytest.mark.parametrize("colour", [(1.2, 0.0, 0.0), (-0.1, 0.0, 0.0), (0.5, 0.5)])
def test_rejects_bad_colours(colour: tuple[float, float, float]) -> None:
    with pytest.raises(ValueError, match="colour"):
        layer("x", colour)


def test_save_rgb_round_trip(tmp_path: Path) -> None:
    pixels = composite(np.linspace(0, 65535, 12).astype(np.uint16).reshape(3, 4), BLACK_RED)
    path = tmp_path / "rgb.tif"
    save_rgb(path, pixels, dpi=(300.0, 300.0), icc_profile=b"icc")
    with tifffile.TiffFile(path) as tif:
        page = tif.pages.first
        assert np.array_equal(page.asarray(), pixels)
        assert page.tags[34675].value == b"icc"


def test_save_rgb_rejects_greyscale(tmp_path: Path) -> None:
    with pytest.raises(ImageFormatError, match="height, width, 3"):
        save_rgb(tmp_path / "x.tif", np.zeros((2, 2), dtype=np.uint16))
