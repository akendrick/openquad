// Saved digital-negative setups ("Cyanotype on Pictorico"): the process curve, ink
// colour, mirror, safe edge, black outline, darkroom marks, printer and paper that go together, and
// for multi-coat processes the separation (its bands, overlap, each negative's own curve and the
// coats curve), so the app can switch between calibrated processes in one step. Each setup is an
// .oqsetup file in the app's setups folder, with copies of its curves beside it, so it keeps
// working if the original curve files are moved or deleted.

import Foundation

/// A setup's separation, as the app shows it: split points and overlap on a step scale (or,
/// split by colour, each coat's colour and the saturation), and the curve files (in the setups
/// folder) of the negatives that have their own and the coats.
public struct SetupSeparation: Sendable, Equatable {
    public var steps: Int
    public var splits: [Int]
    public var overlap: Double
    /// Negative (0 = the lightest, or the first coat) -> its curve's file name in the setups folder.
    public var curves: [Int: String]
    /// The coats curve's file name in the setups folder, if any.
    public var coats: String?
    /// Split by colour: each coat's colour ("#B0306A"), in the order they print; nil: by tone.
    public var colours: [String]?
    public var saturation: Double

    public init(steps: Int, splits: [Int], overlap: Double = 0, curves: [Int: String] = [:], coats: String? = nil,
                colours: [String]? = nil, saturation: Double = 1) {
        self.steps = steps
        self.splits = splits
        self.overlap = overlap
        self.curves = curves
        self.coats = coats
        self.colours = colours
        self.saturation = saturation
    }

    /// How many negatives it makes.
    public var count: Int { colours?.count ?? splits.count + 1 }

    /// The coats' colours, checked (throws if they don't make a colour separation).
    public func coatColours() throws -> [ColourSeparation.RGB8]? {
        guard let colours else { return nil }
        let coats = try colours.map { try ColourSeparation.RGB8(hex: $0) }
        try ColourSeparation.validate(coats: coats, saturation: saturation)
        return coats
    }

    /// The plan it describes (throws if the bands don't make sense).
    public func plan() throws -> SeparationPlan {
        try SeparationPlan.fromSteps(splits.map(Double.init), steps: steps, overlap: overlap)
    }

    struct File: Codable {
        var steps: Int
        var splits: [Int]
        var overlap: Double
        var curves: [String: String]?  // negative number (1 = the lightest) -> file
        var coats: String?
        var colours: [String]?  // absent when split by tone
        var saturation: Double?
    }
}

public struct NegativeSetup: Sendable, Equatable, Identifiable {
    public var name: String
    public var colour: String
    /// The process curve's file name in the setups folder, or nil for none.
    public var process: String?
    public var mirror: Bool
    /// Inches.
    public var safeEdge: Double
    /// Inches of black outline (0 for none).
    public var outline: Double
    /// Darkroom marks in the safe edge: a black guide line round the image, registration marks.
    public var guide: Bool
    public var registration: Bool
    /// The CUPS queue, or nil to choose in the macOS print panel.
    public var printer: String?
    public var paper: String
    /// Several negatives printed coat over coat, or nil for one negative.
    public var separation: SetupSeparation?
    public var created: String

    public var id: String { name }

    public init(name: String, colour: String, process: String? = nil, mirror: Bool = false, safeEdge: Double = 0.25,
                outline: Double = 0, guide: Bool = false, registration: Bool = false, printer: String? = nil,
                paper: String = "Letter", separation: SetupSeparation? = nil, created: String = "") {
        self.name = name
        self.colour = colour
        self.process = process
        self.mirror = mirror
        self.safeEdge = safeEdge
        self.outline = outline
        self.guide = guide
        self.registration = registration
        self.printer = printer
        self.paper = paper
        self.separation = separation
        self.created = created
    }

    struct File: Codable {
        var format: String
        var version: Int
        var name: String
        var colour: String
        var process: String?
        var mirror: Bool
        var safe_edge: Double
        var outline: Double
        var guide: Bool?  // absent in setups saved before darkroom marks
        var registration: Bool?
        var printer: String?
        var paper: String
        var separation: SetupSeparation.File?  // absent for one negative
        var created: String?
    }

    public static func decode(_ data: Data) throws -> NegativeSetup {
        let file: File
        do { file = try JSONDecoder().decode(File.self, from: data) } catch {
            throw FileFormatError(description: "not valid JSON: \(error)")
        }
        guard file.format == "openquad-setup" else { throw FileFormatError(description: "not an OpenQuad negative setup") }
        guard file.version == 1 else { throw FileFormatError(description: "unsupported setup version \(file.version)") }
        guard Negative.colours[file.colour] != nil else { throw FileFormatError(description: "unknown negative colour \(file.colour)") }
        guard Paper.sizes[file.paper] != nil else { throw FileFormatError(description: "unknown paper \(file.paper)") }
        var separation: SetupSeparation?
        if let s = file.separation {
            var curves: [Int: String] = [:]
            for (key, curve) in s.curves ?? [:] {
                guard let n = Int(key), (1...(s.colours?.count ?? s.splits.count + 1)).contains(n) else {
                    throw FileFormatError(description: "the separation has no negative \(key)")
                }
                curves[n - 1] = curve
            }
            separation = SetupSeparation(steps: s.steps, splits: s.splits, overlap: s.overlap, curves: curves, coats: s.coats,
                                         colours: s.colours, saturation: s.saturation ?? 1)
            do {
                _ = try separation!.plan()
                _ = try separation!.coatColours()
            } catch { throw FileFormatError(description: "bad separation: \(error)") }
        }
        return NegativeSetup(name: file.name, colour: file.colour, process: file.process, mirror: file.mirror,
                             safeEdge: min(max(file.safe_edge, 0), 2), outline: min(max(file.outline, 0), 1),
                             guide: file.guide ?? false, registration: file.registration ?? false, printer: file.printer,
                             paper: file.paper, separation: separation, created: file.created ?? "")
    }

    public func encode() throws -> Data {
        let file = File(format: "openquad-setup", version: 1, name: name, colour: colour, process: process, mirror: mirror,
                        safe_edge: safeEdge, outline: outline, guide: guide, registration: registration, printer: printer, paper: paper,
                        separation: separation.map { s in
                            SetupSeparation.File(steps: s.steps, splits: s.splits, overlap: s.overlap,
                                                 curves: s.curves.isEmpty ? nil
                                                    : Dictionary(uniqueKeysWithValues: s.curves.map { ("\($0.key + 1)", $0.value) }),
                                                 coats: s.coats, colours: s.colours,
                                                 saturation: s.colours == nil ? nil : s.saturation)
                        },
                        created: created)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }
}

public struct SetupLibrary: Sendable {
    public let folder: URL

    public init(folder: URL = AppSettings.dataDirectory().appendingPathComponent("setups")) {
        self.folder = folder.resolvingSymlinksInPath()
    }

    /// "cyanotype-on-pictorico" from "Cyanotype on Pictorico".
    static func slug(_ name: String) -> String {
        let words = name.lowercased().split { !$0.isLetter && !$0.isNumber }
        return words.isEmpty ? "setup" : words.joined(separator: "-")
    }

    func url(_ name: String) -> URL { folder.appendingPathComponent("\(Self.slug(name)).oqsetup") }

    /// The setup's own copy of its process curve, if it has one.
    public func processURL(_ setup: NegativeSetup) -> URL? {
        setup.process.map { folder.appendingPathComponent($0) }
    }

    /// The setup's own copies of its separation's curves: each negative's that has one, and the coats.
    public func separationURLs(_ setup: NegativeSetup) -> (curves: [Int: URL], coats: URL?) {
        guard let s = setup.separation else { return ([:], nil) }
        return (s.curves.mapValues { folder.appendingPathComponent($0) }, s.coats.map { folder.appendingPathComponent($0) })
    }

    /// Every curve file the setup named `name` may keep: "slug.oqproc", "slug.neg2.oqproc", "slug.coats.oqproc".
    func curveFiles(_ name: String) -> [URL] {
        let slug = Self.slug(name)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { url in
            let file = url.lastPathComponent
            return file == "\(slug).oqproc" || (file.hasPrefix("\(slug).") && file.hasSuffix(".oqproc"))
        }
    }

    /// Copy the curve at `source` into the folder as `file` (checking it is a curve).
    func keep(_ source: URL, as file: String) throws {
        let data = try Data(contentsOf: source)
        _ = try ProcessCurve.decode(data)
        let target = folder.appendingPathComponent(file)
        if source.resolvingSymlinksInPath() != target { try data.write(to: target, options: .atomic) }
    }

    /// Every saved setup, by name.
    public func all() -> [NegativeSetup] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "oqsetup" }
            .compactMap { try? NegativeSetup.decode(Data(contentsOf: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Save `setup` (replacing one of the same name), copying the process curve at
    /// `process` in beside it, and for a separation each negative's own curve
    /// (`layerProcesses`) and the coats curve. Returns the setup as saved.
    @discardableResult
    public func save(_ setup: NegativeSetup, process: URL?, layerProcesses: [Int: URL] = [:],
                     coats: URL? = nil) throws -> NegativeSetup {
        let name = setup.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw FileFormatError(description: "the setup needs a name") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var saved = setup
        saved.name = name
        saved.process = nil
        let slug = Self.slug(name)
        var kept: Set<String> = []
        if let process {
            try keep(process, as: "\(slug).oqproc")
            saved.process = "\(slug).oqproc"
            kept.insert("\(slug).oqproc")
        }
        if var separation = saved.separation {
            _ = try separation.plan()
            separation.curves = [:]
            for (k, url) in layerProcesses where k < separation.count {
                try keep(url, as: "\(slug).neg\(k + 1).oqproc")
                separation.curves[k] = "\(slug).neg\(k + 1).oqproc"
            }
            separation.coats = nil
            if let coats {
                try keep(coats, as: "\(slug).coats.oqproc")
                separation.coats = "\(slug).coats.oqproc"
            }
            kept.formUnion(separation.curves.values)
            kept.formUnion([separation.coats].compactMap { $0 })
            saved.separation = separation
        }
        for stale in curveFiles(name) where !kept.contains(stale.lastPathComponent) {
            try? FileManager.default.removeItem(at: stale)  // curves this setup no longer has
        }
        if saved.created.isEmpty { saved.created = ISO8601DateFormatter().string(from: Date()) }
        try saved.encode().write(to: url(name), options: .atomic)
        return saved
    }

    /// Remove a setup and its copies of its curves.
    public func delete(_ setup: NegativeSetup) throws {
        try FileManager.default.removeItem(at: url(setup.name))
        for curve in curveFiles(setup.name) { try? FileManager.default.removeItem(at: curve) }
    }
}
