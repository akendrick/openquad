// Multi-layer colour toning. Mirrors openquad/composite.py: layers combine subtractively
// in linear light; a layer's ramp is perceptual strength, so a black layer with a linear
// ramp reproduces the greyscale image exactly.

public struct ColourLayer: Sendable {
    public let name: String
    /// The ink's sRGB colour (0-1 per channel) at full strength on white paper.
    public let colour: (Double, Double, Double)
    public let tone: InkSpec

    public init(name: String, colour: (Double, Double, Double), tone: InkSpec) {
        precondition([colour.0, colour.1, colour.2].allSatisfy { (0.0...1.0).contains($0) },
                     "\(name): colour must be three values within 0-1")
        self.name = name
        self.colour = colour
        self.tone = tone
    }

    /// Linear-light coverage (0-1) at a tone position.
    public func strength(_ position: Double) -> Double {
        1.0 - Colour.srgbToLinear(1.0 - tone.ramp(position))
    }
}

public enum Composite {
    /// Colour toning is always an explicit choice; without one, prints stay neutral.
    public static let defaultPreset = "neutral"

    static func layer(_ name: String, _ colour: (Double, Double, Double), limit: Double, start: Double,
                      peak: Double, end: Double = 1.0, shape: InkSpec.Shape = .smooth) -> ColourLayer {
        ColourLayer(name: name, colour: colour,
                    tone: InkSpec(name, limit: limit, start: start, peak: peak, end: end, shape: shape))
    }

    static let black = (0.0, 0.0, 0.0)
    static let red = (0.78, 0.12, 0.12)

    public static let presets: [String: [ColourLayer]] = [
        "neutral": [layer("black", black, limit: 100, start: 0.0, peak: 1.0, shape: .linear)],
        "black-red": [
            layer("black", black, limit: 100, start: 0.35, peak: 1.0),
            layer("red", red, limit: 75, start: 0.0, peak: 0.55, end: 1.0),
        ],
        "red-only": [layer("red", red, limit: 75, start: 0.0, peak: 0.55, end: 1.0)],
        "warm-split": [
            layer("black", black, limit: 100, start: 0.2, peak: 1.0),
            layer("sepia", (0.62, 0.42, 0.24), limit: 60, start: 0.0, peak: 0.5, end: 0.9),
        ],
    ]

    /// Render layers over a greyscale image as 16-bit sRGB, interleaved R, G, B per pixel.
    public static func composite(_ image: [UInt16], layers: [ColourLayer]) -> [UInt16] {
        let names = layers.map(\.name)
        precondition(Set(names).count == names.count, "layer names must be unique")
        let absorb = layers.map { layer in
            [layer.colour.0, layer.colour.1, layer.colour.2].map { 1.0 - Colour.srgbToLinear($0) }
        }
        var out = [UInt16](repeating: 0, count: image.count * 3)
        for (index, pixel) in image.enumerated() {
            let position = 1.0 - Double(pixel) / Double(maxValue)
            var light = [1.0, 1.0, 1.0]
            for (layer, absorption) in zip(layers, absorb) {
                let strength = layer.strength(position)
                for c in 0..<3 { light[c] *= 1.0 - strength * absorption[c] }
            }
            for c in 0..<3 {
                out[index * 3 + c] = UInt16(rint(Colour.linearToSRGB(light[c]) * Double(maxValue)))
            }
        }
        return out
    }
}
