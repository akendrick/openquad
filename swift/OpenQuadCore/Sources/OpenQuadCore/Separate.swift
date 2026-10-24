// Split a 16-bit greyscale image into per-ink channels. Mirrors openquad/separate.py.
// Image: 0 is black, 65535 white. Curve index 0 is paper white, so position = 65535 - pixel.

public enum Separate {
    /// Highest combined ink of all channels at any tone, as a percentage (100% = one
    /// channel at full ink). Interpolation is linear, so the maximum is at a curve point.
    public static func maxTotalInk(_ curve: QuadCurve) -> Double {
        var best = 0.0
        for level in 0..<quadLevels {
            var total = 0.0
            for row in curve.values { total += Double(row[level]) }
            best = max(best, total)
        }
        return best / Double(maxValue) * 100.0
    }

    /// Ink amounts, one array per channel, each `width * height` long (row-major).
    public static func separate(image: [UInt16], width: Int, height: Int, curve: QuadCurve) -> [[UInt16]] {
        precondition(image.count == width * height, "image must have width x height pixels")
        let luts = Curves.luts(curve)
        return luts.map { lut in image.map { lut[maxValue - Int($0)] } }
    }
}
