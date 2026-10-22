"""Start the OpenQuad desktop app: `openquad-app`."""

from __future__ import annotations

import sys

from PySide6.QtWidgets import QApplication

from openquad import __version__
from openquad.ui.main_window import MainWindow


def main(argv: list[str] | None = None) -> int:  # pragma: no cover - starts the event loop
    app = QApplication(argv if argv is not None else sys.argv)
    app.setApplicationName("OpenQuad")
    app.setApplicationVersion(__version__)
    window = MainWindow()
    window.show()
    return app.exec()


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
