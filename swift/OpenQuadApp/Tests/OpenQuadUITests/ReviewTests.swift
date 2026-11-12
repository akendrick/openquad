// Fixes from reviewing the app: hand-offs between tabs that could crash or mislead, the
// printer list reaching the printer calibration, and leftovers.

import Foundation
import OpenQuadCore
import Testing
@testable import OpenQuadUI

@MainActor
@Suite("Review fixes")
struct ReviewTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("openquad-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func root(_ tab: AppTab) -> AppRoot {
        AppRoot(settingsURL: folder.appendingPathComponent("settings.json"), tab: tab, restoreWorkspace: false)
    }

    @Test func aBlockingColourDoesNotBreakARunStartedInOthers() throws {
        let root = root(.processCalibration)
        let process = try #require(root.process)
        process.colours = ["green"]
        process.start()
        #expect(process.started && process.error == nil)
        root.useBlockingColour("red", scannerHost: "")
        #expect(process.useColour == "green" && process.curvePath != nil)  // was a crash: no red curve in this run
        process.useColour = "red"
        #expect(process.curvePath == nil)
        process.exportCurve(to: folder.appendingPathComponent("red.acv"))
        #expect(process.error?.contains("no red curve") == true)
        process.closeRun()
        root.useBlockingColour("red", scannerHost: "")
        #expect(process.colours == ["red"] && process.useColour == "red")  // a new run is set up in it
    }

    @Test func theNegativeTabDoesNotPickPrinterCalibrations() {
        let root = root(.negative)
        root.negativeModel.setPrinter("Canon_MG3600_series")
        #expect(root.negativeModel.status == nil && root.negativeModel.session.calibration == nil)
    }

    @Test func printersFoundLaterReachThePrinterCalibration() async throws {
        let root = root(.printerCalibration)
        let wizard = try #require(root.calibration)
        #expect(wizard.printers.isEmpty && wizard.printer.isEmpty && wizard.method == .panel)
        await root.printModel.loadPrinters { ["Canon_MG3600_series", "PDF"] }
        #expect(wizard.printers == ["Canon_MG3600_series", "PDF"])
        #expect(wizard.printer == "Canon_MG3600_series" && wizard.method == .direct)
        wizard.printer = "PDF"
        wizard.start()
        wizard.offerPrinters(["Epson"])  // a started run keeps its printer
        #expect(wizard.printer == "PDF" && wizard.printers == ["Canon_MG3600_series", "PDF"])
    }

    @Test func theNoRoomMessageGoesWhenThereIsRoomAgain() async throws {
        let photo = folder.appendingPathComponent("grey.tif")
        try ImageFiles.saveGrey(photo, GreyImage(width: 40, height: 30, pixels: [UInt16](repeating: 30000, count: 1200),
                                                 dpi: (100, 100)))
        let sheet = ContactSheetModel(room: (2, 3), folder: folder)
        sheet.add([photo])
        for _ in 0..<3000 where sheet.loading != nil || sheet.preview == nil { try await Task.sleep(for: .milliseconds(10)) }
        sheet.update { $0.gap = 1 }
        for _ in 0..<3000 where sheet.error == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(sheet.error == ContactSheetModel.noRoom)
        sheet.update { $0.gap = 0.1 }
        for _ in 0..<3000 where sheet.error != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(sheet.error == nil && sheet.preview != nil)
    }
}
