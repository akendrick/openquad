// Building corrections from measurements. Mirrors openquad/greybalance.py
// build_calibration, openquad/linearize.py and openquad/chart.py build_process_curve.

import Foundation

public struct BuildError: Error, Equatable, CustomStringConvertible {
    public let description: String
}

/// One measured wedge (openquad/measure.py Measurement): the target's grey levels, the
/// RGB sent for each, and what was measured (linear RGB relative to paper white, and L*a*b*).
public struct Measurement: Sendable {
    public var levels: [UInt16]
    public var sent: [[UInt16]]
    public var rgb: [[Double]]
    public var lab: [[Double]]

    public init(levels: [UInt16], sent: [[UInt16]], rgb: [[Double]], lab: [[Double]]) {
        precondition(sent.count == levels.count && rgb.count == levels.count && lab.count == levels.count,
                     "one sent, rgb and lab triple per level")
        self.levels = levels
        self.sent = sent
        self.rgb = rgb
        self.lab = lab
    }

    struct File: Codable {
        var format: String
        var levels: [Int]
        var sent: [[Int]]
        var rgb: [[Double]]
        var lab: [[Double]]
    }

    public static func decode(_ data: Data) throws -> Measurement {
        let file: File
        do { file = try JSONDecoder().decode(File.self, from: data) } catch {
            throw FileFormatError(description: "not valid measurement JSON: \(error)")
        }
        guard file.format == "openquad-measurement" else { throw FileFormatError(description: "not an OpenQuad measurement file") }
        guard [file.sent.count, file.rgb.count, file.lab.count].allSatisfy({ $0 == file.levels.count }),
              file.sent.allSatisfy({ $0.count == 3 }), file.rgb.allSatisfy({ $0.count == 3 }),
              file.lab.allSatisfy({ $0.count == 3 })
        else { throw FileFormatError(description: "measurement arrays don't match") }
        return Measurement(levels: file.levels.map { UInt16(clamping: $0) },
                           sent: file.sent.map { $0.map { UInt16(clamping: $0) } }, rgb: file.rgb, lab: file.lab)
    }

    /// Indices that sort by level (numpy argsort; levels are distinct).
    var byLevel: [Int] { stableOrder(levels.map(Double.init)) }
}

/// numpy argsort(kind="stable").
func stableOrder(_ values: [Double]) -> [Int] {
    values.indices.sorted { values[$0] < values[$1] || (values[$0] == values[$1] && $0 < $1) }
}

/// numpy maximum.accumulate.
func runningMax(_ values: [Double]) -> [Double] {
    var best = -Double.infinity
    return values.map { best = max(best, $0); return best }
}

public enum GreyBalance {
    /// Step 17 of 21 and darker: where the Canon switches to pigment black.
    public static let shadowLevel: UInt16 = 13107

    /// Per-channel curves that make each measured step neutral at its own lightness.
    /// `damping` (0-1) applies only that fraction of the change; `shadowDamping`, if
    /// given, replaces it at or below `shadowLevel`.
    public static func build(_ measurement: Measurement, damping: Double = 1.0, shadowDamping: Double? = nil,
                             shadowLevel: UInt16 = shadowLevel, printer: String = "", paper: String = "",
                             settings: String = "") throws -> Calibration {
        for (name, value) in [("damping", damping), ("shadow_damping", shadowDamping)] {
            if let value, !(0.0...1.0).contains(value) { throw BuildError(description: "\(name) must be within 0-1, got \(value)") }
        }
        let order = measurement.byLevel
        let levels = order.map { measurement.levels[$0] }
        let sent = order.map { measurement.sent[$0].map(Double.init) }
        let measured = order.map { measurement.rgb[$0] }
        let target = measured.map { max(Colour.luminance($0[0], $0[1], $0[2]), 0.0) }
        let count = levels.count

        var curves = [[UInt16]]()
        for c in 0..<3 {
            let bySent = stableOrder(sent.map { $0[c] })
            let x = bySent.map { sent[$0][c] }
            let response = runningMax(bySent.map { measured[$0][c] }).enumerated().map { $1 + Double($0) * 1e-9 }
            let proposed = target.map { interp($0, response, x) }
            var row = (0..<count).map { i -> Double in
                let strength = levels[i] <= shadowLevel ? (shadowDamping ?? damping) : damping
                return sent[i][c] + strength * (proposed[i] - sent[i][c])
            }
            row[count - 1] = Double(maxValue)  // paper white stays paper
            row[0] = sent[0][c]  // deepest black stays as sent
            curves.append(runningMax(row.map { clip($0, 0, Double(maxValue)) }).map { UInt16(rint($0)) })
        }
        return try Calibration(levels: levels, curves: curves, printer: printer, paper: paper, settings: settings,
                               created: ISO8601DateFormatter().string(from: Date()))
    }
}

public enum Linearize {
    public static let fineLevels = 257

    /// L* (0-100) of a neutral sRGB grey given as a 16-bit level.
    public static func srgbLightness(_ level: Double) -> Double {
        let grey = Colour.srgbToLinear(level / Double(maxValue))
        return Colour.linearRGBToLab(grey, grey, grey).l
    }

    /// The L* a level should print at, between the paper's black and white.
    public static func targetLightness(_ level: Double, paper: Double, black: Double) -> Double {
        black + (paper - black) * srgbLightness(level) / 100.0
    }

    /// Input level -> level to use instead, at `points` evenly spaced levels.
    public static func toneCurve(_ measurement: Measurement, points: Int = fineLevels) throws -> [Double] {
        let order = measurement.byLevel
        let measured = order.map { measurement.lab[$0][0] }
        let levels = order.map { Double(measurement.levels[$0]) }
        guard levels.count >= 3 else { throw BuildError(description: "need at least 3 measured steps") }
        let response = runningMax(measured).enumerated().map { $1 + Double($0) * 1e-6 }
        guard response[response.count - 1] - response[0] >= 10 else {
            throw BuildError(description: "the measured steps barely differ in lightness; check the scan")
        }
        let paper = measured.max()!, black = measured.min()!
        var curve = linspace(0.0, Double(maxValue), points).map {
            interp(targetLightness($0, paper: paper, black: black), response, levels)
        }
        curve[0] = levels[0]
        curve[points - 1] = levels[levels.count - 1]
        return runningMax(curve)
    }

    /// Fold a tone curve into `calibration`, which must be what the target was printed with.
    public static func linearize(_ calibration: Calibration, _ measurement: Measurement) throws -> Calibration {
        guard calibration.sentFor(measurement.levels) == measurement.sent.flatMap({ $0 }) else {
            throw BuildError(description: "this measurement wasn't printed with this calibration (sent values differ)")
        }
        let tone = try toneCurve(measurement).map { Int(rint($0)) }
        let luts = calibration.luts()
        let settings = String((calibration.settings + "; tone linearized").drop { $0 == ";" || $0 == " " })
        return try Calibration(levels: fineGrid(fineLevels), curves: luts.map { lut in tone.map { lut[$0] } },
                               printer: calibration.printer, paper: calibration.paper, settings: settings,
                               created: ISO8601DateFormatter().string(from: Date()))
    }
}

/// A read process chart (openquad/chart.py ChartReading): the photo level of each patch
/// as designed, its measured L*, and the measured L* of the 21-step strip.
public struct ChartReading: Sendable {
    public var levels: [UInt16]
    public var lightness: [Double]
    public var strip: [Double]
    /// How the print lay on the scanner.
    public var orientation: String
    /// L* of the safe edge (what the process gives where the negative blocks fully).
    public var paper: Double

    public init(levels: [UInt16], lightness: [Double], strip: [Double] = [], orientation: String = "", paper: Double = 100) {
        precondition(levels.count == lightness.count, "one lightness per patch")
        self.levels = levels
        self.lightness = lightness
        self.strip = strip
        self.orientation = orientation
        self.paper = paper
    }

    public var black: Double { lightness.min()! }
    public var white: Double { lightness.max()! }

    /// Measured minus target L* for each patch.
    public func toneErrors() -> [Double] {
        zip(levels, lightness).map { $1 - Linearize.targetLightness(Double($0), paper: white, black: black) }
    }
}

/// Evening out the chart's patch-to-patch noise (openquad/chart.py SMOOTHING).
public enum Smoothing {
    /// How far the smoothing reaches, in patches each side, by name.
    public static let reaches: [(String, Int)] = [("none", 0), ("light", 3), ("medium", 5), ("strong", 9)]
    public static let standard = 5

    /// Each y replaced by a weighted (tricube) straight-line fit to its neighbours within
    /// `reach` patches; x ascending. reach 0 leaves y as it is.
    public static func response(_ x: [Double], _ y: [Double], reach: Int) -> [Double] {
        guard reach > 0 else { return y }
        let n = y.count
        return (0..<n).map { i in
            let lo = max(0, i - reach), hi = min(n, i + reach + 1)
            let w = (lo..<hi).map { j -> Double in
                let d = Double(abs(j - i)) / Double(reach + 1)
                let t = 1.0 - d * d * d
                return t * t * t
            }
            let dx = (lo..<hi).map { x[$0] - x[i] }
            let ys = Array(y[lo..<hi])
            let s0 = pairwiseSum(w), s1 = pairwiseSum(zip(w, dx).map { $0 * $1 })
            let s2 = pairwiseSum(zip(w, dx).map { $0 * $1 * $1 })
            let t0 = pairwiseSum(zip(w, ys).map { $0 * $1 })
            let t1 = pairwiseSum((0..<w.count).map { w[$0] * dx[$0] * ys[$0] })
            let det = s0 * s2 - s1 * s1
            return det > 1e-9 * s0 * s2 ? (s2 * t0 - s1 * t1) / det : t0 / s0
        }
    }

    /// The closest never-falling sequence to y (least squares; pool adjacent violators).
    public static func ascending(_ y: [Double]) -> [Double] {
        var sums: [Double] = [], counts: [Int] = []
        for value in y {
            sums.append(value)
            counts.append(1)
            while sums.count > 1, sums[sums.count - 2] / Double(counts[counts.count - 2]) > sums[sums.count - 1] / Double(counts[counts.count - 1]) {
                let total = sums.removeLast(), count = counts.removeLast()
                sums[sums.count - 1] += total
                counts[counts.count - 1] += count
            }
        }
        return zip(sums, counts).flatMap { Array(repeating: $0 / Double($1), count: $1) }
    }
}

/// Tones lost to paper white or full black (openquad/chart.py clipped_tones).
public enum Clipping {
    public static let tolerance = 1.0  // L*: this close to the print's white (or black) looks the same
    public static let warn = 3  // lost tones (1% steps) worth a warning

    /// (highlights, shadows): how many more patches print as the print's white (or black)
    /// than should; the curve can only squeeze the rest into fewer steps.
    public static func lost(_ reading: ChartReading, tolerance: Double = tolerance) -> (Int, Int) {
        let white = reading.white, black = reading.black
        let target = reading.levels.map { Linearize.targetLightness(Double($0), paper: white, black: black) }
        let light = reading.lightness.filter { $0 >= white - tolerance }.count - target.filter { $0 >= white - tolerance }.count
        let dark = reading.lightness.filter { $0 <= black + tolerance }.count - target.filter { $0 <= black + tolerance }.count
        return (max(0, light), max(0, dark))
    }

    /// What to change when tones are lost, or nil when few are.
    public static func advice(highlights: Int, shadows: Int) -> String? {
        switch (highlights >= warn, shadows >= warn) {
        case (true, true):
            return "\(highlights)% of the highlights print as paper white and \(shadows)% of the shadows as full black: "
                + "the negative's range is longer than the process's. Try a less blocking colour (see the blocking test); "
                + "meanwhile the curve squeezes those tones into fewer steps."
        case (true, false):
            return "The lightest \(highlights)% of tones print as paper white (the negative blocks them fully): give more "
                + "exposure, or use a less blocking colour."
        case (false, true):
            return "The darkest \(shadows)% of tones print as full black: give less exposure, or use a more blocking colour."
        case (false, false):
            return nil
        }
    }
}

extension ProcessCurve {
    /// The curve that puts each grey level on target, from a chart printed through `previous`;
    /// `smoothing` is how many patches each side even out noise (Smoothing.reaches).
    public static func build(_ reading: ChartReading, previous: ProcessCurve? = nil, smoothing: Int = Smoothing.standard,
                             film: String = "", printing: String = "") throws -> ProcessCurve {
        let previous = previous ?? .identity()
        let sent = previous.apply(reading.levels).map(Double.init)
        let order = stableOrder(sent)
        let x = order.map { sent[$0] }
        let smoothed = Smoothing.response(x, order.map { reading.lightness[$0] }, reach: smoothing)
        let response = Smoothing.ascending(smoothed).enumerated().map { $1 + Double($0) * 1e-6 }
        guard response[response.count - 1] - response[0] >= 10 else {
            throw BuildError(description: "the patches barely differ; check the exposure and the scan")
        }
        let grid = fineGrid()
        var curve = grid.map {
            interp(Linearize.targetLightness(Double($0), paper: reading.white, black: reading.black), response, x)
        }
        curve[0] = x[0]
        curve[curve.count - 1] = x[x.count - 1]
        return ProcessCurve(levels: grid, curve: runningMax(curve.map { clip($0, 0, Double(maxValue)) }).map { UInt16(rint($0)) },
                            colour: previous.colour, film: film.isEmpty ? previous.film : film,
                            printing: printing.isEmpty ? previous.printing : printing)
    }
}
