// The Negative tab's separations: splitting into negatives, moving the splits, the step
// scale, the overlap, which negative prints, and saving them all.

import Foundation
import OpenQuadCore
import Testing
@testable import OpenQuadUI

@MainActor
@Suite("Separations")
struct SeparationTests {
    let folder: URL
    let photo: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("openquad-seps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        photo = folder.appendingPathComponent("ramp.tif")
        let pixels = (0..<(60 * 40)).map { UInt16(($0 % 60) * 1110) }
        try ImageFiles.saveGrey(photo, GreyImage(width: 60, height: 40, pixels: pixels, dpi: (300, 300)))
    }

    func negativeModel() -> AppModel {
        let m = AppModel(settingsURL: folder.appendingPathComponent("settings.json"))
        m.openPhoto(photo)
        m.setMode(.negative)
        return m
    }

    @Test func evenBandsOnTheStepScale() {
        let m = negativeModel()
        #expect(m.session.negativeCount == 1 && m.session.separation == nil)
        m.setNegativeCount(3)
        #expect(m.separationSplits == [10, 20] && m.session.negativeCount == 3)
        #expect(m.summary.contains("Separation: 3 negatives, split at steps 10 and 20 of 30"))
        m.setNegativeCount(4)
        #expect(m.separationSplits == [8, 15, 23])  // 7.5 and 22.5 round up
        m.setNegativeCount(1)
        #expect(m.session.separation == nil && m.separationSplits.isEmpty)
        m.setNegativeCount(9)
        #expect(m.session.negativeCount == SeparationPlan.maxNegatives)
    }

    @Test func splitsStayBetweenTheirNeighbours() {
        let m = negativeModel()
        m.setNegativeCount(3)
        m.setSplit(0, step: 25)
        #expect(m.separationSplits == [19, 20])
        m.setSplit(1, step: 40)
        #expect(m.separationSplits == [19, 29])
        m.setSplit(0, step: 0)
        #expect(m.separationSplits == [1, 29])
        m.setSplit(5, step: 3)  // no such split: ignored
        #expect(m.separationSplits == [1, 29])
    }

    @Test func rescalingTheStepsKeepsTheSplitsInPlace() {
        let m = negativeModel()
        m.setNegativeCount(3)
        m.setSeparationOverlap(2)
        m.setSeparationSteps(21)
        #expect(m.separationSteps == 21 && m.separationSplits == [7, 14] && m.separationOverlap == 1.5)
        m.setSeparationSteps(3)  // as small as three negatives allow
        #expect(m.separationSplits == [1, 2] && m.separationOverlap == 0)
        #expect(AppModel.spread([3, 3, 3], steps: 10) == [3, 4, 5])
        #expect(AppModel.spread([9, 9], steps: 10) == [8, 9])
    }

    @Test func overlapIsLimitedToTheNarrowestBand() {
        let m = negativeModel()
        m.setNegativeCount(3)
        m.setSplit(0, step: 4)
        #expect(m.narrowestBand == 4)
        m.setSeparationOverlap(10)
        #expect(m.separationOverlap == 4)
        m.setSplit(0, step: 2)  // a narrower band pulls the overlap in
        #expect(m.separationOverlap == 2 && m.error == nil)
        #expect(m.summary.contains("Separation: 3 negatives, split at steps 2 and 20 of 30, overlap 2 steps"))
    }

    @Test func theShownNegativeIsPrintedAndAllCanBeSaved() async throws {
        let m = negativeModel()
        m.setRegistration(true)
        m.setNegativeCount(3)
        m.setLayer(2)
        #expect(m.summary.contains("This negative: 3 of 3 (steps 20-30, then full strength)"))
        #expect(m.session.jobTitle == "OpenQuad: ramp.tif (negative 3 of 3)")
        m.setLayer(5)  // no such negative
        #expect(m.error != nil && m.session.layer == 2)
        let curve = folder.appendingPathComponent("deep.oqproc")
        try ProcessCurve.identity(colour: "green").encode().write(to: curve)
        m.setLayerProcess(2, curve)
        #expect(m.summary.contains("Process curve: deep.oqproc") && m.summary.contains("Colour: green"))
        m.setLayerProcess(2, nil)
        #expect(m.session.layerProcessPaths.isEmpty)
        await m.saveSeparations(to: folder)
        #expect(m.error == nil)
        for k in 1...3 { #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("ramp-\(k)of3.tif").path)) }
        #expect(m.status?.hasPrefix("Saved ramp-1of3.tif") == true)
    }

    @Test func theStepTestBecomesThePhoto() throws {
        let m = negativeModel()
        let before = m.settings.lastFolder
        m.setNegativeCount(3)
        m.setSeparationSteps(21)
        m.openStepTest()
        #expect(m.error == nil)
        #expect(m.session.source?.lastPathComponent == "step-test-21.tif")
        #expect(m.session.photo?.width == 22 * 95 + 90)  // 7 in across 22 patches at 300 dpi, in a 0.15 in frame
        #expect(m.settings.lastFolder == before)
        #expect(m.summary.contains("Photo: step-test-21.tif"))
    }

    @Test func readingTheCoatsChartBuildsAndUsesTheNextCoatsCurve() async throws {
        let m = negativeModel()
        m.setRegistration(true)
        m.setNegativeCount(3)
        m.openCoatsChart()
        #expect(m.session.source?.lastPathComponent == "coats-chart.tif" && m.error == nil)
        // The chart photo itself stands in for a perfect print of it, on paper as scanned.
        let scan = folder.appendingPathComponent("scan.tif")
        let chart = Chart.photo(dpi: 100), margin = 40, width = chart.width + 2 * margin
        var pixels = [UInt16](repeating: 59000, count: width * (chart.height + 2 * margin))
        for y in 0..<chart.height {
            pixels.replaceSubrange(((y + margin) * width + margin)..<((y + margin) * width + margin + chart.width),
                                   with: chart.pixels[(y * chart.width)..<((y + 1) * chart.width)])
        }
        try ImageFiles.saveGrey(scan, GreyImage(width: width, height: chart.height + 2 * margin, pixels: pixels, dpi: (100, 100)))
        await m.readCoatsScan(scan)
        #expect(m.error == nil, "\(m.error ?? "")")
        #expect(m.session.coatsCurvePath?.lastPathComponent == "coats-1.oqproc")
        #expect(m.status?.hasPrefix("Read the chart:") == true)
        #expect(m.summary.contains("Coats curve: coats-1.oqproc"))
        await m.readCoatsScan(scan)  // the next round builds on the curve in use
        #expect(m.session.coatsCurvePath?.lastPathComponent == "coats-2.oqproc")
        m.setCoatsCurve(nil)
        #expect(m.session.coatsCurve == nil)
        await m.readCoatsScan(folder.appendingPathComponent("missing.tif"))
        #expect(m.error != nil)
    }

    @Test func curvesAlreadyInOpenQuadAreOffered() throws {
        let m = AppModel(settingsURL: folder.appendingPathComponent("settings.json"),
                         setupsFolder: folder.appendingPathComponent("setups"))
        #expect(m.knownCurves.isEmpty)
        let curve = folder.appendingPathComponent("carbon.oqproc")
        try ProcessCurve.identity(colour: "black").encode().write(to: curve)
        m.setMode(.negative)
        m.setProcess(curve)
        m.saveSetup(named: "Carbon on Pictorico")
        let run = try ProcessRun.start(folder: folder.appendingPathComponent("processes/cyanotype"), name: "Cyanotype",
                                       colours: ["green", "red"])
        let seps = folder.appendingPathComponent("separations")
        try FileManager.default.createDirectory(at: seps, withIntermediateDirectories: true)
        for n in [10, 2] { try ProcessCurve.identity(colour: "black").encode().write(to: seps.appendingPathComponent("coats-\(n).oqproc")) }
        let curves = m.knownCurves
        #expect(curves.map(\.group) == ["Setups", "Process calibrations", "Process calibrations", "Coats curves", "Coats curves"])
        #expect(curves.map(\.label) == ["Carbon on Pictorico", "Cyanotype, green: round 0", "Cyanotype, red: round 0",
                                         "coats-2", "coats-10"])
        #expect(curves[1].url.resolvingSymlinksInPath() == run.curvePath("green").resolvingSymlinksInPath())
        m.setNegativeCount(2)
        m.setLayerProcess(1, curves[2].url)  // a calibration's curve is usable straight from the menu
        #expect(m.session.layerProcessPaths[1] == curves[2].url && m.error == nil)
    }
}
