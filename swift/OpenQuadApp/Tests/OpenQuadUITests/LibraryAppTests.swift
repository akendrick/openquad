// The Calibration dropdown: importing, choosing, and following the chosen printer.

import Foundation
import OpenQuadCore
import Testing
@testable import OpenQuadUI

@MainActor
@Suite("Calibration dropdown")
struct LibraryAppTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("openquad-library-\(UUID().uuidString)")

    func calibration(printer: String, paper: String, created: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let levels = Targets.wedgeLevels(21).reversed().map { $0 }
        let curves = (0..<3).map { c in levels.map { UInt16(min(65535, Int($0) * (95 + c) / 100)) } }
        let url = folder.appendingPathComponent("\(printer)-\(paper)-\(created.prefix(10)).oqcal".replacingOccurrences(of: " ", with: "-"))
        try Calibration(levels: Array(levels), curves: curves, printer: printer, paper: paper, settings: "default quality, lp",
                        created: created).encode().write(to: url)
        return url
    }

    @Test func importChooseAndFollowThePrinter() throws {
        let app = AppModel(settingsURL: folder.appendingPathComponent("settings.json"))
        #expect(app.calibrations.isEmpty && app.library.folder.lastPathComponent == "calibrations")
        app.importCalibration(try calibration(printer: "Canon_MG3600_series", paper: "Letter plain", created: "2026-10-22T16:59:09+00:00"))
        #expect(app.error == nil && app.calibrations.count == 1)
        #expect(app.currentCalibration?.label == "Canon MG3600 · Letter plain · 22 Oct 2026")
        #expect(app.status == "Added Canon MG3600 · Letter plain · 22 Oct 2026 to your calibrations.")

        app.setCalibration(nil)
        app.setPrinter("Canon_MG3600_series")  // picks its calibration for Letter
        #expect(app.currentCalibration?.printer == "Canon_MG3600_series")
        #expect(app.status == "Using Canon MG3600 · Letter plain · 22 Oct 2026 for this printer.")
        app.setPaper("4x6")  // nothing for 4x6: keeps the Canon one (same printer)
        #expect(app.currentCalibration != nil)
        app.setPrinter("Epson_P700")  // another printer: never print with the Canon's correction
        #expect(app.session.calibration == nil && app.status?.hasPrefix("No calibration for Epson P700 on 4x6") == true)

        let again = AppModel(settingsURL: folder.appendingPathComponent("settings.json"))
        #expect(again.calibrations.count == 1 && again.session.printer == "Epson_P700")
    }
}
