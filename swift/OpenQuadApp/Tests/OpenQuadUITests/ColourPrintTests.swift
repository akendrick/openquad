// Printing a colour photo in colour: the Print tab's option, the soft-proof preview and the
// print panel's colour-managed image.

import AppKit
import Foundation
import OpenQuadCore
import Testing
@testable import OpenQuadUI

@MainActor
@Suite("Colour prints")
struct ColourPrintTests {
    let folder: URL
    let photo: URL
    let profile: Data
    static let cmyk = URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/Generic CMYK Profile.icc")

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("openquad-colour-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        photo = folder.appendingPathComponent("colour.tif")
        profile = try Data(contentsOf: URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/Display P3.icc"))
        // Saturated red to blue, which a CMYK press can't reach.
        let pixels = (0..<(60 * 40)).flatMap { i -> [UInt16] in
            let t = UInt16((i % 60) * 1110)
            return [65535 - t, 0, t]
        }
        try ImageFiles.saveRGB(photo, RGBImage(width: 60, height: 40, pixels: pixels), dpi: (300, 300), iccProfile: profile)
    }

    func model(role: TabRole = .print) -> AppModel {
        AppModel(settingsURL: folder.appendingPathComponent("settings.json"), role: role)
    }

    func waitForPreview(_ m: AppModel, change from: CGImage? = nil) async throws {
        for _ in 0..<300 where m.preview == nil || m.preview === from { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func offerColourOnlyForAColourPhotoOnThePrintTab() throws {
        let m = model()
        #expect(!m.canPrintColour)
        m.openPhoto(photo)
        #expect(m.canPrintColour && !m.session.colourPrint)  // greyscale by default
        #expect(m.previewCaption == nil)
        m.setColourPrint(true)
        #expect(m.session.printsColour && m.error == nil)
        #expect(m.summary.contains("Output: colour print (colour-managed by macOS)"))
        #expect(m.summary.contains("Colour profile: embedded in the photo"))
        #expect(!m.summary.contains { $0.hasPrefix("Toning") })
        #expect(m.previewCaption == "Colour print: the photo's own colours, colour-managed by macOS")

        let negative = model(role: .negative)
        negative.openPhoto(photo)
        #expect(!negative.canPrintColour)
        let grey = folder.appendingPathComponent("grey.tif")
        try ImageFiles.saveGrey(grey, GreyImage(width: 4, height: 4, pixels: [UInt16](repeating: 30000, count: 16)))
        m.openPhoto(grey)
        #expect(!m.canPrintColour && !m.session.colourPrint)
        m.setColourPrint(true)
        #expect(m.error == "only a colour photo can be printed in colour")
    }

    @Test func previewIsInTheProfileAndSoftProofed() async throws {
        let m = model()
        m.openPhoto(photo)
        m.setColourPrint(true)
        try await waitForPreview(m)
        let plain = try #require(m.preview)
        #expect(plain.colorSpace?.copyICCData() as Data? == profile)  // shown in its own colours

        m.setProofProfile(Self.cmyk)
        #expect(m.previewCaption?.hasPrefix("Soft-proof: ") == true)
        try await waitForPreview(m, change: plain)
        let proofed = try #require(m.preview)
        #expect(proofed.colorSpace?.model == .cmyk)
        #expect(model().proofProfile == Self.cmyk)  // remembered
        m.setColourPrint(false)
        try await waitForPreview(m, change: proofed)
        #expect(m.preview?.colorSpace?.model == .rgb)  // greyscale prints are never proofed
    }

    @Test func softProofFindsOutputProfiles() throws {
        let profiles = folder.appendingPathComponent("Profiles/Vendor", isDirectory: true)
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        func header(_ kind: String, _ space: String) -> Data { Data(count: 12) + Data(kind.utf8) + Data(space.utf8) + Data(count: 108) }
        try header("prtr", "RGB ").write(to: profiles.appendingPathComponent("Glossy Paper.icc"))
        try header("mntr", "RGB ").write(to: profiles.appendingPathComponent("Screen.icc"))
        try header("prtr", "GRAY").write(to: profiles.appendingPathComponent("Grey.icm"))
        try Data("short".utf8).write(to: profiles.appendingPathComponent("Broken.icc"))
        try header("prtr", "CMYK").write(to: profiles.appendingPathComponent("Press.txt"))
        let found = SoftProof.profiles(in: [folder.appendingPathComponent("Profiles"), folder.appendingPathComponent("missing")])
        #expect(found.map(\.name) == ["Glossy Paper"])  // named from the file: no description in it
        #expect(SoftProof.proof(try #require(CGImage.solid()), with: profiles.appendingPathComponent("Glossy Paper.icc")) == nil)
        #expect(SoftProof.profiles(in: [Self.cmyk.deletingLastPathComponent()]).contains { $0.url == Self.cmyk })
    }

    @Test func printPanelImageCarriesThePhotosProfile() async throws {
        let m = model()
        m.openPhoto(photo)
        m.setColourPrint(true)
        let (image, width, height, paper, title) = try #require(await m.printRequest())
        #expect(image.pixels == m.session.photo?.colour)
        let operation = try #require(NativePrint.operation(for: image, widthInches: width, heightInches: height, paper: paper,
                                                           title: title, iccProfile: m.session.printProfile()))
        let view = try #require(operation.view as? PrintImageView)
        #expect(view.image.colorSpace?.copyICCData() as Data? == profile)
    }
}

extension CGImage {
    /// A one-pixel sRGB image.
    static func solid() -> CGImage? {
        RGBImage(width: 1, height: 1, pixels: [65535, 0, 0]).cgImage(eightBit: true)
    }
}
