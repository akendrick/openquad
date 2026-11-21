// The page turned on its side: chosen under Printer and size, remembered for each tab, and
// sent to the print panel turned to match.

import AppKit
import Foundation
import OpenQuadCore
import Testing
@testable import OpenQuadUI

@MainActor
@Suite("Orientation")
struct OrientationTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("openquad-orientation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func model(_ role: TabRole = .print) throws -> AppModel {
        let m = AppModel(settingsURL: folder.appendingPathComponent("settings.json"), role: role)
        let photo = folder.appendingPathComponent("wide.tif")  // 40 x 30 px: wider than tall
        try ImageFiles.saveGrey(photo, GreyImage(width: 40, height: 30, pixels: Array(repeating: 30000, count: 1200), dpi: (100, 100)))
        m.openPhoto(photo)
        return m
    }

    @Test func landscapeTurnsThePageAndIsRememberedForItsTab() throws {
        let m = try model()
        let (portraitWidth, _) = try m.session.sizeInches()
        #expect(abs(portraitWidth - 7.5) < 1e-9)  // Letter's 7.5 in across limits a wide photo
        m.setLandscape(true)
        let (width, _) = try m.session.sizeInches()
        #expect(width > portraitWidth)
        let page = try #require(m.pageLayout).paper
        #expect(page == (11, 8.5))
        #expect(m.summary.contains("Paper: Letter, landscape"))

        let again = try model()  // a new launch: it comes back
        #expect(again.session.landscape)
        let negative = try model(.negative)  // the Negative tab keeps its own
        #expect(!negative.session.landscape)
    }

    @Test func thePrintPanelGetsTheTurnedPage() throws {
        let image = RGBImage(width: 10, height: 7, pixels: Array(repeating: 65535, count: 210))
        let operation = try #require(NativePrint.operation(for: image, widthInches: 10, heightInches: 7, paper: "Letter",
                                                           landscape: true, title: "test"))
        #expect(operation.printInfo.orientation == .landscape)
        #expect(operation.printInfo.paperSize.width > operation.printInfo.paperSize.height)
    }
}
