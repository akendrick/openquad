// The Negative tab's colour separations: switching between tones and colours, the coats and
// their pigments, the saturation, the print preview, and setups that keep them.

import Foundation
import OpenQuadCore
import Testing
@testable import OpenQuadUI

@MainActor
@Suite("Colour separations")
struct ColourSeparationTests {
    let folder: URL
    let photo: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("openquad-colour-seps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        photo = folder.appendingPathComponent("colour.tif")
        var pixels = [UInt16]()
        for y in 0..<40 {
            for x in 0..<60 { pixels += [UInt16(x * 1110), UInt16(y * 1680), 30000] }
        }
        try ImageFiles.saveRGB(photo, RGBImage(width: 60, height: 40, pixels: pixels), dpi: (300, 300),
                               iccProfile: ImageFiles.srgbProfile())
    }

    func negativeModel() -> AppModel {
        let m = AppModel(settingsURL: folder.appendingPathComponent("settings.json"),
                         setupsFolder: folder.appendingPathComponent("setups"))
        m.openPhoto(photo)
        m.setMode(.negative)
        return m
    }

    /// Wait for the colour separation to be worked out and in the session.
    func settled(_ m: AppModel) async throws {
        func done() -> Bool {
            guard let separation = m.session.colourSeparation else { return false }
            return !m.separatingColours && separation.coats == m.colourCoats && separation.saturation == m.colourSaturation
        }
        for _ in 0..<3000 where !done() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(done())
    }

    @Test func colourSplitsByPigmentAndBackToTones() async throws {
        let m = negativeModel()
        m.setNegativeCount(3)
        m.setSeparationKind(.colours)
        try await settled(m)
        #expect(m.session.separation == nil && m.session.negativeCount == 3)
        #expect(m.summary.contains("Colour separation: 3 coats (#224A8C, #B0306A, #F2C230), saturation 1"))
        // Back to tones: the bands as they were.
        m.setSeparationKind(.tones)
        #expect(m.session.colourSeparation == nil && m.session.negativeCount == 3 && m.separationSplits == [10, 20])
    }

    @Test func coatsCanBeChangedAddedAndRemoved() async throws {
        let m = negativeModel()
        m.setSeparationKind(.colours)
        try await settled(m)
        m.setCoat(1, ColourSeparation.pigment("Burnt sienna")!)
        #expect(m.pigmentName(m.colourCoats[1]) == "Burnt sienna")
        m.addCoat()
        #expect(m.colourCoats.count == 4 && m.pigmentName(m.colourCoats[3]) == "Quinacridone magenta")
        m.addCoat()  // four at most
        #expect(m.colourCoats.count == 4)
        try await settled(m)
        #expect(m.session.negativeCount == 4)
        // A removed coat takes its own curve with it; the later coats' curves move up.
        let curve = folder.appendingPathComponent("yellow.oqproc")
        try ProcessCurve.identity(colour: "green").encode().write(to: curve)
        m.setLayerProcess(2, curve)
        m.setLayer(3)
        m.removeCoat(0)
        try await settled(m)
        #expect(m.colourCoats.count == 3 && m.session.layer == 2)
        #expect(m.session.layerProcessPaths.keys.sorted() == [1])
        m.removeCoat(0)
        m.removeCoat(0)  // two at least
        try await settled(m)
        #expect(m.colourCoats.count == 2 && m.pigmentName(m.colourCoats[0]) == "Hansa yellow")
        #expect(m.pigmentName(.init(1, 2, 3)) == nil)
    }

    @Test func aNegativeChosenWhileTheSplitIsWorkedOutIsShownAfter() async throws {
        let m = negativeModel()
        m.setSeparationKind(.colours)
        m.setLayer(2)
        try await settled(m)
        #expect(m.session.layer == 2 && m.error == nil)
    }

    @Test func aPaleCoatIsRefused() async throws {
        let m = negativeModel()
        m.setSeparationKind(.colours)
        try await settled(m)
        m.setCoat(0, .init(255, 255, 255))
        #expect(m.error?.contains("too pale") == true)
        #expect(m.session.colourSeparation?.coats[0] == ColourSeparation.pigment("Cyanotype blue"))
    }

    @Test func saturationIsKeptWithinRange() async throws {
        let m = negativeModel()
        m.setSeparationKind(.colours)
        m.setColourSaturation(1.63)
        #expect(m.colourSaturation == 1.65)
        m.setColourSaturation(5)
        #expect(m.colourSaturation == 2)
        m.setColourSaturation(-1)
        #expect(m.colourSaturation == 0)
        try await settled(m)
        #expect(m.session.colourSeparation?.saturation == 0)
    }

    @Test func thePreviewShowsTheCoatsAsTheyPrint() async throws {
        let m = negativeModel()
        m.setSeparationKind(.colours)
        try await settled(m)
        let negative = m.preview
        m.setShowCoats(true)
        #expect(m.showingCoats)
        #expect(m.previewCaption == "All 3 coats together, in their pigments' colours (prints one negative at a time)")
        for _ in 0..<3000 where m.preview == nil || m.preview === negative { try await Task.sleep(for: .milliseconds(10)) }
        let image = try #require(m.preview)
        #expect(image.width == 60 && image.height == 40)  // the photo alone, no safe edge
    }

    @Test func aSetupKeepsTheColourSeparationAndItsCurves() async throws {
        let m = negativeModel()
        let curve = folder.appendingPathComponent("magenta.oqproc")
        try ProcessCurve.identity(colour: "green").encode().write(to: curve)
        m.setRegistration(true)
        m.setSeparationKind(.colours)
        m.setColourSaturation(1.5)
        try await settled(m)
        m.setLayerProcess(1, curve)
        m.saveSetup(named: "Tricolour gum")
        #expect(m.error == nil && m.currentSetup?.name == "Tricolour gum")
        #expect(m.session.layerProcessPaths[1]?.lastPathComponent == "tricolour-gum.neg2.oqproc")
        // Back to one negative by tone: no longer the setup; choosing it brings the colours back at once.
        m.setSeparationKind(.tones)
        m.setNegativeCount(1)
        #expect(m.currentSetup == nil)
        m.applySetup(m.setups[0])
        #expect(m.separationKind == .colours && m.colourSaturation == 1.5 && m.session.negativeCount == 3)
        #expect(m.session.layerProcessPaths.keys.sorted() == [1])
        #expect(m.currentSetup?.name == "Tricolour gum" && m.error == nil)
        m.setColourSaturation(1)
        #expect(m.currentSetup == nil)
    }

    @Test func allTheNegativesAreSaved() async throws {
        let m = negativeModel()
        m.setSeparationKind(.colours)
        try await settled(m)
        let out = folder.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        await m.saveSeparations(to: out)
        let names = try FileManager.default.contentsOfDirectory(atPath: out.path).sorted()
        #expect(names == ["colour-1of3.tif", "colour-2of3.tif", "colour-3of3.tif"])
    }
}
