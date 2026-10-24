"""The Swift port's test vectors must match what the Python reference produces now."""

import importlib.util
import json
from pathlib import Path
from types import ModuleType

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


def test_committed_vectors_match_the_python_core(tmp_path: Path) -> None:
    fresh = EXPORT.export(tmp_path)
    for path in fresh:
        committed = EXPORT.DEFAULT_DIR / path.name
        assert committed.exists(), f"missing {committed}; run scripts/export_swift_vectors.py"
        assert json.loads(committed.read_text()) == json.loads(path.read_text()), (
            f"{path.name} is out of date: the Python core changed. If intended, run "
            "scripts/export_swift_vectors.py and update the Swift port to match."
        )


def test_main_writes_all_files(tmp_path: Path, capsys) -> None:  # type: ignore[no-untyped-def]
    EXPORT.main(["export_swift_vectors.py", str(tmp_path)])
    assert sorted(p.name for p in tmp_path.iterdir()) == [
        "colour.json",
        "curves.json",
        "quadfile.json",
        "separate.json",
    ]
    assert capsys.readouterr().out.count("wrote") == 4
