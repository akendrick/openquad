"""Shared test setup: Qt runs headless (offscreen) so UI tests work in CI."""

import gc
import os
from collections.abc import Iterator

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")


@pytest.fixture(autouse=True)
def _gc_on_main_thread(request: pytest.FixtureRequest) -> Iterator[None]:
    """UI tests: no automatic garbage collection during the test (it could run on a
    background thread and free Qt objects there); collect on the main thread after
    the test's windows are closed. Mirrors what the app does (see ui/app.py)."""
    if "qtbot" not in request.fixturenames:
        yield
        return
    gc.disable()
    try:
        yield
    finally:
        gc.enable()
        gc.collect()


@pytest.fixture(autouse=True)
def _finish_background_work(request: pytest.FixtureRequest) -> Iterator[None]:
    """UI tests: let background work finish and its results be delivered before the
    test's windows are torn down, so nothing reaches a deleted window."""
    if "qtbot" not in request.fixturenames:
        yield
        return
    request.getfixturevalue("qtbot")  # set qtbot up first, so this tears down before it
    yield
    from PySide6.QtWidgets import QApplication

    from openquad.ui import background

    background.wait()
    QApplication.processEvents()
