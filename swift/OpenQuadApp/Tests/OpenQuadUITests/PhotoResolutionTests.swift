// The sidebar's "Photo's own" line: the resolution saved in the photo, shown as soon as it's open.

import Foundation
import OpenQuadCore
import Testing
@testable import OpenQuadUI

@MainActor
@Suite("The photo's own resolution")
struct PhotoResolutionTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("openquad-ppi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func model(dpi: (Double, Double)?) throws -> AppModel {
        let url = folder.appendingPathComponent("ramp.tif")
        try ImageFiles.saveGrey(url, GreyImage(width: 300, height: 400, pixels: Array(repeating: 30000, count: 300 * 400), dpi: dpi))
        let m = AppModel(settingsURL: folder.appendingPathComponent("settings.json"))
        #expect(m.photoResolutionDescription == nil)  // nothing open yet
        m.openPhoto(url)
        return m
    }

    @Test func itShowsThePhotosResolutionAndTheSizeItMakes() throws {
        let m = try model(dpi: (100, 100))
        #expect(m.photoResolutionDescription == "100 ppi (3.00 x 4.00 in)")
        m.setUnits(.millimetres)
        #expect(m.photoResolutionDescription == "100 ppi (76.2 x 101.6 mm)")
    }

    @Test func aPhotoWithNoResolutionSaysWhatIsUsed() throws {
        let m = try model(dpi: nil)
        #expect(m.photoResolutionDescription == "none set (300 ppi is used)")
    }
}
