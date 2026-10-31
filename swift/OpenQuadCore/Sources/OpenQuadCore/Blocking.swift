// The UV blocking test: which negative colour blocks fully and gives the most steps.
// Mirrors openquad/blocking.py BlockingLayout, ColourResult, BlockingReport and analyse.

import Foundation

public struct BlockingLayout: SheetSpec {
    public static let steps = 11  // 0%, 10%, ... 100% ink
    public var colours = Negative.standardColours
    public var labelWidth = 1.0
    public var marker = 0.3
    public var fullWidth = 0.6
    public var stepWidth = 0.35
    public var rowHeight = 0.45
    public var gap = 0.12

    public init(colours: [String] = Negative.standardColours) { self.colours = colours }

    public var width: Double {
        labelWidth + gap + fullWidth + gap + Double(Self.steps) * stepWidth + gap
    }
    public var height: Double { gap + marker + gap + Double(colours.count) * (rowHeight + gap) }

    public func rowTop(_ row: Int) -> Double { 2 * gap + marker + Double(row) * (rowHeight + gap) }

    public func fullBox(_ row: Int) -> (Double, Double, Double, Double) {
        let left = labelWidth + gap, top = rowTop(row)
        return (left, top, left + fullWidth, top + rowHeight)
    }

    public func stepBox(_ row: Int, _ step: Int) -> (Double, Double, Double, Double) {
        let left = labelWidth + 2 * gap + fullWidth + Double(step) * stepWidth, top = rowTop(row)
        return (left, top, left + stepWidth, top + rowHeight)
    }

    public func markerBox() -> (Double, Double, Double, Double) { (gap, gap, gap + marker, gap + marker) }

    /// Clear film on every sheet (prints darkest): gaps between rows, before each wedge,
    /// and the 0% end of each wedge.
    func darkPoints() -> [(Double, Double)] {
        var points: [(Double, Double)] = []
        let rows = colours.count
        let columns = [(fullBox(0).0 + fullBox(0).2) / 2] + stride(from: 0, to: Self.steps, by: 2).map { (stepBox(0, $0).0 + stepBox(0, $0).2) / 2 }
        for gapRow in 0...rows {
            let y = rowTop(gapRow) - gap / 2
            points += columns.map { ($0, y) }
        }
        let gapX = fullBox(0).2 + gap / 2
        for row in 0..<rows {
            let top = rowTop(row), bottom = rowTop(row) + rowHeight
            points.append((gapX, (top + bottom) / 2))
            let (l, t, r, b) = stepBox(row, Self.steps - 1)
            points.append(((l + r) / 2, (t + b) / 2))
        }
        return points
    }

    /// The most ink on every sheet: full patches and the dense half of each wedge.
    func lightPoints() -> [(Double, Double)] {
        var points: [(Double, Double)] = []
        for row in 0..<colours.count {
            for (l, t, r, b) in [fullBox(row)] + (0..<4).map({ stepBox(row, $0) }) {
                points.append(((l + r) / 2, (t + b) / 2))
            }
        }
        return points
    }
}

public struct ColourResult: Sendable {
    public static let fullBlockDelta = 3.0
    public static let distinctStep = 1.5
    public let name: String
    /// L* of the full-strength patch.
    public let full: Double
    /// L* from 0% to 100% ink.
    public let wedge: [Double]
    /// L* of the process's white.
    public let paper: Double

    public var blocksFully: Bool { paper - full <= Self.fullBlockDelta }
    public var tonalRange: Double { wedge[wedge.count - 1] - wedge[0] }
    public var usableSteps: Int {
        var kept = 1, last = wedge[0]
        for value in wedge.dropFirst() where value - last >= Self.distinctStep {
            kept += 1
            last = value
        }
        return kept
    }
}

public struct BlockingReport: Sendable {
    public static let edgeLeak = 10.0
    public let results: [ColourResult]
    public let orientation: String
    public var paper = 100.0
    public var edge = 100.0
    public var white = 100.0

    public var edgeLeaks: Bool { paper - white > Self.edgeLeak }
    public var safeEdgeLeaks: Bool { white - edge > ColourResult.fullBlockDelta }

    /// The fully blocking colour with the most usable steps (longest range on ties).
    public func best() -> ColourResult? {
        if edgeLeaks { return nil }
        var best: ColourResult?
        for r in results where r.blocksFully {
            if let b = best, (r.usableSteps, r.tonalRange) <= (b.usableSteps, b.tonalRange) { continue }
            best = r
        }
        return best
    }

    public func lines() -> [String] {
        func f(_ v: Double, _ width: Int) -> String { String(format: "%\(width).1f", v) }
        func left(_ s: String, _ width: Int) -> String { s.padding(toLength: max(width, s.count), withPad: " ", startingAt: 0) }
        func right(_ s: String, _ width: Int) -> String { String(repeating: " ", count: max(0, width - s.count)) + s }
        var out = ["\(left("colour", 8)) \(right("full L*", 8)) \(right("blocks", 7)) \(right("range", 6)) \(right("steps", 6))"]
        for r in results {
            out.append("\(left(r.name, 8)) \(f(r.full, 8)) \(right(r.blocksFully ? "yes" : "no", 7)) "
                       + "\(f(r.tonalRange, 6)) \(right(String(r.usableSteps), 4))/\(BlockingLayout.steps)")
        }
        out.append("Process white (best blocker) L* \(f(white, 0)); bare paper L* \(f(paper, 0)) "
                   + "(difference \(f(paper - white, 0)); tissue stain is normally a few L*)")
        if safeEdgeLeaks && !edgeLeaks {
            out.append("The black safe edge leaked (L* \(f(edge, 0))): print safe edges in the best blocking colour.")
        }
        if edgeLeaks {
            out.append("Even the best-blocking ink let light through: the exposure was too long for this "
                       + "film and ink. Try a shorter exposure, then repeat the test.")
        } else if let best = best() {
            out.append("Best: \(best.name) (\(best.usableSteps) usable steps, \(f(best.tonalRange, 0)) L*)")
        } else {
            out.append("No colour blocked fully: this ink and film can't reach paper white at this "
                       + "exposure. Try a shorter exposure, more sensitizer, or denser film (Pictorico).")
        }
        return out
    }
}

public enum Blocking {
    static let minStepPixels = 12.0

    /// Read a scanned print of the blocking sheet, lying any way on the scanner.
    public static func analyse(_ scan: Scan, layout: BlockingLayout = BlockingLayout()) throws -> BlockingReport {
        let expected = layout.width / layout.height
        let original = LightnessMap(scan)
        let rough = try Reader.findSheets(original, aspect: expected)[0]
        let (map, tilt) = Reader.deskew(original, rough)
        let (box, fit, score) = Reader.fitLayout(map, rough, layout, dark: layout.darkPoints(), light: layout.lightPoints())
        let view = SheetView(map, box, fit)
        if score < 2 * Reader.markerContrast || Reader.markerContrast(view, layout) < Reader.markerContrast {
            throw BlockingError(description: "couldn't find the marker square; is the sheet fully on the scan?")
        }
        let ratio = (Double(view.width) / Double(view.height)) / expected
        if abs(ratio - 1) > 0.08 {
            throw BlockingError(description: "the exposed area's shape doesn't match the sheet (\(String(format: "%.2f", ratio))x); "
                                + "check the whole sheet is on the scan and placed square")
        }
        if layout.stepWidth * Double(view.width) / layout.width < minStepPixels {
            throw BlockingError(description: "the patches are too small to read; scan at a higher resolution")
        }
        let edge = try Reader.safeEdgeLightness(map, box, perInch: Double(view.width) / layout.width)
        let fulls = layout.colours.indices.map { Reader.sample(view, layout, layout.fullBox($0)) }
        let white = ([edge] + fulls).max()!
        let results = layout.colours.enumerated().map { row, name in
            ColourResult(name: name, full: fulls[row],
                         wedge: (0..<BlockingLayout.steps).reversed().map { Reader.sample(view, layout, layout.stepBox(row, $0)) },
                         paper: white)
        }
        return BlockingReport(results: results, orientation: Reader.orientation(fit, tilt: tilt),
                              paper: percentile(map.values, [99])[0], edge: edge, white: white)
    }
}

extension Blocking {
    /// The test sheet as a negative (clear film = 65535): an opaque marker, then for each
    /// colour a full-strength patch and an 11-step wedge, inside a black safe edge.
    /// Mirrors openquad/blocking.py blocking_sheet; the colour names are drawn with the
    /// system font (Python uses Pillow's), so `labels: false` gives the identical sheet.
    public static func sheet(layout: BlockingLayout = BlockingLayout(), dpi: Double = 300, mirror: Bool = false,
                             safeEdge: Double = 0.25, labels: Bool = true) -> RGBImage {
        let height = pyRound(layout.height * dpi), width = pyRound(layout.width * dpi)
        var pixels = [UInt16](repeating: UInt16(maxValue), count: width * height * 3)
        func fill(_ box: (Double, Double, Double, Double), _ rgb: (UInt16, UInt16, UInt16)) {
            for y in pySlice(pyRound(box.1 * dpi), pyRound(box.3 * dpi), height) {
                for x in pySlice(pyRound(box.0 * dpi), pyRound(box.2 * dpi), width) {
                    let i = (y * width + x) * 3
                    (pixels[i], pixels[i + 1], pixels[i + 2]) = rgb
                }
            }
        }
        fill(layout.markerBox(), (0, 0, 0))  // opaque marker
        for (row, name) in layout.colours.enumerated() {
            let colour = Negative.colours[name]!
            fill(layout.fullBox(row), Negative.inkToRGB(1.0, colour))
            for step in 0..<BlockingLayout.steps {  // 100% next to the full patch
                fill(layout.stepBox(row, step), Negative.inkToRGB(1.0 - Double(step) / Double(BlockingLayout.steps - 1), colour))
            }
        }
        if labels {
            let mask = TextMask.draw(layout.colours.enumerated().map { row, name in
                (name, Double(pyRound(layout.gap * dpi)), Double(pyRound((layout.rowTop(row) + layout.rowHeight * 0.25) * dpi)))
            }, size: Double(max(8, pyRound(layout.rowHeight * dpi * 0.4))), width: width, height: height)
            for (i, on) in mask.enumerated() where on { (pixels[i * 3], pixels[i * 3 + 1], pixels[i * 3 + 2]) = (0, 0, 0) }
        }
        return Negative.addSafeEdge(RGBImage(width: width, height: height, pixels: pixels),
                                    settings: NegativeSettings(mirror: mirror, safeEdge: safeEdge), dpi: dpi)
    }
}
