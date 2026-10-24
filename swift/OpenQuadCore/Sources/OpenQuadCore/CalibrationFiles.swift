// Grey-balance calibrations (.oqcal) and negative process curves (.oqproc): reading,
// writing and applying. Mirrors openquad/greybalance.py Calibration and
// openquad/chart.py ProcessCurve; the JSON formats are the same, so files move freely
// between the Python and Swift versions.

import Foundation

public struct FileFormatError: Error, Equatable, CustomStringConvertible {
    public let description: String
}

/// A 65,536-entry lookup table from piecewise-linear points (numpy interp + rint).
func lookupTable(levels: [UInt16], values: [UInt16]) -> [UInt16] {
    let xp = levels.map(Double.init), fp = values.map(Double.init)
    return (0..<lutSize).map { UInt16(rint(interp(Double($0), xp, fp))) }
}

/// The 257 evenly spaced levels that folded and process curves are sampled at.
func fineGrid(_ points: Int = 257) -> [UInt16] {
    linspace(0, Double(maxValue), points).map { UInt16(rint($0)) }
}

/// Per-channel printer correction: grey level in -> value to send, for R, G and B.
public struct Calibration: Sendable {
    public var levels: [UInt16]
    public var curves: [[UInt16]]  // R, G, B
    public var printer = ""
    public var paper = ""
    public var settings = ""
    public var created = ""

    public init(levels: [UInt16], curves: [[UInt16]], printer: String = "", paper: String = "",
                settings: String = "", created: String = "") throws {
        guard levels.count >= 2, zip(levels, levels.dropFirst()).allSatisfy({ $0 < $1 }) else {
            throw FileFormatError(description: "levels must be at least 2 strictly ascending values")
        }
        guard curves.count == 3, curves.allSatisfy({ $0.count == levels.count }) else {
            throw FileFormatError(description: "curves must be 3 rows of \(levels.count)")
        }
        self.levels = levels
        self.curves = curves
        self.printer = printer
        self.paper = paper
        self.settings = settings
        self.created = created
    }

    struct File: Codable {
        var format: String
        var version: Int
        var printer: String?
        var paper: String?
        var settings: String?
        var created: String?
        var levels: [Int]
        var curves: [String: [Int]]
    }

    public static func decode(_ data: Data) throws -> Calibration {
        let file: File
        do { file = try JSONDecoder().decode(File.self, from: data) } catch {
            throw FileFormatError(description: "not valid JSON: \(error)")
        }
        guard file.format == "openquad-calibration" else { throw FileFormatError(description: "not an OpenQuad calibration file") }
        guard file.version == 1 else { throw FileFormatError(description: "unsupported calibration version \(file.version)") }
        let curves = try ["R", "G", "B"].map { key -> [UInt16] in
            guard let row = file.curves[key] else { throw FileFormatError(description: "missing curve \(key)") }
            return row.map { UInt16(clamping: $0) }
        }
        return try Calibration(levels: file.levels.map { UInt16(clamping: $0) }, curves: curves,
                               printer: file.printer ?? "", paper: file.paper ?? "",
                               settings: file.settings ?? "", created: file.created ?? "")
    }

    public func encode() throws -> Data {
        let file = File(format: "openquad-calibration", version: 1, printer: printer, paper: paper,
                        settings: settings, created: created, levels: levels.map(Int.init),
                        curves: ["R": curves[0].map(Int.init), "G": curves[1].map(Int.init), "B": curves[2].map(Int.init)])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }

    public func luts() -> [[UInt16]] {
        curves.map { lookupTable(levels: levels, values: $0) }
    }

    /// Correct interleaved 16-bit RGB pixels.
    public func apply(_ rgb: [UInt16]) -> [UInt16] {
        let tables = luts()
        return rgb.enumerated().map { index, value in tables[index % 3][Int(value)] }
    }

    /// The RGB sent for each neutral grey level, interleaved.
    public func sentFor(_ greyLevels: [UInt16]) -> [UInt16] {
        apply(greyLevels.flatMap { [$0, $0, $0] })
    }
}

/// Photo grey level in -> level to make a digital negative from (for one ink colour).
public struct ProcessCurve: Sendable {
    public var levels: [UInt16]
    public var curve: [UInt16]
    public var colour = "green"
    public var process = "carbon"
    public var film = ""
    public var printing = ""
    public var created = ""

    public init(levels: [UInt16], curve: [UInt16], colour: String = "green", process: String = "carbon",
                film: String = "", printing: String = "", created: String = "") {
        self.levels = levels
        self.curve = curve
        self.colour = colour
        self.process = process
        self.film = film
        self.printing = printing
        self.created = created
    }

    /// No correction: every level maps to itself, on the usual 257-point grid.
    public static func identity(colour: String = "green") -> ProcessCurve {
        let levels = fineGrid()
        return ProcessCurve(levels: levels, curve: levels, colour: colour)
    }

    struct File: Codable {
        var format: String
        var version: Int
        var process: String?
        var colour: String?
        var film: String?
        var printing: String?
        var created: String?
        var levels: [Int]
        var curve: [Int]
    }

    public static func decode(_ data: Data) throws -> ProcessCurve {
        let file: File
        do { file = try JSONDecoder().decode(File.self, from: data) } catch {
            throw FileFormatError(description: "not valid JSON: \(error)")
        }
        guard file.format == "openquad-process" else { throw FileFormatError(description: "not an OpenQuad process curve") }
        guard file.levels.count == file.curve.count, file.levels.count >= 2 else {
            throw FileFormatError(description: "levels and curve must be the same length (at least 2)")
        }
        guard zip(file.levels, file.levels.dropFirst()).allSatisfy({ $0 < $1 }) else {
            throw FileFormatError(description: "levels must be strictly ascending")
        }
        let colour = file.colour ?? "green"
        guard Negative.colours[colour] != nil else { throw FileFormatError(description: "unknown negative colour \(colour)") }
        return ProcessCurve(levels: file.levels.map { UInt16(clamping: $0) }, curve: file.curve.map { UInt16(clamping: $0) },
                            colour: colour, process: file.process ?? "carbon", film: file.film ?? "",
                            printing: file.printing ?? "", created: file.created ?? "")
    }

    public func encode() throws -> Data {
        let file = File(format: "openquad-process", version: 1, process: process, colour: colour, film: film,
                        printing: printing, created: created, levels: levels.map(Int.init), curve: curve.map(Int.init))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }

    public func apply(_ photo: [UInt16]) -> [UInt16] {
        let table = lookupTable(levels: levels, values: curve)
        return photo.map { table[Int($0)] }
    }
}
