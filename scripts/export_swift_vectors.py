"""Export test vectors from the Python core for the Swift port (swift/OpenQuadCore).

Each file holds inputs and the outputs the Python reference produces. The Swift
tests must reproduce them; tests/test_swift_vectors.py fails if the committed
files drift from what the Python code produces now.

    uv run python scripts/export_swift_vectors.py [output-dir]
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

import numpy as np

from openquad.colour import linear_rgb_to_lab, linear_to_srgb, srgb_to_linear
from openquad.curves import InkSpec, build_curve, expand, scale_limit
from openquad.quadfile import format_quad, parse_quad
from openquad.separate import max_total_ink, separate

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DIR = ROOT / "swift" / "OpenQuadCore" / "Tests" / "OpenQuadCoreTests" / "Vectors"
GOLDEN_QUAD = ROOT / "fixtures" / "golden" / "three-ink.quad"
SAMPLE_EVERY = 37  # expand() tables are 65,536 long: keep every 37th entry (and the last)


def _floats(values: Any) -> list[float]:
    return [float(v) for v in np.asarray(values, dtype=np.float64).ravel()]


def _ints(values: Any) -> list[int]:
    return [int(v) for v in np.asarray(values).ravel()]


def colour_vectors() -> dict[str, Any]:
    encoded = np.linspace(0.0, 1.0, 1001)
    rng = np.random.default_rng(7)
    rgb = rng.random((60, 3))
    rgb[:3] = np.array([[1.0, 1.0, 1.0], [0.0, 0.0, 0.0], [0.18418, 0.18418, 0.18418]])
    return {
        "encoded": _floats(encoded),
        "srgb_to_linear": _floats(srgb_to_linear(encoded)),
        "linear_to_srgb": _floats(linear_to_srgb(encoded)),
        "rgb": _floats(rgb),
        "lab": _floats(linear_rgb_to_lab(rgb)),
    }


def quadfile_vectors() -> dict[str, Any]:
    text = GOLDEN_QUAD.read_text(encoding="utf-8")
    curve = parse_quad(text)
    small = "## QuadToneRIP K,LK\n# K curve\n" + "\n".join(str(i * 257) for i in range(256))
    small += "\n\n# LK curve\n" + "\n".join("5" for _ in range(256)) + "\n# end\n"
    return {
        "golden_text": text,
        "golden_channels": list(curve.channels),
        "golden_values": _ints(curve.values),
        "small_text": small,
        "small_formatted": format_quad(parse_quad(small)),
        "malformed": [
            "",
            "# not a header\n0\n",
            "## QuadToneRIP K\n12x\n",
            "## QuadToneRIP K\n70000\n",
            "## QuadToneRIP K\n" + "0\n" * 255,
        ],
    }


def curves_vectors() -> dict[str, Any]:
    rng = np.random.default_rng(11)
    curves = [
        np.rint(np.linspace(0, 65535, 256)),
        np.sort(rng.integers(0, 65536, 256)),
        rng.integers(0, 65536, 256),
        parse_quad(GOLDEN_QUAD.read_text(encoding="utf-8")).channel("K"),
    ]
    sample = sorted({*range(0, 65536, SAMPLE_EVERY), 65535})
    specs: list[dict[str, Any]] = [
        {"channel": "LK", "limit": 40.0, "start": 0.2, "peak": 0.5, "end": 0.8, "shape": "linear"},
        {"channel": "LK", "limit": 40.0, "start": 0.2, "peak": 0.5, "end": 0.8, "shape": "smooth"},
        {"channel": "K", "limit": 100.0, "start": 0.4, "peak": 1.0, "end": 1.0, "shape": "smooth"},
        {"channel": "K", "limit": 75.0, "start": 0.0, "peak": 1.0, "end": 1.0, "shape": "linear"},
    ]
    positions = np.linspace(0.0, 1.0, 1001)
    three_ink = [
        InkSpec("LLK", limit=30.0, start=0.0, peak=0.33, end=0.66),
        InkSpec("LK", limit=40.0, start=0.2, peak=0.66, end=1.0),
        InkSpec("K", limit=60.0, start=0.5, peak=1.0),
    ]
    smooth_two = [
        InkSpec("LK", limit=45.0, start=0.0, peak=0.5, end=1.0, shape="smooth"),
        InkSpec("K", limit=90.0, start=0.3, peak=1.0, shape="smooth"),
    ]
    return {
        "expand": [
            {
                "points": _ints(c),
                "sample_indices": sample,
                "table_sampled": _ints(expand(c)[sample]),
            }
            for c in curves
        ],
        "scale_limit": {
            "points": _ints(curves[2]),
            "limit": 37.5,
            "result": _ints(scale_limit(curves[2], 37.5)),
        },
        "ramps": {
            "positions": _floats(positions),
            "specs": specs,
            "values": [_floats(InkSpec(**s).ramp(positions)) for s in specs],
        },
        "build_three_ink_gamma_1_2": {
            "channels": ["K", "C", "M", "Y", "LC", "LM", "LK", "LLK"],
            "values": _ints(build_curve(three_ink, gamma=1.2).values),
        },
        "build_smooth_two": {
            "channels": ["K", "LK"],
            "values": _ints(build_curve(smooth_two, channels=("K", "LK")).values),
        },
    }


def separate_vectors() -> dict[str, Any]:
    curve = parse_quad(GOLDEN_QUAD.read_text(encoding="utf-8"))
    rng = np.random.default_rng(3)
    image = rng.integers(0, 65536, (6, 64)).astype(np.uint16)
    image[0] = np.rint(np.linspace(0, 65535, 64)).astype(np.uint16)
    return {
        "height": 6,
        "width": 64,
        "image": _ints(image),
        "channels": list(curve.channels),
        "separation": _ints(separate(image, curve)),
        "max_total_ink": max_total_ink(curve),
    }


def composite_vectors() -> dict[str, Any]:
    from openquad.composite import PRESETS, composite

    rng = np.random.default_rng(5)
    image = rng.integers(0, 65536, (4, 64)).astype(np.uint16)
    image[0] = np.rint(np.linspace(0, 65535, 64)).astype(np.uint16)
    return {
        "height": 4,
        "width": 64,
        "image": _ints(image),
        "presets": {
            name: {
                "layers": [
                    {
                        "name": layer.name,
                        "colour": list(layer.colour),
                        "tone": {
                            "limit": layer.tone.limit,
                            "start": layer.tone.start,
                            "peak": layer.tone.peak,
                            "end": layer.tone.end,
                            "shape": layer.tone.shape,
                        },
                    }
                    for layer in layers
                ],
                "rgb": _ints(composite(image, layers)),
            }
            for name, layers in PRESETS.items()
        },
    }


def negative_vectors() -> dict[str, Any]:
    from openquad.negative import NEGATIVE_COLOURS, NegativeSettings, ink_to_rgb, make_negative

    photo = np.tile(np.rint(np.linspace(0, 65535, 12)).astype(np.uint16), (10, 1))
    photo[3, 4] = 1234
    cases: list[tuple[str, bool, float, bool, float]] = [
        ("black", False, 0.0, True, 100.0),
        ("green", False, 0.2, True, 100.0),
        ("orange", True, 0.2, True, 100.0),
        ("red", False, 0.05, False, 100.0),
    ]
    coverage = np.linspace(0.0, 1.0, 101)
    rendered = []
    for colour, mirror, edge, mark, dpi in cases:
        settings = NegativeSettings(colour=colour, mirror=mirror, safe_edge=edge, mark=mark)
        negative = make_negative(photo, settings, dpi)
        rendered.append(
            {
                "colour": colour,
                "mirror": mirror,
                "safe_edge": edge,
                "mark": mark,
                "dpi": dpi,
                "shape": list(negative.shape),
                "rgb": _ints(negative),
            }
        )
    return {
        "colours": {name: list(rgb) for name, rgb in NEGATIVE_COLOURS.items()},
        "coverage": _floats(coverage),
        "ink_to_rgb": {
            name: _ints(ink_to_rgb(coverage, rgb)) for name, rgb in NEGATIVE_COLOURS.items()
        },
        "photo": {"height": 10, "width": 12, "pixels": _ints(photo)},
        "cases": rendered,
    }


def paper_vectors() -> dict[str, Any]:
    from openquad.negative import negative_ppi
    from openquad.paper import PAPER_SIZES, box_ppi, fit_ppi, oriented

    sizes = [(3008, 4032), (4000, 2000), (300, 400), (850, 1100)]
    return {
        "papers": {name: list(size) for name, size in PAPER_SIZES.items()},
        "fit": [
            {"width": w, "height": h, "paper": paper, "ppi": fit_ppi(w, h, paper)}
            for w, h in sizes
            for paper in ("Letter", "A4", "4x6")
        ],
        "negative": [
            {
                "width": w,
                "height": h,
                "paper": "Letter",
                "edge": edge,
                "ppi": negative_ppi(w, h, "Letter", edge, 0.5),
            }
            for w, h in sizes
            for edge in (0.0, 0.25, 0.5)
        ],
        "box": [
            {
                "width": w,
                "height": h,
                "box": list(box),
                "edge": edge,
                "oriented": list(oriented(box, w, h)),
                "ppi": box_ppi(w, h, box, edge),
            }
            for w, h in sizes
            for box in ((8.0, 10.0), (10.0, 8.0), (4.0, 5.0), (7.25, 9.5))
            for edge in (0.0, 0.25)
        ],
    }


def calibration_vectors() -> dict[str, Any]:
    from openquad.chart import ProcessCurve
    from openquad.greybalance import load_calibration

    working = ROOT / "calibration-data" / "canon-mg3600-plain" / "canon-plain.oqcal"
    calibration = load_calibration(working)
    rng = np.random.default_rng(9)
    rgb = rng.integers(0, 65536, (50, 3)).astype(np.uint16)
    levels = np.rint(np.linspace(0, 65535, 21)).astype(np.uint16)
    process_levels = np.rint(np.linspace(0, 65535, 257)).astype(np.uint16)
    process_curve = np.rint(65535 * (process_levels / 65535.0) ** 1.3).astype(np.uint16)
    process = ProcessCurve(
        process_levels,
        process_curve,
        colour="green",
        film="office",
        created="2026-10-24T00:00:00+00:00",  # fixed, so exports are reproducible
    )
    grey = rng.integers(0, 65536, 200).astype(np.uint16)
    return {
        "oqcal_text": working.read_text(encoding="utf-8"),
        "rgb": _ints(rgb),
        "applied": _ints(calibration.apply(rgb)),
        "levels": _ints(levels),
        "sent_for": _ints(calibration.sent_for(levels)),
        "oqproc_text": process.to_json(),
        "grey": _ints(grey),
        "process_applied": _ints(process.apply(grey)),
    }


def builds_vectors() -> dict[str, Any]:
    """Building calibrations from measurements: grey balance, linearization, process curves."""
    from openquad.chart import (
        PATCHES,
        ChartReading,
        ProcessCurve,
        build_process_curve,
        patch_level,
        tone_errors,
    )
    from openquad.greybalance import build_calibration, load_calibration
    from openquad.linearize import linearize, srgb_lightness, target_lightness, tone_curve
    from openquad.measure import Measurement

    data = ROOT / "calibration-data" / "canon-mg3600-plain"
    first, second = data / "2026-10-20", data / "2026-10-22"

    def measurement(path: Path) -> tuple[str, Measurement]:
        text = path.read_text(encoding="utf-8")
        return text, Measurement.from_json(text)

    grey = []
    grey_cases: list[tuple[str, float, float | None]] = [
        ("m1.json", 1.0, None),
        ("m5-corrected.json", 1.0, 0.5),
        ("m4-corrected.json", 0.7, None),
    ]
    for name, damping, shadow_damping in grey_cases:
        text, m = measurement(first / name)
        built = build_calibration(m, damping=damping, shadow_damping=shadow_damping)
        grey.append(
            {
                "measurement": text,
                "damping": damping,
                "shadow_damping": shadow_damping,
                "levels": _ints(built.levels),
                "curves": _ints(built.curves),
            }
        )

    linear = []
    for calibration_path, measurement_path in (
        (first / "canon-plain-v3.oqcal", first / "m6-corrected.json"),
        (first / "canon-plain-v4-linear.oqcal", second / "m7-corrected.json"),
    ):
        text, m = measurement(measurement_path)
        calibration = load_calibration(calibration_path)
        result = linearize(calibration, m)
        linear.append(
            {
                "calibration": calibration_path.read_text(encoding="utf-8"),
                "measurement": text,
                "tone_curve": _floats(tone_curve(m)),
                "levels": _ints(result.levels),
                "curves": _ints(result.curves),
                "settings": result.settings,
            }
        )

    # Process curves from simulated chart readings (no carbon print has been read yet).
    rng = np.random.default_rng(11)
    patch_levels = np.array([patch_level(n) for n in range(PATCHES)], dtype=np.uint16)
    passes = []
    previous: ProcessCurve | None = None
    for exponent in (0.6, 0.9):
        sent = (previous or ProcessCurve.identity()).apply(patch_levels).astype(np.float64)
        lightness = 18.0 + 70.0 * (sent / 65535.0) ** exponent + rng.normal(0, 0.4, PATCHES)
        reading = ChartReading(
            levels=patch_levels,
            lightness=lightness,
            strip=np.linspace(18.0, 88.0, 21),
            orientation="F",
            paper=90.0,
        )
        curve = build_process_curve(reading, previous, film="office")
        passes.append(
            {
                "lightness": _floats(lightness),
                "tone_errors": _floats(tone_errors(reading)),
                "levels": _ints(curve.levels),
                "curve": _ints(curve.curve),
            }
        )
        previous = curve

    probe = np.linspace(0.0, 65535.0, 103)
    return {
        "probe": _floats(probe),
        "srgb_lightness": _floats(srgb_lightness(probe)),
        "target_lightness": _floats(target_lightness(probe, 92.5, 23.5)),
        "grey_balance": grey,
        "linearize": linear,
        "patch_levels": _ints(patch_levels),
        "process": passes,
    }


# Real wedge scans, reduced (box filter) so the vectors stay small, as lossless PNGs.
WEDGE_SCANS = (
    ("wedge-single.png", "2026-10-20/scan1.jpg", 2, None),
    ("wedge-pair-v1.png", "2026-10-20/scan4-document.jpg", 4, "2026-10-20/canon-plain.oqcal"),
    ("wedge-pair-v5.png", "2026-10-22/scan8-v5.jpg", 4, "canon-plain.oqcal"),
)


def _measurement(m: Any) -> dict[str, Any]:
    return {
        "levels": _ints(m.levels),
        "sent": _ints(m.sent),
        "rgb": _floats(m.rgb),
        "lab": _floats(m.lab),
    }


def measure_vectors(directory: Path) -> tuple[dict[str, Any], list[Path]]:
    """Reading wedge scans: frames, marks, splitting a comparison page, measurements."""
    import hashlib

    from PIL import Image

    from openquad.greybalance import load_calibration
    from openquad.measure import (
        count_marks,
        load_scan,
        locate_frame,
        measure_pair,
        measure_scan,
        split_pair,
    )
    from openquad.targets import wedge_levels

    data = ROOT / "calibration-data" / "canon-mg3600-plain"
    scans, written = [], []
    for name, source, factor, calibration in WEDGE_SCANS:
        path = directory / name
        with Image.open(data / source) as image:
            image.convert("RGB").reduce(factor).save(path)
        written.append(path)
        scan = load_scan(path)
        entry: dict[str, Any] = {
            "file": name,
            "shape": list(scan.shape),
            "sha256": hashlib.sha256(np.asarray(Image.open(path)).tobytes()).hexdigest(),
        }
        if calibration is None:
            entry["frame"] = list(locate_frame(scan))
            entry["marks"] = count_marks(scan, locate_frame(scan))
            entry["measurement"] = _measurement(measure_scan(scan))
        else:
            sent = load_calibration(data / calibration).sent_for(wedge_levels(21))
            top, bottom = split_pair(scan)
            entry["split"] = top.shape[0]
            entry["frames"] = [list(locate_frame(part)) for part in (top, bottom)]
            entry["marks"] = [count_marks(part, locate_frame(part)) for part in (top, bottom)]
            entry["sent"] = _ints(sent)
            plain, corrected = measure_pair(scan, sent)
            entry["uncorrected"] = _measurement(plain)
            entry["corrected"] = _measurement(corrected)
        scans.append(entry)
    return {"wedge_levels": _ints(wedge_levels(21)), "scans": scans}, written


# Real carbon prints of the blocking sheet (tilted, sideways, mirrored), reduced.
BLOCKING_SCANS = (
    ("blocking-print-1.png", "2026-10-23/blocking-carbon-print-scan.jpg"),
    ("blocking-print-2.png", "2026-10-24/blocking-carbon-print-2-scan.jpg"),
)
CHART_SCANS = ("chart-mirrored.png", "chart-sideways-tissue.png", "chart-tilted.png")
PAGE_SCAN = "chart-page.png"


def _simulated_charts(directory: Path) -> list[Path]:
    """Simulated carbon prints of the chart (no real one exists yet), as 8-bit PNGs."""
    from PIL import Image

    sys.path.insert(0, str(ROOT))
    from openquad.chart import ProcessCurve, chart_negative, chart_page
    from tests.simulation import contact_print
    from tests.test_blocking import on_tissue, scanned

    printed = contact_print(chart_negative("green", dpi=100))
    sideways = np.ascontiguousarray(np.rot90(on_tissue(printed)))
    tilted = (
        np.asarray(
            Image.fromarray(np.rint(printed * 255).astype(np.uint8)).rotate(
                -2.6, resample=Image.Resampling.BILINEAR, expand=True, fillcolor=(30, 30, 30)
            ),
            dtype=np.float64,
        )
        / 255.0
    )
    darker = ProcessCurve(
        np.array([0, 65535], dtype=np.uint16), np.array([0, 32768], dtype=np.uint16), "orange"
    )
    page = contact_print(chart_page(["green", "orange"], [None, darker], dpi=100))
    scans = (
        (CHART_SCANS[0], scanned(printed, "mirrored")),
        (CHART_SCANS[1], scanned(sideways)),
        (CHART_SCANS[2], scanned(tilted, seed=2)),
        (PAGE_SCAN, scanned(page, "turned 180°")),
    )
    written = []
    for name, scan in scans:
        path = directory / name
        Image.fromarray(np.rint(scan * 255).astype(np.uint8)).save(path)
        written.append(path)
    return written


def reading_vectors(directory: Path) -> tuple[dict[str, Any], list[Path]]:
    """Reading prints: the blocking sheet (real carbon prints) and process charts."""
    import hashlib

    from PIL import Image

    from openquad.blocking import (
        BlockingLayout,
        _deskew,
        _find_sheet,
        _fit_layout,
        _lightness,
        analyse,
    )
    from openquad.chart import ChartLayout, _points, read_chart, read_chart_page
    from openquad.measure import load_scan

    def scan_entry(path: Path) -> tuple[Any, dict[str, Any]]:
        scan = load_scan(path)
        digest = hashlib.sha256(np.asarray(Image.open(path)).tobytes()).hexdigest()
        return scan, {"file": path.name, "shape": list(scan.shape), "sha256": digest}

    def steps(lightness: Any, aspect: float, layout: Any, points: Any) -> dict[str, Any]:
        rough = _find_sheet(lightness, aspect)
        turned, tilt = _deskew(lightness, rough)
        box, fit, score = _fit_layout(turned, rough, layout, *points)
        return {
            "rough": _ints(rough),
            "tilt": float(tilt),
            "box": _ints(box),
            "fit": _ints(fit),
            "score": float(score),
        }

    written: list[Path] = []
    blocking = []
    layout = BlockingLayout()
    for name, source in BLOCKING_SCANS:
        path = directory / name
        with Image.open(ROOT / "calibration-data" / "carbon-ohp" / source) as image:
            image.convert("RGB").reduce(3).save(path)
        written.append(path)
        scan, entry = scan_entry(path)
        lightness = _lightness(scan)
        entry["lightness_sample"] = _floats(lightness[::97, ::89])
        entry["percentiles"] = _floats(np.percentile(lightness, [98, 2, 99, 50, 37.5]))
        entry["steps"] = steps(lightness, layout.width / layout.height, layout, (None, None))
        report = analyse(scan)
        entry["report"] = {
            "orientation": report.orientation,
            "paper": report.paper,
            "edge": report.edge,
            "white": report.white,
            "full": [r.full for r in report.results],
            "wedge": [list(r.wedge) for r in report.results],
            "lines": report.lines(),
        }
        blocking.append(entry)

    written += _simulated_charts(directory)
    charts = []
    chart_layout = ChartLayout()
    for name in CHART_SCANS:
        scan, entry = scan_entry(directory / name)
        lightness = _lightness(scan)
        entry["steps"] = steps(
            lightness, chart_layout.width / chart_layout.height, chart_layout, _points(chart_layout)
        )
        reading = read_chart(scan)
        entry["reading"] = _reading(reading)
        charts.append(entry)
    scan, page = scan_entry(directory / PAGE_SCAN)
    page["readings"] = [_reading(r) for r in read_chart_page(scan, 2)]

    # Pillow's bilinear rotate on float32 images, which the deskew relies on.
    rng = np.random.default_rng(5)
    small = (rng.random((23, 37)) * 100).astype(np.float32)
    rotations = []
    for angle, centre, fill in ((-2.75, None, 50.0), (0.35, None, 7.25), (3.0, (11.5, 20.0), 99.0),
                                (-5.95, (30.0, 4.5), 0.0), (0.0, None, 1.0)):  # fmt: skip
        turned = Image.fromarray(small, mode="F").rotate(
            angle, resample=Image.Resampling.BILINEAR, center=centre, fillcolor=fill
        )
        rotations.append({"angle": angle, "centre": centre, "fill": fill,
                          "pixels": _floats(np.asarray(turned))})  # fmt: skip
    return {
        "blocking": blocking,
        "charts": charts,
        "page": page,
        "rotate_input": _floats(small),
        "rotate_shape": list(small.shape),
        "rotations": rotations,
    }, written


def _reading(reading: Any) -> dict[str, Any]:
    return {
        "levels": _ints(reading.levels),
        "lightness": _floats(reading.lightness),
        "strip": _floats(reading.strip),
        "orientation": reading.orientation,
        "paper": reading.paper,
    }


TIFF_CASES = (
    ("grey16.tif", "uint16", "minisblack", (300.0, 300.0), "INCH"),
    ("grey8.tif", "uint8", "minisblack", None, None),
    ("grey16-white.tif", "uint16", "miniswhite", (240.0, 240.0), "INCH"),
    ("grey16-cm.tif", "uint16", "minisblack", (118.0, 118.0), "CENTIMETER"),
    ("grey16-nounit.tif", "uint16", "minisblack", (72.0, 72.0), "NONE"),
)


def devices_vectors(directory: Path) -> tuple[dict[str, Any], list[Path]]:
    """Scanner (eSCL) and printer (CUPS lp) behaviour, and TIFF files for image I/O."""
    import tifffile

    from openquad.escl import (
        ScanError,
        ScanSettings,
        parse_avahi,
        parse_dns_sd_browse,
        parse_dns_sd_resolve,
        scan,
    )
    from openquad.imageio import load_grey, read_dpi, save_rgb
    from openquad.printing import PrintError, PrintJob, list_printers, send

    settings = [
        {"dpi": 300, "width": 2550, "height": 3300, "intent": "Document"},
        {"dpi": 600, "width": 1275, "height": 1650, "intent": "Photo"},
        {"dpi": 75, "width": 100, "height": 200, "intent": "Preview"},
    ]
    for entry in settings:
        entry["xml"] = ScanSettings(**entry).xml().decode()  # type: ignore[arg-type]

    jpeg = b"\xff\xd8\xff\xe0fake-jpeg"
    scenarios: list[tuple[str, str, list[tuple[int, str, str]]]] = [
        ("ok", "876298000000.local:80",
         [(201, "http://876298000000.local/eSCL/ScanJobs/42", ""), (200, "", "jpeg"),
          (200, "", "")]),
        ("busy", "http://192.168.1.20:8080/",
         [(503, "", ""), (503, "", ""), (201, "/eSCL/ScanJobs/7/", ""), (503, "", ""),
          (200, "", "jpeg"), (200, "", "")]),
        ("refused", "scanner.local", [(409, "", "<error>it's busy</error>")]),
        ("epson-https-job", "EPSON255E1C.local:443",
         [(201, "https://EPSON255E1C.local:443/eSCL/ScanJobs/feaf5e67/", ""), (200, "", "jpeg"),
          (200, "", "")]),
        ("no-image", "scanner.local", [(201, "ScanJobs/9", ""), (500, "", "oops"), (-1, "", "")]),
        ("never-free", "scanner.local", [(503, "", "")] * 10),
    ]  # fmt: skip
    scans = []
    for name, host, responses in scenarios:
        queue = list(responses)
        calls: list[dict[str, Any]] = []
        sleeps: list[float] = []

        def fetch(method: str, url: str, body: bytes | None) -> tuple[int, str, bytes]:
            calls.append({"method": method, "url": url, "body": body.decode() if body else None})  # noqa: B023
            status, location, payload = queue.pop(0)  # noqa: B023
            if status == -1:
                raise ScanError("gone")
            return status, location, jpeg if payload == "jpeg" else payload.encode()

        output = directory / "scan-output.jpg"
        try:
            scan(host, output, fetch=fetch, sleep=sleeps.append)
            result: dict[str, Any] = {"image": output.read_bytes().hex()}
            output.unlink()
        except ScanError as exc:
            result = {"error": str(exc)}
        scans.append({"name": name, "host": host, "responses": responses, "calls": calls,
                      "sleeps": sleeps, **result})  # fmt: skip

    avahi = (
        "+;en0;IPv4;Canon\\032MG3600\\032series;_uscan._tcp;local\n"
        "=;en0;IPv4;Canon\\032MG3600\\032series;_uscan._tcp;local;876298000000.local;"
        '192.168.1.20;80;"rs=eSCL"\n'
    )
    columns = "Timestamp     A/R    Flags  if Domain               Service Type         "
    add = "20:29:23.021  Add        2  11 local.               "
    browse = (
        "Browsing for _uscan._tcp.local.\n"
        f"{columns}Instance Name\n"
        f"{add}_uscan._tcp.         Canon MG3600 series\n"
        f"{add}_uscan._tcp.         Canon MG3600 series\n"
        f"{add}_ipp._tcp.           Other\n"
    )
    resolve = (
        "20:29:43.311  Canon\\032MG3600\\032series._uscan._tcp.local. can be reached at "
        "876298000000.local.:80 (interface 11)\n"
    )
    discovery = {
        "avahi": avahi,
        "avahi_found": [list(x) for x in parse_avahi(avahi)],
        "browse": browse,
        "browse_found": parse_dns_sd_browse(browse),
        "resolve": resolve,
        "resolve_found": parse_dns_sd_resolve(resolve),
        "resolve_odd": parse_dns_sd_resolve("x can be reached at somewhere (if 1)"),
    }

    jobs = []
    for kwargs in (
        {},
        {"ppi": 341.5, "copies": 2, "paper": "4x6"},
        {"ppi": 342.5, "title": "Negative: green"},
        {"options": (("MediaType", "photographic-glossy"), ("print-quality", "5"))},
    ):
        job = PrintJob(Path("/tmp/openquad/neg.tif"), "Canon_MG3600_series", **kwargs)
        entry = {k: v for k, v in kwargs.items() if k != "options"}
        entry["options"] = [list(o) for o in job.options]
        entry["command"] = job.command()
        jobs.append(entry)

    written = []
    rng = np.random.default_rng(13)
    tiffs = []
    for name, dtype, photometric, resolution, unit in TIFF_CASES:
        top = 65535 if dtype == "uint16" else 255
        pixels = rng.integers(0, top + 1, (5, 7)).astype(dtype)
        path = directory / name
        tifffile.imwrite(path, pixels, photometric=photometric, resolution=resolution,
                         resolutionunit=unit)  # fmt: skip
        written.append(path)
        grey = load_grey(path)
        tiffs.append({"file": name, "pixels": _ints(grey.pixels), "shape": list(grey.pixels.shape),
                      "dpi": list(grey.dpi) if grey.dpi else None})  # fmt: skip

    class Done:
        def __init__(self, code: int, out: str, err: str = "") -> None:
            self.returncode, self.stdout, self.stderr = code, out, err

    sent = []
    target = directory / "grey8.tif"
    for code, out, err in ((0, "request id is Canon_MG3600_series-3144 (1 file(s))\n", ""),
                           (1, "", "lp: The printer or class does not exist.\n"),
                           (0, "queued\n", "")):  # fmt: skip
        job = PrintJob(target, "Canon_MG3600_series")
        try:
            outcome: dict[str, Any] = {"id": send(job, lambda c: Done(code, out, err))}  # type: ignore[arg-type,return-value]  # noqa: B023
        except PrintError as exc:
            outcome = {"error": str(exc)}
        sent.append({"code": code, "stdout": out, "stderr": err, **outcome})
    printers = list_printers(lambda c: Done(0, "Canon_MG3600_series\nPDF\n\n"))  # type: ignore[arg-type,return-value]

    rgb = rng.integers(0, 65536, (4, 6, 3)).astype(np.uint16)
    path = directory / "rgb16.tif"
    save_rgb(path, rgb, dpi=(200.0, 200.0))
    written.append(path)
    rgb_file = {"file": path.name, "pixels": _ints(rgb), "dpi": list(read_dpi(path) or ())}
    return {
        "scan_settings": settings,
        "scans": scans,
        "discovery": discovery,
        "jobs": jobs,
        "send": sent,
        "printers": printers,
        "tiffs": tiffs,
        "rgb_tiff": rgb_file,
    }, written


def session_vectors(directory: Path) -> tuple[dict[str, Any], list[Path]]:
    """Loading photos of every kind, and what a print session renders and reports."""
    import tifffile
    from PIL import Image

    from openquad.photo import load_photo
    from openquad.session import PrintSession

    rng = np.random.default_rng(17)
    ramp = np.tile(np.linspace(0, 255, 24), (18, 1))
    written = []

    def save(name: str, image: Any, **kwargs: Any) -> None:
        path = directory / name
        image.save(path, **kwargs)
        written.append(path)

    grey8 = ramp.astype(np.uint8)
    save("photo-grey.png", Image.fromarray(grey8, "L"), dpi=(300, 300))
    noisy = np.clip(ramp[..., None] + rng.integers(-1, 2, (18, 24, 3)), 0, 255).astype(np.uint8)
    save("photo-rgb-grey.png", Image.fromarray(noisy, "RGB"))
    colour = rng.integers(0, 256, (18, 24, 3)).astype(np.uint8)
    save("photo-colour.png", Image.fromarray(colour, "RGB"), dpi=(240, 240))
    rgba = np.dstack([noisy, np.full((18, 24), 255, np.uint8)])
    rgba[:4, :, 3] = 0  # a transparent band, as left by resizing a canvas
    rgba[:, -3:, 3] = 0
    rgba[8:12, 5:9, 3] = 128  # partly transparent: goes onto paper white
    save("photo-rgba.png", Image.fromarray(rgba, "RGBA"))
    la = np.dstack([grey8, np.where(ramp > 128, 255, 60).astype(np.uint8)])
    save("photo-la.png", Image.fromarray(la, "LA"))
    save("photo-palette.png", Image.fromarray(colour, "RGB").quantize(16))
    tiff16 = (np.tile(np.linspace(0, 65535, 24), (18, 1))).astype(np.uint16)
    path = directory / "photo-grey16.tif"
    tifffile.imwrite(path, tiff16, photometric="minisblack", resolution=(360, 360),
                     resolutionunit="INCH")  # fmt: skip
    written.append(path)
    rgba16 = np.dstack([np.stack([tiff16] * 3, -1), np.full((18, 24), 65535, np.uint16)])
    rgba16[:, :2, 3] = 0
    rgba16[:, :2, :3] = 0
    path = directory / "photo-rgba16.tif"
    tifffile.imwrite(path, rgba16, photometric="rgb", extrasamples=["unassalpha"])
    written.append(path)

    photos = []
    for path in written:
        photo = load_photo(path)
        photos.append({"file": path.name, "shape": list(photo.pixels.shape),
                       "pixels": _ints(photo.pixels), "dpi": list(photo.dpi) if photo.dpi else None,
                       "converted": photo.converted, "cropped": photo.cropped})  # fmt: skip

    calibration = ROOT / "calibration-data" / "canon-mg3600-plain" / "canon-plain.oqcal"
    process = directory / "session-process.oqproc"
    from openquad.chart import ProcessCurve

    levels = np.rint(np.linspace(0, 65535, 257)).astype(np.uint16)
    curve = np.rint(65535 * (levels / 65535.0) ** 0.8).astype(np.uint16)
    process.write_text(
        ProcessCurve(levels, curve, colour="orange", created="2026-10-24T00:00:00+00:00").to_json()
        + "\n"
    )
    written.append(process)
    configurations: list[dict[str, Any]] = [
        {"photo": "photo-grey16.tif"},
        {"photo": "photo-grey16.tif", "preset": "black-red", "calibration": True, "paper": "4x6"},
        {"photo": "photo-grey.png", "fit": False, "ppi": 12.5},
        {"photo": "photo-grey.png", "fit": False},
        {"photo": "photo-rgb-grey.png", "fit": False},
        {"photo": "photo-grey16.tif", "mode": "negative", "fit": False, "ppi": 40.0,
         "negative_colour": "green", "mirror": True, "safe_edge": 0.25},
        {"photo": "photo-grey16.tif", "mode": "negative", "process": True, "safe_edge": 0.1},
        {"photo": "photo-grey16.tif", "mode": "negative", "max_size": [2.0, 3.0],
         "safe_edge": 0.25},
        {"photo": "photo-grey16.tif", "max_size": [2.5, 1.5]},
        {"photo": "photo-grey16.tif", "max_size": [40.0, 30.0], "paper": "4x6"},
    ]  # fmt: skip
    sessions = []
    for config in configurations:
        session = PrintSession()
        session.open(directory / config["photo"])
        session.set_preset(config.get("preset", "neutral"))
        if config.get("calibration"):
            session.set_calibration(calibration)
        session.set_paper(config.get("paper", "Letter"))
        session.fit = config.get("fit", True)
        session.ppi = config.get("ppi")
        session.set_mode(config.get("mode", "print"))
        if config.get("process"):
            session.set_process(process)
        elif "negative_colour" in config:
            session.set_negative_colour(config["negative_colour"])
        session.mirror = config.get("mirror", False)
        session.safe_edge = config.get("safe_edge", 0.25)
        session.max_size = tuple(config["max_size"]) if "max_size" in config else None
        session.printer = "Canon_MG3600_series"
        rendered = session.render(session._photo().pixels)
        sessions.append({**config, "ppi_used": session.effective_ppi(),
                         "size": list(session.size_inches()), "fits": session.fits_on_paper(),
                         "summary": session.summary(), "notes": session.notes,
                         "rendered_shape": list(rendered.shape),
                         "rendered": _ints(rendered)})  # fmt: skip
    return {"photos": photos, "calibration": calibration.read_text(), "sessions": sessions}, written


def _digest(pixels: Any) -> dict[str, Any]:
    """Shape and SHA-256 of a uint16 image (little-endian), for images too big to list."""
    import hashlib

    array = np.ascontiguousarray(pixels, dtype="<u2")
    return {"shape": list(array.shape), "sha256": hashlib.sha256(array.tobytes()).hexdigest()}


def wizards_vectors(directory: Path) -> dict[str, Any]:
    """What the calibration wizards print, save and judge."""
    from openquad.calibrate import assess
    from openquad.chart import (
        ChartLayout,
        ChartReading,
        ProcessCurve,
        chart_negative,
        chart_page,
        chart_photo,
        reading_to_json,
        tone_errors,
    )
    from openquad.greybalance import Calibration, comparison_page, load_calibration
    from openquad.measure import Measurement
    from openquad.targets import framed_target

    data = ROOT / "calibration-data" / "canon-mg3600-plain"
    canon = load_calibration(data / "canon-plain.oqcal")
    identity = Calibration.identity()
    levels = np.rint(np.linspace(0, 65535, 257)).astype(np.uint16)
    green = ProcessCurve(levels, np.rint(65535 * (levels / 65535.0) ** 1.2).astype(np.uint16))
    darker = ProcessCurve(
        np.array([0, 65535], dtype=np.uint16), np.array([0, 32768], dtype=np.uint16), "orange"
    )
    renders = {
        "framed_target": _digest(framed_target(dpi=50)),
        "comparison_identity": _digest(comparison_page(identity, 50)),
        "comparison_canon": _digest(comparison_page(canon, 50)),
        "chart_photo": _digest(chart_photo(dpi=50)),
        "chart_photo_compact_2": _digest(chart_photo(ChartLayout.compact(), 50, index=2)),
        "chart_negative": _digest(chart_negative("green", green, mirror=True, dpi=50)),
        "chart_page": _digest(chart_page(["green", "orange"], [None, darker], dpi=60)),
    }

    assessments = []
    for session, prefix in (("2026-10-20", "m4"), ("2026-10-20", "m6"), ("2026-10-22", "m8")):
        texts = [(data / session / f"{prefix}-{kind}.json").read_text() for kind in
                 ("uncorrected", "corrected")]  # fmt: skip
        plain, corrected = (Measurement.from_json(t) for t in texts)
        result = assess(plain, corrected)
        assessments.append({
            "uncorrected": texts[0], "corrected": texts[1],
            "worst_cast": result.worst_cast, "mean_cast": result.mean_cast,
            "worst_tone": result.worst_tone, "mean_tone": result.mean_tone,
            "uncorrected_cast": result.uncorrected_cast, "next_step": result.next_step,
            "summary": result.summary(), "measurement_json": corrected.to_json(),
        })  # fmt: skip

    reading_data = json.loads((directory / "reading.json").read_text())
    results = []
    for entry in reading_data["page"]["readings"]:
        reading = ChartReading(
            levels=np.array(entry["levels"], dtype=np.uint16),
            lightness=np.array(entry["lightness"]),
            strip=np.array(entry["strip"]),
            orientation=entry["orientation"],
            paper=entry["paper"],
        )
        errors = np.abs(tone_errors(reading))
        results.append({"worst": float(errors.max()), "mean": float(errors.mean()),
                        "white": reading.white, "black": reading.black,
                        "json": reading_to_json(reading)})  # fmt: skip
    import openquad.blocking as blocking

    labels = blocking._draw_labels
    blocking._draw_labels = lambda sheet, layout, dpi: None
    try:  # Swift draws the colour names with the system font; compare everything else
        renders["blocking_sheet"] = _digest(blocking.blocking_sheet(dpi=50))
        renders["blocking_sheet_mirrored"] = _digest(
            blocking.blocking_sheet(dpi=60, mirror=True, safe_edge=0.3)
        )
    finally:
        blocking._draw_labels = labels
    return {
        "identity_levels": _ints(identity.levels),
        "identity_curves": _ints(identity.curves),
        "renders": renders,
        "assessments": assessments,
        "chart_results": results,
    }


def export(directory: Path) -> list[Path]:
    directory.mkdir(parents=True, exist_ok=True)
    written = []
    for name, data in (
        ("colour", colour_vectors()),
        ("quadfile", quadfile_vectors()),
        ("curves", curves_vectors()),
        ("separate", separate_vectors()),
        ("composite", composite_vectors()),
        ("negative", negative_vectors()),
        ("paper", paper_vectors()),
        ("calibration", calibration_vectors()),
        ("builds", builds_vectors()),
    ):
        path = directory / f"{name}.json"
        path.write_text(json.dumps(data, separators=(",", ":")) + "\n", encoding="utf-8")
        written.append(path)
    measured, images = measure_vectors(directory)
    path = directory / "measure.json"
    path.write_text(json.dumps(measured, separators=(",", ":")) + "\n", encoding="utf-8")
    read, prints = reading_vectors(directory)
    reading_path = directory / "reading.json"
    reading_path.write_text(json.dumps(read, separators=(",", ":")) + "\n", encoding="utf-8")
    devices, files = devices_vectors(directory)
    devices_path = directory / "devices.json"
    devices_path.write_text(json.dumps(devices, separators=(",", ":")) + "\n", encoding="utf-8")
    sessions, photos = session_vectors(directory)
    session_path = directory / "session.json"
    session_path.write_text(json.dumps(sessions, separators=(",", ":")) + "\n", encoding="utf-8")
    wizards_path = directory / "wizards.json"
    wizards_path.write_text(
        json.dumps(wizards_vectors(directory), separators=(",", ":")) + "\n", encoding="utf-8"
    )
    return [*written, path, reading_path, devices_path, session_path, wizards_path, *images,
            *prints, *files, *photos]  # fmt: skip


def main(argv: list[str]) -> None:
    directory = Path(argv[1]) if len(argv) > 1 else DEFAULT_DIR
    for path in export(directory):
        print(f"wrote {path.relative_to(ROOT) if path.is_relative_to(ROOT) else path}")


if __name__ == "__main__":
    main(sys.argv)
