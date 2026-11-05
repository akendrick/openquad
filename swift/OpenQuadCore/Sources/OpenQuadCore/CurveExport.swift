// Process curves as files other software reads (openquad/curve_export.py): Photoshop
// .amp (256 levels, exact) and .acv (at most 16 spline points), a 3D .cube LUT and CSV.

import Foundation

public enum CurveExport {
    public static let acvPoints = 16  // Photoshop's limit
    public static let cubeSize = 33
    public static let formats = ["amp", "acv", "cube", "csv"]

    static func value(_ curve: ProcessCurve, _ level: Double) -> Double {
        interp(level, curve.levels.map(Double.init), curve.curve.map(Double.init))
    }

    static func levels8(_ curve: ProcessCurve) -> [Double] {
        (0..<256).map { value(curve, Double($0) * 257.0) / 257.0 }
    }

    /// The curve at 256 levels (0-255 in and out).
    public static func lut8(_ curve: ProcessCurve) -> [UInt8] {
        levels8(curve).map { UInt8(clip(rint($0), 0, 255)) }
    }

    public static func amp(_ curve: ProcessCurve) -> Data { Data(lut8(curve)) }

    /// A natural cubic spline through (xs, ys) at `at` (as Photoshop's Curves draws).
    public static func spline(_ xs: [Int], _ ys: [Int], _ at: Int) -> Double {
        let n = xs.count
        if n == 2 { return Double(ys[0]) + Double((ys[1] - ys[0]) * (at - xs[0])) / Double(xs[1] - xs[0]) }
        let h = (0..<(n - 1)).map { Double(xs[$0 + 1] - xs[$0]) }
        var diag = (1..<(n - 1)).map { 2.0 * (h[$0 - 1] + h[$0]) }
        var rhs = (1..<(n - 1)).map { k in
            6.0 * (Double(ys[k + 1] - ys[k]) / h[k] - Double(ys[k] - ys[k - 1]) / h[k - 1])
        }
        if n > 3 {
            for k in 1..<(n - 2) {
                let f = h[k] / diag[k - 1]
                diag[k] -= f * h[k]
                rhs[k] -= f * rhs[k - 1]
            }
        }
        var inner = [Double](repeating: 0, count: n - 2)
        for k in stride(from: n - 3, through: 0, by: -1) {
            let upper = k + 1 < n - 2 ? h[k + 1] * inner[k + 1] : 0.0
            inner[k] = (rhs[k] - upper) / diag[k]
        }
        let m = [0.0] + inner + [0.0]
        var k = 0
        while k < n - 2 && at > xs[k + 1] { k += 1 }
        let a = Double(xs[k + 1] - at), b = Double(at - xs[k])
        return m[k] * a * a * a / (6.0 * h[k])
            + m[k + 1] * b * b * b / (6.0 * h[k])
            + (Double(ys[k]) - m[k] * h[k] * h[k] / 6.0) * a / h[k]
            + (Double(ys[k + 1]) - m[k + 1] * h[k] * h[k] / 6.0) * b / h[k]
    }

    /// (input, output) points (0-255) whose spline follows the curve within half a level, or
    /// as near as `limit` points allow: each added where the spline strays most.
    public static func points(_ curve: ProcessCurve, limit: Int = acvPoints) -> [(Int, Int)] {
        let exact = levels8(curve)
        let stored = lut8(curve).map(Int.init)
        var xs = [0, 255]
        while xs.count < limit {
            let ys = xs.map { stored[$0] }
            var worst = 0, error = -1.0
            for i in 0..<256 {
                let e = abs(spline(xs, ys, i) - exact[i])
                if e > error { (worst, error) = (i, e) }
            }
            if error <= 0.5 { break }
            xs = (xs + [worst]).sorted()
        }
        return xs.map { ($0, stored[$0]) }
    }

    /// A Photoshop Curves file (version 1): the curve on the composite (grey) channel and
    /// unchanged red, green, blue and a spare.
    public static func acv(_ curve: ProcessCurve) -> Data {
        var words: [UInt16] = [1, 5]
        let pts = points(curve)
        words.append(UInt16(pts.count))
        for (x, y) in pts { words += [UInt16(y), UInt16(x)] }
        for _ in 0..<4 { words += [2, 0, 0, 255, 255] }
        return Data(words.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
    }

    public static func cube(_ curve: ProcessCurve, size: Int = cubeSize, title: String = "OpenQuad process curve") -> String {
        let values = (0..<size).map { String(format: "%.6f", value(curve, Double($0) / Double(size - 1) * Double(maxValue)) / Double(maxValue)) }
        var lines = ["TITLE \"\(title)\"", "LUT_3D_SIZE \(size)"]
        lines.reserveCapacity(2 + size * size * size)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size { lines.append("\(values[r]) \(values[g]) \(values[b])") }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func csv(_ curve: ProcessCurve) -> String {
        (["input,output"] + zip(curve.levels, curve.curve).map { "\($0),\($1)" }).joined(separator: "\n") + "\n"
    }

    /// Write `curve` in the format its extension names (formats).
    public static func write(_ curve: ProcessCurve, to url: URL) throws {
        switch url.pathExtension.lowercased() {
        case "amp": try amp(curve).write(to: url)
        case "acv": try acv(curve).write(to: url)
        case "cube": try Data(cube(curve, title: "OpenQuad \(curve.colour) process").utf8).write(to: url)
        case "csv": try Data(csv(curve).utf8).write(to: url)
        case let other:
            throw BuildError(description: "can't export to \(other.isEmpty ? "no suffix" : "." + other); use one of "
                             + formats.map { "." + $0 }.joined(separator: ", "))
        }
    }
}
