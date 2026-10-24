"""Start the OpenQuad desktop app: `openquad-app`."""

from __future__ import annotations

import gc
import sys

from PySide6.QtCore import QTimer
from PySide6.QtWidgets import QApplication

from openquad import __version__
from openquad.ui.main_window import MainWindow


def collect_on_main_thread(app: QApplication) -> QTimer:
    """Run Python's cyclic garbage collector only on the GUI thread.

    Left automatic, it can run on a background thread (wherever memory is being
    allocated) and free Qt objects there, which crashes PySide. So it is disabled
    and run from a main-thread timer instead.
    """
    gc.disable()
    timer = QTimer(app)
    timer.timeout.connect(gc.collect)
    timer.start(GC_INTERVAL_MS)
    return timer


GC_INTERVAL_MS = 5000


def main(argv: list[str] | None = None) -> int:  # pragma: no cover - starts the event loop
    app = QApplication(argv if argv is not None else sys.argv)
    collect_on_main_thread(app)
    app.setApplicationName("OpenQuad")
    app.setApplicationVersion(__version__)
    window = MainWindow()
    window.show()
    return app.exec()


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
