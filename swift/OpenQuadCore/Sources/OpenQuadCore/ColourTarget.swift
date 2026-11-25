// The colour target and measuring scans of it (colour calibration, phase 1). Mirrors
// openquad/colour_target.py: the same patches, shuffled the same way, laid out the same,
// and the same JSON, so a target made by either version is measured by the other.

import Foundation

public enum ColourTargets {
    public static let printable = (7.5, 10.0)  // inches: Letter inside 0.5 in margins
    public static let grids = [6, 9]
    public static let neutrals = 21
    public static let tints = [0.3, 0.5, 0.7]
    /// Red, green, blue, cyan, magenta, yellow at full strength (0 or 1).
    public static let hues: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1], [0, 1, 1], [1, 0, 1], [1, 1, 0]]
    public static let hueNames = ["red", "green", "blue", "cyan", "magenta", "yellow"]
    static let shuffleSeed: UInt32 = 7
    static let sample = 0.5

    /// The colours on the target, unshuffled: the RGB grid, the greys, then the tints.
    public static func patches(grid: Int = 6) throws -> [[UInt16]] {
        guard grids.contains(grid) else { throw MeasureError(description: "grid must be one of 6, 9, got \(grid)") }
        let levels = linspace(0, Double(maxValue), grid).map(rint)
        var out: [[Double]] = []
        for r in levels { for g in levels { for b in levels { out.append([r, g, b]) } } }
        for v in Targets.wedgeLevels(neutrals) { out.append([Double(v), Double(v), Double(v)]) }
        for hue in hues { for s in tints { out.append(hue.map { Double(maxValue) * (1 - s * (1 - $0)) }) } }
        return out.map { $0.map { UInt16(rint($0)) } }
    }

    /// The target, shuffled (always the same way), on as many pages as it needs: 0.43 in
    /// patches for the 6-level grid (one page), 0.32 in for the 9-level one (two pages).
    public static func make(grid: Int = 6, patch: Double? = nil) throws -> ColourTarget {
        let all = try patches(grid: grid)
        var rng = NumpyRandom(seed: shuffleSeed)
        let order = rng.permutation(all.count)
        return try layout(order.map { all[$0] }, patch: patch ?? (grid == 6 ? 0.43 : 0.32), grid: grid)
    }

    /// Lay patches out in the order given, on as many pages as they need.
    public static func layout(_ patches: [[UInt16]], patch: Double = 0.43, grid: Int = 0,
                              printable: (Double, Double) = printable) throws -> ColourTarget {
        let shell = ColourTarget(pages: [patches], columns: 1, patch: patch, grid: grid)
        let columns = Int(floor((printable.0 - shell.lead - 2 * shell.edge) / patch + 1e-9))
        let rows = Int(floor((printable.1 - 2 * shell.edge) / patch + 1e-9))
        guard columns >= 4, rows >= 4 else {
            throw MeasureError(description: "patches of \(patch) in don't fit a \(printable.0) x \(printable.1) in page")
        }
        let perPage = columns * rows
        let pages = stride(from: 0, to: patches.count, by: perPage).map { Array(patches[$0..<min($0 + perPage, patches.count)]) }
        return ColourTarget(pages: pages, columns: columns, patch: patch, grid: grid)
    }
}

/// The target's layout and what each patch sent, page by page, in inches. Patch boxes
/// are measured from the outer corner of the page's frame; `lead` is the space to the
/// frame's left that holds the page marks.
public struct ColourTarget: Sendable, Equatable {
    public var pages: [[[UInt16]]]
    public var columns: Int
    public var patch: Double
    public var grid = 6
    public var frame = 0.04
    public var inset = 0.15
    public var lead = 0.4
    public var mark = 0.15
    public var pad = 0.07

    public init(pages: [[[UInt16]]], columns: Int, patch: Double, grid: Int = 6) {
        self.pages = pages
        self.columns = columns
        self.patch = patch
        self.grid = grid
    }

    public var edge: Double { frame + inset }
    public func rows(_ page: Int) -> Int { (pages[page].count + columns - 1) / columns }

    public func frameSize(_ page: Int) -> (Double, Double) {
        (Double(columns) * patch + 2 * edge, Double(rows(page)) * patch + 2 * edge)
    }

    public func pageSize(_ page: Int) -> (Double, Double) {
        let (width, height) = frameSize(page)
        return (width + lead, height)
    }

    public typealias Box = (left: Double, top: Double, right: Double, bottom: Double)

    public func patchBoxes(_ page: Int) -> [Box] {
        pages[page].indices.map { i in
            let left = edge + Double(i % columns) * patch, top = edge + Double(i / columns) * patch
            return (left, top, left + patch, top + patch)
        }
    }

    /// Strips of bare paper above and below the patches.
    public func paperBoxes(_ page: Int) -> [Box] {
        let (width, height) = frameSize(page)
        return [frame, height - edge].map { top in (edge, top + 0.25 * inset, width - edge, top + 0.75 * inset) }
    }

    /// Every patch's RGB, page after page.
    public var sent: [[UInt16]] { pages.flatMap { $0 } }

    public func json() throws -> String {
        try jsonCompact([
            "kind": "openquad colour target", "version": 1, "grid": grid, "columns": columns, "patch": patch,
            "frame": frame, "inset": inset, "lead": lead, "mark": mark, "pad": pad,
            "pages": pages.map { $0.map { $0.map(Int.init) } },
        ] as [String: Any])
    }

    public static func decode(_ data: Data) throws -> ColourTarget {
        guard let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              d["kind"] as? String == "openquad colour target", let pages = d["pages"] as? [[[Int]]],
              let columns = d["columns"] as? Int, let patch = exactDouble(d["patch"]) else {
            throw FileFormatError(description: "not an OpenQuad colour target layout")
        }
        var target = ColourTarget(pages: pages.map { $0.map { $0.map { UInt16(clamping: $0) } } }, columns: columns, patch: patch,
                                  grid: d["grid"] as? Int ?? 6)
        func number(_ key: String) -> Double? { exactDouble(d[key]) }
        target.frame = number("frame") ?? target.frame
        target.inset = number("inset") ?? target.inset
        target.lead = number("lead") ?? target.lead
        target.mark = number("mark") ?? target.mark
        target.pad = number("pad") ?? target.pad
        return target
    }

    /// One page as 16-bit RGB on white, to print sRGB-tagged at 100%.
    public func page(_ page: Int, dpi: Double = 300) -> RGBImage {
        func px(_ inches: Double) -> Int { pyRound(inches * dpi) }
        let (width, height) = pageSize(page), (frameW, frameH) = frameSize(page)
        let w = px(width), h = px(height)
        var pixels = [UInt16](repeating: UInt16(maxValue), count: w * h * 3)
        func fill(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ colour: [UInt16]) {
            for y in max(y0, 0)..<min(y1, h) {
                for x in max(x0, 0)..<min(x1, w) {
                    let k = (y * w + x) * 3
                    pixels[k] = colour[0]
                    pixels[k + 1] = colour[1]
                    pixels[k + 2] = colour[2]
                }
            }
        }
        let black: [UInt16] = [0, 0, 0]
        let x0 = px(lead), fw = px(frameW), fh = px(frameH), f = px(frame)
        let sheetRight = min(x0 + fw, w)
        fill(x0, 0, sheetRight, f, black)
        fill(x0, fh - f, sheetRight, fh, black)
        fill(x0, 0, min(x0 + f, sheetRight), h, black)
        fill(x0 + fw - f, 0, sheetRight, h, black)
        for (colour, box) in zip(pages[page], patchBoxes(page)) {
            fill(x0 + px(box.left), px(box.top), min(x0 + px(box.right), sheetRight), px(box.bottom), colour)
        }
        let m = px(mark), p = px(pad)
        for i in 0...page {
            let y = p + i * (m + p)
            fill(p, y, p + m, y + m, black)
        }
        return RGBImage(width: w, height: h, pixels: pixels)
    }
}

/// What each patch sent and what it measured: D50 XYZ (Y = 1 for a perfect white), the
/// paper's, and L*a*b* relative to the paper.
public struct ColourMeasurement: Sendable, Equatable {
    public var sent: [[UInt16]]
    public var xyz: [[Double]]
    public var lab: [[Double]]
    public var paperXYZ: [Double]
    public var scanner = ""
    public var colourimetry = ""
    public var notes: [String] = []

    public init(sent: [[UInt16]], xyz: [[Double]], lab: [[Double]], paperXYZ: [Double], scanner: String = "",
                colourimetry: String = "", notes: [String] = []) {
        self.sent = sent
        self.xyz = xyz
        self.lab = lab
        self.paperXYZ = paperXYZ
        self.scanner = scanner
        self.colourimetry = colourimetry
        self.notes = notes
    }

    /// Which patches were sent as greys (R = G = B).
    public var neutrals: [Bool] { sent.map { $0[0] == $0[1] && $0[1] == $0[2] } }

    public func summary() -> String {
        let casts = zip(lab, neutrals).filter(\.1).map { max(abs($0.0[1]), abs($0.0[2])) }
        let paperL = Colour.xyzToLab(paperXYZ, white: Colour.d50White)[0]
        var lines = [
            "\(sent.count) patches measured (\(colourimetry)).",
            String(format: "Paper white: Y %.3f (L* %.1f absolute).", paperXYZ[1], paperL),
            String(format: "Deepest black: L* %.1f relative to the paper.", lab.map { $0[0] }.min() ?? 0),
            String(format: "Greys: worst cast %.1f (mean %.2f).", casts.max() ?? 0, casts.isEmpty ? 0 : npMean(casts)),
        ]
        for (name, hue) in zip(ColourTargets.hueNames, ColourTargets.hues) {
            let full = hue.map { UInt16($0 * Double(maxValue)) }
            if let i = sent.firstIndex(of: full) {
                let l = lab[i]
                lines.append(String(format: "Full %@: L* %.1f, a* %.1f, b* %.1f (chroma %.1f).", name, l[0], l[1], l[2], hypot(l[1], l[2])))
            }
        }
        return (lines + notes).joined(separator: "\n")
    }

    public func json() throws -> String {
        try jsonCompact([
            "kind": "openquad colour measurement", "version": 1, "scanner": scanner, "colourimetry": colourimetry,
            "paper_xyz": paperXYZ, "sent": sent.map { $0.map(Int.init) },
            "xyz": xyz.map { $0.map { npRound($0, 6) } }, "lab": lab.map { $0.map { npRound($0, 4) } },
        ] as [String: Any])
    }

    public static func decode(_ data: Data) throws -> ColourMeasurement {
        guard let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              d["kind"] as? String == "openquad colour measurement", let sent = d["sent"] as? [[Int]],
              let xyz = d["xyz"] as? [[NSNumber]], let lab = d["lab"] as? [[NSNumber]], let paper = d["paper_xyz"] as? [NSNumber]
        else { throw FileFormatError(description: "not an OpenQuad colour measurement") }
        return ColourMeasurement(sent: sent.map { $0.map { UInt16(clamping: $0) } }, xyz: xyz.map { $0.map(\.doubleValue) },
                                 lab: lab.map { $0.map(\.doubleValue) }, paperXYZ: paper.map(\.doubleValue),
                                 scanner: d["scanner"] as? String ?? "", colourimetry: d["colourimetry"] as? String ?? "")
    }
}

/// A JSON number as the nearest double: Foundation's parser can land an ulp off (0.07 read
/// as 0.07000000000000001), so the number's text is read again.
func exactDouble(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber else { return nil }
    return Double(number.stringValue) ?? number.doubleValue
}

func jsonCompact(_ object: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
}

// MARK: - measuring

extension Scan {
    /// The scan turned 180 degrees.
    public func turned() -> Scan {
        var out = [UInt16](repeating: 0, count: samples.count)
        let n = width * height
        for i in 0..<n {
            let j = n - 1 - i
            out[j * 3] = samples[i * 3]
            out[j * 3 + 1] = samples[i * 3 + 1]
            out[j * 3 + 2] = samples[i * 3 + 2]
        }
        return Scan(width: width, height: height, samples: out, scale: scale)
    }
}

public enum ColourMeasure {
    /// Which side of the frame the page marks are on: "left", "right" or "" (none).
    static func marksSide(_ scan: Scan, _ frame: PixelBox) -> String {
        let reach = max(pyRound(Double(frame.bottom - frame.top) * 0.2), 4)
        let mask = Measure.darkMask(scan)
        var found: [(String, Int)] = []
        for (side, x0, x1) in [("left", max(frame.left - reach, 0), max(frame.left - 2, 0)),
                               ("right", frame.right + 2, min(frame.right + reach, scan.width))] {
            var count = 0
            if x1 > x0 {
                for y in max(frame.top, 0)..<min(frame.bottom, scan.height) {
                    for x in x0..<x1 where mask[y * scan.width + x] { count += 1 }
                }
            }
            found.append((side, count))
        }
        guard found.map(\.1).max()! > 0 else { return "" }
        return found[1].1 > found[0].1 ? "right" : "left"
    }

    static func isDark(_ scan: Scan, _ x: Int, _ y: Int) -> Bool {
        (scan.value(x, y, 0) + scan.value(x, y, 1) + scan.value(x, y, 2)) / 3 < Measure.dark
    }

    /// The page marks left of an upright frame. Only where the target puts them is looked at:
    /// beside the frame's top, and clear of its line, which a slightly tilted scan brings closer.
    static func pageMarks(_ scan: Scan, _ frame: PixelBox, _ target: ColourTarget) -> Int {
        let scale = Double(frame.right - frame.left) / target.frameSize(0).0  // every page as wide
        let left = Double(frame.left)
        let x0 = max(pyRound(left - (target.lead - target.pad / 2) * scale), 0)
        let x1 = min(max(pyRound(left - (target.lead - target.pad - target.mark) / 2 * scale), 0), scan.width)
        let reach = target.pad + Double(target.pages.count + 1) * (target.mark + target.pad)  // one too many
        let y1 = min(pyRound(Double(frame.top) + reach * scale), frame.bottom, scan.height)
        var marks = 0, run = 0
        for y in max(frame.top, 0)...max(y1, max(frame.top, 0)) {
            let dark = y < y1 && x1 > x0 && (x0..<x1).contains { isDark(scan, $0, y) }
            if dark {
                run += 1
            } else {
                if run > 0 && Double(run) >= target.mark * scale / 2 { marks += 1 }  // specks aren't marks
                run = 0
            }
        }
        return marks
    }

    /// The frame's tilt on the scan in degrees, from where its left line falls, row by row.
    static func tilt(_ scan: Scan, _ frame: PixelBox, _ target: ColourTarget) -> Double {
        let scale = Double(frame.right - frame.left) / target.frameSize(0).0
        let left = Double(frame.left), top = Double(frame.top), bottom = Double(frame.bottom)
        let x0 = max(pyRound(left - 0.15 * scale), 0)
        let x1 = min(pyRound(left + (target.frame + target.inset / 2) * scale), scan.width)
        var ys: [Double] = [], xs: [Double] = []
        let first = top + 0.1 * (bottom - top), last = bottom - 0.1 * (bottom - top)
        for i in 0..<21 {
            let y = pyRound(first + (last - first) * Double(i) / 20)
            guard y >= 0, y < scan.height, x1 > x0 else { continue }
            if let x = (x0..<x1).first(where: { isDark(scan, $0, y) }) {
                ys.append(Double(y))
                xs.append(Double(x))
            }
        }
        guard xs.count >= 3 else { return 0 }
        let my = ys.reduce(0, +) / Double(ys.count), mx = xs.reduce(0, +) / Double(xs.count)
        var covariance = 0.0, variance = 0.0
        for (y, x) in zip(ys, xs) {
            covariance += (y - my) * (x - mx)
            variance += (y - my) * (y - my)
        }
        return variance > 0 ? atan(covariance / variance) * 180 / .pi : 0
    }

    /// The most tilt, in degrees, that keeps every patch's sample inside it: the tilt may move
    /// the far corner by half the margin around each sample.
    static func tiltLimit(_ target: ColourTarget, _ page: Int) -> Double {
        let (width, height) = target.frameSize(page)
        return atan((1 - ColourTargets.sample) / 4 * target.patch / max(width, height)) * 180 / .pi
    }

    /// Candidate frames: skipping the scan's borders first (lid shadows), then not.
    static func frames(_ scan: Scan) throws -> [PixelBox] {
        let frames = [Measure.edgeIgnore, 0.0].compactMap { try? Measure.findFrame(scan, edgeIgnore: $0) }
        guard !frames.isEmpty else { throw MeasureError(description: "no target frame found in the scan") }
        return frames
    }

    /// (page, frame, scan the right way up) for one scan.
    static func locate(_ scan: Scan, _ target: ColourTarget) throws -> (Int, PixelBox, Scan) {
        let shapes = target.pages.indices.map { let (w, h) = target.frameSize($0); return w / h }
        var problem = ""
        for candidate in try frames(scan) {
            var frame = candidate
            let found = Double(frame.right - frame.left) / Double(max(frame.bottom - frame.top, 1))
            let fits = shapes.indices.filter { abs(found / shapes[$0] - 1) <= 0.04 }
            if fits.isEmpty {
                if problem.isEmpty {
                    problem = String(format: "the frame found is %.2f:1 but the target's ", found)
                        + (shapes.count > 1 ? "pages are " : "is ")
                        + shapes.map { String(format: "%.2f:1", $0) }.joined(separator: " and ")
                        + "; check the whole page is on the scan and placed square"
                }
                continue
            }
            var upright = scan
            if marksSide(scan, frame) == "right" {  // scanned the other way up
                upright = scan.turned()
                frame = PixelBox(left: scan.width - frame.right, top: scan.height - frame.bottom,
                                 right: scan.width - frame.left, bottom: scan.height - frame.top)
            }
            let marks = pageMarks(upright, frame, target)
            guard fits.contains(marks - 1) else {
                let pages = target.pages.count
                problem = "couldn't tell which page this is (found \(marks) page marks beside a frame the shape of page "
                    + fits.map { String($0 + 1) }.joined(separator: " or ")
                    + "; the target has \(pages) page\(pages != 1 ? "s" : ""))"
                continue
            }
            let tilted = tilt(upright, frame, target)
            if abs(tilted) > tiltLimit(target, marks - 1) {
                problem = "page \(marks) is tilted " + String(format: "%.1f", abs(tilted))
                    + "° on the scan, too much to read its patches; place it square against the edge of the glass "
                    + "and scan again"
                continue
            }
            return (marks - 1, frame, upright)
        }
        throw MeasureError(description: problem)
    }

    static func median(_ scan: Scan, _ box: ColourTarget.Box) throws -> [Double] {
        let cx = (box.left + box.right) / 2, cy = (box.top + box.bottom) / 2
        let hw = (box.right - box.left) * ColourTargets.sample / 2, hh = (box.bottom - box.top) * ColourTargets.sample / 2
        let y0 = min(max(pyRound(cy - hh), 0), scan.height), y1 = min(max(pyRound(cy + hh), 0), scan.height)
        let x0 = min(max(pyRound(cx - hw), 0), scan.width), x1 = min(max(pyRound(cx + hw), 0), scan.width)
        guard y1 - y0 >= 2, x1 - x0 >= 2 else {
            throw MeasureError(description: "patches too small to sample; scan at 300 ppi or more")
        }
        return (0..<3).map { c in OpenQuadCore.median((y0..<y1).flatMap { y in (x0..<x1).map { x in scan.value(x, y, c) } }) }
    }

    /// (page, each patch's scanner RGB, the paper's), as the scanner encoded them (0-1).
    public static func samplePage(_ scan: Scan, _ target: ColourTarget) throws -> (Int, [[Double]], [Double]) {
        let (page, frame, upright) = try locate(scan, target)
        let (width, height) = target.frameSize(page)
        let sx = Double(frame.right - frame.left) / width, sy = Double(frame.bottom - frame.top) / height
        func pixels(_ b: ColourTarget.Box) -> ColourTarget.Box {
            (Double(frame.left) + b.left * sx, Double(frame.top) + b.top * sy,
             Double(frame.left) + b.right * sx, Double(frame.top) + b.bottom * sy)
        }
        let patches = try target.patchBoxes(page).map { try median(upright, pixels($0)) }
        let papers = try target.paperBoxes(page).map { try median(upright, pixels($0)) }
        let paper = (0..<3).map { c in papers.reduce(0.0) { $0 + $1[c] } / Double(papers.count) }
        return (page, patches, paper)
    }

    /// Measure scans of every page of the target, in any order and either way up.
    public static func measure(_ scans: [Scan], target: ColourTarget, model: ScannerModel? = nil,
                               scanner: String = "") throws -> ColourMeasurement {
        var found: [Int: ([[Double]], [Double])] = [:]
        for scan in scans {
            let (page, patches, paper) = try samplePage(scan, target)
            guard found[page] == nil else { throw MeasureError(description: "two scans of page \(page + 1)") }
            found[page] = (patches, paper)
        }
        let missing = target.pages.indices.filter { found[$0] == nil }.map { String($0 + 1) }
        guard missing.isEmpty else { throw MeasureError(description: "no scan of page \(missing.joined(separator: ", "))") }
        let encoded = target.pages.indices.flatMap { found[$0]!.0 }
        let papers = target.pages.indices.map { found[$0]!.1 }
        let toXYZ: ([Double]) -> [Double] = model.map { m in { m.toXYZ($0) } } ?? Colour.srgbToD50
        let colourimetry = model.map { "scanner model\($0.scanner.isEmpty ? "" : " for \($0.scanner)"), D50" }
            ?? "scan taken as sRGB (no scanner model)"
        let xyz = encoded.map { toXYZ($0).map { max($0, 0) } }
        let paperEach = papers.map(toXYZ)
        let paperXYZ = (0..<3).map { c in paperEach.reduce(0.0) { $0 + $1[c] } / Double(paperEach.count) }
        guard paperXYZ[1] > 0.2 else { throw MeasureError(description: "paper white measured too dark; check the scan") }
        var notes: [String] = []
        if papers.count > 1 {
            let spread = paperEach.map { abs($0[1] / paperXYZ[1] - 1) }.max()!
            if spread > 0.03 {
                notes.append(String(format: "Note: the pages' paper white differs by %.0f%%; scan every page with the same settings.",
                                    100 * spread))
            }
        }
        return ColourMeasurement(sent: target.sent, xyz: xyz, lab: xyz.map { Colour.xyzToLab($0, white: paperXYZ) },
                                 paperXYZ: paperXYZ, scanner: scanner.isEmpty ? (model?.scanner ?? "") : scanner,
                                 colourimetry: colourimetry, notes: notes)
    }
}
