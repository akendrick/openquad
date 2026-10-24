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


def export(directory: Path) -> list[Path]:
    directory.mkdir(parents=True, exist_ok=True)
    written = []
    for name, data in (
        ("colour", colour_vectors()),
        ("quadfile", quadfile_vectors()),
        ("curves", curves_vectors()),
        ("separate", separate_vectors()),
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
