// Reading scanned contact prints of a sheet (the blocking test or a process chart):
// find the sheet inside its light safe edge, square up a tilt, pin its edges and pick
// the orientation whose layout fits. Mirrors the reader in openquad/blocking.py.

import Foundation

public struct BlockingError: Error, Equatable, CustomStringConvertible {
    public let description: String
}

/// What the reader needs to know about a sheet (sizes in inches).
public protocol SheetSpec: Sendable {
    var width: Double { get }
    var height: Double { get }
    var gap: Double { get }
    func markerBox() -> (Double, Double, Double, Double)
}

/// Sheet box in scan pixels: (top, left) inclusive, (bottom, right) exclusive.
public struct SheetBox: Equatable, Sendable {
    public var top, left, bottom, right: Int
    public init(_ top: Int, _ left: Int, _ bottom: Int, _ right: Int) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }
}

/// How the print lies on the scanner: quarter turns (0 or 1), row step and column step.
public struct Fit: Equatable, Comparable, Sendable {
    public var k, rs, cs: Int
    public static func < (a: Fit, b: Fit) -> Bool { (a.k, a.rs, a.cs) < (b.k, b.rs, b.cs) }

    /// The eight ways a print can lie on the scanner.
    public static let all: [Fit] = [0, 1].flatMap { k in
        [(1, 1), (-1, -1), (1, -1), (-1, 1)].map { Fit(k: k, rs: $0.0, cs: $0.1) }
    }

    public var name: String {
        let mirrored = rs != cs
        if k != 0 { return mirrored ? "sideways, mirrored" : "sideways" }
        if mirrored { return rs == 1 ? "mirrored" : "mirrored and turned 180°" }
        return rs == 1 ? "as scanned" : "turned 180°"
    }
}

/// L* of every pixel of a scan.
public struct LightnessMap: Sendable {
    public let width: Int
    public let height: Int
    public var values: [Double]

    public init(width: Int, height: Int, values: [Double]) {
        precondition(values.count == width * height)
        self.width = width
        self.height = height
        self.values = values
    }

    public init(_ scan: Scan) {
        var values = [Double](repeating: 0, count: scan.width * scan.height)
        for i in values.indices {
            let s = scan.samples, k = i * 3
            values[i] = Colour.lightness(Colour.srgbToLinear(Double(s[k]) / scan.scale),
                                         Colour.srgbToLinear(Double(s[k + 1]) / scan.scale),
                                         Colour.srgbToLinear(Double(s[k + 2]) / scan.scale))
        }
        self.init(width: scan.width, height: scan.height, values: values)
    }

    @inlinable
    public subscript(_ y: Int, _ x: Int) -> Double { values[y * width + x] }
}

/// A crop of the lightness map, turned and flipped to the sheet's own orientation.
struct SheetView {
    let map: LightnessMap
    let top, left, cropHeight, cropWidth: Int
    let fit: Fit

    init(_ map: LightnessMap, _ box: SheetBox, _ fit: Fit) {
        self.map = map
        let rows = pySlice(box.top, box.bottom, map.height), columns = pySlice(box.left, box.right, map.width)
        top = rows.lowerBound
        left = columns.lowerBound
        cropHeight = rows.count
        cropWidth = columns.count
        self.fit = fit
    }

    var height: Int { fit.k == 1 ? cropWidth : cropHeight }
    var width: Int { fit.k == 1 ? cropHeight : cropWidth }

    @inlinable
    func at(_ i: Int, _ j: Int) -> Double {
        let r = fit.rs == 1 ? i : height - 1 - i, c = fit.cs == 1 ? j : width - 1 - j
        // np.rot90(m, 1) is transpose(flip(m, axis=1)): element [r, c] is m[c, W - 1 - r].
        return fit.k == 1 ? map[top + c, left + cropWidth - 1 - r] : map[top + r, left + c]
    }

    /// The values in view[rows, columns] (Python slice bounds).
    func region(_ y0: Int, _ y1: Int, _ x0: Int, _ x1: Int) -> [Double] {
        let rows = pySlice(y0, y1, height), columns = pySlice(x0, x1, width)
        var out: [Double] = []
        out.reserveCapacity(rows.count * columns.count)
        for i in rows { for j in columns { out.append(at(i, j)) } }
        return out
    }
}

enum Reader {
    static let sheetShapeTolerance = 0.12
    static let nearSquare = 0.15
    static let maxTilt = 6.0
    static let markerSlack = 0.12
    static let edgeReach = 0.04
    static let erode = 3
    static let markerContrast = 10.0

    /// Connected dark regions as (pixels, top, left, bottom, right), 4-connected.
    static func darkRegions(_ dark: [Bool], width: Int, height: Int) -> [(count: Int, top: Int, left: Int, bottom: Int, right: Int)] {
        var seen = [Bool](repeating: false, count: dark.count)
        var regions: [(count: Int, top: Int, left: Int, bottom: Int, right: Int)] = []
        var queue: [Int] = []
        for start in dark.indices where dark[start] && !seen[start] {
            seen[start] = true
            queue.removeAll(keepingCapacity: true)
            queue.append(start)
            var head = 0, count = 0
            var top = start / width, bottom = top, left = start % width, right = left
            while head < queue.count {
                let p = queue[head]
                head += 1
                let y = p / width, x = p % width
                count += 1
                top = min(top, y); bottom = max(bottom, y); left = min(left, x); right = max(right, x)
                for (ny, nx) in [(y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)]
                where ny >= 0 && ny < height && nx >= 0 && nx < width {
                    let q = ny * width + nx
                    if dark[q] && !seen[q] {
                        seen[q] = true
                        queue.append(q)
                    }
                }
            }
            regions.append((count, top, left, bottom, right))
        }
        return regions
    }

    /// Keep only pixels whose whole (2r+1)-square neighbourhood is set.
    static func erode(_ mask: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        var out = mask
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] {
                var keep = true
                outer: for dy in -radius...radius {
                    for dx in -radius...radius {
                        let ny = y + dy, nx = x + dx
                        if ny < 0 || ny >= height || nx < 0 || nx >= width || !mask[ny * width + nx] {
                            keep = false
                            break outer
                        }
                    }
                }
                out[y * width + x] = keep
            }
        }
        return out
    }

    /// The sheet's exposed inner area (clear film, so dark, enclosed by the light safe
    /// edge): the dark regions not reaching the border, shaped like the sheet.
    static func findSheets(_ map: LightnessMap, aspect: Double = 0, count: Int = 1) throws -> [SheetBox] {
        let p = percentile(map.values, [98, 2])
        let light = p[0], deep = p[1]
        guard light - deep >= 20 else {
            throw BlockingError(description: "no exposed area found; is this a scan of the exposed print?")
        }
        let step = max(1, pyRound(Double(max(map.height, map.width)) / 500))
        let h = (map.height + step - 1) / step, w = (map.width + step - 1) / step
        let threshold = (light + deep) / 2
        var small = [Bool](repeating: false, count: h * w)
        for y in 0..<h { for x in 0..<w { small[y * w + x] = map[y * step, x * step] < threshold } }
        let shrunk = erode(small, width: w, height: h, radius: erode)
        var inside = darkRegions(shrunk, width: w, height: h).filter { r in
            !(r.top <= erode || r.left <= erode || r.bottom >= h - 1 - erode || r.right >= w - 1 - erode)
                && Double(r.count) >= 0.01 * Double(h * w)
        }
        guard !inside.isEmpty else {
            throw BlockingError(description: "couldn't find the sheet inside a light safe edge; is the whole sheet on the scan?")
        }
        func shapeError(_ r: (count: Int, top: Int, left: Int, bottom: Int, right: Int)) -> Double {
            if aspect == 0 { return 0 }
            let found = Double(r.right - r.left + 1) / Double(r.bottom - r.top + 1)
            return min(abs(found / aspect - 1), abs(found * aspect - 1))
        }
        if count > 1 && aspect != 0 { inside = inside.filter { shapeError($0) <= sheetShapeTolerance } }
        let ranked = inside.enumerated().sorted { a, b in
            let ka = (pyRound(shapeError(a.element), 2), -a.element.count), kb = (pyRound(shapeError(b.element), 2), -b.element.count)
            return ka != kb ? ka < kb : a.offset < b.offset
        }.map(\.element)
        guard ranked.count >= count else {
            throw BlockingError(description: "expected \(count) sheets on the scan, found \(ranked.count)")
        }
        return ranked.prefix(count).map { r in
            let top = max(r.top - erode, 0), left = max(r.left - erode, 0)
            let bottom = min(r.bottom + erode, h - 1), right = min(r.right + erode, w - 1)
            return SheetBox(top * step, left * step, (bottom + 1) * step, (right + 1) * step)
        }
    }

    /// Square up a print laid a few degrees off: the rotated map and the angle. The tilt
    /// that makes the profile across the sheet's straight dark gaps most contrasty wins.
    static func deskew(_ map: LightnessMap, _ rough: SheetBox) -> (LightnessMap, Double) {
        let rows = pySlice(rough.top, rough.bottom, map.height), columns = pySlice(rough.left, rough.right, map.width)
        let h = rows.count, w = columns.count
        if h * w == 0 { return (map, 0) }
        var pixels = [Float]()
        pixels.reserveCapacity(h * w)
        for y in rows { for x in columns { pixels.append(Float(map[y, x])) } }
        let crop = FloatImage(width: w, height: h, pixels: pixels)
        let sortedCrop = pixels.sorted()
        let fill = Double(h * w % 2 == 1 ? sortedCrop[h * w / 2] : (sortedCrop[h * w / 2 - 1] + sortedCrop[h * w / 2]) / 2)
        let across = h > w  // sideways: rows run up and down, so average along each row
        let inner = (rows: (h / 8)..<(h - h / 8), columns: (w / 8)..<(w - w / 8))

        func contrast(_ angle: Double) -> Double {
            let turned = pilRotate(crop, angle: angle, fill: fill, region: inner)
            var profile: [Float] = []
            if across {
                for y in inner.rows {
                    let row = Array(turned.pixels[(y * w + inner.columns.lowerBound)..<(y * w + inner.columns.upperBound)])
                    profile.append(Float(Double(pairwiseSum(row)) / Double(row.count)))
                }
            } else {
                var sums = [Float](repeating: 0, count: inner.columns.count)
                for y in inner.rows {
                    for (i, x) in inner.columns.enumerated() { sums[i] += turned.pixels[y * w + x] }
                }
                profile = sums.map { Float(Double($0) / Double(inner.rows.count)) }
            }
            return Double(npVar(profile))
        }
        func best(_ angles: [Double]) -> Double {
            var top = angles[0], score = contrast(angles[0])
            for angle in angles.dropFirst() {
                let s = contrast(angle)
                if s > score { top = angle; score = s }
            }
            return top
        }
        let coarse = best(arange(-maxTilt, maxTilt + 1e-9, 0.25))
        let tilt = best(arange(coarse - 0.25, coarse + 0.26, 0.05))
        if abs(tilt) < 0.1 { return (map, 0) }
        let whole = FloatImage(width: map.width, height: map.height, pixels: map.values.map { Float($0) })
        let centre = (Double(rough.left + rough.right) / 2, Double(rough.top + rough.bottom) / 2)
        let turned = pilRotate(whole, angle: tilt, centre: centre, fill: percentile(map.values, [99])[0])
        return (LightnessMap(width: map.width, height: map.height, values: turned.pixels.map(Double.init)), tilt)
    }

    /// numpy arange for floats: start + i * (second - start), length ceil((stop - start) / step).
    static func arange(_ start: Double, _ stop: Double, _ step: Double) -> [Double] {
        let length = Int(((stop - start) / step).rounded(.up))
        guard length > 0 else { return [] }
        let delta = (start + step) - start
        return (0..<length).map { $0 == 0 ? start : ($0 == 1 ? start + step : start + Double($0) * delta) }
    }

    /// Move each side of the rough box to the sharpest step from the lighter safe edge
    /// (outside) to the darker clear film (inside).
    static func refineEdges(_ map: LightnessMap, _ rough: SheetBox) -> SheetBox {
        let spanY = rough.bottom - rough.top, spanX = rough.right - rough.left
        let reachY = pyRound(edgeReach * Double(spanY)), reachX = pyRound(edgeReach * Double(spanX))
        let win = max(2, pyRound(0.012 * Double(max(spanY, spanX))))
        let profileColumns = pySlice(rough.left + spanX / 5, rough.right - spanX / 5, map.width)
        let profileRows = pySlice(rough.top + spanY / 5, rough.bottom - spanY / 5, map.height)
        let rowProfile = (0..<map.height).map { y in median(profileColumns.map { map[y, $0] }) }
        let columnProfile = (0..<map.width).map { x in median(profileRows.map { map[$0, x] }) }

        func bestStep(_ profile: [Double], _ centre: Int, _ reach: Int, _ inward: Int) -> Int {
            var bestPos = centre, bestJump = -1e9
            let range = max(centre - reach, win)..<max(max(centre - reach, win), min(centre + reach, profile.count - win))
            for pos in range {
                let before = median(Array(profile[(pos - win)..<pos])), after = median(Array(profile[pos..<(pos + win)]))
                let (outside, inside) = inward > 0 ? (before, after) : (after, before)
                let jump = (outside - inside) - 2.0 * Double(abs(pos - centre)) / Double(reach)
                if jump > bestJump { bestPos = pos; bestJump = jump }
            }
            return bestPos
        }
        return SheetBox(bestStep(rowProfile, rough.top, reachY, 1), bestStep(columnProfile, rough.left, reachX, 1),
                        bestStep(rowProfile, rough.bottom, reachY, -1), bestStep(columnProfile, rough.right, reachX, -1))
    }

    /// Median L* in a small square around a point given in sheet inches.
    static func point(_ view: SheetView, _ layout: SheetSpec, _ x: Double, _ y: Double, _ r: Int) -> Double {
        let px = pyRound(x / layout.width * Double(view.width)), py = pyRound(y / layout.height * Double(view.height))
        let patch = view.region(max(py - r, 0), py + r + 1, max(px - r, 0), px + r + 1)
        return patch.isEmpty ? 0 : median(patch)
    }

    /// Median L* of the marker square, allowing it up to `markerSlack` inches off its spot.
    static func markerLightness(_ view: SheetView, _ layout: SheetSpec) -> Double {
        let h = Double(view.height), w = Double(view.width)
        let (l, t, r, b) = layout.markerBox()
        let inset = (r - l) * 0.2
        var best = 0.0
        for dx in [-markerSlack, 0.0, markerSlack] {
            for dy in [-markerSlack, 0.0, markerSlack] {
                let region = view.region(max(pyRound((t + inset + dy) / layout.height * h), 0), pyRound((b - inset + dy) / layout.height * h),
                                         max(pyRound((l + inset + dx) / layout.width * w), 0), pyRound((r - inset + dx) / layout.width * w))
                if !region.isEmpty { best = max(best, median(region)) }
            }
        }
        return best
    }

    /// Marker square L* minus the clear film beside it.
    static func markerContrast(_ view: SheetView, _ layout: SheetSpec) -> Double {
        let h = Double(view.height), w = Double(view.width)
        let (l, t, r, b) = layout.markerBox()
        let inset = (r - l) * 0.2
        func regionMedian(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Double {
            let region = view.region(pyRound(y0 / layout.height * h), pyRound(y1 / layout.height * h),
                                     pyRound(x0 / layout.width * w), pyRound(x1 / layout.width * w))
            return region.isEmpty ? 0 : median(region)
        }
        return markerLightness(view, layout) - regionMedian(r + layout.gap, t + inset, r + layout.gap + (r - l), b - inset)
    }

    /// (inked - clear film) + (marker - clear film), in L*: how well the layout fits.
    static func fitScore(_ map: LightnessMap, _ box: SheetBox, _ fit: Fit, _ layout: SheetSpec,
                         dark: [(Double, Double)], light: [(Double, Double)]) -> Double {
        let view = SheetView(map, box, fit)
        if view.height < 20 || view.width < 20 { return -1e9 }
        let r = max(1, pyRound(Double(min(view.height, view.width)) / 200))
        let marker = markerLightness(view, layout)
        let darks = npMean(dark.map { point(view, layout, $0.0, $0.1, r) })
        let lights = npMean(light.map { point(view, layout, $0.0, $0.1, r) })
        return (lights - darks) + (marker - darks)
    }

    /// Pin the sheet's edges, then pick the orientation whose layout fits best there.
    static func fitLayout(_ map: LightnessMap, _ rough: SheetBox, _ layout: SheetSpec,
                          dark: [(Double, Double)], light: [(Double, Double)]) -> (SheetBox, Fit, Double) {
        let box = refineEdges(map, rough)
        var candidates = Fit.all
        if abs(layout.width / layout.height - 1) > nearSquare {
            let portrait = (box.bottom - box.top) > (box.right - box.left)
            let sideways = portrait == (layout.width > layout.height)
            candidates = candidates.filter { ($0.k == 1) == sideways }
        }
        let scored = candidates.map { (fitScore(map, box, $0, layout, dark: dark, light: light), $0) }
        let best = scored.max { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }!
        return (box, best.1, best.0)
    }

    /// Median L* of the safe edge: thin bands just outside the inner area on all sides.
    static func safeEdgeLightness(_ map: LightnessMap, _ box: SheetBox, perInch: Double) throws -> Double {
        let near = pyRound(0.06 * perInch), far = pyRound(0.14 * perInch)
        let h = map.height, w = map.width
        let cy0 = box.top + (box.bottom - box.top) / 4, cy1 = box.bottom - (box.bottom - box.top) / 4
        let cx0 = box.left + (box.right - box.left) / 4, cx1 = box.right - (box.right - box.left) / 4
        let bands = [
            (max(box.top - far, 0), max(box.top - near, 0), cx0, cx1),
            (min(box.bottom + near, h), min(box.bottom + far, h), cx0, cx1),
            (cy0, cy1, max(box.left - far, 0), max(box.left - near, 0)),
            (cy0, cy1, min(box.right + near, w), min(box.right + far, w)),
        ]
        var values: [Double] = []
        for (y0, y1, x0, x1) in bands {
            for y in pySlice(y0, y1, h) { for x in pySlice(x0, x1, w) { values.append(map[y, x]) } }
        }
        guard !values.isEmpty else { throw BlockingError(description: "no safe edge around the sheet on the scan") }
        return median(values)
    }

    /// Median L* of the central half of a box (sheet inches) in the view.
    static func sample(_ view: SheetView, _ layout: SheetSpec, _ box: (Double, Double, Double, Double)) -> Double {
        let sx = Double(view.width) / layout.width, sy = Double(view.height) / layout.height
        let (l, t, r, b) = box
        let cx = (l + r) / 2 * sx, cy = (t + b) / 2 * sy, hw = (r - l) * sx / 4, hh = (b - t) * sy / 4
        let region = view.region(pyRound(cy - hh), pyRound(cy + hh), pyRound(cx - hw), pyRound(cx + hw))
        return region.isEmpty ? .nan : median(region)
    }

    static func orientation(_ fit: Fit, tilt: Double) -> String {
        fit.name + (tilt != 0 ? String(format: ", tilted %+.1f°", tilt) : "")
    }
}
