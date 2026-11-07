// Tonal separations: one photo split into several negatives, each printing a band of tones.
// Mirrors openquad/separations.py bit for bit.
//
// Some processes (gum bichromate, multi-coat cyanotype, gum over platinum) can't reach a full
// tonal range in one coat. The print is built up from several coats, each exposed under its
// own negative. Negative k prints nothing in tones lighter than its band, ramps up across the
// band, and prints at its coat's full strength in every darker tone, so the coats add up. An
// overlap softens each band's corners over that width of tone (its ramp averaged over a window
// that wide) so the seams don't show; the coats still add up to the photo exactly, and paper
// white and full black are untouched.
//
// Tone positions run 0 (paper white) to 1 (full black): position = 1 - pixel / 65535.

import Foundation

public struct SeparationPlan: Sendable, Equatable {
    public static let maxNegatives = 6
    /// The step scale split points are shown on (a 30-step scale: splits at 10 and 20 for three).
    public static let defaultSteps = 30

    /// Where the bands meet (tone positions, ascending, within 0-1).
    public let splits: [Double]
    /// Width of tone over which neighbouring bands blend.
    public let overlap: Double
    /// Only how the plan is shown: the scale its split points are counted on.
    public let steps: Int

    public init(splits: [Double], overlap: Double = 0, steps: Int = SeparationPlan.defaultSteps) throws {
        guard splits.count + 1 <= Self.maxNegatives else {
            throw BuildError(description: "at most \(Self.maxNegatives) negatives, got \(splits.count + 1)")
        }
        guard splits.allSatisfy({ $0 > 0 && $0 < 1 }) else {
            throw BuildError(description: "split points must lie between paper white and full black")
        }
        guard zip(splits, splits.dropFirst()).allSatisfy({ $1 > $0 }) else {
            throw BuildError(description: "split points must be in order, lightest first, none the same")
        }
        guard steps >= 2 else { throw BuildError(description: "the step scale needs at least 2 steps, got \(steps)") }
        self.splits = splits
        self.overlap = overlap
        self.steps = steps
        let narrowest = bands.map { $0.1 - $0.0 }.min()!
        guard overlap >= 0 && overlap <= narrowest + 1e-9 else {  // allow for rounding in s / steps
            throw BuildError(description: "the overlap can be up to the narrowest band (\(Self.g(narrowest * Double(steps))) steps), "
                             + "got \(Self.g(overlap * Double(steps)))")
        }
    }

    /// `count` bands of equal width.
    public static func even(_ count: Int, overlap: Double = 0, steps: Int = defaultSteps) throws -> SeparationPlan {
        guard (1...maxNegatives).contains(count) else { throw BuildError(description: "1-\(maxNegatives) negatives, got \(count)") }
        return try SeparationPlan(splits: (1..<count).map { Double($0) / Double(count) }, overlap: overlap, steps: steps)
    }

    /// Split points and overlap counted in steps of a `steps`-step scale.
    public static func fromSteps(_ splits: [Double], steps: Int, overlap: Double = 0) throws -> SeparationPlan {
        guard steps >= 2 else { throw BuildError(description: "the step scale needs at least 2 steps, got \(steps)") }
        return try SeparationPlan(splits: splits.map { $0 / Double(steps) }, overlap: overlap / Double(steps), steps: steps)
    }

    public var count: Int { splits.count + 1 }

    /// Each negative's band of tone, (lighter edge, darker edge), lightest first.
    public var bands: [(Double, Double)] {
        let edges = [0.0] + splits + [1.0]
        return Array(zip(edges, edges.dropFirst()))
    }

    static func g(_ value: Double) -> String { String(format: "%g", value) }

    /// e.g. "3 negatives, split at steps 10 and 20 of 30, overlap 1 step".
    public func describe() -> String {
        if count == 1 { return "1 negative (no separation)" }
        let points = splits.map { Self.g($0 * Double(steps)) }
        let joined = points.count == 1 ? points[0] : points.dropLast().joined(separator: ", ") + " and " + points.last!
        let word = points.count == 1 ? "step" : "steps"
        let amount = Self.g(overlap * Double(steps))
        let blend = overlap != 0 ? ", overlap \(amount) step\(amount == "1" ? "" : "s")" : ""
        return "\(count) negatives, split at \(word) \(joined) of \(steps)\(blend)"
    }

    /// The integral of a band's ramp (in band units): see separations.py.
    static func antiderivative(_ v: Double, first: Bool, last: Bool) -> Double {
        if !last && v > 1.0 { return v - 0.5 }
        if !first && v < 0.0 { return 0.0 }
        return v * v / 2.0
    }

    /// How strongly negative `layer` (0 = the lightest band) prints at a tone position, 0-1.
    public func strength(_ layer: Int, at position: Double) -> Double {
        precondition((0..<count).contains(layer), "negative \(layer + 1) of \(count) doesn't exist")
        let (lower, upper) = bands[layer]
        let width = upper - lower
        let first = layer == 0, last = layer == count - 1
        let u = (position - lower) / width
        var ramp: Double
        if overlap == 0 {
            ramp = last ? u : min(u, 1.0)
            ramp = first ? ramp : max(ramp, 0.0)
        } else {
            let h = overlap / (2.0 * width)
            ramp = (Self.antiderivative(u + h, first: first, last: last)
                - Self.antiderivative(u - h, first: first, last: last)) / (2.0 * h)
        }
        return min(max(ramp, 0.0), 1.0)
    }

    /// Photo pixel (0 black .. 65535 white) -> that coat's image pixel.
    public func coatLUT(_ layer: Int) -> [UInt16] {
        (0...maxValue).map { pixel in
            let position = 1.0 - Double(pixel) / Double(maxValue)
            return UInt16(rint((1.0 - strength(layer, at: position)) * Double(maxValue)))
        }
    }

    /// The greyscale image negative `layer` is made from: its coat's strength as darkness.
    public func coatImage(_ photo: [UInt16], layer: Int) -> [UInt16] {
        let lut = coatLUT(layer)
        return photo.map { lut[Int($0)] }
    }
}
