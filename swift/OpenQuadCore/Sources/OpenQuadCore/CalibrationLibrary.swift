// The calibrations this Mac knows: every .oqcal under the app's calibrations folder
// (wizard runs and imported files), labelled from what each file records, so the app
// can offer them by printer and paper and pick the right one for a printer.

import Foundation

public struct LibraryEntry: Sendable, Equatable, Identifiable {
    public let url: URL
    public let printer: String
    public let paper: String
    public let settings: String
    public let created: Date?
    /// From a "-vN" file name (wizard rounds), if any.
    public let version: Int?

    public var id: URL { url }

    /// "Canon MG3600" from "Canon_MG3600_series".
    public static func printerName(_ queue: String) -> String {
        var name = queue.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        if name.lowercased().hasSuffix(" series") { name = String(name.dropLast(7)) }
        return name.isEmpty ? "Unknown printer" : name
    }

    /// Printed through the macOS print panel (not straight to the printer).
    public var viaPanel: Bool { settings.lowercased().contains("print panel") }

    /// E.g. "Canon MG3600 · Letter plain · v5 · 22 Oct 2026".
    public var label: String {
        var parts = [Self.printerName(printer)]
        if !paper.isEmpty { parts.append(paper) }
        if let version { parts.append("v\(version)") }
        if viaPanel { parts.append("print panel") }
        if let created {
            let format = DateFormatter()
            format.dateFormat = "d MMM yyyy"
            format.locale = Locale(identifier: "en_GB")
            parts.append(format.string(from: created))
        }
        return parts.joined(separator: " · ")
    }

    /// Same printer, and the calibration's paper ("Letter plain") is for this page size ("Letter").
    public func fits(printer queue: String, paper size: String) -> Bool {
        guard printer == queue else { return false }
        let words = paper.lowercased().split(separator: " ")
        return words.first.map(String.init) == size.lowercased() || paper.isEmpty
    }
}

public struct CalibrationLibrary: Sendable {
    public let folder: URL

    public init(folder: URL = AppSettings.dataDirectory().appendingPathComponent("calibrations")) {
        self.folder = folder.resolvingSymlinksInPath()
    }

    static func date(_ text: String) -> Date? {
        let full = ISO8601DateFormatter()
        if let date = full.date(from: text) { return date }
        full.formatOptions.insert(.withFractionalSeconds)
        return full.date(from: text)
    }

    static func version(_ url: URL) -> Int? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard let match = stem.firstMatch(of: /-v(\d+)$/) else { return nil }
        return Int(match.1)
    }

    /// Read one file into an entry; nil if it isn't a calibration or makes no correction.
    public static func entry(_ file: URL) -> LibraryEntry? {
        let url = file.resolvingSymlinksInPath()  // one spelling per file (/var is /private/var)
        guard let data = try? Data(contentsOf: url), let calibration = try? Calibration.decode(data) else { return nil }
        let identity = calibration.curves.allSatisfy { $0 == calibration.levels }
        if identity { return nil }  // a run's starting point: no correction
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return LibraryEntry(url: url, printer: calibration.printer, paper: calibration.paper, settings: calibration.settings,
                            created: date(calibration.created) ?? modified, version: version(url))
    }

    /// Every calibration, newest first.
    public func all() -> [LibraryEntry] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return [] }
        let entries = walker.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "oqcal" }.compactMap(Self.entry)
        return entries.sorted { ($0.created ?? .distantPast, $0.url.path) > ($1.created ?? .distantPast, $1.url.path) }
    }

    /// The newest calibration for each printer, paper and print method.
    public func latest() -> [LibraryEntry] {
        var seen = Set<String>()
        return all().filter { seen.insert("\($0.printer)|\($0.paper.lowercased())|\($0.viaPanel)").inserted }
    }

    /// The best calibration for printing to `printer` on `paper`: newest, preferring the
    /// same print method (straight to the printer, or through the print panel).
    public func match(printer: String, paper: String, viaPanel: Bool = false) -> LibraryEntry? {
        let fitting = all().filter { $0.fits(printer: printer, paper: paper) }
        return fitting.first { $0.viaPanel == viaPanel } ?? fitting.first
    }

    /// Copy a calibration into the library (under "imported"); returns its new entry.
    @discardableResult
    public func importFile(_ source: URL) throws -> LibraryEntry {
        let data = try Data(contentsOf: source)
        let calibration = try Calibration.decode(data)
        let target = folder.appendingPathComponent("imported")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        if let existing = all().first(where: { (try? Data(contentsOf: $0.url)) == data }) { return existing }  // already in
        let day = Self.date(calibration.created).map { date -> String in
            let format = DateFormatter()
            format.dateFormat = "yyyy-MM-dd"
            return format.string(from: date)
        } ?? source.deletingPathExtension().lastPathComponent
        let base = [LibraryEntry.printerName(calibration.printer), calibration.paper, day]
            .filter { !$0.isEmpty }.joined(separator: "-")
            .lowercased().replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "/", with: "-")
        var url = target.appendingPathComponent("\(base).oqcal"), n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = target.appendingPathComponent("\(base)-\(n).oqcal")
            n += 1
        }
        try data.write(to: url)
        guard let entry = Self.entry(url) else {
            try? FileManager.default.removeItem(at: url)
            throw FileFormatError(description: "\(source.lastPathComponent) makes no correction")
        }
        return entry
    }
}
