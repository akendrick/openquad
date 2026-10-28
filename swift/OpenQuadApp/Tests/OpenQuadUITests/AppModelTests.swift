// The print window's model and the native print operation, without showing anything.

import AppKit
import Foundation
import OpenQuadCore
import Testing
@testable import OpenQuadUI

@MainActor
@Suite("Print window")
struct AppModelTests {
    let folder: URL
    let photo: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("openquad-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        photo = folder.appendingPathComponent("ramp.tif")
        let pixels = (0..<(60 * 40)).map { UInt16(($0 % 60) * 1110) }
        try ImageFiles.saveGrey(photo, GreyImage(width: 60, height: 40, pixels: pixels, dpi: (300, 300)))
    }

    func model() -> AppModel { AppModel(settingsURL: folder.appendingPathComponent("settings.json")) }

    @Test func startsNeutralAndNeverRemembersToning() throws {
        let first = model()
        #expect(first.session.preset == "neutral")
        first.openPhoto(photo)
        first.setPreset("black-red")
        first.setPaper("4x6")
        let again = model()
        #expect(again.session.preset == "neutral")
        #expect(again.session.paper == "4x6")
        #expect(again.settings.lastFolder == folder.path)
        let text = try String(contentsOf: folder.appendingPathComponent("settings.json"), encoding: .utf8)
        #expect(!text.contains("black-red"))
    }

    @Test func describesThePhotoAndTheSize() async throws {
        let m = model()
        #expect(m.photoDescription == "No photo open" && !m.canPrint)
        m.openPhoto(photo)
        #expect(m.photoDescription.hasPrefix("ramp.tif: 60 x 40 px, 300 ppi"))
        #expect(m.sizeDescription.hasPrefix("7.50 x 5.00 in at 8 ppi"))
        m.setFit(false)
        #expect(m.sizeDescription.hasPrefix("0.20 x 0.13 in at 300 ppi"))
        #expect(m.canPrint)
        for _ in 0..<200 where m.preview == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(m.preview?.width == 60)
    }

    @Test func maxSizeFitsTheNegativeToTheTissueAndIsRemembered() throws {
        let m = model()
        m.openPhoto(photo)  // 60 x 40 px, landscape
        m.setMode(.negative)
        m.setMaxSize((2, 3))  // turned to 3 x 2 in for a landscape photo
        let (width, height) = try m.session.sizeInches()  // height limits: 2 in tall, 2.75 in wide
        #expect(abs(height - 2) < 1e-9 && width <= 3 + 1e-9 && abs(width - 2.75) < 1e-9)
        #expect(m.summary.contains("Fit within: 3 x 2 in"))
        m.setMaxSize((0, 3))  // not a size: ignored
        #expect(m.session.maxSize?.0 == 2)
        let again = model()
        #expect(again.session.maxSize?.0 == 2 && again.session.maxSize?.1 == 3 && again.rememberedMaxSize.1 == 3)
        again.setMaxSize(nil)
        #expect(again.session.maxSize == nil && model().session.maxSize == nil && again.rememberedMaxSize == (8, 10))
    }

    @Test func negativesAndErrors() throws {
        let m = model()
        m.openPhoto(photo)
        m.setMode(.negative)
        m.setNegativeColour("orange")
        m.setMirror(true)
        #expect(m.summary.contains("Output: digital negative") && m.summary.contains("Mirrored: yes"))
        m.openPhoto(folder.appendingPathComponent("missing.tif"))
        #expect(m.error != nil)
    }

    @Test func printOperationIsAtRealSize() async throws {
        let m = model()
        m.openPhoto(photo)
        m.setFit(false)
        m.setPPI(20)  // 3 x 2 in
        let request = try #require(await m.printRequest())
        #expect(request.0.width == 60 && request.1 == 3 && request.2 == 2 && request.3 == "Letter")
        let operation = try #require(NativePrint.operation(for: request.0, widthInches: request.1, heightInches: request.2,
                                                           paper: request.3, title: request.4))
        #expect(operation.view?.frame.size == NSSize(width: 216, height: 144))
        let paper = operation.printInfo.paperSize  // snapped to the printer's own Letter size
        #expect(abs(paper.width - 612) < 0.01 && abs(paper.height - 792) < 0.01)
        #expect(operation.printInfo.horizontalPagination == .clip && operation.printInfo.isHorizontallyCentered)
        #expect(operation.jobTitle == "OpenQuad: ramp.tif")
    }

    @Test func savesTheFullResolutionPrintFile() async throws {
        let m = model()
        m.openPhoto(photo)
        let out = folder.appendingPathComponent("out.tif")
        await m.savePrintFile(out)
        #expect(m.error == nil)
        let saved = try Scan.load(out)
        let expected = try m.session.renderPrint().pixels
        #expect(saved.width == 60 && saved.samples == expected)
    }
}
