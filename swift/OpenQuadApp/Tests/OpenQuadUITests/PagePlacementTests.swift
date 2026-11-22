// The Negative tab's page preview: the negative shown on its page, moved about inside the
// margins, and printed where it was put.

import Foundation
import OpenQuadCore
import Testing
@testable import OpenQuadUI

@MainActor
@Suite("Placing a negative on the page")
struct PagePlacementTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("openquad-page-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// A 3 x 4 in negative (photo at 100 ppi) with its 0.25 in safe edge: 3.5 x 4.5 in on Letter.
    func negativeModel() throws -> AppModel {
        let url = folder.appendingPathComponent("ramp.tif")
        let pixels = (0..<(300 * 400)).map { UInt16(($0 % 300) * 218) }
        try ImageFiles.saveGrey(url, GreyImage(width: 300, height: 400, pixels: pixels, dpi: (100, 100)))
        let m = AppModel(settingsURL: folder.appendingPathComponent("settings.json"))
        m.openPhoto(url)
        m.setMode(.negative)
        m.setFit(false)
        return m
    }

    @Test func thePageShowsTheNegativeWhereItPrints() throws {
        let m = try negativeModel()
        #expect(!m.showingPage && m.positionDescription == "Centred")
        m.setShowOnPage(true)
        #expect(m.showingPage && m.previewCaption?.hasPrefix("On the page") == true)
        let layout = try #require(m.pageLayout)
        #expect(layout.paper == (8.5, 11) && layout.margin == 0.5)
        #expect(layout.negative == CGRect(x: 2.5, y: 3.25, width: 3.5, height: 4.5))
        // The coats preview and the page take turns.
        m.setShowCoats(true)
        #expect(!m.showOnPage)
        m.setShowOnPage(true)
        #expect(!m.showCoats)
    }

    @Test func movingKeepsItInsideTheMargins() throws {
        let m = try negativeModel()
        m.setPlacement((1, 1.25))
        #expect(m.pageLayout?.negative.origin == CGPoint(x: 1, y: 1.25))
        #expect(m.positionDescription == "1 in from the left, 1.25 in from the top")
        #expect(m.summary.contains("Position: 1 in from the left, 1.25 in from the top"))
        m.setPlacement((-4, 40))  // dragged off the page: held at the margins, and kept there
        #expect(m.session.placement! == (0.5, 6.0))
        m.setPlacement((.nan, 1))
        #expect(m.error?.contains("not a position") == true && m.session.placement! == (0.5, 6.0))
        m.setPlacement(nil)
        #expect(m.positionDescription == "Centred" && m.error == nil)
    }

    @Test func aMovedNegativePrintsAsThePageInsideItsMargins() async throws {
        let m = try negativeModel()
        m.setPrinter(nil)
        m.setPlacement((4, 6))
        let (image, width, height, paper, _) = try #require(await m.printRequest())
        #expect(paper == "Letter" && image.width == 750 && image.height == 1000)
        #expect(width == 7.5 && height == 10)  // centred on Letter, so the negative lands at (4, 6)
        m.setPlacement(nil)
        let (alone, aloneWidth, _, _, _) = try #require(await m.printRequest())
        #expect(alone.width == 350 && aloneWidth == 3.5)
    }

    @Test func aNegativeTooBigToMoveSaysSo() throws {
        let m = try negativeModel()
        m.setPPI(40)  // 7.5 x 10 in and its safe edge: wider than the room inside the margins
        m.setPlacement((1, 1))
        #expect(m.positionDescription == "Centred (no room to move it)")
        m.setShowOnPage(true)
        #expect(m.previewCaption == "On the page: too big to move inside the margins")
    }

    @Test func aPrintIsPlacedOnItsPageToo() throws {
        let m = AppModel(settingsURL: folder.appendingPathComponent("settings.json"), role: .print)
        let photo = folder.appendingPathComponent("print.tif")
        try ImageFiles.saveGrey(photo, GreyImage(width: 300, height: 400, pixels: Array(repeating: 30000, count: 120_000), dpi: (100, 100)))
        m.openPhoto(photo)
        m.setFit(false)
        m.setShowOnPage(true)
        #expect(m.showingPage && m.pageLayout?.negative.size == CGSize(width: 3, height: 4))
        m.setPlacement((1, 1))
        #expect(m.positionDescription == "1 in from the left, 1 in from the top")
    }
}
