// The calibration library: listing, labelling, importing and matching calibrations.

import Foundation
import Testing
@testable import OpenQuadCore

@Suite("Calibration library")
struct LibraryTests {
    func canon() throws -> (Data, Calibration) {
        let text = try #require(try vectors("calibration")["oqcal_text"] as? String)
        return (Data(text.utf8), try Calibration.decode(Data(text.utf8)))
    }

    func write(_ calibration: Calibration, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try calibration.encode().write(to: url)
    }

    @Test func importsAndLabelsTheCanonCalibration() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("canon-plain.oqcal")
        try canon().0.write(to: source)
        let library = CalibrationLibrary(folder: folder.appendingPathComponent("calibrations"))
        #expect(library.all().isEmpty)
        let entry = try library.importFile(source)
        #expect(entry.url.lastPathComponent == "canon-mg3600-letter-plain-2026-10-22.oqcal")
        #expect(entry.label == "Canon MG3600 · Letter plain · 22 Oct 2026")
        #expect(try library.importFile(source) == entry)  // importing again adds nothing
        #expect(library.all() == [entry])
    }

    @Test func newestPerPrinterAndMatching() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (_, base) = try canon()
        func made(_ printer: String, _ paper: String, _ created: String, settings: String = "lp") throws -> Calibration {
            try Calibration(levels: base.levels, curves: base.curves, printer: printer, paper: paper, settings: settings, created: created)
        }
        let root = folder.appendingPathComponent("calibrations")
        try write(try made("Canon_MG3600_series", "Letter plain", "2026-10-20T10:00:00+00:00"), root.appendingPathComponent("run-a/canon-v2.oqcal"))
        try write(try made("Canon_MG3600_series", "Letter plain", "2026-10-22T10:00:00+00:00"), root.appendingPathComponent("run-a/canon-v3.oqcal"))
        try write(try made("Canon_MG3600_series", "Letter plain", "2026-10-23T10:00:00Z", settings: "macOS print panel"),
                  root.appendingPathComponent("run-b/canon-v1.oqcal"))
        try write(try made("Canon_MG3600_series", "4x6 photo", "2026-10-21T10:00:00+00:00"), root.appendingPathComponent("run-c/canon-v1.oqcal"))
        try write(.identity(), root.appendingPathComponent("run-a/canon-v0.oqcal"))  // no correction: left out
        try Data("not json".utf8).write(to: root.appendingPathComponent("run-a/broken.oqcal"))

        let library = CalibrationLibrary(folder: root)
        #expect(library.all().count == 4)
        let latest = library.latest()
        #expect(latest.map { $0.url.lastPathComponent }.sorted() == ["canon-v1.oqcal", "canon-v1.oqcal", "canon-v3.oqcal"])
        #expect(latest.first { $0.url.path.contains("run-b") }?.label.contains("v1 · print panel") == true)

        #expect(library.match(printer: "Canon_MG3600_series", paper: "Letter")?.url.lastPathComponent == "canon-v3.oqcal")
        #expect(library.match(printer: "Canon_MG3600_series", paper: "Letter", viaPanel: true)?.url.path.contains("run-b") == true)
        #expect(library.match(printer: "Canon_MG3600_series", paper: "4x6")?.paper == "4x6 photo")
        #expect(library.match(printer: "Canon_MG3600_series", paper: "Legal") == nil)
        #expect(library.match(printer: "Epson_P700", paper: "Letter") == nil)
    }

    @Test func wizardRunsKeepTheirPaperLabel() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (_, canon) = try canon()
        let run = try CalibrationRun.start(folder: folder.appendingPathComponent("run"), name: "canon", printer: "Canon_MG3600_series",
                                           starting: canon, paperLabel: "Letter plain")
        let paper = try run.calibration().paper
        #expect(run.paper == "Letter" && paper == "Letter plain")
        #expect(LibraryEntry.printerName("Canon_MG3600_series") == "Canon MG3600")
    }
}
