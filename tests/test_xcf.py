import os
import subprocess
from pathlib import Path

import numpy as np
import pytest

from openquad import xcf
from openquad.imageio import ImageFormatError
from openquad.photo import load_photo
from tests.test_session import colour_file

ROOT = Path(__file__).resolve().parents[1]


def fake_gimp(folder: Path, copying: Path | None, name: str = "gimp-console") -> Path:
    """A stand-in for gimp-console: copies a TIFF to where GIMP would save, or fails."""
    script = folder / name
    body = (
        f"cp '{copying}' \"$OPENQUAD_XCF_OUT\""
        if copying
        else "echo 'GIMP-Error: Opening failed' >&2"
    )
    script.write_text(f'#!/bin/sh\n[ -f "$OPENQUAD_XCF_IN" ] || exit 1\n{body}\n')
    script.chmod(0o755)
    return script


def an_xcf(folder: Path) -> Path:
    path = folder / "layers.xcf"
    path.write_bytes(b"gimp xcf v011\0")
    return path


@pytest.mark.skipif(os.name == "nt", reason="a shell script stands in for GIMP")
def test_an_xcf_is_read_through_gimp(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    tiff = colour_file(tmp_path)
    monkeypatch.setenv("OPENQUAD_GIMP", str(fake_gimp(tmp_path, tiff)))
    photo, direct = load_photo(an_xcf(tmp_path)), load_photo(tiff)
    assert np.array_equal(photo.pixels, direct.pixels) and photo.converted == direct.converted


@pytest.mark.skipif(os.name == "nt", reason="a shell script stands in for GIMP")
def test_gimp_missing_or_failing(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    path = an_xcf(tmp_path)
    failing = fake_gimp(tmp_path, None, "gimp-console-3.0")
    with (
        pytest.raises(
            ImageFormatError, match=r"GIMP 3 could not open it \(GIMP-Error: Opening failed\)"
        ),
        xcf.flattened(path, failing),
    ):
        pass
    assert xcf.find_gimp({"PATH": f"/nowhere{os.pathsep}{tmp_path}"}, [tmp_path]) == failing
    assert xcf.find_gimp({"PATH": "/nowhere"}, [tmp_path]) is None
    assert xcf.find_gimp({"OPENQUAD_GIMP": str(tmp_path / "nowhere")}) is None
    monkeypatch.setenv("OPENQUAD_GIMP", str(tmp_path / "nowhere"))
    with pytest.raises(ImageFormatError, match="needs GIMP 3 installed"):
        load_photo(path)


def test_gimp_that_hangs_or_wont_run(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    path = an_xcf(tmp_path)

    def hang(*args: object, **kwargs: object) -> None:
        raise subprocess.TimeoutExpired("gimp-console", xcf.TIMEOUT)

    monkeypatch.setattr(xcf.subprocess, "run", hang)
    with (
        pytest.raises(ImageFormatError, match="took too long"),
        xcf.flattened(path, tmp_path / "gimp-console"),
    ):
        pass
    monkeypatch.undo()
    with (
        pytest.raises(ImageFormatError, match="could not run GIMP"),
        xcf.flattened(path, tmp_path / "missing-gimp-console"),
    ):
        pass


def test_a_gimp_app_is_searched_for_its_console(tmp_path: Path) -> None:
    macos = tmp_path / "Applications" / "GIMP.app" / "Contents" / "MacOS"
    macos.mkdir(parents=True)
    console = macos / "gimp-console-3.2"
    console.write_text("#!/bin/sh\n")
    console.chmod(0o755)
    assert xcf.find_gimp({"OPENQUAD_GIMP": str(macos.parents[1])}) == console
    assert xcf.find_gimp({}, [tmp_path / "Applications"]) == console
    assert xcf.find_gimp({"OPENQUAD_GIMP": str(tmp_path / "Other.app")}) is None
    assert xcf.app_folders()[0] == Path("/Applications")


def test_the_command_runs_the_script_quietly() -> None:
    command = xcf.command(Path("gimp-console"))
    assert command[0] == "gimp-console" and "-i" in command and command[-1] == xcf.SCRIPT
    assert 'os.environ["OPENQUAD_XCF_IN"]' in xcf.SCRIPT and xcf.is_xcf(b"gimp xcf v011")


@pytest.mark.skipif(xcf.find_gimp() is None, reason="GIMP 3 is not installed")
def test_a_real_xcf_through_real_gimp() -> None:
    photo = load_photo(ROOT / "fixtures" / "layers.xcf")
    assert photo.size == (64, 48) and photo.converted
    assert photo.colour is not None and photo.colour[0, 0].tolist() == [31754, 43593, 59396]
