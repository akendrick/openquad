"""Tests for the eSCL scanner client, against a fake scanner (no network)."""

from pathlib import Path

import pytest

from openquad.escl import ScanError, ScanSettings, http_fetch, scan

JPEG = b"\xff\xd8\xff\xe0fake-jpeg"


class FakeScanner:
    def __init__(self, busy: int = 0, job_status: int = 201, doc_status: int = 200) -> None:
        self.busy, self.job_status, self.doc_status = busy, job_status, doc_status
        self.calls: list[tuple[str, str, bytes | None]] = []

    def __call__(self, method: str, url: str, body: bytes | None) -> tuple[int, str, bytes]:
        self.calls.append((method, url, body))
        if self.busy:
            self.busy -= 1
            return 503, "", b""
        if method == "POST":
            return self.job_status, "http://scanner.local/eSCL/ScanJobs/42", b""
        return self.doc_status, "", JPEG


def test_scan_posts_settings_and_saves_the_jpeg(tmp_path: Path) -> None:
    fake = FakeScanner()
    out = scan("scanner.local", tmp_path / "scan.jpg", fetch=fake)
    assert out.read_bytes() == JPEG
    (method, url, body), (method2, url2, _) = fake.calls
    assert (method, url) == ("POST", "http://scanner.local/eSCL/ScanJobs")
    assert body is not None and b"<scan:ColorMode>RGB24</scan:ColorMode>" in body
    assert b"<scan:XResolution>300</scan:XResolution>" in body
    assert (method2, url2) == ("GET", "http://scanner.local/eSCL/ScanJobs/42/NextDocument")


def test_scan_waits_while_the_scanner_is_busy(tmp_path: Path) -> None:
    waits: list[float] = []
    fake = FakeScanner(busy=2)
    scan("http://scanner.local/", tmp_path / "s.jpg", fetch=fake, sleep=waits.append)
    assert len(waits) == 2


def test_refused_job(tmp_path: Path) -> None:
    with pytest.raises(ScanError, match="refused"):
        scan("scanner.local", tmp_path / "s.jpg", fetch=FakeScanner(job_status=409))


def test_missing_image(tmp_path: Path) -> None:
    with pytest.raises(ScanError, match="no image"):
        scan("scanner.local", tmp_path / "s.jpg", fetch=FakeScanner(doc_status=404))


def test_settings_resolution_is_checked() -> None:
    with pytest.raises(ValueError, match="resolution"):
        ScanSettings(dpi=333)
    assert b"<scan:XResolution>600" in ScanSettings(dpi=600).xml()


def test_unreachable_scanner() -> None:
    with pytest.raises(ScanError, match="can't reach"):
        http_fetch("GET", "http://127.0.0.1:9/eSCL/ScannerCapabilities", None)
