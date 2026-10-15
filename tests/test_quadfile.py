"""Tests for reading and writing `.quad` files."""

from pathlib import Path

import numpy as np
import pytest
from hypothesis import given
from hypothesis import strategies as st
from hypothesis.extra.numpy import arrays

from openquad.quadfile import (
    LEVELS,
    STANDARD_CHANNELS,
    QuadCurve,
    QuadFormatError,
    format_quad,
    parse_quad,
    read_quad,
    write_quad,
)


def ramp_curve(channels: tuple[str, ...] = ("K", "LK")) -> QuadCurve:
    values = np.stack([np.linspace(0, 65535 // (i + 1), LEVELS) for i in range(len(channels))])
    return QuadCurve.from_values(channels, values.round().astype(np.uint16))


def quad_text(channels: str, blocks: list[list[int]], comments: str = "") -> str:
    body = "\n".join(str(v) for block in blocks for v in block)
    return f"## QuadToneRIP {channels}\n{comments}{body}\n"


# --- parsing -------------------------------------------------------------------------


def test_parse_reads_channels_and_values() -> None:
    text = quad_text("K,LK", [list(range(256)), [5] * 256])
    curve = parse_quad(text)
    assert curve.channels == ("K", "LK")
    assert curve.values.shape == (2, 256)
    assert curve.values.dtype == np.uint16
    assert curve.channel("K")[255] == 255
    assert np.all(curve.channel("LK") == 5)


def test_parse_keeps_comments_with_the_following_block() -> None:
    lines = ["## QuadToneRIP K,LK", "# made by test", "# K curve"]
    lines += ["0"] * 256 + ["", "# LK curve"] + ["1"] * 256 + ["# end"]
    curve = parse_quad("\n".join(lines) + "\n")
    assert curve.comments == (("# made by test", "# K curve"), ("", "# LK curve"))
    assert curve.trailer == ("# end",)


def test_header_without_channel_list_means_standard_eight() -> None:
    text = "## QuadToneRIP\n" + "0\n" * (256 * 8)
    assert parse_quad(text).channels == STANDARD_CHANNELS


def test_windows_line_endings_are_accepted() -> None:
    text = quad_text("K", [list(range(256))]).replace("\n", "\r\n")
    assert parse_quad(text).channel("K")[10] == 10


@pytest.mark.parametrize(
    ("text", "message"),
    [
        ("", "line 1"),
        ("# not a header\n0\n", "line 1"),
        ("## QuadToneRIP K,,LK\n", "empty channel name"),
        (quad_text("K", [[0] * 255]), "found 255"),
        (quad_text("K", [[0] * 257]), "more values"),
        ("## QuadToneRIP K\n12x\n", "line 2: expected an integer"),
        ("## QuadToneRIP K\n70000\n", "outside 0-65535"),
        ("## QuadToneRIP K\n-1\n", "outside 0-65535"),
        ("## QuadToneRIP K,K\n" + "0\n" * 512, "duplicate"),
    ],
)
def test_malformed_files_raise_clear_errors(text: str, message: str) -> None:
    with pytest.raises(QuadFormatError, match=message):
        parse_quad(text)


# --- round trips ---------------------------------------------------------------------


def test_format_then_parse_is_identity() -> None:
    curve = ramp_curve()
    assert parse_quad(format_quad(curve)) == curve


def test_file_round_trip_is_byte_identical(tmp_path: Path) -> None:
    path = tmp_path / "a.quad"
    write_quad(ramp_curve(STANDARD_CHANNELS), path)
    first = path.read_bytes()
    write_quad(read_quad(path), path)
    assert path.read_bytes() == first


def test_read_accepts_latin1(tmp_path: Path) -> None:
    path = tmp_path / "latin.quad"
    text = quad_text("K", [[0] * 256], comments="# Café paper\n")
    path.write_bytes(text.encode("latin-1"))
    assert read_quad(path).comments == (("# Café paper",),)


@given(
    values=arrays(np.uint16, (3, LEVELS)),
    comment=st.text(alphabet=st.characters(blacklist_categories=["Cc", "Cs", "Zl", "Zp"])),
)
def test_any_curve_round_trips(values: np.ndarray, comment: str) -> None:
    curve = QuadCurve(
        channels=("K", "C", "M"),
        values=values,
        comments=((f"# {comment}",), (), ("",)),
        trailer=("# trailer",),
    )
    text = format_quad(curve)
    assert parse_quad(text) == curve
    assert format_quad(parse_quad(text)) == text


# --- the QuadCurve model -------------------------------------------------------------


def test_values_are_read_only_copies() -> None:
    source = np.zeros((1, LEVELS), dtype=np.uint16)
    curve = QuadCurve(("K",), source)
    source[0, 0] = 9
    assert curve.values[0, 0] == 0
    with pytest.raises(ValueError, match="read-only"):
        curve.values[0, 0] = 1


def test_integer_values_are_converted_to_uint16() -> None:
    curve = QuadCurve(("K",), np.full((1, LEVELS), 300, dtype=np.int64))
    assert curve.values.dtype == np.uint16


def test_from_values_adds_standard_comments() -> None:
    assert ramp_curve().comments == (("# K curve",), ("# LK curve",))


def test_unknown_channel_lookup_names_the_channels() -> None:
    with pytest.raises(KeyError, match="no channel 'C'"):
        ramp_curve().channel("C")


def test_equality() -> None:
    assert ramp_curve() == ramp_curve()
    assert ramp_curve() != ramp_curve(("K", "C"))
    assert ramp_curve() != "not a curve"


@pytest.mark.parametrize(
    ("kwargs", "message"),
    [
        ({"channels": ()}, "at least one channel"),
        ({"channels": ("K", "K")}, "duplicate"),
        ({"channels": ("K,C",)}, "invalid channel name"),
        ({"channels": (" K",)}, "invalid channel name"),
        ({"values": np.zeros((1, 10))}, "shape"),
        ({"values": np.full((1, LEVELS), 70000)}, "within 0-65535"),
        ({"values": np.full((1, LEVELS), -1)}, "within 0-65535"),
        ({"comments": ((), ())}, "one entry per channel"),
        ({"comments": (("not a comment",),)}, "must start with '#'"),
        ({"trailer": ("5",)}, "must start with '#'"),
    ],
)
def test_invalid_curves_are_rejected(kwargs: dict[str, object], message: str) -> None:
    args: dict[str, object] = {"channels": ("K",), "values": np.zeros((1, LEVELS))}
    args.update(kwargs)
    with pytest.raises(ValueError, match=message):
        QuadCurve(**args)  # type: ignore[arg-type]
