// Darkroom marks in the Print and Negative tabs and saved setups, and the test sheets'
// preferred size and marks in the calibration wizards.

import Foundation
import OpenQuadCore
import Testing
@testable import OpenQuadUI

@MainActor
@Suite("Darkroom marks")
struct MarksTests {
    let folder: URL
    let photo: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("openquad-marks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        photo = folder.appendingPathComponent("ramp.tif")
        try ImageFiles.saveGrey(photo, GreyImage(width: 60, height: 40, pixels: (0..<2400).map { UInt16(($0 % 60) * 1110) },
                                                 dpi: (20, 20)))
    }

    func model(_ role: TabRole = .print) -> AppModel {
        AppModel(settingsURL: folder.appendingPathComponent("settings.json"),
                 setupsFolder: folder.appendingPathComponent("setups"), role: role)
    }

    @Test func printMarksAddAWhiteBorder() throws {
        let app = model()
        app.openPhoto(photo)
        app.setFit(false)
        let plain = try app.session.sizeInches()
        app.setGuide(true)
        app.setRegistration(true)
        let marked = try app.session.sizeInches()
        #expect(abs(marked.0 - plain.0 - 0.5) < 1e-9 && abs(marked.1 - plain.1 - 0.5) < 1e-9)
        let print = try app.session.renderPrint()
        #expect(print.width == 70 && print.height == 50)  // 0.25 in at 20 ppi each side
        #expect(try app.session.summary().contains("Darkroom marks: guide line and registration marks"))
    }

    @Test func negativeMarksStayInTheSafeEdgeAndAreSavedInSetups() throws {
        let app = model(.negative)
        app.openPhoto(photo)
        app.setFit(false)
        app.setNegativeColour("orange")
        let size = try app.session.sizeInches()
        app.setGuide(true)
        #expect(try app.session.sizeInches() == size)
        let negative = try app.session.renderPrint()
        #expect(negative.pixels.contains(0))  // black ink in an orange negative
        app.saveSetup(named: "Orange with a guide")
        #expect(app.currentSetup?.guide == true && app.currentSetup?.registration == false)
        app.setGuide(false)
        #expect(app.currentSetup == nil)
        app.applySetup(try #require(app.setups.first))
        #expect(app.session.guide && !app.session.registration)
    }

    @Test func testSheetsTakeAPreferredSizeAndMarks() throws {
        let app = model(.negative)
        let test = app.blockingTest()
        #expect(test.sheetSize == nil && test.scale == 1)
        let plain = test.sheet()
        test.sheetSize = (4, 6)
        test.guide = true
        let small = test.sheet()
        #expect(test.scale < 1 && small.width < plain.width)
        #expect(Double(max(small.width, small.height)) / 300 <= 6.01 && Double(min(small.width, small.height)) / 300 <= 4.01)
        test.sheetSize = (20, 30)  // never past Letter's margins
        let big = test.sheet()
        #expect(Double(big.width) / 300 <= 7.51 && Double(big.height) / 300 <= 10.01)

        // The size is remembered, and shared with the process charts.
        #expect(model(.negative).processWizard().sheetSize.map { [$0.0, $0.1] } == [20, 30])
        let wizard = ProcessWizardModel(folder: folder.appendingPathComponent("processes"), scannerHost: "")
        wizard.sheetSize = (4, 6)
        wizard.registration = true
        wizard.colours = ["green"]
        wizard.start()
        let run = try #require(wizard.run)
        #expect(run.size.map { [$0.0, $0.1] } == [4, 6] && run.registration && !run.guide)
        #expect(try run.scale() < 1)
        let resumed = try ProcessRun.resume(run.folder)
        #expect(resumed.size.map { [$0.0, $0.1] } == [4, 6] && resumed.registration)
    }

    @Test func processWizardPreviewsThePageAndKeepsAnEditedPrintNote() throws {
        let wizard = ProcessWizardModel(folder: folder.appendingPathComponent("processes"), scannerHost: "")
        #expect(wizard.printing.isEmpty)
        wizard.colours = ["green", "red"]
        let before = try #require(wizard.preview())
        wizard.sheetSize = (4, 6)
        let small = try #require(wizard.preview())
        #expect(small.width < before.width || small.height < before.height)
        #expect(Double(max(small.width, small.height)) / ProcessWizardModel.previewPPI <= 6.1)
        wizard.start()
        let run = try #require(wizard.run)
        let started = try #require(wizard.preview())
        #expect(started.width == small.width && started.height == small.height)
        wizard.printing = "Glossy film, Highest quality, 2400 x 1200 "
        wizard.savePrinting()
        #expect(run.printing == "Glossy film, Highest quality, 2400 x 1200")
        #expect(try ProcessRun.resume(run.folder).printing == run.printing)
    }

    @Test func processRunsCanBeContinuedOrAdjustedFurther() throws {
        let processes = folder.appendingPathComponent("processes")
        let first = ProcessWizardModel(folder: processes, scannerHost: "")
        first.colours = ["green", "red"]
        first.printing = "2400 x 1200"
        first.start()
        let run = try #require(first.run)
        var bent = ProcessCurve.identity(colour: "red")
        bent.curve = bent.curve.map { $0 / 2 }
        let file = folder.appendingPathComponent("red.oqproc")
        try bent.encode().write(to: file)

        let later = ProcessWizardModel(folder: processes, scannerHost: "")
        #expect(later.savedRuns.map(\.folder.lastPathComponent) == [run.folder.lastPathComponent])
        later.resume(run.folder)
        #expect(later.started && later.colours == ["green", "red"] && later.printing == "2400 x 1200")
        later.closeRun()
        #expect(!later.started)

        later.startFrom(files: [file])
        #expect(later.startingCurves["red"]?.curve == bent.curve && later.colours.contains("red"))
        later.name = "adjusted"
        later.start()
        #expect(try later.run?.curve("red").curve == bent.curve)
        #expect(try later.run?.curve("green").curve == ProcessCurve.identity(colour: "green").curve)

        let third = ProcessWizardModel(folder: processes, scannerHost: "")
        third.startFrom(run: try #require(later.run).folder)
        #expect(third.startingCurves["red"]?.curve == bent.curve && third.startingName?.hasPrefix("adjusted") == true)
    }
}
