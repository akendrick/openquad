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


def difference(a: Any, b: Any, where: str = "", off_by: int = 0) -> str | None:
    """Where a and b first differ, or None. Floats may differ in the last digits: numpy's
    maths routines vary slightly between CPUs (the Swift tests allow the same 1e-12). Inside
    a lossy JPEG 2000 entry, whole numbers may differ by 1: its wavelet is floating point."""
    if isinstance(a, float) or isinstance(b, float):
        close = math.isclose(a, b, rel_tol=1e-12, abs_tol=1e-12)
        return None if close else f"{where}: {a!r} != {b!r}"
    if isinstance(a, dict) and isinstance(b, dict):
        if a.keys() != b.keys():
            return f"{where}: keys {sorted(a)} != {sorted(b)}"
        if a.get("lossy") is True and b.get("lossy") is True:
            off_by = 1
        for k in a:
            found = difference(a[k], b[k], f"{where}.{k}", off_by)
            if found:
                return found
        return None
    if isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            return f"{where}: {len(a)} items != {len(b)}"
        for i, (x, y) in enumerate(zip(a, b, strict=True)):
            found = difference(x, y, f"{where}[{i}]", off_by)
            if found:
                return found
        return None
    numbers = type(a) is int and type(b) is int
    if numbers and abs(a - b) <= off_by:
        return None
    return None if a == b else f"{where}: {a!r} != {b!r}"


def same(a: Any, b: Any) -> bool:
    return difference(a, b) is None


def test_same_allows_only_tiny_float_differences() -> None:
    assert same({"x": [1.0, 2]}, {"x": [1.0 + 1e-15, 2]})
    assert not same({"x": [1.0]}, {"x": [1.0001]})
    assert not same([1, 2], [1, 3])
    assert not same({"x": 1}, {"y": 1})
    lossy = {"lossy": True, "raw": [10, 20]}
    assert same(lossy, {"lossy": True, "raw": [11, 19]})
    assert not same(lossy, {"lossy": True, "raw": [12, 20]})
    assert not same({"lossy": False, "raw": [10]}, {"lossy": False, "raw": [11]})
    assert not same([True], [False])
    assert difference({"a": [1, 2]}, {"a": [1, 3]}) == ".a[1]: 2 != 3"


def test_committed_vectors_match_the_python_core(tmp_path: Path) -> None:
    fresh = EXPORT.export(tmp_path)
    for path in (p for p in fresh if p.suffix == ".json"):  # scans are checked via measure.json
        committed = EXPORT.DEFAULT_DIR / path.name
        assert committed.exists(), f"missing {committed}; run scripts/export_swift_vectors.py"
        found = difference(json.loads(committed.read_text()), json.loads(path.read_text()))
        assert found is None, (
            f"{path.name} is out of date at {found}: the Python core changed. If intended, run "
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
        "colour-calibration.json",
        "colour-separations.json",
        "colour.json",
        "composite.json",
        "contactsheet.json",
        "curves.json",
        "devices.json",
        "formats.json",
        "grey16-cm.tif",
        "grey16-nounit.tif",
        "grey16-white.tif",
        "grey16.tif",
        "grey8.tif",
        "jp2-grey12.j2k",
        "jp2-grey16-signed.j2k",
        "jp2-grey16.j2k",
        "jp2-grey8.jp2",
        "jp2-la8.jp2",
        "jp2-rgb16.jp2",
        "jp2-rgb8-icc.jp2",
        "jp2-rgb8-lossy.jp2",
        "jp2-rgba16-lossy.jp2",
        "jp2-rgba8.jp2",
        "layers.xcf",
        "measure.json",
        "negative.json",
        "paper.json",
        "photo-colour-icc.png",
        "photo-colour.png",
        "photo-colour16.tif",
        "photo-grey.png",
        "photo-grey16.tif",
        "photo-la.png",
        "photo-palette.png",
        "photo-rgb-grey.png",
        "photo-rgba.png",
        "photo-rgba16.tif",
        "quadfile.json",
        "reading.json",
        "rgb16.tif",
        "separate.json",
        "separations.json",
        "session-process.oqproc",
        "session.json",
        "wedge-pair-v1.png",
        "wedge-pair-v5.png",
        "wedge-single.png",
        "wizards.json",
    ]
    assert capsys.readouterr().out.count("wrote") == 56
