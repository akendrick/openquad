// Reading scanned prints of the ChartThrob-style process chart. Mirrors the reading
// half of openquad/chart.py (ChartLayout, read_chart, read_chart_page).

import Foundation

public struct ChartLayout: SheetSpec {
    public static let patches = 101  // 0% .. 100% in 1% steps
    public static let idColumn = 5  // first bottom-row column used for identification squares
    public static let maxID = 4
    public static let strip = 21

    public var patch = 0.36
    public var gap = 0.06
    public var marker = 0.3
    public var stripWidth = 0.4
    public var gradientWidth = 0.3

    public init(patch: Double = 0.36, gap: Double = 0.06, marker: Double = 0.3, stripWidth: Double = 0.4, gradientWidth: Double = 0.3) {
        self.patch = patch
        self.gap = gap
        self.marker = marker
        self.stripWidth = stripWidth
        self.gradientWidth = gradientWidth
    }

    /// The smaller chart, two to a page.
    public static func compact() -> ChartLayout {
        ChartLayout(patch: 0.3, gap: 0.05, marker: 0.25, stripWidth: 0.33, gradientWidth: 0.25)
    }

    public var gridLeft: Double { gap * 2 }
    public var gridTop: Double { 3 * gap + marker }
    public var gridWidth: Double { 10 * patch + 9 * gap }
    public var gridHeight: Double { 11 * patch + 10 * gap }
    public var stripLeft: Double { gridLeft + gridWidth + 3 * gap }
    public var gradientLeft: Double { stripLeft + stripWidth + 2 * gap }
    public var width: Double { gradientLeft + gradientWidth + 2 * gap }
    public var height: Double { gridTop + gridHeight + 2 * gap }

    public func markerBox() -> (Double, Double, Double, Double) { (gap * 2, gap * 2, gap * 2 + marker, gap * 2 + marker) }

    public func idBox(_ k: Int) -> (Double, Double, Double, Double) { patchBox(Self.patches - 1 + Self.idColumn + k) }

    /// Patch n (0 = white print .. 100 = black print), row by row.
    public func patchBox(_ n: Int) -> (Double, Double, Double, Double) {
        let row = n / 10, column = n % 10
        let left = gridLeft + Double(column) * (patch + gap), top = gridTop + Double(row) * (patch + gap)
        return (left, top, left + patch, top + patch)
    }

    public func stripBox(_ step: Int) -> (Double, Double, Double, Double) {
        let height = gridHeight / Double(Self.strip)
        let top = gridTop + Double(step) * height
        return (stripLeft, top, stripLeft + stripWidth, top + height)
    }

    /// (clear-film spots, heavily inked spots) for fitting the layout to a print.
    func points() -> (dark: [(Double, Double)], light: [(Double, Double)]) {
        var dark: [(Double, Double)] = []
        for n in 0..<(Self.patches - 1) {
            let (l, t, r, b) = patchBox(n)
            dark.append((r + gap / 2, (t + b) / 2))
            dark.append(((l + r) / 2, b + gap / 2))
        }
        let (l, t, r, b) = patchBox(Self.patches - 1)
        dark.append(((l + r) / 2, (t + b) / 2))
        for n in 1..<10 where !(Self.idColumn..<(Self.idColumn + Self.maxID)).contains(n) {
            dark.append(((l + r) / 2 + Double(n) * (patch + gap), (t + b) / 2))
        }
        let light = (0..<30).map { n -> (Double, Double) in
            let (l, t, r, b) = patchBox(n)
            return ((l + r) / 2, (t + b) / 2)
        }
        return (dark, light)
    }
}

public enum Chart {
    /// The photo grey level (0 black .. 65535 white) of patch n: 0 is white, 100 black.
    public static func patchLevel(_ n: Int) -> UInt16 {
        UInt16(pyRound(Double(maxValue) * (1 - Double(n) / Double(ChartLayout.patches - 1))))
    }

    static func readOne(_ full: LightnessMap, _ rough: SheetBox, _ layout: ChartLayout) throws -> (ChartReading, Int) {
        let (map, tilt) = Reader.deskew(full, rough)
        let (dark, light) = layout.points()
        let (box, fit, score) = Reader.fitLayout(map, rough, layout, dark: dark, light: light)
        let view = SheetView(map, box, fit)
        if score < 2 * Reader.markerContrast || Reader.markerContrast(view, layout) < Reader.markerContrast {
            throw BlockingError(description: "couldn't find the chart's marker; is the whole chart on the scan?")
        }
        if layout.patch * Double(view.width) / layout.width < 10 {
            throw BlockingError(description: "the patches are too small to read; scan at a higher resolution")
        }
        let patches = (0..<ChartLayout.patches).map { Reader.sample(view, layout, layout.patchBox($0)) }
        let background = Reader.sample(view, layout, layout.patchBox(ChartLayout.patches))
        let marker = Reader.sample(view, layout, layout.markerBox())
        let index = (0..<ChartLayout.maxID).filter { Reader.sample(view, layout, layout.idBox($0)) > (marker + background) / 2 }.count
        let reading = ChartReading(
            levels: (0..<ChartLayout.patches).map(patchLevel), lightness: patches,
            strip: (0..<ChartLayout.strip).map { Reader.sample(view, layout, layout.stripBox($0)) },
            orientation: Reader.orientation(fit, tilt: tilt),
            paper: try Reader.safeEdgeLightness(map, box, perInch: Double(view.width) / layout.width))
        return (reading, index)
    }

    /// Measure every patch of a scanned print of the chart (any way up, tilted, mirrored).
    public static func read(_ scan: Scan, layout: ChartLayout = ChartLayout()) throws -> ChartReading {
        let map = LightnessMap(scan)
        return try readOne(map, try Reader.findSheets(map, aspect: layout.width / layout.height)[0], layout).0
    }

    /// Measure the `count` compact charts of a scanned page, in page order (chart 0 first),
    /// told apart by their identification squares.
    public static func readPage(_ scan: Scan, count: Int) throws -> [ChartReading] {
        let layout = ChartLayout.compact()
        let map = LightnessMap(scan)
        let found = try Reader.findSheets(map, aspect: layout.width / layout.height, count: count).map { try readOne(map, $0, layout) }
        let indices = found.map(\.1).sorted()
        guard indices == Array(0..<count) else {
            throw BlockingError(description: "couldn't tell the charts apart (identification marks read \(indices)); "
                                + "is every chart fully on the scan?")
        }
        return found.sorted { $0.1 < $1.1 }.map(\.0)
    }
}
