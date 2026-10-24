// Digital negatives for contact printing (carbon). Mirrors openquad/negative.py.
// The photo is inverted (its light tones get the most ink), printed in black or a
// UV-blocking colour, inside a safe edge in that colour with an orientation "F" cut
// into it, then mirrored if asked. The F flips with the image, so it reads correctly
// in the contact print exactly when the mirror setting was right.

public enum Negative {
    public static let colours: [String: (Double, Double, Double)] = [
        "black": (0.0, 0.0, 0.0),
        "green": (0.10, 0.45, 0.20),
        "orange": (0.95, 0.45, 0.05),
        "yellow": (1.0, 0.85, 0.0),
        "red": (0.85, 0.10, 0.10),
        "olive": (0.40, 0.40, 0.0),
    ]
    public static let defaultColour = "black"

    /// The letter F, 7 rows by 5 columns: asymmetric both ways, so a flip shows.
    static let fGlyph: [[Bool]] = [
        [true, true, true, true, true],
        [true, false, false, false, false],
        [true, false, false, false, false],
        [true, true, true, true, false],
        [true, false, false, false, false],
        [true, false, false, false, false],
        [true, false, false, false, false],
    ]

    /// Ink coverage (0-1, perceptual) in `colour`, as 16-bit sRGB on clear film.
    public static func inkToRGB(_ coverage: Double, _ colour: (Double, Double, Double)) -> (UInt16, UInt16, UInt16) {
        let strength = 1.0 - Colour.srgbToLinear(1.0 - clip(coverage, 0.0, 1.0))
        func channel(_ c: Double) -> UInt16 {
            let light = 1.0 - strength * (1.0 - Colour.srgbToLinear(c))
            return UInt16(rint(Colour.linearToSRGB(light) * Double(maxValue)))
        }
        return (channel(colour.0), channel(colour.1), channel(colour.2))
    }
}

public struct NegativeSettings: Sendable {
    public let colour: String
    public let mirror: Bool
    /// Inches of opaque border; 0 for none.
    public let safeEdge: Double
    public let mark: Bool

    public init(colour: String = Negative.defaultColour, mirror: Bool = false, safeEdge: Double = 0.25, mark: Bool = true) {
        precondition(Negative.colours[colour] != nil, "unknown negative colour \(colour)")
        precondition((0.0...2.0).contains(safeEdge), "safe edge must be 0-2 in")
        self.colour = colour
        self.mirror = mirror
        self.safeEdge = safeEdge
        self.mark = mark
    }
}

/// A 16-bit RGB image, interleaved R, G, B per pixel, row-major.
public struct RGBImage: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt16]

    public init(width: Int, height: Int, pixels: [UInt16]) {
        precondition(pixels.count == width * height * 3, "pixels must be width x height x 3")
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

extension Negative {
    /// A greyscale photo (0 black .. 65535 white) as a negative at `dpi`.
    public static func make(_ photo: [UInt16], width: Int, height: Int, settings: NegativeSettings, dpi: Double) -> RGBImage {
        precondition(photo.count == width * height, "photo must be width x height")
        let colour = colours[settings.colour]!
        var pixels = [UInt16](repeating: 0, count: photo.count * 3)
        for (index, value) in photo.enumerated() {
            let (r, g, b) = inkToRGB(Double(value) / Double(maxValue), colour)
            pixels[index * 3] = r
            pixels[index * 3 + 1] = g
            pixels[index * 3 + 2] = b
        }
        return addSafeEdge(RGBImage(width: width, height: height, pixels: pixels), settings: settings, dpi: dpi)
    }

    /// Surround with the safe edge (in the negative's colour) and the F; then mirror if asked.
    public static func addSafeEdge(_ image: RGBImage, settings: NegativeSettings, dpi: Double) -> RGBImage {
        var result = image
        let edge = Int(rint(settings.safeEdge * dpi))
        if edge > 0 {
            let (r, g, b) = inkToRGB(1.0, colours[settings.colour]!)
            let width = image.width + 2 * edge, height = image.height + 2 * edge
            var pixels = [UInt16](repeating: 0, count: width * height * 3)
            for i in 0..<(width * height) {
                pixels[i * 3] = r
                pixels[i * 3 + 1] = g
                pixels[i * 3 + 2] = b
            }
            for y in 0..<image.height {
                let source = y * image.width * 3
                let target = ((y + edge) * width + edge) * 3
                pixels.replaceSubrange(target..<target + image.width * 3,
                                       with: image.pixels[source..<source + image.width * 3])
            }
            if settings.mark {
                let cell = max(1, edge * 6 / 10 / fGlyph.count)
                let glyphHeight = fGlyph.count * cell, glyphWidth = fGlyph[0].count * cell
                let corner = (edge - glyphHeight) / 2  // only used when the glyph fits, so never negative
                if glyphHeight < edge && glyphWidth < edge {
                    for gy in 0..<glyphHeight {
                        for gx in 0..<glyphWidth where fGlyph[gy / cell][gx / cell] {
                            let i = ((corner + gy) * width + corner + gx) * 3
                            pixels[i] = UInt16(maxValue)
                            pixels[i + 1] = UInt16(maxValue)
                            pixels[i + 2] = UInt16(maxValue)
                        }
                    }
                }
            }
            result = RGBImage(width: width, height: height, pixels: pixels)
        }
        if settings.mirror {
            var flipped = result.pixels
            for y in 0..<result.height {
                for x in 0..<result.width {
                    let from = (y * result.width + x) * 3
                    let to = (y * result.width + (result.width - 1 - x)) * 3
                    flipped[to] = result.pixels[from]
                    flipped[to + 1] = result.pixels[from + 1]
                    flipped[to + 2] = result.pixels[from + 2]
                }
            }
            result.pixels = flipped
        }
        return result
    }
}
