"""The Swift port's test vectors must match what the Python reference produces now."""

import importlib.util
import json
import math
from pathlib import Path
from types import ModuleType
from typing import Any

ROOT = Path(__file__).resolve().parents[1]


def load_script() -> ModuleType:
    spec = importlib.util.spec_from_file_location(
        "export_swift_vectors", ROOT / "scripts" / "export_swift_vectors.py"
    )
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


EXPORT = load_script()


def same(a: Any, b: Any) -> bool:
    """Equal, except floats may differ in the last digits: numpy's maths routines vary
    slightly between CPUs (the Swift tests allow the same 1e-12)."""
    if isinstance(a, float) or isinstance(b, float):
        return math.isclose(a, b, rel_tol=1e-12, abs_tol=1e-12)
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(same(a[k], b[k]) for k in a)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b, strict=True))
    return bool(a == b)


def test_same_allows_only_tiny_float_differences() -> None:
    assert same({"x": [1.0, 2]}, {"x": [1.0 + 1e-15, 2]})
    assert not same({"x": [1.0]}, {"x": [1.0001]})
    assert not same([1, 2], [1, 3])
    assert not same({"x": 1}, {"y": 1})


def test_committed_vectors_match_the_python_core(tmp_path: Path) -> None:
    fresh = EXPORT.export(tmp_path)
    for path in (p for p in fresh if p.suffix == ".json"):  # scans are checked via measure.json
        committed = EXPORT.DEFAULT_DIR / path.name
        assert committed.exists(), f"missing {committed}; run scripts/export_swift_vectors.py"
        assert same(json.loads(committed.read_text()), json.loads(path.read_text())), (
            f"{path.name} is out of date: the Python core changed. If intended, run "
            "scripts/export_swift_vectors.py and update the Swift port to match."
        )


def test_main_writes_all_files(tmp_path: Path, capsys) -> None:  # type: ignore[no-untyped-def]
    EXPORT.main(["export_swift_vectors.py", str(tmp_path)])
    assert sorted(p.name for p in tmp_path.iterdir()) == [
        "blocking-print-1.png",
        "blocking-print-2.png",
        "builds.json",
        "calibration.json",
        "chart-mirrored.png",
        "chart-page.png",
        "chart-sideways-tissue.png",
        "chart-tilted.png",
        "colour.json",
        "composite.json",
        "curves.json",
        "devices.json",
        "grey16-cm.tif",
        "grey16-nounit.tif",
        "grey16-white.tif",
        "grey16.tif",
        "grey8.tif",
        "measure.json",
        "negative.json",
        "paper.json",
        "quadfile.json",
        "reading.json",
        "rgb16.tif",
        "separate.json",
        "wedge-pair-v1.png",
        "wedge-pair-v5.png",
        "wedge-single.png",
    ]
    assert capsys.readouterr().out.count("wrote") == 27
