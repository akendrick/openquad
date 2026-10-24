// Curve maths: 16-bit lookup tables, ink limits and parametric curves.
// Mirrors openquad/curves.py. Positions run from 0.0 (paper white) to 1.0 (full density).

import Foundation

public let lutSize = maxValue + 1
let nodes = linspace(0.0, Double(maxValue), quadLevels)

public enum Curves {
    /// A 256-point curve interpolated to a 65,536-entry lookup table (linear, so a
    /// monotonic curve stays monotonic and every original point is kept).
    public static func expand(_ points: [UInt16]) -> [UInt16] {
        precondition(points.count == quadLevels, "a curve has \(quadLevels) points")
        let fp = points.map(Double.init)
        return (0..<lutSize).map { UInt16(rint(interp(Double($0), nodes, fp))) }
    }

    /// One lookup table per channel.
    public static func luts(_ curve: QuadCurve) -> [[UInt16]] {
        curve.values.map(expand)
    }

    /// Scale a curve so its full-density point uses `limitPercent` of the original ink.
    public static func scaleLimit(_ points: [UInt16], _ limitPercent: Double) -> [UInt16] {
        precondition((0.0...100.0).contains(limitPercent), "ink limit must be 0-100%")
        return points.map { UInt16(rint(Double($0) * (limitPercent / 100.0))) }
    }

    /// Generate a curve from ink specifications; channels without a spec stay at zero.
    public static func build(_ inks: [InkSpec], channels: [String] = standardChannels, gamma: Double = 1.0) throws -> QuadCurve {
        guard gamma > 0 else { throw QuadFormatError(description: "gamma must be positive, got \(gamma)") }
        var rows = Array(repeating: Array(repeating: UInt16(0), count: quadLevels), count: channels.count)
        let positions = linspace(0.0, 1.0, quadLevels).map { pow($0, gamma) }
        var seen = Set<String>()
        for ink in inks {
            guard let index = channels.firstIndex(of: ink.channel) else {
                throw QuadFormatError(description: "ink '\(ink.channel)' is not one of the channels \(channels)")
            }
            guard seen.insert(ink.channel).inserted else {
                throw QuadFormatError(description: "ink '\(ink.channel)' is specified twice")
            }
            rows[index] = positions.map { UInt16(rint(ink.ramp($0) * Double(maxValue))) }
        }
        return try QuadCurve.fromValues(channels, rows)
    }
}

/// How one ink contributes across the tonal range (see openquad/curves.py InkSpec).
public struct InkSpec: Sendable {
    public enum Shape: String, Sendable { case linear, smooth }

    public let channel: String
    public let limit: Double
    public let start: Double
    public let peak: Double
    public let end: Double
    public let shape: Shape

    public init(_ channel: String, limit: Double, start: Double, peak: Double, end: Double = 1.0, shape: Shape = .linear) {
        precondition((0.0...100.0).contains(limit), "\(channel): limit must be 0-100%")
        precondition(0.0 <= start && start < peak && peak <= end && end <= 1.0,
                     "\(channel): need 0 <= start < peak <= end <= 1")
        self.channel = channel
        self.limit = limit
        self.start = start
        self.peak = peak
        self.end = end
        self.shape = shape
    }

    static func smoothstep(_ t: Double) -> Double { t * t * (3.0 - 2.0 * t) }

    /// Ink amount (0-1 of full ink) at a position.
    public func ramp(_ position: Double) -> Double {
        let rise = (position - start) / (peak - start)
        let fall = end > peak ? (end - position) / (end - peak) : 1.0
        var amount = clip(min(rise, fall), 0.0, 1.0)
        if shape == .smooth {
            amount = end > peak ? Self.smoothstep(amount) : 2.0 * Self.smoothstep(amount / 2.0)
        }
        return amount * (limit / 100.0)
    }
}
