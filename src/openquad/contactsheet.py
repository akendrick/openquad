"""Contact sheets: up to 16 photos as thumbnails on one sheet, for proofing or a
negative of them all.

The sheet is a greyscale image (0 black .. 65535 white) the size of the printable
area, so it prints like any photo: as an inkjet print, or as a digital negative.
Thumbnails sit in an even grid on a black or white background, each either whole
(fitted inside its cell) or cropped to fill the cell, with an optional file name
under it and an optional 21-step greyscale wedge along the bottom.

Resizing is an exact integer box average, so the Swift version gives identical
pixels. File names are drawn with each platform's own font, so they are left out of
the comparison (``labels=False`` gives identical sheets).
"""

from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np
from numpy.typing import NDArray
from PIL import Image, ImageDraw, ImageFont

from openquad.targets import wedge_levels

MAX_VALUE = 65535
MAX_PHOTOS = 16
WEDGE_STEPS = 21
BACKGROUNDS = ("black", "white")


@dataclass(frozen=True)
class SheetLayout:
    """A contact sheet's size and options; lengths in inches."""

    width: float = 7.5
    height: float = 10.0
    gap: float = 0.15  # between thumbnails and round the edge
    background: str = "black"  # or "white"
    crop: bool = False  # fill each cell (cropping) instead of showing whole photos
    wedge: bool = False  # a 21-step greyscale wedge along the bottom
    labels: bool = False  # the file name under each thumbnail
    wedge_height: float = 0.3
    label_height: float = 0.18

    def __post_init__(self) -> None:
        if self.background not in BACKGROUNDS:
            raise ValueError(f"background must be black or white, got {self.background!r}")
        if not (self.width > 0 and self.height > 0):
            raise ValueError("the sheet must have a positive size")
        if not 0.0 <= self.gap <= 1.0:
            raise ValueError(f"gap must be 0-1 in, got {self.gap}")


@dataclass(frozen=True)
class Cell:
    """Where one photo's thumbnail goes, in pixels: its box (left, top, width, height)."""

    left: int
    top: int
    width: int
    height: int


def grid(count: int, aspect: float, room: tuple[int, int], gap: int, label: int) -> tuple[int, int]:
    """(columns, rows) that make thumbnails of this mean aspect (width / height) largest."""
    best, best_score = (1, count), -1.0
    for columns in range(1, count + 1):
        rows = math.ceil(count / columns)
        cell_w = (room[0] - gap * (columns - 1)) // columns
        box_h = (room[1] - gap * (rows - 1)) // rows - label
        if cell_w < 1 or box_h < 1:
            continue
        score = min(cell_w, box_h * aspect) * min(cell_w / aspect, box_h)
        if score > best_score:
            best, best_score = (columns, rows), score
    return best


def _px(inches: float, dpi: float) -> int:
    return round(inches * dpi)


def cells(
    sizes: list[tuple[int, int]], layout: SheetLayout, dpi: float
) -> tuple[list[Cell], tuple[int, int, int, int] | None]:
    """Each photo's thumbnail box, and the wedge's box (or None), for photos of these sizes."""
    if not 1 <= len(sizes) <= MAX_PHOTOS:
        raise ValueError(f"a contact sheet takes 1-{MAX_PHOTOS} photos, got {len(sizes)}")
    width, height, gap = _px(layout.width, dpi), _px(layout.height, dpi), _px(layout.gap, dpi)
    label = _px(layout.label_height, dpi) if layout.labels else 0
    wedge_h = _px(layout.wedge_height, dpi) if layout.wedge else 0
    room_w = width - 2 * gap
    room_h = height - 2 * gap - (wedge_h + gap if layout.wedge else 0)
    if room_w < 1 or room_h < 1:
        raise ValueError("no room for photos on a sheet this small")
    aspect = sum(w / h for w, h in sizes) / len(sizes)
    columns, rows = grid(len(sizes), aspect, (room_w, room_h), gap, label)
    cell_w = (room_w - gap * (columns - 1)) // columns
    cell_h = (room_h - gap * (rows - 1)) // rows
    if cell_w < 1 or cell_h - label < 1:
        raise ValueError("no room for photos on a sheet this small")
    left0 = gap + (room_w - (columns * cell_w + (columns - 1) * gap)) // 2
    top0 = gap + (room_h - (rows * cell_h + (rows - 1) * gap)) // 2
    boxes = []
    for index in range(len(sizes)):
        row, column = divmod(index, columns)
        boxes.append(
            Cell(
                left0 + column * (cell_w + gap), top0 + row * (cell_h + gap), cell_w, cell_h - label
            )
        )
    wedge = None
    if layout.wedge:
        step = room_w // WEDGE_STEPS
        wedge = (gap + (room_w - step * WEDGE_STEPS) // 2, height - gap - wedge_h, step, wedge_h)
    return boxes, wedge


def _spans(start: int, length: int, out: int) -> NDArray[np.int64]:
    """The first source index of each of `out` boxes covering [start, start + length)."""
    return start + (np.arange(out, dtype=np.int64) * length) // out


def resize(
    pixels: NDArray[np.uint16], region: tuple[int, int, int, int], size: tuple[int, int]
) -> NDArray[np.uint16]:
    """`region` (left, top, width, height) of a photo resized to `size` (width, height):
    each output pixel is the rounded mean of the source pixels its box covers (the
    nearest source pixel when enlarging)."""
    left, top, region_w, region_h = region
    out_w, out_h = size
    xs, ys = _spans(left, region_w, out_w), _spans(top, region_h, out_h)
    source = pixels[top : top + region_h, left : left + region_w].astype(np.int64)
    if out_w <= region_w:
        across = np.add.reduceat(source, xs - left, axis=1)
        x_count = np.diff(np.append(xs, left + region_w))
    else:
        across, x_count = source[:, xs - left], np.ones(out_w, dtype=np.int64)
    if out_h <= region_h:
        both = np.add.reduceat(across, ys - top, axis=0)
        y_count = np.diff(np.append(ys, top + region_h))
    else:
        both, y_count = across[ys - top, :], np.ones(out_h, dtype=np.int64)
    count = y_count[:, None] * x_count[None, :]
    out: NDArray[np.uint16] = ((both + count // 2) // count).astype(np.uint16)
    return out


def thumbnail(
    pixels: NDArray[np.uint16], cell: Cell, crop: bool
) -> tuple[NDArray[np.uint16], int, int]:
    """The photo sized for its cell, and its (left, top) on the sheet (centred in the cell)."""
    height, width = pixels.shape
    if crop:  # the largest centred part of the photo with the cell's shape
        if width * cell.height > height * cell.width:
            region_w, region_h = max(1, (height * cell.width) // cell.height), height
        else:
            region_w, region_h = width, max(1, (width * cell.height) // cell.width)
        region = ((width - region_w) // 2, (height - region_h) // 2, region_w, region_h)
        return resize(pixels, region, (cell.width, cell.height)), cell.left, cell.top
    if width * cell.height > height * cell.width:  # wider than the cell: width limits
        out_w, out_h = cell.width, max(1, round(height * cell.width / width))
    else:
        out_w, out_h = max(1, round(width * cell.height / height)), cell.height
    left = cell.left + (cell.width - out_w) // 2
    top = cell.top + (cell.height - out_h) // 2
    return resize(pixels, (0, 0, width, height), (out_w, out_h)), left, top


def make_sheet(
    photos: list[NDArray[np.uint16]],
    names: list[str] | None = None,
    layout: SheetLayout | None = None,
    dpi: float = 300.0,
) -> NDArray[np.uint16]:
    """The contact sheet at `dpi`, greyscale (0 black .. 65535 white)."""
    layout = layout or SheetLayout()
    if any(photo.ndim != 2 for photo in photos):
        raise ValueError("photos must be greyscale")
    boxes, wedge = cells([(p.shape[1], p.shape[0]) for p in photos], layout, dpi)
    fill = 0 if layout.background == "black" else MAX_VALUE
    sheet = np.full((_px(layout.height, dpi), _px(layout.width, dpi)), fill, dtype=np.uint16)
    for photo, cell in zip(photos, boxes, strict=True):
        thumb, left, top = thumbnail(photo, cell, layout.crop)
        sheet[top : top + thumb.shape[0], left : left + thumb.shape[1]] = thumb
    if wedge:
        left, top, step, wedge_h = wedge
        for index, level in enumerate(wedge_levels(WEDGE_STEPS)[::-1]):  # black to white
            sheet[top : top + wedge_h, left + index * step : left + (index + 1) * step] = level
    if layout.labels and names:
        _draw_labels(sheet, names, boxes, layout, dpi)
    return sheet


def _draw_labels(
    sheet: NDArray[np.uint16], names: list[str], boxes: list[Cell], layout: SheetLayout, dpi: float
) -> None:
    """File names under the thumbnails, in white on black (black on white)."""
    mask = Image.new("L", (sheet.shape[1], sheet.shape[0]), 0)
    draw = ImageDraw.Draw(mask)
    font = ImageFont.load_default(size=max(6, round(layout.label_height * dpi * 0.6)))
    for name, cell in zip(names, boxes, strict=False):
        text = name
        while text and draw.textlength(text, font=font) > cell.width:
            text = text[:-1]
        if text != name and len(text) > 1:
            text = text[:-1] + "…"
        draw.text(
            (cell.left, cell.top + cell.height + round(0.03 * dpi)), text, fill=255, font=font
        )
    covered = np.asarray(mask) > 127
    sheet[covered] = MAX_VALUE if layout.background == "black" else 0
