// Calibrating colour prints in the app: the wizard's colour rounds, then the Print tab
// printing through the profile. The "printer" is a perfect sRGB one: each page's own file
// is read back as its scan.

import Foundation
import OpenQuadCore
import Testing
@testable import OpenQuadUI

@MainActor
func waitUntilBuilt(_ model: WizardModel) async throws {
    for _ in 0..<12000 where model.busy { try await Task.sleep(for: .milliseconds(10)) }
}

@MainActor
@Suite("Colour calibration (app)")
struct ColourWizardTests {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("openquad-colour-wizard-\(UUID().uuidString)")
    var library: URL { base.appendingPathComponent("calibrations") }

    func wizard() -> CalibrationWizardModel {
        let model = CalibrationWizardModel(folder: library, paper: "Letter", scannerHost: "", starting: nil, startingName: nil,
                                           printers: ["Canon_MG3600_series"], printer: "Canon_MG3600_series", find: { [] })
        model.colourPPI = 60
        return model
    }

    @Test func roundsFromTargetToProfileThenPrintThroughIt() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let model = wizard()
        #expect(model.scannerModels.isEmpty && model.scannerModel == nil)
        model.kind = .colour
        model.method = .panel
        #expect(model.runName == "canon-mg3600-letter-plain-colour" && model.step == .setup)
        model.start()
        try await waitUntilBuilt(model)
        #expect(model.error == nil, "\(model.error ?? "")")
        #expect(model.step == .print && model.round == 1 && model.colourRounds.map(\.then) == ["To print"])
        let pages = try model.colourPagesForPrinting()
        #expect(pages.count == 1 && pages[0].3 == "Letter" && pages[0].4.hasPrefix("OpenQuad colour target"))
        #expect(abs(pages[0].1 - Double(pages[0].0.width) / 60) < 1e-9)
        model.colourPrinted("print panel")
        #expect(model.step == .scan && !model.canUse)

        let run = try #require(model.colourRun)
        model.scanColour(file: run.pagesToPrint[0])
        try await waitUntilBuilt(model)
        #expect(model.error == nil, "\(model.error ?? "")")
        #expect(model.profileSummary?.contains("255 patches measured") == true)
        #expect(model.step == .print && model.round == 2 && model.canUse)
        #expect(model.calibrationPath?.lastPathComponent == "canon-mg3600-letter-plain-colour-v0.icc")

        model.colourPrinted("print panel")
        let verify = try #require(model.colourRun?.pagesToPrint.first)
        model.scanColour(file: verify)
        try await waitUntilBuilt(model)
        #expect(model.error == nil, "\(model.error ?? "")")
        #expect(model.step == .result && model.verification?.passed == true)
        #expect(model.colourRounds.map(\.then) == ["Built v0", "Goals met"] && model.colourRounds[1].mean != nil)

        // Carried on later, in a new window.
        let again = wizard()
        let saved = try #require(again.savedRuns.first)
        #expect(saved.label.contains("colour: round 2"))
        again.resume(saved.folder)
        #expect(again.kind == .colour && again.step == .result && again.verification?.passed == true && again.paperType == "plain")
        #expect(again.profileSummary == model.profileSummary)
        again.refineColour()
        try await waitUntilBuilt(again)
        #expect(again.step == .print && again.round == 3 && again.colourRounds.map(\.then) == ["Built v0", "Refined", "To print"])

        // The Print tab: the profile is matched to the printer and the photo printed through it.
        let photo = base.appendingPathComponent("colour.tif")
        var pixels: [UInt16] = []
        for i in 0..<(30 * 20) {
            let step = UInt16(i % 30) * 2000
            pixels += [step, 30000, 60000 - step]
        }
        try ImageFiles.saveRGB(photo, RGBImage(width: 30, height: 20, pixels: pixels), dpi: (300, 300), iccProfile: ImageFiles.srgbProfile())
        let app = AppModel(settingsURL: base.appendingPathComponent("settings.json"), libraryFolder: library)
        app.openPhoto(photo)
        app.setColourPrint(true)
        #expect(app.currentColourProfile == nil && app.colourProfiles.count == 1)
        app.finishColourProfile(try #require(model.calibrationPath), scannerHost: "")
        #expect(app.currentColourProfile?.version == 0 && app.status?.hasPrefix("Colour prints now go through") == true)
        #expect(app.summary.contains { $0.hasPrefix("Output: colour print through the printer profile") })
        #expect(app.previewCaption?.hasPrefix("Soft-proof: through Canon MG3600 · Letter plain · v0") == true)
        #expect(app.session.printProfile() == ImageFiles.srgbProfile())
        let printed = try app.session.renderPrint()
        let gaps = zip(printed.pixels, pixels).map { abs(Int($0) - Int($1)) }
        // A perfect sRGB printer: nearly as it was (least so at the gamut's edge, as here at red 0).
        #expect(gaps.max()! < 6000 && Double(gaps.reduce(0, +)) / Double(gaps.count) < 1200, "worst \(gaps.max()!)")
        app.exportColourProfile(folder: base.appendingPathComponent("ColorSync"))
        #expect(app.status?.contains("canon-mg3600-letter-plain-colour v0.icc") == true, "\(app.status ?? "")")

        // Remembered, and matched to the printer when it's chosen.
        let later = AppModel(settingsURL: base.appendingPathComponent("settings.json"), libraryFolder: library)
        #expect(later.currentColourProfile?.version == 0)
        later.session.printer = "Epson_ET_2900"
        later.matchCalibration()
        #expect(later.currentColourProfile == nil)
        later.session.printer = "Canon_MG3600_series"
        later.matchCalibration()
        #expect(later.currentColourProfile?.version == 1)  // the newest
        later.setColourProfile(nil)
        #expect(later.session.colourProfilePath == nil && AppSettings.load(base.appendingPathComponent("settings.json")).colourProfile == nil)
    }

    @Test func aWrongScanIsThrownAwayAndAScannerModelCanBeAdded() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let model = wizard()
        let file = base.appendingPathComponent("flatbed.json")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let grid = linspace(0, 1, ScannerModel.curvePoints)
        try JSONSerialization.data(withJSONObject: ["kind": "matrix", "scanner": "Flatbed", "curves": [grid, grid, grid],
                                                    "coefficients": [[0.4, 0.2, 0.02], [0.35, 0.7, 0.1], [0.2, 0.08, 0.7], [0, 0, 0]]])
            .write(to: file)
        model.addScannerModel(file)
        #expect(model.scannerModels.map(\.name) == ["Flatbed (flatbed)"] && model.scannerModel != nil)
        model.addScannerModel(base.appendingPathComponent("missing.json"))
        #expect(model.error?.hasPrefix("Couldn't add the scanner model") == true)
        model.kind = .colour
        model.start()
        try await waitUntilBuilt(model)
        model.colourPrinted("print panel")
        // A scan with no target on it: measuring fails and the scan is dropped.
        let blank = base.appendingPathComponent("blank.tif")
        try ImageFiles.saveRGB(blank, RGBImage(width: 50, height: 60, pixels: [UInt16](repeating: 65535, count: 50 * 60 * 3)))
        model.scanColour(file: blank)
        try await waitUntilBuilt(model)
        #expect(model.error?.hasPrefix("Build failed") == true && model.colourRun?.scansSoFar.isEmpty == true)
        #expect(model.step == .scan)
    }
}
