// Measuring scans of the framed grey-balance target. Mirrors openquad/targets.py
// (FramedLayout, wedge_levels) and openquad/measure.py.

public struct MeasureError: Error, Equatable, CustomStringConvertible {
    public let description: String
}

/// Pixel edges (left, top) inclusive, (right, bottom) exclusive.
public struct PixelBox: Equatable, Sendable {
    public var left, top, right, bottom: Int
    public init(left: Int, top: Int, right: Int, bottom: Int) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }
}

/// Geometry of the framed grey-balance target, in inches: two wedge rows (white to
/// black, then black to white) inside a thin black frame.
public struct FramedLayout: Sendable {
    public var steps = 21
    public var patchWidth = 0.32
    public var patchHeight = 0.8
    public var rowGap = 0.2
    public var frame = 0.04
    public var inset = 0.12

    public init() {}

    public var width: Double { Double(steps) * patchWidth + 2 * (frame + inset) }
    public var height: Double { 2 * patchHeight + rowGap + 2 * (frame + inset) }

    /// (level index, left, top, right, bottom) from the frame's outer corner; index 0 is white.
    public func patchBoxes() -> [(level: Int, left: Double, top: Double, right: Double, bottom: Double)] {
        let edge = frame + inset
        var boxes: [(level: Int, left: Double, top: Double, right: Double, bottom: Double)] = []
        for row in 0..<2 {
            let top = edge + Double(row) * (patchHeight + rowGap)
            for column in 0..<steps {
                let level = row == 0 ? column : steps - 1 - column
                let left = edge + Double(column) * patchWidth
                boxes.append((level, left, top, left + patchWidth, top + patchHeight))
            }
        }
        return boxes
    }

    /// A strip of bare paper inside the frame, between the two rows.
    public func paperBox() -> (Double, Double, Double, Double) {
        let edge = frame + inset
        let top = edge + patchHeight + 0.25 * rowGap
        return (edge, top, width - edge, top + 0.5 * rowGap)
    }
}

public enum Targets {
    /// `steps` evenly spaced grey levels from white (65535) to black (0).
    public static func wedgeLevels(_ steps: Int) -> [UInt16] {
        precondition(steps >= 2, "a wedge needs at least 2 steps")
        return linspace(Double(maxValue), 0, steps).map { UInt16(rint($0)) }
    }
}

public enum Measure {
    /// Encoded value below which a pixel counts as frame or ink.
    public static let dark = 0.35
    /// Fraction of the scan at each border ignored (lid shadows).
    public static let edgeIgnore = 0.02
    /// Central fraction of each patch that is sampled.
    public static let sample = 0.5

    static func darkMask(_ scan: Scan) -> [Bool] {
        (0..<(scan.width * scan.height)).map { i in
            let s = scan.samples, k = i * 3
            return (Double(s[k]) / scan.scale + Double(s[k + 1]) / scan.scale + Double(s[k + 2]) / scan.scale) / 3 < dark
        }
    }

    /// The target's outer frame, skipping `edgeIgnore` of the scan at each border.
    public static func findFrame(_ scan: Scan, edgeIgnore: Double = edgeIgnore) throws -> PixelBox {
        let width = scan.width, height = scan.height
        var mask = darkMask(scan)
        let ey = Int(rint(Double(height) * edgeIgnore)), ex = Int(rint(Double(width) * edgeIgnore))
        for y in 0..<height {
            for x in 0..<width where y < ey || y >= height - ey || x < ex || x >= width - ex {
                mask[y * width + x] = false
            }
        }
        func span(_ counts: [Int]) throws -> (Int, Int) {
            let most = counts.max() ?? 0
            guard most > 0 else { throw MeasureError(description: "no target frame found in the scan") }
            let hits = counts.indices.filter { Double(counts[$0]) >= 0.5 * Double(most) }
            return (hits.first!, hits.last! + 1)
        }
        var rowCounts = [Int](repeating: 0, count: height), columnCounts = [Int](repeating: 0, count: width)
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] {
                rowCounts[y] += 1
                columnCounts[x] += 1
            }
        }
        let (top, bottom) = try span(rowCounts)
        let (left, right) = try span(columnCounts)
        return PixelBox(left: left, top: top, right: right, bottom: bottom)
    }

    /// Find the frame and check its shape matches the layout.
    public static func locateFrame(_ scan: Scan, layout: FramedLayout = FramedLayout()) throws -> PixelBox {
        let expected = layout.width / layout.height
        var found = 0.0
        for ignore in [edgeIgnore, 0.0] {
            let box = try findFrame(scan, edgeIgnore: ignore)
            found = Double(box.right - box.left) / Double(max(box.bottom - box.top, 1))
            if abs(found / expected - 1) <= 0.04 { return box }
        }
        throw MeasureError(description: "frame shape \(String(format: "%.2f", found)):1 doesn't match the target "
                           + "(\(String(format: "%.2f", expected)):1); check the whole target is on the scan and placed square")
    }

    /// Per-channel median of the central `sample` fraction of a box (in scan pixels).
    static func boxMedian(_ scan: Scan, _ box: (Double, Double, Double, Double)) throws -> [Double] {
        let (left, top, right, bottom) = box
        let cx = (left + right) / 2, cy = (top + bottom) / 2
        let hw = (right - left) * sample / 2, hh = (bottom - top) * sample / 2
        let y0 = max(Int(rint(cy - hh)), 0), y1 = min(Int(rint(cy + hh)), scan.height)
        let x0 = max(Int(rint(cx - hw)), 0), x1 = min(Int(rint(cx + hw)), scan.width)
        guard y1 > y0, x1 > x0 else {
            throw MeasureError(description: "patch too small to sample; scan at a higher resolution")
        }
        return (0..<3).map { c in
            median((y0..<y1).flatMap { y in (x0..<x1).map { x in scan.value(x, y, c) } })
        }
    }

    /// Measure every level of a scanned framed target. `sent` is the RGB sent for each
    /// level (steps x 3) if a calibration was applied; by default R = G = B = level.
    public static func measure(_ scan: Scan, layout: FramedLayout = FramedLayout(), sent: [[UInt16]]? = nil) throws -> Measurement {
        let frame = try locateFrame(scan, layout: layout)
        let sx = Double(frame.right - frame.left) / layout.width, sy = Double(frame.bottom - frame.top) / layout.height
        func toPixels(_ b: (Double, Double, Double, Double)) -> (Double, Double, Double, Double) {
            (Double(frame.left) + b.0 * sx, Double(frame.top) + b.1 * sy, Double(frame.left) + b.2 * sx, Double(frame.top) + b.3 * sy)
        }
        let paper = try boxMedian(scan, toPixels(layout.paperBox())).map(Colour.srgbToLinear)
        guard paper.min()! > 0.2 else { throw MeasureError(description: "paper white measured too dark; check the scan") }
        var samples = [[[Double]]](repeating: [], count: layout.steps)
        for box in layout.patchBoxes() {
            samples[box.level].append(try boxMedian(scan, toPixels((box.left, box.top, box.right, box.bottom))).map(Colour.srgbToLinear))
        }
        let rgb = samples.map { patches in
            (0..<3).map { c in patches.reduce(0.0) { $0 + $1[c] } / Double(patches.count) / paper[c] }
        }
        let levels = Targets.wedgeLevels(layout.steps)
        let sentRows = sent ?? levels.map { [$0, $0, $0] }
        guard sentRows.count == layout.steps, sentRows.allSatisfy({ $0.count == 3 }) else {
            throw MeasureError(description: "sent must have shape (\(layout.steps), 3)")
        }
        let lab = rgb.map { v -> [Double] in
            let l = Colour.linearRGBToLab(v[0], v[1], v[2])
            return [l.l, l.a, l.b]
        }
        return Measurement(levels: levels, sent: sentRows, rgb: rgb, lab: lab)
    }

    /// Black squares beside a frame: 1 = uncorrected, 2 = corrected target. Looks both
    /// sides, since full-page scans may come back rotated 180 degrees.
    public static func countMarks(_ scan: Scan, frame: PixelBox) -> Int {
        let reach = max(Int(rint(Double(frame.bottom - frame.top) * 0.2)), 4)
        let mask = darkMask(scan)
        var counts: [Int] = []
        for (x0, x1) in [(max(frame.left - reach, 0), max(frame.left - 2, 0)),
                         (frame.right + 2, min(frame.right + reach, scan.width))] where x1 > x0 {
            var marks = 0, previous = false
            for y in frame.top..<min(frame.bottom, scan.height) {
                let row = (x0..<x1).contains { mask[y * scan.width + $0] }
                if row && !previous { marks += 1 }
                previous = row
            }
            counts.append(marks)
        }
        return counts.max() ?? 0
    }

    /// Split a two-target page at the widest ink-free band between the targets; returns
    /// the row where the second part starts.
    public static func splitRow(_ scan: Scan) throws -> Int {
        let height = scan.height, width = scan.width
        let margin = Int(rint(Double(height) * edgeIgnore))
        let mask = darkMask(scan)
        let rows = (margin..<max(height - margin, margin)).filter { y in
            Double((0..<width).count { mask[y * width + $0] }) > 0.005 * Double(width)
        }
        guard rows.count >= 2 else { throw MeasureError(description: "no targets found in the scan") }
        let gaps = zip(rows, rows.dropFirst()).map { $1 - $0 }
        let widest = gaps.firstIndex(of: gaps.max()!)!
        guard Double(gaps[widest]) >= 0.05 * Double(height) else {
            throw MeasureError(description: "expected two targets one above the other; found one")
        }
        return (rows[widest] + rows[widest + 1]) / 2
    }

    public static func splitPair(_ scan: Scan) throws -> (Scan, Scan) {
        let split = try splitRow(scan)
        return (scan.rows(0..<split), scan.rows(split..<scan.height))
    }

    /// Measure a comparison page: (uncorrected, corrected), told apart by their marks.
    public static func measurePair(_ scan: Scan, sent: [[UInt16]], layout: FramedLayout = FramedLayout()) throws -> (Measurement, Measurement) {
        var found: [Int: Measurement] = [:]
        let (top, bottom) = try splitPair(scan)
        for part in [top, bottom] {
            let marks = countMarks(part, frame: try locateFrame(part, layout: layout))
            guard marks == 1 || marks == 2, found[marks] == nil else {
                throw MeasureError(description: "couldn't identify a target by its marks (found \(marks))")
            }
            found[marks] = try measure(part, layout: layout, sent: marks == 2 ? sent : nil)
        }
        return (found[1]!, found[2]!)
    }
}
