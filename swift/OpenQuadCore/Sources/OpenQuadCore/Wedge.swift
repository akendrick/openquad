// Step wedges printed beside the photo: a 31-step grey wedge, and for colour prints a
// colour gamut wedge. Mirrors openquad/wedge.py.
//
// The grey wedge runs from paper white to full black in 31 equal steps and goes through the
// same toning, calibration or process curve as the photo, so the print shows what that does
// to every tone. The colour wedge is 31 hues round the colour wheel in three rows (a tint,
// the full colour and a shade), to see how much of the colour the printer reaches.
//
// A wedge is as long as the photo's side it sits along, and sits `gap` inches from the print
// (or the negative's safe edge) on the chosen side, centred along it.

import Foundation

public enum Wedge {
    public static let steps = 31
    /// Inches across the grey wedge.
    public static let width = 0.4
    /// Inches across each of the colour wedge's three rows.
    public static let colourRow = 0.2
    /// Inches between the print and its wedge.
    public static let defaultGap = 0.25
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

    /// The grey wedge, greyscale (0 black, 65535 white): white to black, left to right (or top
    /// to bottom), `length` x `thickness` pixels. Returns (pixels, width, height).
    public static func grey(length: Int, thickness: Int, horizontal: Bool) -> ([UInt16], Int, Int) {
        precondition(length >= 1 && thickness >= 1, "the wedge has no pixels")
        let edges = edges(length, steps)
        var strip = [UInt16](repeating: 0, count: length)
        for i in 0..<steps {
            let level = UInt16(pyRound(Double(maxValue * (steps - 1 - i)) / Double(steps - 1)))
            for x in edges[i]..<edges[i + 1] { strip[x] = level }
        }
        if horizontal {
            return (Array((0..<thickness).map { _ in strip }.joined()), length, thickness)
        }
        return (strip.flatMap { Array(repeating: $0, count: thickness) }, thickness, length)
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

    /// Inches across a wedge, with `border` on each side.
    public static func thickness(_ kind: Kind, border: Double = 0) -> Double {
        (kind == .grey ? width : colourRow * Double(colourRows.count)) + 2 * border
    }

    /// (width, height) in inches the wedges add to the print.
    public static func extra(_ kinds: [Kind], side: String, gap: Double, border: Double = 0) -> (Double, Double) {
        let added = kinds.reduce(0.0) { $0 + (gap + thickness($1, border: border)) }
        return side == "left" || side == "right" ? (added, 0) : (0, added)
    }

    /// The image with its wedges on `side`, nearest first, `gap` pixels apart, each centred
    /// along the side, on white (clear film on a negative).
    public static func attach(_ image: RGBImage, _ wedges: [RGBImage], side: String, gap: Int) -> RGBImage {
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
        var canvas = [UInt16](repeating: UInt16(maxValue), count: width * height * 3)
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
