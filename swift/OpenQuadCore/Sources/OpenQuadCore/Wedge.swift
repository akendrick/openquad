// Step wedges printed beside the photo: a 31-step grey wedge, and for colour prints a
// colour gamut wedge. Mirrors openquad/wedge.py.
//
// The grey wedge runs from paper white to full black in 31 equal steps and goes through the
// same toning, calibration or process curve as the photo, so the print shows what that does
// to every tone. The colour wedge is 31 hues round the colour wheel in three rows (a tint,
// the full colour and a shade), to see how much of the colour the printer reaches.
//
// The grey wedge has 11, 21, 31 or 51 steps, any width from 0.2 to 1 in, and comes as a plain
// strip, in the style of the printer calibration target (two rows, white to black then
// black to white, inside a thin black frame), or in ChartThrob's style (a 21-step strip with a
// smooth gradient bar beside it). Its steps can be numbered in a band beside it.
//
// A wedge is as long as the photo's side it sits along, and sits `gap` inches from the print
// (or the negative's safe edge) on the chosen side, centred along it.

import Foundation

public enum Wedge {
    public static let steps = 31
    public static let stepChoices = [11, 21, 31, 51]
    /// Inches across the grey wedge.
    public static let width = 0.4
    public static let minWidth = 0.2, maxWidth = 1.0
    public static let styles = ["strip", "calibration", "chartthrob"]
    /// ChartThrob's style: always this many steps, with a smooth gradient bar beside them.
    public static let chartThrobSteps = 21
    /// What fills the space between the photo and its wedges: "colour" (on a negative its own
    /// colour, opaque like the safe edge; on a print, white paper), "black" or "white".
    public static let backgrounds = ["colour", "black", "white"]
    /// Inches: the calibration style's black frame, and the white inset inside it.
    public static let frame = 0.03
    /// Inches across the band of step numbers.
    public static let labelBand = 0.15
    /// Inches across each of the colour wedge's three rows.
    public static let colourRow = 0.2
    /// Inches between the print and its wedge.
    public static let defaultGap = 0.0
    public static let maxGap = 2.0
    public static let sides = ["top", "bottom", "left", "right"]
    /// The colour wedge's rows: (saturation, value) for a tint, the full colour and a shade.
    public static let colourRows: [(Double, Double)] = [(0.5, 1.0), (1.0, 1.0), (1.0, 0.5)]

    public enum Kind: String, Sendable {
        case grey, colour
    }

    /// Where `count` equal patches start and end along `length` pixels.
    static func edges(_ length: Int, _ count: Int) -> [Int] {
        (0...count).map { pyRound(Double($0 * length) / Double(count)) }
    }

    /// Python's floor division.
    static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    /// The calibration style's frame in pixels: none if the wedge is too small for it.
    static func framePixels(length: Int, thickness: Int, steps: Int, frame: Int) -> Int {
        floorDiv(thickness - 6 * frame, 2) < 1 || length - 4 * frame < steps ? 0 : frame
    }

    /// Where the patches start along the wedge: (offset, edges).
    static func patches(length: Int, thickness: Int, steps: Int, calibration: Bool, frame: Int) -> (Int, [Int]) {
        guard calibration else { return (0, edges(length, steps)) }
        let f = framePixels(length: length, thickness: thickness, steps: steps, frame: frame)
        return (2 * f, edges(length - 4 * f, steps))
    }

    static func level(_ i: Int, _ steps: Int) -> UInt16 {
        UInt16(pyRound(Double(maxValue * (steps - 1 - i)) / Double(steps - 1)))
    }

    /// The wedge itself, laid out horizontally: `thickness` rows of `length`.
    static func greyArea(length: Int, thickness: Int, steps: Int, calibration: Bool, frame: Int,
                         gradient: Bool = false) -> [UInt16] {
        var area = [UInt16](repeating: UInt16(maxValue), count: thickness * length)
        let (offset, edges) = patches(length: length, thickness: thickness, steps: steps, calibration: calibration, frame: frame)
        func fill(_ rows: Range<Int>, _ columns: Range<Int>, _ value: UInt16) {
            for y in rows { for x in columns { area[y * length + x] = value } }
        }
        guard calibration else {
            // ChartThrob's style: the steps take the first 3/5 of the width, a gap, then the gradient bar.
            let stripRows = gradient && thickness >= 3 && length >= 2 ? max(1, thickness * 3 / 5) : thickness
            for i in 0..<steps { fill(0..<stripRows, edges[i]..<edges[i + 1], level(i, steps)) }
            if stripRows < thickness {
                let start = min(thickness - 1, stripRows + max(1, thickness / 20))
                for x in 0..<length {
                    let value = UInt16(pyRound(Double(maxValue) * (1 - Double(x) / Double(length - 1))))
                    fill(start..<thickness, x..<x + 1, value)
                }
            }
            return area
        }
        let f = offset / 2
        if f > 0 {
            fill(0..<f, 0..<length, 0)
            fill(thickness - f..<thickness, 0..<length, 0)
            fill(0..<thickness, 0..<f, 0)
            fill(0..<thickness, length - f..<length, 0)
        }
        let rows = floorDiv(thickness - 6 * f, 2), second = thickness - 2 * f - rows
        for i in 0..<steps {
            let columns = offset + edges[i]..<offset + edges[i + 1]
            fill(2 * f..<2 * f + rows, columns, level(i, steps))
            fill(second..<second + rows, columns, level(steps - 1 - i, steps))
        }
        return area
    }

    /// The step numbers in black on white beside the wedge: `band` rows of `length` (or
    /// `length` rows of `band`). Every step is numbered if there's room, else every 2nd, 5th...
    static func labelBand(length: Int, thickness: Int, band: Int, steps: Int, calibration: Bool, frame: Int,
                          horizontal: Bool) -> [UInt16] {
        var canvas = [UInt16](repeating: UInt16(maxValue), count: band * length)
        let cell = band / 12
        guard cell >= 1 else { return canvas }
        let columns = horizontal ? length : band
        let (offset, edges) = patches(length: length, thickness: thickness, steps: steps, calibration: calibration, frame: frame)
        let narrowest = (0..<steps).map { edges[$0 + 1] - edges[$0] }.min()!
        let needed = horizontal ? (6 * String(steps).count + 1) * cell : 8 * cell
        let every = [1, 2, 5, 10, 25].first { needed <= narrowest * $0 } ?? steps
        for i in stride(from: 0, to: steps, by: every) {
            let text = String(i + 1)
            let wide = text.count * 6 * cell - cell, high = 7 * cell
            let start = offset + edges[i], span = edges[i + 1] - edges[i]
            if wide > (horizontal ? length : band) || high > (horizontal ? band : length) { break }
            let x = horizontal ? min(max(start + floorDiv(span - wide, 2), 0), length - wide) : floorDiv(band - wide, 2)
            let y = horizontal ? floorDiv(band - high, 2) : min(max(start + floorDiv(span - high, 2), 0), length - high)
            for (j, digit) in text.enumerated() {
                let glyph = Negative.digitGlyphs[Int(String(digit))!]!
                let left = x + j * 6 * cell
                for (gy, row) in glyph.enumerated() {
                    for (gx, on) in row.enumerated() where on {
                        for dy in 0..<cell {
                            for dx in 0..<cell { canvas[(y + gy * cell + dy) * columns + left + gx * cell + dx] = 0 }
                        }
                    }
                }
            }
        }
        return canvas
    }

    /// The grey wedge, greyscale (0 black, 65535 white): white to black, left to right (or top
    /// to bottom), `length` x `thickness` pixels, plus a `band` of step numbers beside it (before
    /// the wedge if `bandFirst`). The calibration style has two rows inside a black frame `frame`
    /// pixels wide. Returns (pixels, width, height).
    public static func grey(length: Int, thickness: Int, horizontal: Bool, steps: Int = steps, calibration: Bool = false,
                            frame: Int = 0, band: Int = 0, bandFirst: Bool = false, gradient: Bool = false) -> ([UInt16], Int, Int) {
        precondition(length >= 1 && thickness >= 1, "the wedge has no pixels")
        precondition(steps >= 2, "a wedge needs at least 2 steps, got \(steps)")
        let calibration = calibration && thickness >= 2
        let area = greyArea(length: length, thickness: thickness, steps: steps, calibration: calibration, frame: frame,
                            gradient: gradient)
        if horizontal {
            guard band >= 1 else { return (area, length, thickness) }
            let labels = labelBand(length: length, thickness: thickness, band: band, steps: steps, calibration: calibration,
                                   frame: frame, horizontal: true)
            return (bandFirst ? labels + area : area + labels, length, thickness + band)
        }
        var turned = [UInt16](repeating: 0, count: thickness * length)  // length rows of thickness
        for y in 0..<thickness { for x in 0..<length { turned[x * thickness + y] = area[y * length + x] } }
        guard band >= 1 else { return (turned, thickness, length) }
        let labels = labelBand(length: length, thickness: thickness, band: band, steps: steps, calibration: calibration,
                               frame: frame, horizontal: false)
        var joined = [UInt16]()
        joined.reserveCapacity((thickness + band) * length)
        for row in 0..<length {
            let wedgeRow = turned[row * thickness..<(row + 1) * thickness], labelRow = labels[row * band..<(row + 1) * band]
            if bandFirst { joined += labelRow; joined += wedgeRow } else { joined += wedgeRow; joined += labelRow }
        }
        return (joined, thickness + band, length)
    }

    /// HSV (each 0-1) to RGB (0-1), as Python's colorsys does.
    public static func hsvToRGB(_ hue: Double, _ saturation: Double, _ value: Double) -> (Double, Double, Double) {
        if saturation == 0.0 { return (value, value, value) }
        let i = Int(hue * 6.0)
        let f = hue * 6.0 - Double(i)
        let p = value * (1.0 - saturation), q = value * (1.0 - saturation * f)
        let t = value * (1.0 - saturation * (1.0 - f))
        switch i % 6 {
        case 0: return (value, t, p)
        case 1: return (q, value, p)
        case 2: return (p, value, t)
        case 3: return (p, q, value)
        case 4: return (t, p, value)
        default: return (value, p, q)
        }
    }

    /// The colour gamut wedge, 16-bit sRGB: 31 hues from red round the wheel, in three rows
    /// (tint, full colour, shade) of `row` pixels each.
    public static func colour(length: Int, row: Int, horizontal: Bool) -> RGBImage {
        precondition(length >= 1 && row >= 1, "the wedge has no pixels")
        let edges = edges(length, steps), rows = row * colourRows.count
        var pixels = [UInt16](repeating: 0, count: rows * length * 3)
        for (r, (saturation, value)) in colourRows.enumerated() {
            for i in 0..<steps {
                let (red, green, blue) = hsvToRGB(Double(i) / Double(steps), saturation, value)
                let rgb = [red, green, blue].map { UInt16(pyRound(Double(maxValue) * $0)) }
                for y in r * row..<(r + 1) * row {
                    for x in edges[i]..<edges[i + 1] {
                        let (column, line) = horizontal ? (x, y) : (y, x)
                        let at = (line * (horizontal ? length : rows) + column) * 3
                        pixels[at] = rgb[0]
                        pixels[at + 1] = rgb[1]
                        pixels[at + 2] = rgb[2]
                    }
                }
            }
        }
        return horizontal ? RGBImage(width: length, height: rows, pixels: pixels) : RGBImage(width: rows, height: length, pixels: pixels)
    }

    /// Inches across a wedge, with `border` on each side; a grey wedge `width` wide, with its
    /// band of step numbers if `labels`.
    public static func thickness(_ kind: Kind, border: Double = 0, width: Double = width, labels: Bool = false) -> Double {
        (kind == .grey ? width + (labels ? labelBand : 0.0) : colourRow * Double(colourRows.count)) + 2 * border
    }

    /// (width, height) in inches the wedges add to the print.
    public static func extra(_ kinds: [Kind], side: String, gap: Double, border: Double = 0, width: Double = width,
                             labels: Bool = false) -> (Double, Double) {
        let added = kinds.reduce(0.0) { $0 + (gap + thickness($1, border: border, width: width, labels: labels)) }
        return side == "left" || side == "right" ? (added, 0) : (0, added)
    }

    /// The image with its wedges on `side`, nearest first, `gap` pixels apart, each centred
    /// along the side, on white (clear film on a negative).
    public static func attach(_ image: RGBImage, _ wedges: [RGBImage], side: String, gap: Int,
                              fill: UInt16 = UInt16(maxValue)) -> RGBImage {
        if wedges.isEmpty { return image }
        precondition(sides.contains(side), "unknown side \(side)")
        let horizontal = side == "top" || side == "bottom"
        var parts: [RGBImage?] = [image]  // nil: a gap
        for wedge in wedges { parts += [nil, wedge] }
        if side == "top" || side == "left" { parts.reverse() }
        let alongOf = { (p: RGBImage) in horizontal ? p.height : p.width }
        let acrossOf = { (p: RGBImage) in horizontal ? p.width : p.height }
        let along = parts.reduce(0) { $0 + ($1.map(alongOf) ?? gap) }
        let across = parts.compactMap { $0 }.map(acrossOf).max()!
        let (width, height) = horizontal ? (across, along) : (along, across)
        var canvas = [UInt16](repeating: fill, count: width * height * 3)
        var at = 0
        for part in parts {
            guard let part else {
                at += gap
                continue
            }
            let offset = (across - acrossOf(part)) / 2
            let (left, top) = horizontal ? (offset, at) : (at, offset)
            for y in 0..<part.height {
                let from = y * part.width * 3, to = ((top + y) * width + left) * 3
                canvas.replaceSubrange(to..<to + part.width * 3, with: part.pixels[from..<from + part.width * 3])
            }
            at += alongOf(part)
        }
        return RGBImage(width: width, height: height, pixels: canvas)
    }
}

extension RGBImage {
    /// A joined negative wedge with its inner safe edge (`edge` pixels, on the side facing the
    /// photo) made `gap` pixels wide, repeating its innermost row or column.
    func innerEdge(side: String, edge: Int, gap: Int) -> RGBImage {
        let w = width, h = height
        func row(_ y: Int) -> ArraySlice<UInt16> { pixels[y * w * 3..<(y + 1) * w * 3] }
        var out = [UInt16]()
        switch side {
        case "bottom":
            for _ in 0..<gap { out += row(0) }
            for y in edge..<h { out += row(y) }
            return RGBImage(width: w, height: gap + h - edge, pixels: out)
        case "top":
            for y in 0..<h - edge { out += row(y) }
            for _ in 0..<gap { out += row(h - 1) }
            return RGBImage(width: w, height: h - edge + gap, pixels: out)
        case "right":
            for y in 0..<h {
                let r = row(y), first = r[r.startIndex..<r.startIndex + 3]
                for _ in 0..<gap { out += first }
                out += r[(r.startIndex + edge * 3)...]
            }
            return RGBImage(width: gap + w - edge, height: h, pixels: out)
        default:
            for y in 0..<h {
                let r = row(y), last = r[(r.endIndex - 3)...]
                out += r[r.startIndex..<r.endIndex - edge * 3]
                for _ in 0..<gap { out += last }
            }
            return RGBImage(width: w - edge + gap, height: h, pixels: out)
        }
    }
}
