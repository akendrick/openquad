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
    ):
        path = directory / f"{name}.json"
        path.write_text(json.dumps(data, separators=(",", ":")) + "\n", encoding="utf-8")
        written.append(path)
    return written


def main(argv: list[str]) -> None:
    directory = Path(argv[1]) if len(argv) > 1 else DEFAULT_DIR
    for path in export(directory):
        print(f"wrote {path.relative_to(ROOT) if path.is_relative_to(ROOT) else path}")


if __name__ == "__main__":
    main(sys.argv)
