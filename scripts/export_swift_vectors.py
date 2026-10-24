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
    from openquad.paper import PAPER_SIZES, fit_ppi

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
    return [*written, path, reading_path, *images, *prints]


def main(argv: list[str]) -> None:
    directory = Path(argv[1]) if len(argv) > 1 else DEFAULT_DIR
    for path in export(directory):
        print(f"wrote {path.relative_to(ROOT) if path.is_relative_to(ROOT) else path}")


if __name__ == "__main__":
    main(sys.argv)
