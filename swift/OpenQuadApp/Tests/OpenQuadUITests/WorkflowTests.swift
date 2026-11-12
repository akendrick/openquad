// The process calibration wizard step by step, test sheets on the Negative tab's paper, the
// coats preview, and kept runs shown as soon as they change.

import CoreGraphics
import Foundation
import OpenQuadCore
import Testing
@testable import OpenQuadUI

/// A file from the core package's test vectors (real scans of prints).
func coreVector(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("OpenQuadCore/Tests/OpenQuadCoreTests/Vectors/\(name)")
}

@MainActor
@Suite("Workflow")
struct WorkflowTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("openquad-workflow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func root(_ tab: AppTab) -> AppRoot {
        AppRoot(settingsURL: folder.appendingPathComponent("settings.json"), tab: tab, restoreWorkspace: false)
    }

    @Test func theWizardGoesFromTheBlockingTestToACurve() async throws {
        let root = root(.processCalibration)
        let (blocking, process) = (try #require(root.blocking), try #require(root.process))
        #expect(root.guideStage == .blockingPrint)
        blocking.save(folder.appendingPathComponent("sheet.tif"))
        #expect(root.guideStage == .blockingScan)
        blocking.read(file: coreVector("blocking-print-1.png"))
        try await waitUntilIdle(blocking)
        #expect(blocking.error == nil, "\(blocking.error ?? "")")
        #expect(root.guideStage == .blockingChoose)
        let best = try #require(blocking.best)
        root.useBlockingColour(best, scannerHost: "")
        #expect(root.guideStage == .curveStart && process.colours == [best])
        // The chart page scan has green and orange charts: calibrate those two.
        process.colours = ["green", "orange"]
        process.name = "carbon-office"
        process.start()
        #expect(root.guideStage == .curvePrint && process.error == nil)
        process.printed("printed elsewhere")
        #expect(root.guideStage == .curveScan)
        process.scanAndRead(file: coreVector("chart-page.png"))
        try await waitUntilIdle(process)
        #expect(process.error == nil, "\(process.error ?? "")")
        #expect(root.guideStage == .curveResult && process.readings.count == 2)
        #expect(process.onTarget == process.run!.colours.allSatisfy { process.run!.results()[$0]?.done == true })
        process.refine()
        #expect(root.guideStage == .curvePrint && !process.onTarget)
    }

    @Test func theBlockingTestCanBeSkipped() throws {
        let root = root(.processCalibration)
        root.negativeModel.setNegativeColour("orange")
        root.skipBlocking()
        #expect(root.processStep == .curve && root.process?.colours == ["orange"] && root.guideStage == .curveStart)
    }

    @Test func theModeIsRemembered() {
        let root = root(.processCalibration)
        root.processMode = .advanced
        #expect(self.root(.print).processMode == .advanced)
        root.processMode = .wizard
        #expect(self.root(.print).processMode == .wizard)
    }

    @Test func testSheetsPrintOnTheNegativeTabsPaper() throws {
        let root = root(.negative)
        root.negativeModel.setPaper("A4")
        root.show(.processCalibration)
        let (blocking, process) = (try #require(root.blocking), try #require(root.process))
        #expect(blocking.paper == "A4" && blocking.printRequest().3 == "A4" && process.paper == "A4")
        process.colours = ["green"]
        process.start()
        #expect(try process.run?.paper == "A4" && process.pageForPrinting()?.3 == "A4")
        root.show(.negative)
        root.negativeModel.setPaper("Letter")
        root.show(.processCalibration)
        #expect(blocking.paper == "Letter" && process.paper == "A4")  // a started run keeps its paper
        #expect(process.savedRuns.count == 1)  // shown at once, not after the list is read again
    }

    @Test func theCoatsPreviewShowsEveryCoatInItsColour() async throws {
        let photo = folder.appendingPathComponent("ramp.tif")
        try ImageFiles.saveGrey(photo, GreyImage(width: 60, height: 10, pixels: (0..<600).map { UInt16(($0 % 60) * 1110) },
                                                 dpi: (300, 300)))
        let m = AppModel(settingsURL: folder.appendingPathComponent("settings.json"), role: .negative)
        m.openPhoto(photo)
        m.setNegativeCount(3)
        m.setShowCoats(true)
        #expect(m.showingCoats && m.previewCaption?.hasPrefix("All 3 coats together") == true)
        for _ in 0..<3000 where m.preview?.bitsPerPixel != 24 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(m.preview?.width == 60 && m.preview?.bitsPerPixel == 24)
        m.setNegativeCount(1)
        #expect(!m.showingCoats && m.previewCaption == nil)  // one negative: the negative itself

        // Paper white stays white; light tones show the first coat's colour (orange), the
        // darkest the last coat's (blue), each darker than the one before.
        let plan = try SeparationPlan.even(3)
        let image = try #require(CoatsPreview.image([65535, 60000, 30000, 0], width: 4, height: 1, plan: plan))
        let data = try #require(image.dataProvider?.data as Data?)
        let rgb = (0..<4).map { i in Array(data[(3 * i)..<(3 * i + 3)]).map(Int.init) }
        #expect(rgb[0] == [255, 255, 255])
        #expect(rgb[1][0] > rgb[1][2] && rgb[3][2] > rgb[3][0])  // orange, then blue
        #expect(rgb[2][1] > rgb[2][0] && rgb[2][1] > rgb[2][2])  // the middle tones: green
        #expect(rgb.map { $0.reduce(0, +) } == rgb.map { $0.reduce(0, +) }.sorted(by: >))
    }
}
