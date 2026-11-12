// The tabbed window's model: each tab's own work, hand-offs between tabs, and keeping
// the open photos for next time.

import Foundation
import OpenQuadCore
import Testing
@testable import OpenQuadUI

@MainActor
@Suite("Tabs")
struct TabsTests {
    let folder: URL
    let photo: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("openquad-tabs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        photo = folder.appendingPathComponent("ramp.tif")
        try ImageFiles.saveGrey(photo, GreyImage(width: 60, height: 40, pixels: (0..<2400).map { UInt16(($0 % 60) * 1110) },
                                                 dpi: (300, 300)))
    }

    func root(tab: AppTab = .print, restore: Bool = true) -> AppRoot {
        let root = AppRoot(settingsURL: folder.appendingPathComponent("settings.json"), tab: tab, restoreWorkspace: restore)
        root.askOnQuit = false
        return root
    }

    @Test func eachTabKeepsItsOwnPhotoPrinterAndPaper() {
        let r = root()
        #expect(r.printModel.role == .print && !r.printModel.session.negative)
        #expect(r.negativeModel.role == .negative && r.negativeModel.session.negative)
        r.printModel.openPhoto(photo)
        r.printModel.setPrinter("Canon_MG3600_series")
        r.negativeModel.setPrinter("Epson_ET_2900")
        r.negativeModel.setPaper("A4")
        r.printModel.setPaper("Letter")
        #expect(r.negativeModel.session.photo == nil && r.printModel.session.photo != nil)
        let again = root()  // both remembered, neither overwriting the other
        #expect(again.printModel.session.printer == "Canon_MG3600_series" && again.printModel.session.paper == "Letter")
        #expect(again.negativeModel.session.printer == "Epson_ET_2900" && again.negativeModel.session.paper == "A4")
    }

    @Test func tabsAreRememberedAndSetUpWhenShown() {
        let r = root(tab: .print)
        #expect(r.calibration == nil && r.process == nil && r.blocking == nil)
        r.show(.processCalibration)
        #expect(r.process != nil && r.blocking != nil && r.processStep == .blocking)
        r.show(.printerCalibration)
        #expect(r.calibration != nil)
        #expect(UserDefaults.standard.string(forKey: AppRoot.tabKey) == "printer-calibration")
        let first = r.calibration
        r.newCalibration()
        #expect(r.calibration !== first)
        #expect(AppTab.allCases.map(\.title) == ["Print", "Negative", "Contact Sheet", "Printer Calibration", "Process Calibration"])
        #expect(AppTab.processCalibration.shortcut == "5")
    }

    @Test func unitsReachEveryTab() {
        let r = root()
        r.show(.processCalibration)
        r.setUnits(.millimetres)
        #expect(r.printModel.units == .millimetres && r.negativeModel.session.units == .millimetres)
        #expect(r.contactSheet.units == .millimetres && r.blocking?.units == .millimetres)
        r.setUnits(.inches)
    }

    @Test func blockingColourAndProcessCurveHandOff() throws {
        let r = root(tab: .processCalibration)
        r.useBlockingColour("orange", scannerHost: "")
        #expect(r.negativeModel.session.negativeColour == "orange")
        #expect(r.process?.colours == ["orange"] && r.process?.useColour == "orange" && r.processStep == .curve)
        #expect(r.notice?.contains("orange") == true)
        let curve = folder.appendingPathComponent("carbon.oqproc")
        try ProcessCurve.identity(colour: "orange").encode().write(to: curve)
        r.useProcess(curve, scannerHost: "")
        #expect(r.tab == .negative && r.negativeModel.session.processPath == curve)
        #expect(r.negativeModel.setupOffer != nil && r.notice?.contains("carbon.oqproc") == true)
        #expect(r.printModel.session.processPath == nil)  // the Print tab doesn't make negatives
    }

    @Test func printerCalibrationGoesToThePrintTabOnThatPrinter() throws {
        let r = root(tab: .printerCalibration)
        let levels: [UInt16] = [0, 32768, 65535]
        let calibration = try Calibration(levels: levels, curves: [[0, 30000, 65535], [0, 32768, 65535], [0, 34000, 65535]],
                                          printer: "Canon_MG3600_series", paper: "Letter plain")
        let path = folder.appendingPathComponent("calibrations/canon.oqcal")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try calibration.encode().write(to: path)
        r.printModel.setPrinter("Epson_ET_2900")
        r.useCalibration(path, scannerHost: "")
        #expect(r.tab == .print && r.printModel.session.calibrationPath == nil)
        #expect(r.notice?.contains("choose Canon MG3600") == true)
        r.printModel.setPrinter("Canon_MG3600_series")
        r.useCalibration(path, scannerHost: "")
        #expect(r.printModel.session.calibrationPath?.lastPathComponent == "canon.oqcal")
        #expect(r.notice?.hasPrefix("The Print tab now uses") == true)
    }

    @Test func contactSheetsOpenInTheChosenTab() async throws {
        let r = root(tab: .contactSheet)
        r.negativeModel.setSafeEdge(0.5)
        r.show(.contactSheet)
        #expect(r.contactSheet.size(for: .print) == (7.5, 10) && r.contactSheet.size(for: .negative) == (6.5, 9))
        r.contactSheet.add([photo, photo])
        for _ in 0..<3000 where r.contactSheet.busy { try await Task.sleep(for: .milliseconds(10)) }
        var made: URL?
        r.contactSheet.make(dpi: 20, for: .negative) { made = $0 }
        for _ in 0..<3000 where made == nil { try await Task.sleep(for: .milliseconds(10)) }
        r.useContactSheet(try #require(made), for: .negative)
        #expect(r.tab == .negative && r.negativeModel.session.photo?.width == 130 && r.printModel.session.photo == nil)
    }

    @Test func workIsKeptForNextTimeOnlyWhenAsked() async throws {
        let r = root()
        #expect(r.workspace.isEmpty)
        r.printModel.openPhoto(photo)
        r.negativeModel.openPhoto(photo)
        r.contactSheet.setLandscape(true)
        r.contactSheet.update { $0.background = .white; $0.wedge = true }
        r.contactSheet.add([photo])
        for _ in 0..<3000 where r.contactSheet.busy { try await Task.sleep(for: .milliseconds(10)) }
        try r.keepWorkspace()

        let next = root()
        #expect(next.printModel.session.source == photo && next.negativeModel.session.source == photo)
        for _ in 0..<3000 where next.contactSheet.busy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(next.contactSheet.entries.count == 1 && next.contactSheet.landscape)
        #expect(next.contactSheet.layout.background == .white && next.contactSheet.layout.wedge)
        #expect(root().printModel.session.photo == nil)  // reopened once; asked again at the next quit

        try r.keepWorkspace()
        r.forgetWorkspace()  // Start Fresh
        #expect(root().printModel.session.photo == nil)
        #expect(r.confirmQuit())  // not asking (tests): quits, keeping nothing
    }

    @Test func loadingEstimatesTheTimeLeft() {
        let start = Date(timeIntervalSince1970: 0)
        var loading = ContactSheetModel.Loading(done: 0, total: 12, started: start, current: "frame-01.tif")
        #expect(loading.description(now: start.addingTimeInterval(1)) == "Opening frame-01.tif (1 of 12)")
        loading.done = 3
        loading.current = "frame-04.tif"
        #expect(loading.secondsLeft(now: start.addingTimeInterval(6)) == 18)
        #expect(loading.description(now: start.addingTimeInterval(6)) == "Opening frame-04.tif (4 of 12) · about 18 s left")
        loading.done = 1
        #expect(loading.description(now: start.addingTimeInterval(30)).hasSuffix("about 6 min left"))
    }
}
