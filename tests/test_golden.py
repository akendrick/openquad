"""Golden-file test: a known image and a known curve give exactly the stored channels.

Phase 1 exit gate. If this fails after an intended change, regenerate with
`uv run python scripts/update_golden.py` and review the fixture diff in the PR.
"""

import importlib.util
from pathlib import Path
from types import ModuleType

import numpy as np

from openquad.curves import InkSpec, build_curve
from openquad.quadfile import format_quad, read_quad
from openquad.separate import separate

ROOT = Path(__file__).resolve().parents[1]


def load_script() -> ModuleType:
    spec = importlib.util.spec_from_file_location(
        "update_golden", ROOT / "scripts" / "update_golden.py"
    )
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


GOLDEN = load_script()


def test_stored_curve_matches_its_generator() -> None:
    specs: list[InkSpec] = GOLDEN.golden_curve_specs()
    expected = format_quad(build_curve(specs, gamma=1.2))
    assert GOLDEN.CURVE_PATH.read_text(encoding="utf-8") == expected


def test_separation_matches_golden_output_exactly() -> None:
    stored = np.load(GOLDEN.SEPARATION_PATH)["separation"]
    actual = separate(GOLDEN.golden_image(), read_quad(GOLDEN.CURVE_PATH))
    assert actual.dtype == stored.dtype == np.uint16
    assert actual.shape == stored.shape == (8, 16, 1024)
    assert np.array_equal(actual, stored)
