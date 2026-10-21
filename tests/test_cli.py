"""Tests for the command line. Printing always goes through a fake runner."""

import shlex
from pathlib import Path

import numpy as np
import pytest
import tifffile

from openquad.cli import main
from openquad.imageio import GreyImage, load_grey, read_dpi, save_grey
from tests.test_printing import FakeRunner

JOB_REPLY = "request id is Canon_MG3600_series-7 (1 file(s))\n"


def grey_file(tmp_path: Path, dpi: tuple[float, float] | None = (240.0, 240.0)) -> Path:
    path = tmp_path / "grey.tif"
    pixels = np.linspace(0, 65535, 40).astype(np.uint16).reshape(4, 10)
    save_grey(path, GreyImage(pixels, dpi=dpi))
    return path


def test_target_writes_a_wedge(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    out = tmp_path / "wedge.tif"
    args = ["target", "-o", str(out), "--steps", "5", "--patch-width", "3", "--patch-height", "2"]
    assert main([*args, "--dpi", "360"]) == 0
    image = load_grey(out)
    assert image.pixels.shape == (2, 15)
    assert image.dpi == pytest.approx((360.0, 360.0))
    assert "5 steps" in capsys.readouterr().out


def test_vertical_target(tmp_path: Path) -> None:
    out = tmp_path / "v.tif"
    assert main(["target", "-o", str(out), "--steps", "3", "--vertical"]) == 0
    assert load_grey(out).pixels.shape == (300, 100)


def test_composite_keeps_input_dpi(tmp_path: Path) -> None:
    out = tmp_path / "toned.tif"
    assert main(["composite", str(grey_file(tmp_path)), "-o", str(out)]) == 0
    with tifffile.TiffFile(out) as tif:
        assert tif.pages.first.shape == (4, 10, 3)
    assert read_dpi(out) == pytest.approx((240.0, 240.0))


def test_composite_dpi_override_and_default(tmp_path: Path) -> None:
    out = tmp_path / "toned.tif"
    assert main(["composite", str(grey_file(tmp_path)), "-o", str(out), "--dpi", "600"]) == 0
    assert read_dpi(out) == pytest.approx((600.0, 600.0))
    assert main(["composite", str(grey_file(tmp_path, dpi=None)), "-o", str(out)]) == 0
    assert read_dpi(out) == pytest.approx((300.0, 300.0))


def test_presets_lists_every_preset(capsys: pytest.CaptureFixture[str]) -> None:
    assert main(["presets"]) == 0
    out = capsys.readouterr().out
    assert "black-red: black, red" in out
    assert "neutral: black" in out


def test_print_dry_run_shows_lp_and_never_prints(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    runner = FakeRunner(JOB_REPLY)
    source = grey_file(tmp_path)
    assert (
        main(["print", str(source), "--printer", "Canon_MG3600_series", "--dry-run"], runner) == 0
    )
    command = shlex.split(capsys.readouterr().out)
    assert runner.commands == []
    assert command[:3] == ["lp", "-d", "Canon_MG3600_series"]
    assert "ppi=240" in command  # from the file's own DPI
    assert "PageSize=Letter" in command
    assert command[-1] == str(source)


def test_print_sends_the_job(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    runner = FakeRunner(JOB_REPLY)
    args = ["print", str(grey_file(tmp_path)), "--printer", "P", "--paper", "A4", "--copies", "2"]
    assert main([*args, "--option", "CNIJMediaType=0", "--title", "T"], runner) == 0
    command = runner.commands[0]
    assert "PageSize=A4" in command
    assert "CNIJMediaType=0" in command
    assert command[command.index("-n") + 1] == "2"
    assert "job Canon_MG3600_series-7" in capsys.readouterr().out


def test_print_with_preset_prints_a_toned_temporary_file(tmp_path: Path) -> None:
    seen: list[tuple[int, ...]] = []

    class InspectingRunner(FakeRunner):
        def __call__(self, command):  # type: ignore[no-untyped-def]
            with tifffile.TiffFile(command[-1]) as tif:
                seen.append(tif.pages.first.shape)
            return super().__call__(command)

    runner = InspectingRunner(JOB_REPLY)
    source = grey_file(tmp_path)
    assert main(["print", str(source), "--printer", "P", "--preset", "black-red"], runner) == 0
    assert seen == [(4, 10, 3)]  # an RGB file was printed, not the greyscale source
    assert not Path(runner.commands[0][-1]).exists()  # and cleaned up afterwards


def test_print_ppi_override(tmp_path: Path) -> None:
    runner = FakeRunner(JOB_REPLY)
    assert main(["print", str(grey_file(tmp_path)), "--printer", "P", "--ppi", "720"], runner) == 0
    assert "ppi=720" in runner.commands[0]


def test_printers_lists_names(capsys: pytest.CaptureFixture[str]) -> None:
    assert main(["printers"], FakeRunner("Canon_MG3600_series\n")) == 0
    assert capsys.readouterr().out == "Canon_MG3600_series\n"


@pytest.mark.parametrize(
    "argv",
    [
        ["print", "missing.tif", "--printer", "P"],
        ["composite", "missing.tif", "-o", "out.tif"],
    ],
)
def test_errors_return_1_with_a_message(
    argv: list[str], tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    argv = [str(tmp_path / a) if a.endswith(".tif") else a for a in argv]
    assert main(argv, FakeRunner(JOB_REPLY)) == 1
    assert capsys.readouterr().err.startswith("openquad: error:")


def test_lp_failure_returns_1(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    runner = FakeRunner(returncode=1, stderr="printer is offline")
    assert main(["print", str(grey_file(tmp_path)), "--printer", "P"], runner) == 1
    assert "printer is offline" in capsys.readouterr().err


def test_bad_option_format_is_a_usage_error() -> None:
    with pytest.raises(SystemExit) as exc:
        main(["print", "x.tif", "--printer", "P", "--option", "novalue"])
    assert exc.value.code == 2


def test_no_command_prints_help(capsys: pytest.CaptureFixture[str]) -> None:
    assert main([]) == 0
    assert "COMMAND" in capsys.readouterr().out


# --- grey balance workflow -----------------------------------------------------------


def test_grey_balance_workflow_end_to_end(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """target -> (simulated print + scan) -> measure -> greybalance -> corrected target."""
    from PIL import Image

    from openquad.greybalance import load_calibration
    from tests.simulation import print_sheet, scan_sheet

    target = tmp_path / "gb.tif"
    assert main(["target", "--kind", "grey-balance", "-o", str(target), "--dpi", "150"]) == 0
    sheet = tifffile.imread(target)
    assert sheet.shape[-1] == 3

    scan = tmp_path / "scan.jpg"
    pixels = np.round(scan_sheet(print_sheet(sheet)) * 255).astype(np.uint8)
    Image.fromarray(pixels).save(scan, quality=92)

    measurement = tmp_path / "m.json"
    assert main(["measure", str(scan), "-o", str(measurement)]) == 0
    out = capsys.readouterr().out
    assert "worst cast" in out
    assert out.count("\n") > 21

    cal = tmp_path / "canon.oqcal"
    args = ["greybalance", str(measurement), "-o", str(cal), "--printer", "Canon"]
    assert main([*args, "--paper", "plain", "--settings", "default"]) == 0
    assert load_calibration(cal).printer == "Canon"

    corrected = tmp_path / "gb2.tif"
    argv = ["target", "--kind", "grey-balance", "-o", str(corrected), "--dpi", "150"]
    assert main([*argv, "--calibration", str(cal)]) == 0
    assert not np.array_equal(tifffile.imread(corrected), sheet)

    rescan = tmp_path / "scan2.jpg"
    pixels = np.round(scan_sheet(print_sheet(tifffile.imread(corrected))) * 255)
    Image.fromarray(pixels.astype(np.uint8)).save(rescan, quality=92)
    measurement2 = tmp_path / "m2.json"
    assert main(["measure", str(rescan), "-o", str(measurement2), "--calibration", str(cal)]) == 0
    from openquad.measure import Measurement

    before = Measurement.from_json(measurement.read_text()).worst_cast()
    after = Measurement.from_json(measurement2.read_text()).worst_cast()
    assert after < 3 < before


def test_composite_and_print_apply_a_calibration(tmp_path: Path) -> None:
    from openquad.greybalance import Calibration, save_calibration

    levels = np.array([0, 65535])
    darker_blue = Calibration(levels=levels, curves=np.array([[0, 65535], [0, 65535], [0, 30000]]))
    cal = tmp_path / "c.oqcal"
    save_calibration(darker_blue, cal)

    plain, calibrated = tmp_path / "plain.tif", tmp_path / "cal.tif"
    source = grey_file(tmp_path)
    assert main(["composite", str(source), "-o", str(plain), "--preset", "neutral"]) == 0
    argv = ["composite", str(source), "-o", str(calibrated), "--preset", "neutral"]
    assert main([*argv, "--calibration", str(cal)]) == 0
    assert tifffile.imread(calibrated)[..., 2].sum() < tifffile.imread(plain)[..., 2].sum()

    seen: list[np.ndarray] = []

    class InspectingRunner(FakeRunner):
        def __call__(self, command):  # type: ignore[no-untyped-def]
            seen.append(tifffile.imread(command[-1]))
            return super().__call__(command)

    for path in (plain, source):  # an RGB file and a greyscale file
        assert main(["print", str(path), "--printer", "P", "--calibration", str(cal)],
                    InspectingRunner(JOB_REPLY)) == 0  # fmt: skip
    assert all(image.shape[-1] == 3 for image in seen)
    assert seen[0][..., 2].sum() < tifffile.imread(plain)[..., 2].sum()


def test_print_calibration_rejects_odd_tiffs(tmp_path: Path) -> None:
    from openquad.greybalance import Calibration, save_calibration

    cal = tmp_path / "c.oqcal"
    save_calibration(Calibration.identity(), cal)
    odd = tmp_path / "odd.tif"
    tifffile.imwrite(odd, np.zeros((4, 4, 4), dtype=np.uint16), photometric="rgb", extrasamples=[2])
    assert main(["print", str(odd), "--printer", "P", "--calibration", str(cal)],
                FakeRunner(JOB_REPLY)) == 1  # fmt: skip


def test_scan_command_uses_escl(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    from tests.test_escl import JPEG, FakeScanner

    fake = FakeScanner()
    out = tmp_path / "s.jpg"
    assert (
        main(["scan", "--host", "scanner.local", "-o", str(out), "--dpi", "600"], fetch=fake) == 0
    )
    assert out.read_bytes() == JPEG
    assert b"<scan:XResolution>600" in (fake.calls[0][2] or b"")
    assert "600 dpi" in capsys.readouterr().out


def test_scan_errors_return_1(tmp_path: Path) -> None:
    from tests.test_escl import FakeScanner

    argv = ["scan", "--host", "s", "-o", str(tmp_path / "s.jpg")]
    assert main(argv, fetch=FakeScanner(job_status=500)) == 1
