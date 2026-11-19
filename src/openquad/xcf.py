"""Read GIMP's own .xcf files, by asking GIMP 3 to merge them into a 16-bit TIFF.

An XCF holds layers, masks, blend modes and effects that only GIMP composites exactly, so
GIMP does it: `gimp-console` loads the file, merges the visible layers (keeping
transparency, so transparent edges are still cropped), turns an indexed image into RGB and
any depth other than 8-bit into 16-bit, and saves a TIFF that `photo.load_photo` reads as
usual. It takes a few seconds. Swift: Xcf.swift, with the same script.

GIMP is found through OPENQUAD_GIMP (a gimp-console program or a GIMP.app), then GIMP.app
in /Applications or ~/Applications, then gimp-console on the PATH.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

from openquad.imageio import ImageFormatError

SIGNATURE = b"gimp xcf "
TIMEOUT = 180.0  # seconds; a large XCF takes a while
CONSOLE_NAMES = ("gimp-console-3.2", "gimp-console-3.0", "gimp-console-3", "gimp-console")
NEEDS_GIMP = "opening a GIMP .xcf file needs GIMP 3 installed (or export it from GIMP as a TIFF)"

# Run inside GIMP's Python; the paths come in through the environment, never in the code.
SCRIPT = """\
import os
from gi.repository import Gimp, Gio
quietly, file = Gimp.RunMode.NONINTERACTIVE, Gio.File.new_for_path
image = Gimp.file_load(quietly, file(os.environ["OPENQUAD_XCF_IN"]))
if image.get_base_type() == Gimp.ImageBaseType.INDEXED:
    image.convert_rgb()
if image.get_precision() != Gimp.Precision.U8_NON_LINEAR:
    image.convert_precision(Gimp.Precision.U16_NON_LINEAR)
image.merge_visible_layers(Gimp.MergeType.CLIP_TO_IMAGE)
Gimp.file_save(quietly, image, file(os.environ["OPENQUAD_XCF_OUT"]), None)
image.delete()
"""


def is_xcf(head: bytes) -> bool:
    """Do these first bytes of a file start a GIMP XCF?"""
    return head.startswith(SIGNATURE)


def _console_in(app: Path) -> Path | None:
    for name in CONSOLE_NAMES:
        candidate = app / "Contents" / "MacOS" / name
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate
    return None


def app_folders() -> list[Path]:
    """Where GIMP.app is looked for."""
    return [Path("/Applications"), Path.home() / "Applications"]


def find_gimp(
    environ: dict[str, str] | None = None, folders: list[Path] | None = None
) -> Path | None:
    """The gimp-console program to run, or None if GIMP isn't installed."""
    environ = dict(os.environ) if environ is None else environ
    chosen = environ.get("OPENQUAD_GIMP")
    if chosen:
        path = Path(chosen)
        if path.suffix == ".app":
            return _console_in(path)
        return path if path.is_file() and os.access(path, os.X_OK) else None
    for folder in app_folders() if folders is None else folders:
        for app in sorted(folder.glob("GIMP*.app"), reverse=True):
            found = _console_in(app)
            if found:
                return found
    for name in CONSOLE_NAMES:
        found_on_path = shutil.which(name, path=environ.get("PATH"))
        if found_on_path:
            return Path(found_on_path)
    return None


def command(gimp: Path) -> list[str]:
    """The command line: no window, no fonts or brushes to load, run the script, quit."""
    return [
        str(gimp),
        "-i",
        "-d",
        "-f",
        "--quit",
        "--batch-interpreter=python-fu-eval",
        "-b",
        SCRIPT,
    ]


@contextmanager
def flattened(path: Path, gimp: Path | None = None) -> Iterator[Path]:
    """The XCF merged into a TIFF (in a temporary folder, removed afterwards)."""
    gimp = gimp or find_gimp()
    if gimp is None:
        raise ImageFormatError(f"{path}: {NEEDS_GIMP}")
    with tempfile.TemporaryDirectory(prefix="openquad-xcf-") as folder:
        out = Path(folder) / f"{path.stem}.tif"
        environ = dict(os.environ, OPENQUAD_XCF_IN=str(path.resolve()), OPENQUAD_XCF_OUT=str(out))
        try:
            result = subprocess.run(
                command(gimp), env=environ, capture_output=True, text=True, timeout=TIMEOUT,
                check=False,
            )  # fmt: skip
        except subprocess.TimeoutExpired:
            raise ImageFormatError(f"{path}: GIMP took too long to open it") from None
        except OSError as e:
            raise ImageFormatError(f"{path}: could not run GIMP ({e.strerror})") from None
        if not out.is_file():
            lines = [line for line in (result.stderr + result.stdout).splitlines() if line.strip()]
            detail = f" ({lines[-1].strip()})" if lines else ""
            raise ImageFormatError(f"{path}: GIMP 3 could not open it{detail}")
        yield out
