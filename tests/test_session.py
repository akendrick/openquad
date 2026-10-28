"""The Qt-free print session behind the desktop app."""

from pathlib import Path

import numpy as np
import pytest
import tifffile

from openquad.greybalance import Calibration, save_calibration
from openquad.session import PrintSession, SessionError
from tests.test_printing import FakeRunner

REPLY = "request id is Canon_MG3600_series-9 (1 file(s))\n"


def photo_file(tmp_path: Path, shape: tuple[int, int] = (400, 300), dpi: float = 72.0) -> Path:
    path = tmp_path / "photo.tif"
    pixels = np.tile(np.linspace(0, 65535, shape[1]).astype(np.uint16), (shape[0], 1))
    tifffile.imwrite(path, pixels, resolution=(dpi, dpi), resolutionunit="INCH")
    return path


def opened(tmp_path: Path, **kwargs: object) -> PrintSession:
    session = PrintSession(**kwargs)  # type: ignore[arg-type]
    session.open(photo_file(tmp_path))
    return session


def test_new_session_is_neutral() -> None:
    assert PrintSession().preset == "neutral"


def test_neutral_preview_is_grey(tmp_path: Path) -> None:
    preview = opened(tmp_path).preview(max_side=100)
    assert preview.dtype == np.uint8
    assert max(preview.shape[:2]) == 100
    assert np.array_equal(preview[..., 0], preview[..., 2])


def test_black_red_preview_is_red_only_when_chosen(tmp_path: Path) -> None:
    session = opened(tmp_path)
    session.set_preset("black-red")
    preview = session.preview(max_side=100).astype(int)
    assert (preview[..., 0] - preview[..., 1]).max() > 20


def test_small_photo_preview_is_not_enlarged(tmp_path: Path) -> None:
    session = PrintSession()
    session.open(photo_file(tmp_path, shape=(20, 30)))
    assert session.preview(max_side=900).shape == (20, 30, 3)


def test_fit_to_letter_by_default(tmp_path: Path) -> None:
    session = opened(tmp_path)
    _, height = session.size_inches()
    assert height == pytest.approx(10.0)  # 400 x 300 px portrait: height limits
    assert session.fits_on_paper()


def test_own_dpi_when_fit_is_off(tmp_path: Path) -> None:
    session = opened(tmp_path)
    session.fit = False
    assert session.effective_ppi() == pytest.approx(72.0)
    session.ppi = 50.0
    assert session.size_inches() == pytest.approx((6.0, 8.0))
    session.ppi = 10.0
    assert not session.fits_on_paper()


def test_fallback_ppi_without_dpi(tmp_path: Path) -> None:
    path = tmp_path / "nodpi.tif"
    tifffile.imwrite(path, np.zeros((10, 10), dtype=np.uint16))
    session = PrintSession(fit=False)
    session.open(path)
    assert session.effective_ppi() == 300.0


def test_notes_for_converted_and_cropped_photos(tmp_path: Path) -> None:
    rgba = np.zeros((6, 4, 4), dtype=np.uint8)
    rgba[:4, :, 0] = 200  # red: a colour photo
    rgba[:4, :, 3] = 255  # bottom two rows transparent
    path = tmp_path / "c.tif"
    tifffile.imwrite(path, rgba, photometric="rgb", extrasamples=["unassalpha"])
    session = PrintSession()
    session.open(path)
    assert len(session.notes) == 2


def test_choices_are_validated(tmp_path: Path) -> None:
    session = PrintSession()
    with pytest.raises(SessionError, match="preset"):
        session.set_preset("purple")
    with pytest.raises(SessionError, match="paper"):
        session.set_paper("Tabloid")
    with pytest.raises(SessionError, match="open a photo"):
        session.size_inches()
    session.set_paper("A4")
    assert session.paper == "A4"


def test_calibration_is_applied_to_the_print_file(tmp_path: Path) -> None:
    session = opened(tmp_path)
    plain = tmp_path / "plain.tif"
    session.write_print_file(plain)
    cal = tmp_path / "c.oqcal"
    less_blue = Calibration(
        levels=np.array([0, 65535]), curves=np.array([[0, 65535]] * 2 + [[0, 40000]])
    )
    save_calibration(less_blue, cal)
    session.set_calibration(cal)
    corrected = tmp_path / "cal.tif"
    session.write_print_file(corrected)
    assert tifffile.imread(corrected)[..., 2].sum() < tifffile.imread(plain)[..., 2].sum()
    assert "Calibration: c.oqcal" in session.summary()
    session.set_calibration(None)
    assert session.calibration is None
    assert "Calibration: none" in session.summary()


def test_print_file_carries_the_print_resolution(tmp_path: Path) -> None:
    session = opened(tmp_path)
    out = session.write_print_file(tmp_path / "p.tif")
    with tifffile.TiffFile(out) as tif:
        num, den = tif.pages.first.tags["XResolution"].value
    assert num / den == pytest.approx(session.effective_ppi(), rel=1e-3)


def test_summary_lists_the_settings(tmp_path: Path) -> None:
    session = opened(tmp_path, printer="Canon_MG3600_series")
    lines = session.summary()
    assert "Printer: Canon_MG3600_series" in lines
    assert "Toning: neutral" in lines
    assert any(line.startswith("Size: 7.50 x 10.00 in") for line in lines)


def test_print_sends_a_job(tmp_path: Path) -> None:
    session = opened(tmp_path, printer="Canon_MG3600_series")
    runner = FakeRunner(REPLY)
    assert session.print(tmp_path, runner) == "Canon_MG3600_series-9"
    command = runner.commands[0]
    assert "PageSize=Letter" in command
    assert command[command.index("-t") + 1] == "OpenQuad: photo.tif"


def test_print_needs_a_printer_and_a_fitting_size(tmp_path: Path) -> None:
    session = opened(tmp_path)
    with pytest.raises(SessionError, match="printer"):
        session.print(tmp_path, FakeRunner(REPLY))
    with pytest.raises(SessionError, match="printer"):
        session.print_job(tmp_path / "x.tif")
    session.printer, session.fit, session.ppi = "P", False, 10.0
    with pytest.raises(SessionError, match="larger than the paper"):
        session.print_job(tmp_path / "x.tif")


def test_max_size_keeps_a_negative_within_the_tissue(tmp_path: Path) -> None:
    """A 4 x 5 in tissue: the negative's outer edge (safe edge included) fits it exactly."""
    # (5, 4) or (4, 5): the box turns to match the photo
    session = opened(tmp_path, mode="negative", safe_edge=0.25, max_size=(5.0, 4.0))
    width, height = session.size_inches()  # the photo is portrait: 300 x 400 px
    assert height == pytest.approx(5.0) and width <= 4.0 + 1e-9
    assert "Fit within: 4 x 5 in" in session.summary()
    edge = round(0.25 * session.effective_ppi())
    assert session.render(session._photo().pixels).shape[0] == 400 + 2 * edge


def test_max_size_bounds_a_print_and_never_passes_the_page(tmp_path: Path) -> None:
    session = opened(tmp_path, max_size=(4.0, 5.0))
    assert session.effective_ppi() == pytest.approx(80.0)  # 300 / 4 and 400 / 5
    assert session.size_inches() == pytest.approx((3.75, 5.0))
    session.max_size = (20.0, 30.0)  # bigger than the page: the page still limits
    assert session.size_inches()[1] == pytest.approx(10.0)
    session.fit = False  # the box only applies when fitting
    session.max_size = (1.0, 1.0)
    assert session.effective_ppi() == pytest.approx(72.0)
    assert not any(line.startswith("Fit within") for line in session.summary())
