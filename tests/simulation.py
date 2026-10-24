"""A simulated colour printer and flatbed scanner for calibration tests.

The printer prints neutral RGB with a blue cast (channel gammas differ and the
channels bleed into each other), like the Canon MG3600 on plain paper. The
scanner adds its own white cast, 8-bit quantisation and noise.
"""

import numpy as np
from numpy.typing import NDArray

from openquad.colour import linear_to_srgb, srgb_to_linear

GAMMAS = np.array([1.0, 1.08, 0.82])  # blue reflects more light -> blue cast
CROSSTALK = np.array([[0.92, 0.06, 0.02], [0.05, 0.90, 0.05], [0.02, 0.08, 0.90]])
PAPER = np.array([0.93, 0.94, 0.96])
SCANNER_WHITE = np.array([1.0, 0.98, 1.03])
DMIN = 0.01


def print_sheet(rgb: NDArray[np.uint16]) -> NDArray[np.float64]:
    """Linear reflectance (..., 3) of a printed 16-bit RGB image."""
    sent = srgb_to_linear(rgb.astype(np.float64) / 65535)
    response = DMIN + (1 - DMIN) * sent**GAMMAS
    result: NDArray[np.float64] = (response @ CROSSTALK.T) * PAPER
    return result


def scan_sheet(
    reflectance: NDArray[np.float64], margin: int = 40, seed: int = 0
) -> NDArray[np.float64]:
    """Encoded 0-1 scan of a printed sheet laid on the platen with paper around it."""
    rng = np.random.default_rng(seed)
    h, w = reflectance.shape[:2]
    canvas = np.tile(PAPER, (h + 2 * margin, w + 2 * margin + 13, 1))
    canvas[margin : margin + h, margin + 7 : margin + 7 + w] = reflectance
    encoded = linear_to_srgb(np.clip(canvas * SCANNER_WHITE, 0, 1))
    noisy = encoded + rng.normal(0, 1.5 / 255, encoded.shape)
    result: NDArray[np.float64] = np.round(np.clip(noisy, 0, 1) * 255) / 255
    return result


class SimulatedLab:
    """A fake printer (`lp`) and scanner (eSCL) wired together.

    Printing a file "prints" it with the simulated printer onto a Letter-sized
    sheet; the next scan returns a JPEG of that sheet as the scanner would.
    """

    def __init__(self, scan_dpi: int = 150) -> None:
        self.scan_dpi = scan_dpi
        self.sheet: NDArray[np.float64] | None = None
        self.jobs = 0
        self.commands: list[list[str]] = []

    def runner(self, command):  # type: ignore[no-untyped-def]
        import subprocess

        import tifffile

        self.commands.append(list(command))
        page = tifffile.imread(command[-1])
        step = max(1, round(300 / self.scan_dpi))
        self.sheet = print_sheet(page[::step, ::step])
        self.jobs += 1
        return subprocess.CompletedProcess(
            command, 0, f"request id is Sim-{self.jobs} (1 file(s))\n", ""
        )

    def fetch(self, method: str, url: str, body: bytes | None) -> tuple[int, str, bytes]:
        import io

        from PIL import Image

        if method == "POST":
            return 201, url + "/1", b""
        if method == "DELETE":
            return 200, "", b""
        if self.sheet is None:
            return 404, "", b""
        scan = scan_sheet(self.sheet, margin=60)[::-1, ::-1]  # Document scans come back rotated
        buffer = io.BytesIO()
        Image.fromarray(np.round(scan * 255).astype(np.uint8)).save(buffer, "JPEG", quality=92)
        return 200, "", buffer.getvalue()


def contact_print(
    negative: NDArray[np.uint16],
    exposure: float = 1.0,
    film: float = 0.9,
    black_leak: float = 0.0,
) -> NDArray[np.float64]:
    """A simulated carbon print (encoded sRGB 0-1) contact-printed through a negative.

    Carbon tissue is exposed by near-UV, which ink absorbs mostly through its blue
    channel: transmission = film base * (mostly blue, a little green). More exposure
    hardens more pigment, so the print gets darker, up to the tissue's maximum.
    """
    linear = srgb_to_linear(negative.astype(np.float64) / 65535)
    # No ink is perfectly opaque: a small leak means long exposures eventually show through.
    transmission = film * (0.003 + 0.85 * linear[..., 2] + 0.15 * linear[..., 1])
    # Pigment black sits thinly on coated film: it can pass more UV than coloured dyes.
    transmission += film * black_leak * (1.0 - linear.max(axis=-1))
    hardened = 1.0 - np.exp(-4.0 * exposure * transmission)
    reflectance = 0.88 * (1.0 - 0.97 * hardened)  # paper white 0.88, max density ~1.5
    grey = linear_to_srgb(reflectance)
    result: NDArray[np.float64] = np.repeat(grey[..., np.newaxis], 3, axis=-1)
    return result


class CarbonLab(SimulatedLab):
    """Like SimulatedLab, but printing makes a negative that is contact printed in
    (simulated) carbon, and the scanner returns that carbon print."""

    def runner(self, command):  # type: ignore[no-untyped-def]
        import subprocess

        import tifffile

        self.commands.append(list(command))
        page = tifffile.imread(command[-1])
        step = max(1, round(300 / self.scan_dpi))
        self.sheet = contact_print(page[::step, ::step])
        self.jobs += 1
        return subprocess.CompletedProcess(
            command, 0, f"request id is Sim-{self.jobs} (1 file(s))\n", ""
        )

    def contact_print_file(self, path: str) -> None:
        """For pages 'printed from GIMP': make the carbon print from the saved file."""
        import tifffile

        page = tifffile.imread(path)
        step = max(1, round(300 / self.scan_dpi))
        self.sheet = contact_print(page[::step, ::step])
