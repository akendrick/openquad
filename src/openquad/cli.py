"""OpenQuad command line: make targets, tone images and print them."""

from __future__ import annotations

import argparse
import shlex
import sys
import tempfile
from collections.abc import Sequence
from pathlib import Path

from openquad import __version__
from openquad.composite import PRESETS, composite
from openquad.imageio import GreyImage, load_grey, read_dpi, save_grey, save_rgb, srgb_profile
from openquad.printing import PrintError, PrintJob, Runner, list_printers, run_command, send
from openquad.targets import step_wedge

DEFAULT_DPI = 300.0


def _option(text: str) -> tuple[str, str]:
    name, sep, value = text.partition("=")
    if not sep or not name:
        raise argparse.ArgumentTypeError(f"expected NAME=VALUE, got {text!r}")
    return (name, value)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="openquad", description=__doc__)
    parser.add_argument("--version", action="version", version=f"openquad {__version__}")
    commands = parser.add_subparsers(dest="command", metavar="COMMAND")

    target = commands.add_parser("target", help="make a step-wedge target TIFF")
    target.add_argument("-o", "--output", type=Path, required=True, help="TIFF to write")
    target.add_argument("--steps", type=int, default=21, help="number of patches (default 21)")
    target.add_argument("--patch-width", type=int, default=100, help="pixels (default 100)")
    target.add_argument("--patch-height", type=int, default=100, help="pixels (default 100)")
    target.add_argument("--vertical", action="store_true", help="stack patches top to bottom")
    target.add_argument("--dpi", type=float, default=DEFAULT_DPI, help="resolution (default 300)")

    comp = commands.add_parser("composite", help="tone a greyscale TIFF with colour layers")
    comp.add_argument("input", type=Path, help="16-bit (or 8-bit) greyscale TIFF")
    comp.add_argument("-o", "--output", type=Path, required=True, help="sRGB TIFF to write")
    comp.add_argument("--preset", choices=sorted(PRESETS), default="black-red")
    comp.add_argument("--dpi", type=float, help="override the input's resolution")

    commands.add_parser("presets", help="list the colour-layer presets")

    prt = commands.add_parser("print", help="print a TIFF through the printer's normal driver")
    prt.add_argument("input", type=Path, help="TIFF to print")
    prt.add_argument("--printer", required=True, help="CUPS printer name (see 'printers')")
    prt.add_argument("--paper", default="Letter", help="page size (default Letter)")
    prt.add_argument("--copies", type=int, default=1)
    prt.add_argument("--ppi", type=float, help="print resolution; default: the file's own DPI")
    prt.add_argument("--preset", choices=sorted(PRESETS), help="tone a greyscale input first")
    prt.add_argument("--title", help="job title shown in the print queue")
    prt.add_argument(
        "--option",
        type=_option,
        action="append",
        default=[],
        metavar="NAME=VALUE",
        help="extra driver option passed to lp -o (repeatable)",
    )
    prt.add_argument("--dry-run", action="store_true", help="show the lp command, don't print")

    commands.add_parser("printers", help="list printers set up on this computer")
    return parser


def _target(args: argparse.Namespace) -> None:
    pixels = step_wedge(args.steps, args.patch_width, args.patch_height, vertical=args.vertical)
    save_grey(args.output, GreyImage(pixels, dpi=(args.dpi, args.dpi)))
    print(f"wrote {args.output} ({args.steps} steps, {args.dpi:g} dpi)")


def _composite_file(source: Path, output: Path, preset: str, dpi: float | None) -> None:
    image = load_grey(source)
    resolution = (dpi, dpi) if dpi else image.dpi or (DEFAULT_DPI, DEFAULT_DPI)
    save_rgb(output, composite(image.pixels, PRESETS[preset]), resolution, srgb_profile())


def _composite(args: argparse.Namespace) -> None:
    _composite_file(args.input, args.output, args.preset, args.dpi)
    print(f"wrote {args.output} (preset {args.preset})")


def _presets() -> None:
    for name in sorted(PRESETS):
        layers = ", ".join(layer.name for layer in PRESETS[name])
        print(f"{name}: {layers}")


def _print(args: argparse.Namespace, runner: Runner) -> None:
    if not args.input.is_file():
        raise PrintError(f"file not found: {args.input}")
    with tempfile.TemporaryDirectory(prefix="openquad-") as scratch:
        path = args.input
        if args.preset:
            path = Path(scratch) / f"{args.input.stem}-{args.preset}.tif"
            _composite_file(args.input, path, args.preset, args.ppi)
        ppi = args.ppi or (read_dpi(path) or (DEFAULT_DPI, DEFAULT_DPI))[0]
        job = PrintJob(
            path=path,
            printer=args.printer,
            paper=args.paper,
            ppi=ppi,
            copies=args.copies,
            title=args.title or f"OpenQuad: {args.input.name}",
            options=tuple(args.option),
        )
        if args.dry_run:
            print(shlex.join(job.command()))
            return
        print(f"printing {args.input} on {args.printer}: job {send(job, runner)}")


def main(argv: Sequence[str] | None = None, runner: Runner = run_command) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        if args.command == "target":
            _target(args)
        elif args.command == "composite":
            _composite(args)
        elif args.command == "presets":
            _presets()
        elif args.command == "print":
            _print(args, runner)
        elif args.command == "printers":
            for name in list_printers(runner):
                print(name)
        else:
            parser.print_help()
    except (OSError, ValueError, PrintError) as exc:
        print(f"openquad: error: {exc}", file=sys.stderr)
        return 1
    return 0
