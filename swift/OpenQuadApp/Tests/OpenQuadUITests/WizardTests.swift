// The wizards' models, driven like the views drive them, with a fake scanner.

import CoreGraphics
import Foundation
import ImageIO
import OpenQuadCore
import Testing
import UniformTypeIdentifiers
@testable import OpenQuadUI

/// A comparison page as a scanner would return it (a JPEG of the digital page).
func scannedPage() throws -> Data {
    let page = GreyBalance.comparisonPage(.identity(), dpi: 100)
    let image = try #require(page.cgImage(eightBit: true))
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

@MainActor
func waitUntilIdle(_ model: WizardModel) async throws {
    for _ in 0..<1000 where model.busy { try await Task.sleep(for: .milliseconds(10)) }
}

@MainActor
@Suite("Calibration wizards (app)")
struct WizardTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("openquad-wizard-\(UUID().uuidString)")

    @Test func printerCalibrationRound() async throws {
        let model = CalibrationWizardModel(folder: folder, paper: "Letter", scannerHost: "", starting: nil, startingName: nil,
                                           printers: [], printer: "", find: { [("Canon MG3600 series", "876298000000.local:80")] })
        #expect(model.runName == "printer-letter-plain" && !model.started && model.method == .panel)
        model.start()
        #expect(!model.started && model.error == "Choose the printer you're calibrating.")
        model.printer = "Canon_MG3600_series"
        #expect(model.runName == "canon-mg3600-letter-plain" && model.paperLabel == "Letter plain")
        model.findScanners()
        try await waitUntilIdle(model)
        #expect(model.scannerHost == "876298000000.local:80")
        model.start()
        #expect(model.started && !model.printed)
        let request = try #require(try model.pageForPrinting())
        let page = GreyBalance.comparisonPage(.identity())
        #expect(request.1 == Double(page.width) / 300 && request.2 == Double(page.height) / 300 && request.3 == "Letter")
        model.printed("print panel")
        #expect(model.printed)

        let image = try scannedPage()
        model.scanAndMeasure(fetch: { method, _, _ in
            method == "POST" ? (201, "/eSCL/ScanJobs/1", Data()) : (200, "", method == "GET" ? image : Data())
        })
        try await waitUntilIdle(model)
        #expect(model.error == nil)
        #expect(model.measured && model.corrected != nil && model.result.contains("Colour cast"))
        model.improve("grey balance")
        #expect(model.run?.current.version == 1 && model.result.hasPrefix("Built canon-mg3600-letter-plain-v1.oqcal"))
        #expect(model.canUse && model.calibrationPath?.lastPathComponent == "canon-mg3600-letter-plain-v1.oqcal")
        // (A perfect digital page needs no correction, so the library itself would leave this one out.)
        let made = try Calibration.decode(Data(contentsOf: try #require(model.calibrationPath)))
        #expect(made.printer == "Canon_MG3600_series" && made.paper == "Letter plain" && made.settings.hasPrefix("macOS print panel"))
    }

    @Test func printsTheWizardPageStraightToThePrinter() async throws {
        let model = CalibrationWizardModel(folder: folder, paper: "Letter", scannerHost: "", starting: nil, startingName: nil,
                                           printers: ["Canon_MG3600_series"], printer: "Canon_MG3600_series", find: { [] })
        #expect(model.method == .direct)
        model.start()
        var command: [String] = []
        model.printDirect { command = $0; return (0, "request id is Canon_MG3600_series-30 (1 file(s))\n", "") }
        try await waitUntilIdle(model)
        #expect(model.printed && model.run?.current.job == "Canon_MG3600_series-30")
        #expect(command.prefix(3) == ["lp", "-d", "Canon_MG3600_series"] && command.contains("PageSize=Letter"))
        let settings = try model.run?.calibration().settings
        #expect(settings?.hasPrefix("default quality, straight to the printer (lp)") == true)
    }

    @Test func processCalibrationStart() throws {
        let model = ProcessWizardModel(folder: folder, scannerHost: "scanner.local", find: { [] })
        #expect(model.orderedColours == ["green", "orange"])
        model.colours = ["orange", "black", "green"]
        model.start()
        #expect(model.run?.colours == ["black", "green", "orange"] && model.result.contains("black over green over orange"))
        let request = try #require(try model.pageForPrinting())
        #expect(request.4 == "OpenQuad process chart: carbon-office-film v0")
        model.printed("printed elsewhere")
        #expect(model.printed && !model.measured)
        model.refine()
        #expect(model.error?.hasPrefix("Couldn't refine") == true)
        #expect(model.curvePath?.lastPathComponent == "carbon-office-film-black-v0.oqproc")
    }

    @Test func appOffersWizardsWithItsSettings() throws {
        let app = AppModel(settingsURL: folder.appendingPathComponent("settings.json"))
        let wizard = app.calibrationWizard()
        #expect(wizard.paper == app.session.paper && wizard.starting == nil)
        app.finishProcess(folder.appendingPathComponent("missing.oqproc"), scannerHost: "scanner.local")
        #expect(app.settings.scannerHost == "scanner.local" && app.error != nil)
    }
}
