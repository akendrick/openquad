"""Scan from a network scanner over eSCL (AirScan), with fixed settings.

Every scan uses the same settings (RGB, sRGB, Photo intent, lowest compression,
no automatic adjustments), so measurements from different days compare.
"""

from __future__ import annotations

import time
import urllib.error
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urljoin

# (method, url, body) -> (status, location header or "", body)
Fetch = Callable[[str, str, bytes | None], tuple[int, str, bytes]]

LETTER_300THS = (2550, 3300)  # 8.5 x 11 in, in 1/300 in units
BUSY_RETRIES = 10


class ScanError(RuntimeError):
    """The scanner refused or failed the scan."""


def http_fetch(method: str, url: str, body: bytes | None) -> tuple[int, str, bytes]:
    request = urllib.request.Request(url, data=body, method=method)
    if body is not None:
        request.add_header("Content-Type", "text/xml")
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            return response.status, response.headers.get("Location", ""), response.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.headers.get("Location", "") if exc.headers else "", exc.read()
    except (urllib.error.URLError, TimeoutError) as exc:
        raise ScanError(f"can't reach the scanner at {url}: {exc}") from None


@dataclass(frozen=True)
class ScanSettings:
    dpi: int = 300
    width: int = LETTER_300THS[0]
    height: int = LETTER_300THS[1]

    def __post_init__(self) -> None:
        if self.dpi not in (75, 100, 150, 200, 300, 600, 1200):
            raise ValueError(f"unsupported scan resolution {self.dpi}")

    def xml(self) -> bytes:
        return f"""<?xml version="1.0" encoding="UTF-8"?>
<scan:ScanSettings xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" \
xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
  <pwg:Version>2.5</pwg:Version>
  <scan:Intent>Photo</scan:Intent>
  <pwg:ScanRegions>
    <pwg:ScanRegion>
      <pwg:Height>{self.height}</pwg:Height>
      <pwg:ContentRegionUnits>escl:ThreeHundredthsOfInches</pwg:ContentRegionUnits>
      <pwg:Width>{self.width}</pwg:Width>
      <pwg:XOffset>0</pwg:XOffset>
      <pwg:YOffset>0</pwg:YOffset>
    </pwg:ScanRegion>
  </pwg:ScanRegions>
  <pwg:InputSource>Platen</pwg:InputSource>
  <scan:DocumentFormatExt>image/jpeg</scan:DocumentFormatExt>
  <scan:XResolution>{self.dpi}</scan:XResolution>
  <scan:YResolution>{self.dpi}</scan:YResolution>
  <scan:ColorMode>RGB24</scan:ColorMode>
  <scan:ColorSpace>sRGB</scan:ColorSpace>
  <scan:CompressionFactor>0</scan:CompressionFactor>
</scan:ScanSettings>
""".encode()


def scan(
    host: str,
    output: str | Path,
    settings: ScanSettings | None = None,
    fetch: Fetch = http_fetch,
    sleep: Callable[[float], None] = time.sleep,
) -> Path:
    """Scan the platen to a JPEG file and return its path."""
    settings = settings or ScanSettings()
    base = host if host.startswith("http") else f"http://{host}"
    jobs_url = urljoin(base.rstrip("/") + "/", "eSCL/ScanJobs")

    for _ in range(BUSY_RETRIES):
        status, location, body = fetch("POST", jobs_url, settings.xml())
        if status != 503:  # 503 = busy (e.g. warming up)
            break
        sleep(2.0)
    if status != 201 or not location:
        raise ScanError(f"scanner refused the job (HTTP {status}): {body[:200]!r}")

    document_url = urljoin(jobs_url, location.rstrip("/") + "/NextDocument")
    for _ in range(BUSY_RETRIES):
        status, _, image = fetch("GET", document_url, None)
        if status != 503:
            break
        sleep(2.0)
    if status != 200 or not image.startswith(b"\xff\xd8"):
        raise ScanError(f"no image from the scanner (HTTP {status})")
    path = Path(output)
    path.write_bytes(image)
    return path
