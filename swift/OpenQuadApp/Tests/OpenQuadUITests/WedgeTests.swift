// Step wedges beside the print or negative: chosen in the app, remembered for each tab.

import Foundation
import OpenQuadCore
import Testing
@testable import OpenQuadUI

@MainActor
@Suite("Step wedges")
struct WedgeTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("openquad-wedge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func model(_ role: TabRole = .print, colour: Bool = false) throws -> AppModel {
        let m = AppModel(settingsURL: folder.appendingPathComponent("settings.json"), role: role)
        let photo = folder.appendingPathComponent(colour ? "colour.tif" : "grey.tif")
        if colour {
            let pixels = [UInt16]((0..<1200).flatMap { _ -> [UInt16] in [60000, 20000, 10000] })
            try ImageFiles.saveRGB(photo, RGBImage(width: 30, height: 40, pixels: pixels), dpi: (100, 100))
        } else {
            try ImageFiles.saveGrey(photo, GreyImage(width: 30, height: 40, pixels: Array(repeating: 30000, count: 1200), dpi: (100, 100)))
        }
        m.openPhoto(photo)
        return m
    }

    @Test func aWedgeIsAddedAndRememberedForItsTab() throws {
        let m = try model()
        #expect(m.wedgeDescription == "none")
        let (width, height) = try m.session.sizeInches()
        m.setWedge(true)
        m.setWedgeSide("right")
        m.setWedgeGap(5)  // clamped to 2 in
        #expect(m.session.wedgeGap == Wedge.maxGap)
        #expect(m.wedgeDescription == "31 steps, on the right")
        let (wider, same) = try m.session.sizeInches()
        #expect(wider > width && abs(same - height) < 1e-9 || wider / same > width / height)

        m.setWedgeSteps(21)
        m.setWedgeWidth(3)  // clamped to 1 in
        m.setWedgeStyle("calibration")
        m.setWedgeLabels(true)
        m.setWedgeBackground("black")
        m.setWedgeBackground("grey")  // not a choice: kept as it was
        #expect(m.session.wedgeWidth == Wedge.maxWidth && m.wedgeDescription == "21 steps, on the right")

        let again = try model()  // a new launch: the wedge and its options come back
        #expect(again.session.wedge && again.session.wedgeSide == "right" && again.session.wedgeGap == Wedge.maxGap)
        #expect(again.session.wedgeSteps == 21 && again.session.wedgeWidth == 1 && again.session.wedgeStyle == "calibration")
        #expect(again.session.wedgeLabels && again.session.wedgeBackground == "black")

        let negative = try model(.negative)  // the Negative tab keeps its own
        #expect(!negative.session.wedge && negative.wedgeDescription == "none")
        let film = try model(.negative)  // made separately, a negative's wedge has its own safe edge
        film.setWedge(true)
        let (_, joined) = try film.session.sizeInches()
        film.setWedgeSeparate(true)
        #expect(try film.session.sizeInches().1 != joined || film.session.fit)
        #expect(try model(.negative).session.wedgeSeparate)
    }

    @Test func theColourWedgeIsOnlyForAColourPrint() throws {
        let m = try model(colour: true)
        m.setColourWedge(true)
        m.setColourPrint(false)
        #expect(m.session.wedgeKinds.isEmpty)  // a black and white print has no colour wedge
        m.setColourPrint(true)
        #expect(m.session.wedgeKinds == [.colour] && m.wedgeDescription == "colour, below")
        m.setWedge(true)
        #expect(m.wedgeDescription == "31 steps and colour, below")
    }
}
