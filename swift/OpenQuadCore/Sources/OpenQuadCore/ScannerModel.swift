// A scanner's colour model (openquad/scanner_profile.py ScannerModel): scanner RGB, as
// encoded (0-1), to CIE XYZ under D50. The app reads models made with
// `openquad scanner-profile` from an IT8.7/2 target; it doesn't fit them yet.

import Foundation

public struct ScannerModel: Sendable, Equatable {
    public static let kinds = ["matrix", "poly"]
    public static let curvePoints = 256

    public let kind: String
    /// Per channel, scanner value (256 points over 0-1) to linear light.
    public let curves: [[Double]]
    /// (terms, 3): the linear values' terms to XYZ.
    public let coefficients: [[Double]]
    public let scanner: String
    public let reference: String

    public init(kind: String, curves: [[Double]], coefficients: [[Double]], scanner: String = "", reference: String = "") throws {
        guard Self.kinds.contains(kind) else { throw FileFormatError(description: "unknown scanner model kind \(pyRepr(kind))") }
        guard curves.count == 3, curves.allSatisfy({ $0.count == Self.curvePoints }),
              coefficients.count == (kind == "matrix" ? 4 : 11), coefficients.allSatisfy({ $0.count == 3 }) else {
            throw FileFormatError(description: "the scanner model's tables are the wrong size")
        }
        self.kind = kind
        self.curves = curves
        self.coefficients = coefficients
        self.scanner = scanner
        self.reference = reference
    }

    public static func decode(_ data: Data) throws -> ScannerModel {
        guard let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let kind = d["kind"] as? String,
              kinds.contains(kind) else {
            throw FileFormatError(description: "not an OpenQuad scanner model")
        }
        func table(_ key: String) throws -> [[Double]] {
            guard let rows = d[key] as? [[NSNumber]] else { throw FileFormatError(description: "the scanner model has no \(key)") }
            return rows.map { $0.map(\.doubleValue) }
        }
        return try ScannerModel(kind: kind, curves: try table("curves"), coefficients: try table("coefficients"),
                                scanner: d["scanner"] as? String ?? "", reference: d["reference"] as? String ?? "")
    }

    static let grid = linspace(0, 1, curvePoints)

    func terms(_ v: [Double]) -> [Double] {
        let (r, g, b) = (v[0], v[1], v[2])
        if kind == "matrix" { return [r, g, b, 1] }
        return [r, g, b, r * g, r * b, g * b, r * r, g * g, b * b, r * g * b, 1]
    }

    /// Scanner RGB (0-1, as encoded) to D50 XYZ.
    public func toXYZ(_ rgb: [Double]) -> [Double] {
        let linear = (0..<3).map { interp(rgb[$0], Self.grid, curves[$0]) }
        let t = terms(linear)
        return (0..<3).map { c in t.indices.reduce(0.0) { $0 + t[$1] * coefficients[$1][c] } }
    }
}
