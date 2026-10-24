"""Scan from a network scanner over eSCL (AirScan), with fixed settings.

Every scan uses the same settings (RGB, sRGB, Photo intent, lowest compression,
no automatic adjustments), so measurements from different days compare.
"""

from __future__ import annotations

import contextlib
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


INTENTS = ("Photo", "Document", "TextAndGraphic", "Preview")


@dataclass(frozen=True)
class ScanSettings:
    """eSCL scan settings. `intent` changes how the scanner processes the image.

    Document is the default for measuring: on the Canon MG3600, Photo auto-crops
    to one detected "photo" and alters its colour and levels (it read a target's
    deepest black as L* 19 where Document reads L* 27, and its cast as 6.7 vs 5.4).
    """

    dpi: int = 300
    width: int = LETTER_300THS[0]
    height: int = LETTER_300THS[1]
    intent: str = "Document"

    def __post_init__(self) -> None:
        if self.dpi not in (75, 100, 150, 200, 300, 600, 1200):
            raise ValueError(f"unsupported scan resolution {self.dpi}")
        if self.intent not in INTENTS:
            raise ValueError(f"intent must be one of {INTENTS}, got {self.intent!r}")

    def xml(self) -> bytes:
        return f"""<?xml version="1.0" encoding="UTF-8"?>
<scan:ScanSettings xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" \
xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
  <pwg:Version>2.5</pwg:Version>
  <scan:Intent>{self.intent}</scan:Intent>
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

    job_url = urljoin(jobs_url, location.rstrip("/"))
    try:
        for _ in range(BUSY_RETRIES):
            status, _, image = fetch("GET", job_url + "/NextDocument", None)
            if status != 503:
                break
            sleep(2.0)
    finally:
        # Close the job, or the scanner keeps it open and refuses the next one (503).
        with contextlib.suppress(ScanError):
            fetch("DELETE", job_url, None)
    if status != 200 or not image.startswith(b"\xff\xd8"):
        raise ScanError(f"no image from the scanner (HTTP {status})")
    path = Path(output)
    path.write_bytes(image)
    return path


# --- finding scanners on the network -------------------------------------------------

Browse = Callable[[list[str], float], str]  # (command, seconds) -> text it printed


def run_for(command: list[str], seconds: float) -> str:
    """Run a browsing command for `seconds` (they never exit on their own) and return its output."""
    import os
    import signal
    import subprocess

    try:
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            start_new_session=True,  # its own process group, so children stop with it
        )
    except FileNotFoundError:
        return ""
    try:
        out, _ = process.communicate(timeout=seconds)
    except subprocess.TimeoutExpired:
        # Stop the whole group: a child left running would hold the pipe open.
        os.killpg(process.pid, signal.SIGKILL)
        out, _ = process.communicate()
    return out or ""


def parse_avahi(text: str) -> list[tuple[str, str]]:
    """(name, host:port) from `avahi-browse -rpt _uscan._tcp` output."""
    found = []
    for line in text.splitlines():
        fields = line.split(";")
        if len(fields) >= 9 and fields[0] == "=":
            found.append((fields[3].replace("\\032", " "), f"{fields[6]}:{fields[8]}"))
    return found


def parse_dns_sd_browse(text: str) -> list[str]:
    """Instance names from `dns-sd -B _uscan._tcp` output."""
    names = []
    for line in text.splitlines():
        parts = line.split(None, 6)
        if len(parts) == 7 and parts[1] == "Add" and parts[5] == "_uscan._tcp.":
            names.append(parts[6].strip())
    return names


def parse_dns_sd_resolve(text: str) -> str | None:
    """host:port from `dns-sd -L NAME _uscan._tcp` output."""
    for line in text.splitlines():
        if "can be reached at" in line:
            target = line.split("can be reached at", 1)[1].split()[0]
            host, _, port = target.rpartition(":")
            return f"{host.rstrip('.')}:{port}" if port.isdigit() else target
    return None


def discover(browse: Browse = run_for, seconds: float = 3.0) -> list[tuple[str, str]]:
    """eSCL scanners on the network: [(name, "host:port")]. Uses avahi or dns-sd."""
    import shutil

    if shutil.which("avahi-browse"):
        return parse_avahi(browse(["avahi-browse", "-rpt", "_uscan._tcp"], seconds))
    found = []
    for name in dict.fromkeys(
        parse_dns_sd_browse(browse(["dns-sd", "-B", "_uscan._tcp"], seconds))
    ):
        host = parse_dns_sd_resolve(browse(["dns-sd", "-L", name, "_uscan._tcp"], seconds))
        if host:
            found.append((name, host))
    return found
