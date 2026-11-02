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

    @Test func blackOutlineGoesBetweenTheSafeEdgeAndThePhoto() throws {
        let m = model()
        m.openPhoto(photo)  // 60 x 40 px
        m.setMode(.negative)
        m.setFit(false)  // 300 ppi: 0.2 x 0.133 in
        m.setSafeEdge(0.25)
        let (plainWidth, _) = try m.session.sizeInches()
        m.setOutline(true)
        #expect(m.session.outline == 0.1)
        let (width, _) = try m.session.sizeInches()
        #expect(abs(width - plainWidth - 0.2) < 1e-9)
        #expect(m.summary.joined().contains("and a 0.1 in black outline"))
        m.setOutlineSize(0.3)
        #expect(m.session.outline == 0.3)
        m.setOutline(false)
        #expect(m.session.outline == 0 && !m.summary.joined().contains("black outline"))
        m.setOutline(true)
        #expect(m.session.outline == 0.3)  // the width comes back
        let negative = try m.session.renderPrint()
        #expect(negative.width == 60 + 2 * (90 + 75))  // 0.3 in outline + 0.25 in safe edge at 300 ppi
    }

    @Test func lengthsCanBeShownInMillimetresAndAreRemembered() throws {
        let m = model()
        #expect(m.units == .inches)
        m.openPhoto(photo)  // 60 x 40 px at 300 ppi
        m.setFit(false)
        m.setUnits(.millimetres)
        #expect(m.sizeDescription.hasPrefix("5.1 x 3.4 mm at 300 ppi"))
        m.setMode(.negative)
        m.setSafeEdge(LengthUnit.millimetres.toInches(5))
        #expect(m.summary.joined().contains("with a 5 mm safe edge"))
        #expect(model().units == .millimetres && model().session.units == .millimetres)
        m.setUnits(.inches)
        #expect(m.summary.joined().contains("with a 0.19685 in safe edge") && model().units == .inches)
    }

    @Test func negativeSetupsAreSavedAndSwitchedBetween() throws {
        let m = model()
        #expect(m.setups.isEmpty && m.currentSetup == nil)
        let curve = folder.appendingPathComponent("cyanotype-curve.oqproc")
        try ProcessCurve.identity(colour: "orange").encode().write(to: curve)
        m.openPhoto(photo)
        m.setMode(.negative)
        m.setProcess(curve)
        m.setMirror(true)
        m.setSafeEdge(0.3)
        m.setOutlineSize(0.05)
        m.setOutline(true)
        m.setPaper("A4")
        m.setPrinter("Epson_ET_2900")
        #expect(m.suggestedSetupName == "Carbon, orange, A4")
        m.saveSetup(named: "Cyanotype")
        #expect(m.error == nil && m.setups.map(\.name) == ["Cyanotype"] && m.currentSetup?.name == "Cyanotype")
        #expect(m.session.processPath?.lastPathComponent == "cyanotype.oqproc")  // the setup's own copy

        m.setProcess(nil)
        m.setNegativeColour("black")
        m.setMirror(false)
        m.setSafeEdge(0.25)
        m.setOutline(false)
        m.setPaper("Letter")
        m.setPrinter(nil)
        #expect(m.currentSetup == nil)
        m.saveSetup(named: "Carbon black")
        #expect(m.setups.map(\.name) == ["Carbon black", "Cyanotype"] && m.currentSetup?.name == "Carbon black")

        m.applySetup(m.setups[1])
        #expect(m.currentSetup?.name == "Cyanotype")
        #expect(m.session.negativeColour == "orange" && m.session.mirror && m.session.safeEdge == 0.3)
        #expect(m.session.outline == 0.05 && m.session.paper == "A4" && m.session.printer == "Epson_ET_2900")
        let again = model()  // a new window sees the same setups
        #expect(again.setups.count == 2)
        again.deleteSetup(again.setups[1])
        #expect(again.setups.map(\.name) == ["Carbon black"])
    }

    @Test func contactSheetFillsThePrintableRoomAndBecomesThePhoto() async throws {
        let m = model()
        #expect(m.printableRoom == (7.5, 10))  // Letter inside 0.5 in margins
        m.setMode(.negative)
        m.setSafeEdge(0.25)
        #expect(m.printableRoom == (7, 9.5))
        m.setMaxSize((4, 5))
        #expect(m.printableRoom == (3.5, 4.5))  // the tissue, less the safe edge
        m.setMaxSize(nil)

        let sheet = m.contactSheet()
        #expect(sheet.size == (7, 9.5) && sheet.entries.isEmpty && sheet.preview == nil)
        sheet.setLandscape(true)
        #expect(sheet.size == (9.5, 7) && sheet.layout.width == 9.5)
        let urls = (0..<3).map { folder.appendingPathComponent("p\($0).tif") }
        for (i, url) in urls.enumerated() {
            try ImageFiles.saveGrey(url, GreyImage(width: 30 + 10 * i, height: 20, pixels: Array(repeating: UInt16(20000 * i), count: (30 + 10 * i) * 20)))
        }
        sheet.add(urls + [folder.appendingPathComponent("missing.tif")])
        for _ in 0..<300 where sheet.busy || sheet.preview == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(sheet.entries.map(\.url.lastPathComponent) == ["p0.tif", "p1.tif", "p2.tif"] && sheet.error != nil)
        #expect(sheet.preview != nil)
        sheet.move(from: [2], to: 0)
        #expect(sheet.entries.first?.url.lastPathComponent == "p2.tif")
        sheet.remove(sheet.entries[1])
        #expect(sheet.entries.count == 2)
        sheet.add(Array(repeating: urls[0], count: 20))  // only 14 more fit
        for _ in 0..<300 where sheet.busy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(sheet.entries.count == 16 && !sheet.canAdd)

        var made: URL?
        sheet.make(dpi: 20) { made = $0 }
        for _ in 0..<300 where made == nil { try await Task.sleep(for: .milliseconds(10)) }
        let url = try #require(made)
        #expect(url.deletingLastPathComponent() == m.contactSheetFolder && url.lastPathComponent.hasPrefix("contact-sheet-"))
        m.useContactSheet(url)
        #expect(m.session.photo?.width == 140 && m.session.photo?.height == 190 && m.session.fit)  // turned to stand up
        let (width, height) = try m.session.sizeInches()  // fills the room, plus the safe edge
        #expect(abs(width - 7.5) < 1e-9 && abs(height - 10) < 1e-9)
    }

    @Test func bigPhotosAreShrunkForTheSheet() {
        let big = Photo(width: 4800, height: 100, pixels: Array(repeating: 1000, count: 4800 * 100), dpi: nil)
        let small = ContactSheetModel.shrunk(big)
        #expect(small.width == 2400 && small.height == 50 && small.pixels.count == 2400 * 50 && small.pixels[0] == 1000)
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
