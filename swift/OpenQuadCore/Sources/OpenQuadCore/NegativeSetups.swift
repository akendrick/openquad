// Saved digital-negative setups ("Cyanotype on Pictorico"): the process curve, ink
// colour, mirror, safe edge, black outline, darkroom marks, printer and paper that go together, so the
// app can switch between calibrated processes in one step. Each setup is an .oqsetup
// file in the app's setups folder, with a copy of its process curve beside it, so it
// keeps working if the original curve file is moved or deleted.

import Foundation

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
    public var created: String

    public var id: String { name }

    public init(name: String, colour: String, process: String? = nil, mirror: Bool = false, safeEdge: Double = 0.25,
                outline: Double = 0, guide: Bool = false, registration: Bool = false, printer: String? = nil,
                paper: String = "Letter", created: String = "") {
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
        return NegativeSetup(name: file.name, colour: file.colour, process: file.process, mirror: file.mirror,
                             safeEdge: min(max(file.safe_edge, 0), 2), outline: min(max(file.outline, 0), 1),
                             guide: file.guide ?? false, registration: file.registration ?? false, printer: file.printer, paper: file.paper, created: file.created ?? "")
    }

    public func encode() throws -> Data {
        let file = File(format: "openquad-setup", version: 1, name: name, colour: colour, process: process, mirror: mirror,
                        safe_edge: safeEdge, outline: outline, guide: guide, registration: registration, printer: printer, paper: paper, created: created)
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

    /// Every saved setup, by name.
    public func all() -> [NegativeSetup] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "oqsetup" }
            .compactMap { try? NegativeSetup.decode(Data(contentsOf: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Save `setup` (replacing one of the same name), copying the process curve at
    /// `process` in beside it. Returns the setup as saved.
    @discardableResult
    public func save(_ setup: NegativeSetup, process: URL?) throws -> NegativeSetup {
        let name = setup.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw FileFormatError(description: "the setup needs a name") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var saved = setup
        saved.name = name
        saved.process = nil
        if let process {
            let data = try Data(contentsOf: process)
            _ = try ProcessCurve.decode(data)
            let file = "\(Self.slug(name)).oqproc"
            if process.resolvingSymlinksInPath() != folder.appendingPathComponent(file) {
                try data.write(to: folder.appendingPathComponent(file), options: .atomic)
            }
            saved.process = file
        } else {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(Self.slug(name)).oqproc"))
        }
        if saved.created.isEmpty { saved.created = ISO8601DateFormatter().string(from: Date()) }
        try saved.encode().write(to: url(name), options: .atomic)
        return saved
    }

    /// Remove a setup and its copy of the process curve.
    public func delete(_ setup: NegativeSetup) throws {
        try FileManager.default.removeItem(at: url(setup.name))
        if let curve = processURL(setup) { try? FileManager.default.removeItem(at: curve) }
    }
}
