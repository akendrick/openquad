"""OpenQuad command line: make targets, tone images, calibrate and print them."""

from __future__ import annotations

import argparse
import shlex
import sys
import tempfile
from collections.abc import Sequence
from dataclasses import replace
from pathlib import Path

import numpy as np
import tifffile
from numpy.typing import NDArray
from PIL import Image

from openquad import __version__
from openquad.blocking import BlockingLayout, analyse, blocking_scale, blocking_sheet
from openquad.chart import (
    PAGE_EDGE,
    SMOOTHING,
    ChartReading,
    ProcessCurve,
    build_process_curve,
    chart_negative,
    chart_page,
    chart_scale,
    clipped_tones,
    clipping_advice,
    load_process,
    page_scale,
    read_chart,
    read_chart_page,
    save_process,
    tone_errors,
)
from openquad.composite import DEFAULT_PRESET, PRESETS, composite
from openquad.contactsheet import BACKGROUNDS, MAX_PHOTOS, SheetLayout, make_sheet
from openquad.curve_export import FORMATS, export_curve
from openquad.escl import INTENTS, Fetch, ScanError, ScanSettings, http_fetch, scan
from openquad.greybalance import (
    Calibration,
    build_calibration,
    comparison_page,
    load_calibration,
    save_calibration,
)
from openquad.imageio import GreyImage, read_dpi, save_grey, save_rgb, srgb_profile
from openquad.linearize import linearize, tone_report
from openquad.measure import Measurement, load_scan, measure_pair, measure_scan
from openquad.negative import (
    DEFAULT_COLOUR,
    MIXTURE_COLOURS,
    NEGATIVE_COLOURS,
    NegativeSettings,
    make_negative,
    negative_ppi,
)
from openquad.paper import DEFAULT_MARGIN, box_ppi, fit_ppi
from openquad.photo import load_photo
from openquad.printing import PrintError, PrintJob, Runner, list_printers, run_command, send
from openquad.separations import (
    DEFAULT_STEPS,
    MAX_SEPARATIONS,
    SeparationPlan,
    coat_image,
    step_test,
)
from openquad.targets import framed_target, step_wedge, wedge_levels

DEFAULT_DPI = 300.0


def _colours(text: str) -> list[str]:
    names = [name.strip() for name in text.split(",") if name.strip()]
    unknown = [name for name in names if name not in NEGATIVE_COLOURS]
    if not names or unknown:
        raise argparse.ArgumentTypeError(
            f"choose from {', '.join(NEGATIVE_COLOURS)} (comma-separated), got {text!r}"
        )
    return names


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
        choices=["wedge", "grey-balance", "comparison", "blocking", "chart", "steps"],
        default="wedge",
        help="wedge: greyscale step wedge; grey-balance: framed RGB target to scan; "
        "comparison: uncorrected + corrected targets on one page (needs --calibration); "
        "blocking: digital-negative colour test sheet; "
        "chart: ChartThrob-style process chart as a negative (--colour, --process); "
        "steps: numbered step scale over a continuous gradient, to print through a separation "
        "(openquad negative --separations)",
    )
    target.add_argument("--steps", type=int,
                        help="wedge patches (default 21); for --kind steps, the step "
                             "scale (default 30)")  # fmt: skip
    target.add_argument("--patch-width", type=int, default=100, help="wedge pixels (default 100)")
    target.add_argument("--patch-height", type=int, default=100, help="wedge pixels (default 100)")
    target.add_argument("--vertical", action="store_true", help="wedge: stack top to bottom")
    target.add_argument("--dpi", type=float, default=DEFAULT_DPI, help="resolution (default 300)")
    target.add_argument("--calibration", type=Path, help="grey-balance: apply this calibration")
    target.add_argument("--mirror", action="store_true", help="blocking/chart: mirror the sheet")
    target.add_argument("--size", metavar="WxH", type=_inches_pair,
                        help="blocking/chart: enlarge or shrink the sheet to fit within W x H "
                             "inches, safe edge included (turned to match)")  # fmt: skip
    _mark_arguments(target, "blocking/chart: ")
    target.add_argument(
        "--mixtures",
        action="store_true",
        help="blocking: the ink-mixture chart (10 printable colours) instead of the usual 6",
    )
    target.add_argument(
        "--colour",
        type=_colours,
        default=["green"],
        help="chart: negative colour, or several stacked on one page, e.g. green,orange",
    )
    target.add_argument(
        "--process",
        type=Path,
        action="append",
        default=[],
        help="chart: print through this process curve (one per colour, in order)",
    )

    comp = commands.add_parser("composite", help="tone a greyscale TIFF with colour layers")
    comp.add_argument("input", type=Path, help="16-bit (or 8-bit) greyscale TIFF")
    comp.add_argument("-o", "--output", type=Path, required=True, help="sRGB TIFF to write")
    comp.add_argument(
        "--preset",
        choices=sorted(PRESETS),
        default=DEFAULT_PRESET,
        help=f"colour layers (default {DEFAULT_PRESET}: no toning)",
    )
    comp.add_argument("--dpi", type=float, help="override the input's resolution")
    comp.add_argument("--calibration", type=Path, help="grey-balance calibration to apply")

    commands.add_parser("presets", help="list the colour-layer presets")

    crt = commands.add_parser("chart", help="read a scanned print of the process chart")
    crt.add_argument("scan", type=Path, help="scan of the contact print (JPEG, PNG or TIFF)")
    crt.add_argument(
        "--colours",
        type=_colours,
        default=None,
        help="a page of stacked charts, top to bottom, e.g. green,orange",
    )
    crt.add_argument(
        "--process",
        type=Path,
        action="append",
        default=[],
        help="process curve each chart was printed through (one per chart, in order)",
    )
    crt.add_argument(
        "-o", "--output", type=Path, help="process curve (.oqproc) to write; NAME-COLOUR for a page"
    )
    crt.add_argument("--film", default="", help="film it was made for")
    crt.add_argument("--printing", default="", help="printer and print dialog settings")
    crt.add_argument(
        "--smoothing",
        choices=list(SMOOTHING),
        default="medium",
        help="how much the curve evens out patch-to-patch noise (default medium)",
    )

    crv = commands.add_parser(
        "curve", help="export a process curve for other software, or apply it to a photo"
    )
    crv.add_argument("curve", type=Path, help="process curve (.oqproc)")
    crv.add_argument(
        "output",
        type=Path,
        help=f"file to write: {', '.join(FORMATS)}, or .tif (with --image) for the curved photo",
    )
    crv.add_argument("--image", type=Path, help="photo to apply the curve to (16-bit grey TIFF)")

    blk = commands.add_parser("blocking", help="read a scanned print of the blocking test")
    blk.add_argument("scan", type=Path, help="scan of the exposed print (JPEG, PNG or TIFF)")
    blk.add_argument("--mixtures", action="store_true", help="it is the ink-mixture chart")

    neg = commands.add_parser("negative", help="make a digital negative for contact printing")
    neg.add_argument("input", type=Path, help="greyscale photo (any bit depth; RGB/RGBA grey too)")
    neg.add_argument("-o", "--output", type=Path, required=True, help="negative TIFF to write")
    neg.add_argument("--colour", choices=sorted(NEGATIVE_COLOURS), default=DEFAULT_COLOUR,
                     help="ink colour of the negative (default black)")  # fmt: skip
    neg.add_argument("--mirror", action="store_true", help="flip left to right")
    neg.add_argument("--safe-edge", type=float, default=0.25, help="opaque border, inches (0.25)")
    neg.add_argument("--no-mark", action="store_true", help="leave the orientation F out")
    neg.add_argument("--outline", type=float, default=0.0, metavar="INCHES",
                     help="black outline inside the safe edge (default none)")  # fmt: skip
    neg.add_argument("--process", type=Path, help="process curve (.oqproc) to apply first")
    _mark_arguments(neg)
    size = neg.add_mutually_exclusive_group()
    size.add_argument("--dpi", type=float, help="print resolution (default: the photo's own)")
    size.add_argument("--fit", metavar="PAPER", help="size photo + safe edge to fit PAPER")
    neg.add_argument("--max-size", metavar="WxH", type=_inches_pair,
                     help="with --fit: also keep within W x H inches, safe edge included "
                          "(e.g. 8x10 for the tissue; turned to match the photo)")  # fmt: skip
    seps = neg.add_argument_group(
        "separations", "split the negative by tone into several, printed one after another in "
        "register on one sheet (writes OUTPUT-1of3.tif, OUTPUT-2of3.tif, ...)")  # fmt: skip
    seps.add_argument("--separations", type=int, default=1, metavar="N",
                      help=f"how many negatives (1-{MAX_SEPARATIONS}; default 1)")  # fmt: skip
    seps.add_argument("--splits", type=_step_list, metavar="STEPS",
                      help="where the bands meet, in steps from paper white, lightest first "
                           "(e.g. 10,20; default: even bands)")  # fmt: skip
    seps.add_argument("--steps", type=int, default=DEFAULT_STEPS,
                      help=f"the step scale --splits and --overlap count on "
                           f"(default {DEFAULT_STEPS})")  # fmt: skip
    seps.add_argument("--overlap", type=float, default=0.0, metavar="STEPS",
                      help="how many steps neighbouring bands blend over (default 0)")  # fmt: skip
    seps.add_argument("--layer-process", action="append", default=[], metavar="K=CURVE",
                      help="process curve for negative K alone "
                           "(repeat; the others use --process)")  # fmt: skip

    sheet = commands.add_parser("contact-sheet", help="up to 16 photos as thumbnails on one sheet")
    sheet.add_argument("inputs", type=Path, nargs="+", metavar="PHOTO", help="photos (1-16)")
    sheet.add_argument("-o", "--output", type=Path, required=True, help="greyscale TIFF to write")
    sheet.add_argument(
        "--size",
        metavar="WxH",
        type=_inches_pair,
        default=(7.5, 10.0),
        help="sheet size in inches (default 7.5x10: Letter inside 0.5 in margins)",
    )
    sheet.add_argument("--dpi", type=float, default=DEFAULT_DPI, help="resolution (default 300)")
    sheet.add_argument("--gap", type=float, default=0.15, help="inches between photos (0.15)")
    sheet.add_argument(
        "--background",
        choices=BACKGROUNDS,
        default="black",
        help="sheet background (default black)",
    )
    sheet.add_argument("--crop", action="store_true", help="crop photos to fill their cells")
    sheet.add_argument(
        "--wedge", action="store_true", help="a 21-step greyscale wedge at the bottom"
    )
    sheet.add_argument("--labels", action="store_true", help="file names under the photos")

    prt = commands.add_parser("print", help="print a TIFF through the printer's normal driver")
    prt.add_argument("input", type=Path, help="TIFF to print")
    prt.add_argument("--printer", required=True, help="CUPS printer name (see 'printers')")
    prt.add_argument("--paper", default="Letter", help="page size (default Letter)")
    prt.add_argument("--copies", type=int, default=1)
    size = prt.add_mutually_exclusive_group()
    size.add_argument("--ppi", type=float, help="print resolution; default: the file's own DPI")
    size.add_argument(
        "--fit", action="store_true", help="scale to fit the paper with 0.5 in margins"
    )
    prt.add_argument(
        "--preset",
        choices=sorted(PRESETS),
        help="tone a greyscale input first (default: print the file as it is)",
    )
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
    msr.add_argument(
        "--pair",
        action="store_true",
        help="scan of a comparison page: writes OUTPUT-uncorrected.json and -corrected.json",
    )

    gb = commands.add_parser("greybalance", help="build a grey-balance calibration")
    gb.add_argument("measurement", type=Path, help="measurement JSON from 'measure'")
    gb.add_argument("-o", "--output", type=Path, required=True, help="calibration to write")
    gb.add_argument(
        "--damping", type=float, default=1.0, help="fraction of each correction to apply (0-1)"
    )
    gb.add_argument(
        "--shadow-damping", type=float, help="damping for the darkest steps (17-21) instead"
    )
    gb.add_argument("--printer", default="", help="printer it was made for")
    gb.add_argument("--paper", default="", help="paper it was made for")
    gb.add_argument("--settings", default="", help="driver settings it was made with")

    lin = commands.add_parser(
        "linearize", help="even out tone: fold a tone curve into a calibration"
    )
    lin.add_argument("measurement", type=Path, help="measurement of a target printed with CAL")
    lin.add_argument("--calibration", type=Path, required=True, help="CAL the target used")
    lin.add_argument("-o", "--output", type=Path, help="linearized calibration to write")
    return parser


def _mark_arguments(parser: argparse.ArgumentParser, prefix: str = "") -> None:
    parser.add_argument("--guide", action="store_true",
                        help=f"{prefix}black guide line round the image, in the safe edge "
                             "(shows under a red safelight)")  # fmt: skip
    parser.add_argument("--registration", action="store_true",
                        help=f"{prefix}black registration marks in the safe edge")  # fmt: skip


def _calibration(path: Path | None) -> Calibration | None:
    return load_calibration(path) if path else None


def _target(args: argparse.Namespace) -> None:
    dpi = (args.dpi, args.dpi)
    marks = {"guide": args.guide, "registration": args.registration}
    if args.kind == "steps":
        steps = args.steps or DEFAULT_STEPS
        test = step_test(steps, args.dpi)
        save_grey(args.output, GreyImage(test, dpi=dpi))
        height, width = test.shape
        size = f"{width / args.dpi:.2f} x {height / args.dpi:.2f} in"
        print(f"wrote {args.output} (steps 0-{steps}, {size} at {args.dpi:g} dpi)")
        return
    if args.kind == "chart":
        processes = [load_process(path) for path in args.process]
        colours = [pr.colour for pr in processes] if processes else args.colour
        if processes and len(processes) != len(args.colour) and args.colour != ["green"]:
            raise ValueError("give one --process per colour")
        if len(colours) > 1:
            curves: list[ProcessCurve | None] = list(processes) or [None] * len(colours)
            scale = page_scale(len(colours), args.size) if args.size else 1.0
            sheet = chart_page(colours, curves, args.mirror, args.dpi, scale, **marks)
        else:
            process = processes[0] if processes else None
            scale = chart_scale(args.size) if args.size else 1.0
            sheet = chart_negative(colours[0], process, args.mirror, args.dpi * scale,
                                   safe_edge=PAGE_EDGE / scale, **marks)  # fmt: skip
        colour = " over ".join(colours)
        save_rgb(args.output, sheet, dpi, srgb_profile())
        width, height = sheet.shape[1] / args.dpi, sheet.shape[0] / args.dpi
        through = f", through {', '.join(p.name for p in args.process)}" if args.process else ""
        print(
            f"wrote {args.output} (process chart, {colour}{through}, {width:.2f} x {height:.2f} in)"
        )
        print("print it on film, contact print it, then scan the print: openquad chart SCAN")
        return
    if args.kind == "blocking":
        layout = _blocking_layout(args.mixtures)
        scale = blocking_scale(args.size, layout) if args.size else 1.0
        sheet = blocking_sheet(layout, args.dpi, args.mirror, scale=scale, **marks)
        save_rgb(args.output, sheet, dpi, srgb_profile())
        width, height = sheet.shape[1] / args.dpi, sheet.shape[0] / args.dpi
        print(f"wrote {args.output} (blocking test, {width:.2f} x {height:.2f} in): print it on")
        print("film, expose it at your usual time, then scan the print: openquad blocking SCAN")
        return
    if args.kind == "comparison":
        calibration = _calibration(args.calibration)
        if not calibration:
            raise ValueError("--kind comparison needs --calibration")
        save_rgb(args.output, comparison_page(calibration, args.dpi), dpi, srgb_profile())
        print(f"wrote {args.output} (comparison page: 1 mark uncorrected, 2 marks corrected)")
        return
    if args.kind == "grey-balance":
        sheet = framed_target(dpi=args.dpi)
        calibration = _calibration(args.calibration)
        if calibration:
            sheet = calibration.apply(sheet)
        save_rgb(args.output, sheet, dpi, srgb_profile())
        note = " with calibration" if calibration else ""
        print(f"wrote {args.output} (grey-balance target{note}, {args.dpi:g} dpi)")
        return
    steps = args.steps or 21
    pixels = step_wedge(steps, args.patch_width, args.patch_height, vertical=args.vertical)
    save_grey(args.output, GreyImage(pixels, dpi=dpi))
    print(f"wrote {args.output} ({steps} steps, {args.dpi:g} dpi)")


def _composite_file(
    source: Path, output: Path, preset: str, dpi: float | None, calibration: Calibration | None
) -> None:
    image = load_photo(source)
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


def _pixel_size(path: Path) -> tuple[int, int]:
    """(width, height) in pixels, without decoding the image."""
    if path.suffix.lower() in (".tif", ".tiff"):
        with tifffile.TiffFile(path) as tif:
            shape = tif.pages.first.shape
        return (int(shape[1]), int(shape[0]))
    with Image.open(path) as image:
        return image.size


def _blocking_layout(mixtures: bool) -> BlockingLayout:
    return BlockingLayout(colours=MIXTURE_COLOURS) if mixtures else BlockingLayout()


def _blocking(args: argparse.Namespace) -> None:
    report = analyse(load_scan(args.scan), _blocking_layout(args.mixtures))
    print(f"Read the print {report.orientation}.")
    for line in report.lines():
        print(line)


def _report_chart(reading: ChartReading, label: str) -> None:
    errors = tone_errors(reading)
    print(f"{label}: read {reading.orientation}.")
    print(f"Process white L* {reading.white:.1f}, black L* {reading.black:.1f} "
          f"(range {reading.white - reading.black:.1f}).")  # fmt: skip
    print("patch  tone   measured  target  error")
    for n in range(0, 101, 10):
        target = reading.lightness[n] - errors[n]
        print(
            f"{n:>5} {100 - n:>4}%  {reading.lightness[n]:8.1f}  {target:6.1f}  {errors[n]:+5.1f}"
        )
    worst, mean = abs(errors).max(), abs(errors).mean()
    print(f"tone error: worst {worst:.1f} L*, mean {mean:.2f} (goal under 3)")
    advice = clipping_advice(*clipped_tones(reading))
    if advice:
        print(f"warning: {advice}")


def _chart(args: argparse.Namespace) -> None:
    scan = load_scan(args.scan)
    colours = args.colours or [None]
    previous = [load_process(path) for path in args.process]
    if previous and len(previous) != len(colours):
        raise ValueError("give one --process per chart")
    readings = read_chart_page(scan, len(colours)) if args.colours else [read_chart(scan)]
    for k, (colour, reading) in enumerate(zip(colours, readings, strict=True)):
        label = f"Chart {k + 1} ({colour})" if colour else "Chart"
        _report_chart(reading, label)
        if args.output:
            before = previous[k] if previous else None
            if before is None and colour:
                before = ProcessCurve.identity(colour)
            curve = build_process_curve(
                reading, before, smoothing=SMOOTHING[args.smoothing], film=args.film,
                printing=args.printing,
            )  # fmt: skip
            path = args.output
            if args.colours:
                path = args.output.with_name(f"{args.output.stem}-{colour}{args.output.suffix}")
            save_process(curve, path)
            print(f"wrote {path}")


def _curve(args: argparse.Namespace) -> None:
    curve = load_process(args.curve)
    if args.output.suffix.lower() in (".tif", ".tiff"):
        if not args.image:
            raise ValueError("give --image PHOTO to write a curved photo")
        photo = load_photo(args.image)
        save_grey(args.output, GreyImage(curve.apply(photo.pixels), photo.dpi))
    elif args.image:
        raise ValueError("--image needs a .tif output")
    else:
        export_curve(curve, args.output)
    print(f"wrote {args.output}")


def _step_list(text: str) -> list[float]:
    """'10,20' -> [10.0, 20.0]."""
    try:
        return [float(part) for part in text.replace(" ", "").split(",")]
    except ValueError:
        raise argparse.ArgumentTypeError(f"expected steps like 10,20, got {text!r}") from None


def _separation(args: argparse.Namespace) -> SeparationPlan | None:
    """The separation the negative command asks for, or None for one negative."""
    if args.separations == 1 and args.splits is None:
        if args.layer_process:
            raise ValueError("--layer-process needs --separations")
        return None
    if args.splits is None:
        plan = SeparationPlan.even(args.separations, args.overlap / args.steps, args.steps)
    else:
        if args.separations not in (1, len(args.splits) + 1):
            raise ValueError(
                f"{len(args.splits)} split points make {len(args.splits) + 1} negatives, "
                f"not {args.separations}"
            )
        plan = SeparationPlan(
            tuple(s / args.steps for s in args.splits), args.overlap / args.steps, args.steps
        )
    return plan if plan.count > 1 else None


def _layer_processes(args: argparse.Namespace, count: int) -> dict[int, ProcessCurve]:
    curves = {}
    for item in args.layer_process:
        number, _, path = item.partition("=")
        if not number.isdigit() or not path or not 1 <= int(number) <= count:
            raise ValueError(f"--layer-process takes K=CURVE with K 1-{count}, got {item!r}")
        curves[int(number) - 1] = load_process(Path(path))
    return curves


def _inches_pair(text: str) -> tuple[float, float]:
    """'8x10' (or '8 x 10', '8.5X11') -> (8.0, 10.0)."""
    parts = text.lower().replace(" ", "").split("x")
    try:
        width, height = (float(p) for p in parts)
    except ValueError:
        message = f"expected W x H in inches, like 8x10, got {text!r}"
        raise argparse.ArgumentTypeError(message) from None
    if width <= 0 or height <= 0:
        raise argparse.ArgumentTypeError(f"the size must be positive, got {text!r}")
    return (width, height)


def _contact_sheet(args: argparse.Namespace) -> None:
    if len(args.inputs) > MAX_PHOTOS:
        raise ValueError(f"a contact sheet takes up to {MAX_PHOTOS} photos, got {len(args.inputs)}")
    layout = SheetLayout(
        width=args.size[0], height=args.size[1], gap=args.gap, background=args.background,
        crop=args.crop, wedge=args.wedge, labels=args.labels,
    )  # fmt: skip
    photos = [load_photo(path).pixels for path in args.inputs]
    sheet = make_sheet(photos, [path.name for path in args.inputs], layout, args.dpi)
    save_grey(args.output, GreyImage(sheet, dpi=(args.dpi, args.dpi)))
    print(f"wrote {args.output} ({len(photos)} photos on {args.size[0]:g} x {args.size[1]:g} in)")


def _negative(args: argparse.Namespace) -> None:
    photo = load_photo(args.input)
    process = load_process(args.process) if args.process else None
    colour = args.colour
    if process is not None:
        if args.colour != DEFAULT_COLOUR and args.colour != process.colour:
            raise ValueError(
                f"the process curve is for {process.colour} negatives, not {args.colour}"
            )
        colour = process.colour
    settings = NegativeSettings(
        colour=colour,
        mirror=args.mirror,
        safe_edge=args.safe_edge,
        mark=not args.no_mark,
        outline=args.outline,
        guide=args.guide,
        registration=args.registration,
    )
    if args.max_size and not args.fit:
        raise ValueError("--max-size works with --fit PAPER")
    if args.fit:
        dpi = negative_ppi(*photo.size, args.fit, settings.border, DEFAULT_MARGIN)
        if args.max_size:
            dpi = max(dpi, box_ppi(*photo.size, args.max_size, settings.border))
    else:
        dpi = args.dpi or (photo.dpi[0] if photo.dpi else DEFAULT_DPI)
    width, height = (n / dpi + 2 * settings.border for n in photo.size)
    flip = ", mirrored" if settings.mirror else ""
    size = f"{width:.2f} x {height:.2f} in at {dpi:.0f} dpi"
    plan = _separation(args)
    if plan is None:
        pixels = process.apply(photo.pixels) if process else photo.pixels
        save_rgb(args.output, make_negative(pixels, settings, dpi), (dpi, dpi), srgb_profile())
        print(f"wrote {args.output} ({settings.colour}{flip}, {size})")
        return
    own = _layer_processes(args, plan.count)
    print(plan.describe())
    for k, (lower, upper) in enumerate(plan.bands):
        curve = own.get(k, process)
        pixels = coat_image(photo.pixels, plan, k)
        pixels = curve.apply(pixels) if curve else pixels
        layer = replace(settings, colour=curve.colour if curve else colour, label=k + 1,
                        clear_targets=True)  # fmt: skip
        path = args.output.with_name(f"{args.output.stem}-{k + 1}of{plan.count}.tif")
        save_rgb(path, make_negative(pixels, layer, dpi), (dpi, dpi), srgb_profile())
        band = f"steps {lower * plan.steps:g}-{upper * plan.steps:g}"
        print(f"wrote {path} ({band}, {layer.colour}{flip}, {size})")


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
        if args.fit:
            ppi = fit_ppi(*_pixel_size(path), args.paper)
        else:
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


def _measure_pair(args: argparse.Namespace, calibration: Calibration | None) -> None:
    if not calibration:
        raise ValueError("--pair needs the --calibration used for the corrected target")
    plain, corrected = measure_pair(load_scan(args.scan), calibration.sent_for(wedge_levels(21)))
    stem = args.output.with_suffix("")
    for name, measurement in (("uncorrected", plain), ("corrected", corrected)):
        path = stem.with_name(f"{stem.name}-{name}.json")
        path.write_text(measurement.to_json() + "\n", encoding="utf-8")
        print(f"wrote {path}")
    print("step   level    uncorrected L* a* b*     corrected L* a* b*")
    for step, (level, a, b) in enumerate(
        zip(plain.levels, plain.lab, corrected.lab, strict=True), start=1
    ):
        print(
            f"{step:>4} {int(level):>7}   {a[0]:6.1f} {a[1]:5.1f} {a[2]:5.1f}"
            f"      {b[0]:6.1f} {b[1]:5.1f} {b[2]:5.1f}"
        )
    print(
        f"worst cast: uncorrected {plain.worst_cast():.1f}, corrected {corrected.worst_cast():.1f}"
    )


def _measure(args: argparse.Namespace) -> None:
    calibration = _calibration(args.calibration)
    if args.pair:
        _measure_pair(args, calibration)
        return
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
        measurement,
        damping=args.damping,
        shadow_damping=args.shadow_damping,
        printer=args.printer,
        paper=args.paper,
        settings=args.settings,
    )
    save_calibration(calibration, args.output)
    print(f"wrote {args.output} (from a wedge with worst cast {measurement.worst_cast():.1f})")


def _linearize(args: argparse.Namespace) -> None:
    measurement = Measurement.from_json(args.measurement.read_text(encoding="utf-8"))
    report = tone_report(measurement)
    print("step   level   measured L*   target L*   error")
    for step, (level, measured, target) in enumerate(
        zip(report.levels[::-1], report.measured[::-1], report.target[::-1], strict=True), start=1
    ):
        print(
            f"{step:>4} {int(level):>7}   {measured:10.1f}   {target:9.1f}"
            f"   {measured - target:+5.1f}"
        )
    print(f"worst tone error: {report.worst():.1f} L*")
    if args.output:
        calibration = linearize(load_calibration(args.calibration), measurement)
        save_calibration(calibration, args.output)
        print(f"wrote {args.output}")


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
        elif args.command == "negative":
            _negative(args)
        elif args.command == "contact-sheet":
            _contact_sheet(args)
        elif args.command == "blocking":
            _blocking(args)
        elif args.command == "chart":
            _chart(args)
        elif args.command == "curve":
            _curve(args)
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
        elif args.command == "linearize":
            _linearize(args)
        else:
            parser.print_help()
    except (OSError, ValueError, PrintError, ScanError) as exc:
        print(f"openquad: error: {exc}", file=sys.stderr)
        return 1
    return 0
