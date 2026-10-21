"""OpenQuad command line: make targets, tone images, calibrate and print them."""

from __future__ import annotations

import argparse
import shlex
import sys
import tempfile
from collections.abc import Sequence
from pathlib import Path

import numpy as np
import tifffile
from numpy.typing import NDArray

from openquad import __version__
from openquad.composite import PRESETS, composite
from openquad.escl import INTENTS, Fetch, ScanError, ScanSettings, http_fetch, scan
from openquad.greybalance import (
    Calibration,
    build_calibration,
    load_calibration,
    save_calibration,
)
from openquad.imageio import GreyImage, load_grey, read_dpi, save_grey, save_rgb, srgb_profile
from openquad.measure import Measurement, load_scan, measure_scan
from openquad.printing import PrintError, PrintJob, Runner, list_printers, run_command, send
from openquad.targets import framed_target, step_wedge, wedge_levels

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

    target = commands.add_parser("target", help="make a target TIFF to print")
    target.add_argument("-o", "--output", type=Path, required=True, help="TIFF to write")
    target.add_argument(
        "--kind",
        choices=["wedge", "grey-balance"],
        default="wedge",
        help="wedge: plain greyscale step wedge; grey-balance: framed RGB target to scan",
    )
    target.add_argument("--steps", type=int, default=21, help="wedge patches (default 21)")
    target.add_argument("--patch-width", type=int, default=100, help="wedge pixels (default 100)")
    target.add_argument("--patch-height", type=int, default=100, help="wedge pixels (default 100)")
    target.add_argument("--vertical", action="store_true", help="wedge: stack top to bottom")
    target.add_argument("--dpi", type=float, default=DEFAULT_DPI, help="resolution (default 300)")
    target.add_argument("--calibration", type=Path, help="grey-balance: apply this calibration")

    comp = commands.add_parser("composite", help="tone a greyscale TIFF with colour layers")
    comp.add_argument("input", type=Path, help="16-bit (or 8-bit) greyscale TIFF")
    comp.add_argument("-o", "--output", type=Path, required=True, help="sRGB TIFF to write")
    comp.add_argument("--preset", choices=sorted(PRESETS), default="black-red")
    comp.add_argument("--dpi", type=float, help="override the input's resolution")
    comp.add_argument("--calibration", type=Path, help="grey-balance calibration to apply")

    commands.add_parser("presets", help="list the colour-layer presets")

    prt = commands.add_parser("print", help="print a TIFF through the printer's normal driver")
    prt.add_argument("input", type=Path, help="TIFF to print")
    prt.add_argument("--printer", required=True, help="CUPS printer name (see 'printers')")
    prt.add_argument("--paper", default="Letter", help="page size (default Letter)")
    prt.add_argument("--copies", type=int, default=1)
    prt.add_argument("--ppi", type=float, help="print resolution; default: the file's own DPI")
    prt.add_argument("--preset", choices=sorted(PRESETS), help="tone a greyscale input first")
    prt.add_argument("--calibration", type=Path, help="grey-balance calibration to apply")
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

    scn = commands.add_parser("scan", help="scan the platen over eSCL (AirScan) to a JPEG")
    scn.add_argument("--host", required=True, help="scanner host, e.g. 876298000000.local")
    scn.add_argument("-o", "--output", type=Path, required=True, help="JPEG to write")
    scn.add_argument("--dpi", type=int, default=300, help="scan resolution (default 300)")
    scn.add_argument(
        "--intent", choices=INTENTS, default="Document", help="scanner mode (default Document)"
    )

    msr = commands.add_parser("measure", help="measure a scanned grey-balance target")
    msr.add_argument("scan", type=Path, help="scan of the printed target (JPEG, PNG or TIFF)")
    msr.add_argument("-o", "--output", type=Path, required=True, help="measurement JSON")
    msr.add_argument("--calibration", type=Path, help="calibration used when printing it")

    gb = commands.add_parser("greybalance", help="build a grey-balance calibration")
    gb.add_argument("measurement", type=Path, help="measurement JSON from 'measure'")
    gb.add_argument("-o", "--output", type=Path, required=True, help="calibration to write")
    gb.add_argument("--printer", default="", help="printer it was made for")
    gb.add_argument("--paper", default="", help="paper it was made for")
    gb.add_argument("--settings", default="", help="driver settings it was made with")
    return parser


def _calibration(path: Path | None) -> Calibration | None:
    return load_calibration(path) if path else None


def _target(args: argparse.Namespace) -> None:
    dpi = (args.dpi, args.dpi)
    if args.kind == "grey-balance":
        sheet = framed_target(dpi=args.dpi)
        calibration = _calibration(args.calibration)
        if calibration:
            sheet = calibration.apply(sheet)
        save_rgb(args.output, sheet, dpi, srgb_profile())
        note = " with calibration" if calibration else ""
        print(f"wrote {args.output} (grey-balance target{note}, {args.dpi:g} dpi)")
        return
    pixels = step_wedge(args.steps, args.patch_width, args.patch_height, vertical=args.vertical)
    save_grey(args.output, GreyImage(pixels, dpi=dpi))
    print(f"wrote {args.output} ({args.steps} steps, {args.dpi:g} dpi)")


def _composite_file(
    source: Path, output: Path, preset: str, dpi: float | None, calibration: Calibration | None
) -> None:
    image = load_grey(source)
    resolution = (dpi, dpi) if dpi else image.dpi or (DEFAULT_DPI, DEFAULT_DPI)
    rgb = composite(image.pixels, PRESETS[preset])
    if calibration:
        rgb = calibration.apply(rgb)
    save_rgb(output, rgb, resolution, srgb_profile())


def _calibrate_file(source: Path, output: Path, calibration: Calibration) -> None:
    pixels: NDArray[np.uint16] = np.asarray(tifffile.imread(source))
    if pixels.dtype == np.uint8:
        pixels = pixels.astype(np.uint16) * 257
    if pixels.ndim == 2:
        pixels = np.repeat(pixels[..., np.newaxis], 3, axis=-1)
    if pixels.dtype != np.uint16 or pixels.ndim != 3 or pixels.shape[-1] != 3:
        raise ValueError(f"{source}: expected an 8/16-bit greyscale or RGB TIFF")
    save_rgb(output, calibration.apply(pixels), read_dpi(source), srgb_profile())


def _composite(args: argparse.Namespace) -> None:
    calibration = _calibration(args.calibration)
    _composite_file(args.input, args.output, args.preset, args.dpi, calibration)
    print(f"wrote {args.output} (preset {args.preset})")


def _presets() -> None:
    for name in sorted(PRESETS):
        layers = ", ".join(layer.name for layer in PRESETS[name])
        print(f"{name}: {layers}")


def _print(args: argparse.Namespace, runner: Runner) -> None:
    if not args.input.is_file():
        raise PrintError(f"file not found: {args.input}")
    calibration = _calibration(args.calibration)
    with tempfile.TemporaryDirectory(prefix="openquad-") as scratch:
        path = args.input
        if args.preset:
            path = Path(scratch) / f"{args.input.stem}-{args.preset}.tif"
            _composite_file(args.input, path, args.preset, args.ppi, calibration)
        elif calibration:
            path = Path(scratch) / f"{args.input.stem}-calibrated.tif"
            _calibrate_file(args.input, path, calibration)
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


def _scan(args: argparse.Namespace, fetch: Fetch) -> None:
    path = scan(args.host, args.output, ScanSettings(dpi=args.dpi, intent=args.intent), fetch=fetch)
    print(f"wrote {path} ({args.dpi} dpi, {args.intent})")


def _measure(args: argparse.Namespace) -> None:
    calibration = _calibration(args.calibration)
    sent = calibration.sent_for(wedge_levels(21)) if calibration else None
    measurement = measure_scan(load_scan(args.scan), sent=sent)
    args.output.write_text(measurement.to_json() + "\n", encoding="utf-8")
    print("step   level     L*      a*      b*")
    for step, (level, (l_star, a_star, b_star)) in enumerate(
        zip(measurement.levels, measurement.lab, strict=True), start=1
    ):
        print(f"{step:>4} {int(level):>7} {l_star:6.1f} {a_star:7.1f} {b_star:7.1f}")
    print(f"worst cast (largest |a*| or |b*|): {measurement.worst_cast():.1f}")
    print(f"wrote {args.output}")


def _greybalance(args: argparse.Namespace) -> None:
    measurement = Measurement.from_json(args.measurement.read_text(encoding="utf-8"))
    calibration = build_calibration(
        measurement, printer=args.printer, paper=args.paper, settings=args.settings
    )
    save_calibration(calibration, args.output)
    print(f"wrote {args.output} (from a wedge with worst cast {measurement.worst_cast():.1f})")


def main(
    argv: Sequence[str] | None = None, runner: Runner = run_command, fetch: Fetch = http_fetch
) -> int:
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
        elif args.command == "scan":
            _scan(args, fetch)
        elif args.command == "measure":
            _measure(args)
        elif args.command == "greybalance":
            _greybalance(args)
        else:
            parser.print_help()
    except (OSError, ValueError, PrintError, ScanError) as exc:
        print(f"openquad: error: {exc}", file=sys.stderr)
        return 1
    return 0
