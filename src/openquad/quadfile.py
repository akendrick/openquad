"""Read and write `.quad` curve files.

A `.quad` file is plain text:

    ## QuadToneRIP K,C,M,Y,LC,LM,LK,LLK
    # any comment lines
    0
    ...            (256 integers, 0-65535, per channel, in header order)

Index 0 of each channel is paper white (no ink) and index 255 is maximum density.
Comment and blank lines are kept with the channel block that follows them, so a
file written by `format_quad` reads back and re-writes byte for byte.
"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
from numpy.typing import ArrayLike, NDArray

HEADER_PREFIX = "## QuadToneRIP"
LEVELS = 256
MAX_VALUE = 65535
STANDARD_CHANNELS: tuple[str, ...] = ("K", "C", "M", "Y", "LC", "LM", "LK", "LLK")


class QuadFormatError(ValueError):
    """A `.quad` file is malformed. The message names the line where possible."""


@dataclass(frozen=True, eq=False)
class QuadCurve:
    """One curve per ink channel, each 256 values from paper white to full density.

    `values` has shape (channels, 256), dtype uint16, and is read-only.
    `comments[i]` holds the comment/blank lines written before channel i's block;
    `trailer` holds any written after the last block.
    """

    channels: tuple[str, ...]
    values: NDArray[np.uint16]
    comments: tuple[tuple[str, ...], ...] = field(default=())
    trailer: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        if not self.channels:
            raise ValueError("a curve needs at least one channel")
        if len(set(self.channels)) != len(self.channels):
            raise ValueError(f"duplicate channel names: {self.channels}")
        for name in self.channels:
            if not name or "," in name or name != name.strip():
                raise ValueError(f"invalid channel name: {name!r}")
        values = np.array(self.values, copy=True)
        if values.shape != (len(self.channels), LEVELS):
            raise ValueError(
                f"values must have shape ({len(self.channels)}, {LEVELS}), got {values.shape}"
            )
        if values.dtype != np.uint16:
            if values.size and (values.min() < 0 or values.max() > MAX_VALUE):
                raise ValueError(f"values must be within 0-{MAX_VALUE}")
            values = values.astype(np.uint16)
        values.setflags(write=False)
        object.__setattr__(self, "values", values)
        if not self.comments:
            object.__setattr__(self, "comments", tuple(() for _ in self.channels))
        elif len(self.comments) != len(self.channels):
            raise ValueError("comments must have one entry per channel")
        for lines in (*self.comments, self.trailer):
            for line in lines:
                if line.strip() and not line.lstrip().startswith("#"):
                    raise ValueError(f"comment lines must start with '#': {line!r}")

    @classmethod
    def from_values(cls, channels: Sequence[str], values: ArrayLike) -> QuadCurve:
        """Build a curve with a standard '# <name> curve' comment before each block."""
        names = tuple(channels)
        return cls(
            channels=names,
            values=np.asarray(values),
            comments=tuple((f"# {name} curve",) for name in names),
        )

    def channel(self, name: str) -> NDArray[np.uint16]:
        """The 256 values of one channel."""
        try:
            index = self.channels.index(name)
        except ValueError:
            raise KeyError(f"no channel {name!r}; channels are {self.channels}") from None
        row: NDArray[np.uint16] = self.values[index]
        return row

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, QuadCurve):
            return NotImplemented
        return (
            self.channels == other.channels
            and np.array_equal(self.values, other.values)
            and self.comments == other.comments
            and self.trailer == other.trailer
        )

    __hash__ = None  # type: ignore[assignment]


def parse_quad(text: str) -> QuadCurve:
    """Parse the text of a `.quad` file."""
    lines = text.splitlines()
    if not lines or not lines[0].startswith(HEADER_PREFIX):
        raise QuadFormatError(f"line 1: expected a header starting with {HEADER_PREFIX!r}")

    names_part = lines[0][len(HEADER_PREFIX) :].strip()
    if names_part:
        channels = tuple(name.strip() for name in names_part.split(","))
        if any(not name for name in channels):
            raise QuadFormatError(f"line 1: empty channel name in {names_part!r}")
    else:
        channels = STANDARD_CHANNELS

    numbers: list[int] = []
    comments: list[tuple[str, ...]] = []
    pending: list[str] = []
    for lineno, raw in enumerate(lines[1:], start=2):
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            pending.append(raw)
            continue
        try:
            number = int(stripped)
        except ValueError:
            raise QuadFormatError(f"line {lineno}: expected an integer, got {stripped!r}") from None
        if not 0 <= number <= MAX_VALUE:
            raise QuadFormatError(f"line {lineno}: value {number} outside 0-{MAX_VALUE}")
        if len(numbers) % LEVELS == 0:
            if len(numbers) // LEVELS >= len(channels):
                raise QuadFormatError(
                    f"line {lineno}: more values than {len(channels)} channels x {LEVELS}"
                )
            comments.append(tuple(pending))
            pending = []
        numbers.append(number)

    expected = len(channels) * LEVELS
    if len(numbers) != expected:
        raise QuadFormatError(
            f"expected {expected} values ({len(channels)} channels x {LEVELS}), "
            f"found {len(numbers)}"
        )
    values = np.array(numbers, dtype=np.uint16).reshape(len(channels), LEVELS)
    try:
        return QuadCurve(channels, values, tuple(comments), tuple(pending))
    except ValueError as exc:
        raise QuadFormatError(str(exc)) from None


def format_quad(curve: QuadCurve) -> str:
    """The `.quad` text for a curve, with '\\n' line endings and a final newline."""
    out = [f"{HEADER_PREFIX} {','.join(curve.channels)}"]
    for block_comments, block in zip(curve.comments, curve.values, strict=True):
        out.extend(block_comments)
        out.extend(str(int(v)) for v in block)
    out.extend(curve.trailer)
    return "\n".join(out) + "\n"


def read_quad(path: str | Path) -> QuadCurve:
    """Read a `.quad` file. Accepts UTF-8 or Latin-1 text and any line endings."""
    data = Path(path).read_bytes()
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        text = data.decode("latin-1")
    return parse_quad(text)


def write_quad(curve: QuadCurve, path: str | Path) -> None:
    """Write a `.quad` file."""
    Path(path).write_text(format_quad(curve), encoding="utf-8", newline="\n")
