// Opening JPEG 2000 and GIMP XCF photos in the app: the Open dialog offers them, a JPEG 2000
// opens at once, and an XCF opens through GIMP off the main thread.

import Foundation
import OpenQuadCore
import Testing
import UniformTypeIdentifiers
@testable import OpenQuadUI

@MainActor
@Suite("Photo formats", .serialized)
struct PhotoFormatsTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("openquad-formats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func model() -> AppModel {
        AppModel(settingsURL: folder.appendingPathComponent("settings.json"),
                 setupsFolder: folder.appendingPathComponent("setups"))
    }

    /// A 16-bit colour photo as a TIFF, and a JPEG 2000 of the same pixels (lossless).
    func tiff() throws -> URL {
        let url = folder.appendingPathComponent("colour.tif")
        var pixels = [UInt16]()
        for y in 0..<32 {
            for x in 0..<40 { pixels += [UInt16(x * 1600), UInt16(y * 2000), 65535] }
        }
        try ImageFiles.saveRGB(url, RGBImage(width: 40, height: 32, pixels: pixels), dpi: (300, 300))
        return url
    }

    @Test func theOpenDialogOffersJPEG2000AndXcf() {
        let extensions = PhotoTypes.all.compactMap(\.preferredFilenameExtension)
        for wanted in ["tiff", "png", "jpeg", "jp2", "xcf"] {
            #expect(extensions.contains(wanted), "\(wanted)")
        }
    }

    @Test func anXcfOpensThroughGIMPWithoutBlocking() async throws {
        let gimp = folder.appendingPathComponent("gimp-console")
        try "#!/bin/sh\nsleep 0.3\ncp '\(try tiff().path)' \"$OPENQUAD_XCF_OUT\"\n".write(to: gimp, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gimp.path)
        let xcf = folder.appendingPathComponent("layers.xcf")
        try Data("gimp xcf v011\0".utf8).write(to: xcf)
        setenv("OPENQUAD_GIMP", gimp.path, 1)
        defer { unsetenv("OPENQUAD_GIMP") }

        let m = model()
        m.openPhoto(xcf)
        #expect(m.openingInGIMP == "layers.xcf" && m.session.photo == nil)
        for _ in 0..<500 where m.openingInGIMP != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(m.openingInGIMP == nil && m.error == nil)
        #expect(m.session.photo?.width == 40 && m.session.photo?.converted == true)
        #expect(m.session.source == xcf)
    }

    @Test func aFailedXcfSaysWhy() async throws {
        let xcf = folder.appendingPathComponent("broken.xcf")
        try Data("gimp xcf v011\0".utf8).write(to: xcf)
        setenv("OPENQUAD_GIMP", folder.appendingPathComponent("nowhere").path, 1)
        defer { unsetenv("OPENQUAD_GIMP") }
        let m = model()
        m.openPhoto(xcf)
        for _ in 0..<500 where m.openingInGIMP != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(m.error?.contains("needs GIMP 3 installed") == true && m.session.photo == nil)
    }
}
