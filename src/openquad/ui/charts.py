"""A small chart of a measured wedge: colour cast and tone error per step."""

from __future__ import annotations

import itertools

import numpy as np
from PySide6.QtCore import QPointF, QRectF, Qt
from PySide6.QtGui import QColor, QPainter, QPaintEvent, QPen
from PySide6.QtWidgets import QWidget

from openquad.calibrate import CAST_GOAL, TONE_GOAL
from openquad.chart import ChartReading, tone_errors
from openquad.linearize import tone_report
from openquad.measure import Measurement
from openquad.process_run import TONE_GOAL as PROCESS_GOAL

A_COLOUR = QColor("#c2185b")  # a*: green-red axis
B_COLOUR = QColor("#1565c0")  # b*: blue-yellow axis
TONE_COLOUR = QColor("#455a64")
GOAL_FILL = QColor(46, 125, 50, 40)


class WedgeChart(QWidget):
    """Top: a* and b* per step (corrected solid, uncorrected faint) with the ±3 goal band.
    Bottom: tone error per step (L*) with the ±2 goal band."""

    def __init__(self) -> None:
        super().__init__()
        self.setMinimumSize(420, 260)
        self.corrected: Measurement | None = None
        self.uncorrected: Measurement | None = None

    def set_data(self, uncorrected: Measurement | None, corrected: Measurement | None) -> None:
        self.uncorrected, self.corrected = uncorrected, corrected
        self.update()

    def paintEvent(self, event: QPaintEvent) -> None:  # noqa: N802 (Qt override)
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        painter.fillRect(self.rect(), self.palette().base())
        if self.corrected is None:
            painter.drawText(self.rect(), Qt.AlignmentFlag.AlignCenter, "No measurement yet")
            return
        w, h = self.width(), self.height()
        cast = QRectF(40, 10, w - 50, h * 0.55 - 20)
        tone = QRectF(40, h * 0.55 + 10, w - 50, h * 0.45 - 30)
        self._panel(painter, cast, 8.0, CAST_GOAL, "cast")
        self._panel(painter, tone, 8.0, TONE_GOAL, "tone L*")
        legend = QRectF(cast.right() - 330, cast.top() + 2, 324, 16)
        for offset, colour, text in (
            (0, A_COLOUR, "a* green-red"),
            (160, B_COLOUR, "b* blue-yellow"),
        ):
            painter.setPen(QPen(colour, 3))
            y0 = legend.center().y()
            painter.drawLine(
                QPointF(legend.left() + offset, y0), QPointF(legend.left() + offset + 18, y0)
            )
            painter.setPen(self.palette().text().color())
            painter.drawText(
                legend.adjusted(offset + 24, 0, 0, 0), Qt.AlignmentFlag.AlignLeft, text
            )
        steps = len(self.corrected.levels)

        def x(i: int, area: QRectF) -> float:
            return area.left() + (i + 0.5) * area.width() / steps

        def y(value: float, area: QRectF, limit: float) -> float:
            clipped = max(-limit, min(limit, value))
            return area.center().y() - clipped / limit * area.height() / 2

        if self.uncorrected is not None:
            for channel, colour in ((1, A_COLOUR), (2, B_COLOUR)):
                faint = QColor(colour)
                faint.setAlpha(70)
                self._line(painter, faint, [
                    QPointF(x(i, cast), y(v, cast, 8.0))
                    for i, v in enumerate(self.uncorrected.lab[:, channel])
                ])  # fmt: skip
        for channel, colour in ((1, A_COLOUR), (2, B_COLOUR)):
            values = self.corrected.lab[:, channel]
            points = [QPointF(x(i, cast), y(v, cast, 8.0)) for i, v in enumerate(values)]
            self._line(painter, colour, points)

        report = tone_report(self.corrected)
        errors = np.asarray(report.errors)[::-1]  # white first, like the wedge
        bar = tone.width() / steps * 0.6
        painter.setPen(Qt.PenStyle.NoPen)
        painter.setBrush(TONE_COLOUR)
        for i, error in enumerate(errors):
            top = y(float(max(error, 0.0)), tone, 8.0)
            bottom = y(float(min(error, 0.0)), tone, 8.0)
            painter.drawRect(QRectF(x(i, tone) - bar / 2, top, bar, max(bottom - top, 1.0)))
        painter.setPen(self.palette().text().color())
        painter.drawText(QRectF(40, h - 18, w - 50, 16), Qt.AlignmentFlag.AlignCenter,
                         "step 1 (paper white) … step 21 (black)")  # fmt: skip

    def _panel(
        self, painter: QPainter, area: QRectF, limit: float, goal: float, label: str
    ) -> None:
        band = area.height() / 2 * goal / limit
        painter.fillRect(
            QRectF(area.left(), area.center().y() - band, area.width(), 2 * band), GOAL_FILL
        )
        painter.setPen(QPen(self.palette().mid().color(), 1))
        painter.drawRect(area)
        painter.drawLine(
            QPointF(area.left(), area.center().y()), QPointF(area.right(), area.center().y())
        )
        painter.setPen(self.palette().text().color())
        painter.drawText(QRectF(0, area.top(), 38, 16), Qt.AlignmentFlag.AlignRight, f"+{limit:g}")
        painter.drawText(
            QRectF(0, area.bottom() - 16, 38, 16), Qt.AlignmentFlag.AlignRight, f"-{limit:g}"
        )
        painter.drawText(
            area.adjusted(6, 2, 0, 0), Qt.AlignmentFlag.AlignTop, f"{label} (goal ±{goal:g})"
        )

    @staticmethod
    def _line(painter: QPainter, colour: QColor, points: list[QPointF]) -> None:
        painter.setPen(QPen(colour, 2))
        for a, b in itertools.pairwise(points):
            painter.drawLine(a, b)


class ToneChart(QWidget):
    """Measured L* of the 101 chart patches against their targets, one line per colour,
    with the ±3 L* goal band around the target."""

    def __init__(self) -> None:
        super().__init__()
        self.setMinimumSize(420, 220)
        self.readings: dict[str, ChartReading] = {}

    def set_readings(self, readings: dict[str, ChartReading]) -> None:
        self.readings = readings
        self.update()

    def paintEvent(self, event: QPaintEvent) -> None:  # noqa: N802 (Qt override)
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        painter.fillRect(self.rect(), self.palette().base())
        if not self.readings:
            painter.drawText(self.rect(), Qt.AlignmentFlag.AlignCenter, "No chart read yet")
            return
        area = QRectF(44, 10, self.width() - 54, self.height() - 40)
        painter.setPen(QPen(self.palette().mid().color(), 1))
        painter.drawRect(area)

        def x(n: int) -> float:
            return area.left() + n / 100 * area.width()

        def y(lightness: float) -> float:
            return area.bottom() - max(0.0, min(100.0, lightness)) / 100 * area.height()

        first = next(iter(self.readings.values()))
        target = first.lightness - tone_errors(first)
        band = [QPointF(x(n), y(v + PROCESS_GOAL)) for n, v in enumerate(target)]
        band += [QPointF(x(n), y(v - PROCESS_GOAL)) for n, v in reversed(list(enumerate(target)))]
        painter.setPen(Qt.PenStyle.NoPen)
        painter.setBrush(GOAL_FILL)
        painter.drawPolygon(band)
        painter.setPen(QPen(self.palette().text().color(), 1, Qt.PenStyle.DashLine))
        for a, b in itertools.pairwise(enumerate(target)):
            painter.drawLine(QPointF(x(a[0]), y(a[1])), QPointF(x(b[0]), y(b[1])))
        for k, (colour, reading) in enumerate(self.readings.items()):
            pen = QColor(LINE_COLOURS.get(colour, "#455a64"))
            points = [QPointF(x(n), y(v)) for n, v in enumerate(reading.lightness)]
            self._line(painter, pen, points)
            painter.setPen(pen)
            painter.drawText(QRectF(area.left() + 8, area.top() + 4 + 16 * k, 200, 16),
                             Qt.AlignmentFlag.AlignLeft, colour)  # fmt: skip
        painter.setPen(self.palette().text().color())
        painter.drawText(QRectF(0, area.top(), 40, 16), Qt.AlignmentFlag.AlignRight, "L* 100")
        painter.drawText(QRectF(0, area.bottom() - 16, 40, 16), Qt.AlignmentFlag.AlignRight, "0")
        painter.drawText(QRectF(area.left(), area.bottom() + 4, area.width(), 16),
                         Qt.AlignmentFlag.AlignCenter,
                         "patch 0 (print white) … 100 (print black); dashed: target")  # fmt: skip

    @staticmethod
    def _line(painter: QPainter, colour: QColor, points: list[QPointF]) -> None:
        painter.setPen(QPen(colour, 2))
        for a, b in itertools.pairwise(points):
            painter.drawLine(a, b)


LINE_COLOURS = {
    "black": "#212121",
    "green": "#2e7d32",
    "orange": "#ef6c00",
    "yellow": "#f9a825",
    "red": "#c62828",
    "olive": "#827717",
}
