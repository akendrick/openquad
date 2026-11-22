// Parity for JPEG 2000 photos (against src/openquad/jpeg2000.py, through the same OpenJPEG
// version) and for how an XCF is handed to GIMP (src/openquad/xcf.py). Lossless files match
// exactly; lossy ones go through floating-point wavelets, so to within 1.

import Foundation
import Testing
@testable import OpenQuadCore

@Suite("JPEG 2000 and XCF")
struct FormatsParity {
    func worst(_ a: [Int], _ b: [Int]) -> Int {
        zip(a, b).map { abs($0 - $1) }.max() ?? 0
    }

    @Test func theSameOpenJPEGAsPillow() {
        #expect(JPEG2000.openJPEGVersion == "2.5.4")
    }

    @Test func jpeg2000ReadsAsInPython() throws {
        for f in try #require(try vectors("formats")["jpeg2000"] as? [[String: Any]]) {
            let file = f["file"] as! String
            let lossy = f["lossy"] as! Bool
            let url = try vectorURL(file)
            let raw = try JPEG2000.read(url, data: Data(contentsOf: url))
            #expect([raw.height, raw.width, raw.channels] == ints(f["shape"]), "\(file)")
            #expect(raw.bits == f["bits"] as? Int, "\(file)")
            let values = raw.values.map(Int.init), expected = ints(f["raw"])
            #expect(values.count == expected.count, "\(file)")
            #expect(worst(values, expected) <= (lossy ? 1 : 0), "\(file)")
            #expect(raw.dpi.map { [$0.0, $0.1] } == (f["dpi"] as? [NSNumber])?.map(\.doubleValue), "\(file)")
            #expect((raw.profile?.count ?? 0) == f["profile_length"] as? Int, "\(file)")

            let p = f["photo"] as! [String: Any]
            let photo = try Photos.load(url)
            #expect([photo.height, photo.width] == ints(p["shape"]), "\(file)")
            #expect(worst(photo.pixels.map(Int.init), ints(p["pixels"])) <= (lossy ? 1 : 0), "\(file)")
            #expect(photo.converted == p["converted"] as? Bool, "\(file)")
            #expect(photo.cropped == p["cropped"] as? Bool, "\(file)")
            if p["colour"] is NSNull {
                #expect(photo.colour == nil, "\(file)")
            } else {
                #expect(worst(photo.colour?.map(Int.init) ?? [], ints(p["colour"])) <= (lossy ? 1 : 0), "\(file)")
            }
            #expect((photo.iccProfile != nil) == p["has_profile"] as? Bool, "\(file)")
        }
    }

    @Test func brightSixteenBitColourStaysBright() throws {
        // Pillow's own reader turns these black; read through OpenJPEG they are kept.
        let photo = try Photos.load(try vectorURL("jp2-rgb16.jp2"))
        let colour = try #require(photo.colour)
        #expect(Array(colour[0..<12]) == [65535, 65535, 65535, 65408, 65408, 65408, 65407, 65407, 65407, 65400, 30000, 100])
    }

    @Test func resolutionsAndBoxes() {
        #expect(JPEG2000.perInch(11811, 1, 0) == 254.0 * 11811 / 10000)
        #expect(JPEG2000.perInch(1181, 1, 1) == 254.0 * 11810 / 10000)
        #expect(JPEG2000.perInch(11811, 10, -1) == 254.0 * 11811 / 1_000_000)
        #expect(JPEG2000.perInch(0, 1, 0) == nil)
        #expect(JPEG2000.perInch(1, 0, 0) == nil)
        #expect(JPEG2000.perInch(1, 1, 7) == nil)
        #expect(JPEG2000.scale(4095, precision: 12, bits: 16) == 65535)
        #expect(JPEG2000.scale(2048, precision: 12, bits: 16) == 32776)
        #expect(JPEG2000.scale(255, precision: 8, bits: 8) == 255)
        #expect(JPEG2000.jp2DPI(Data([0, 0, 0, 8, 0x6A, 0x70, 0x32, 0x68])) == nil)  // an empty header
    }

    @Test func notJPEG2000OrBroken() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("openquad-jp2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let broken = folder.appendingPathComponent("broken.jp2")
        let whole = try Data(contentsOf: try vectorURL("jp2-rgb16.jp2"))
        try whole.prefix(200).write(to: broken)
        #expect(throws: ImageFormatError.self) { try Photos.load(broken) }
        #expect(JPEG2000.isJPEG2000(whole) && !JPEG2000.isJPEG2000(Data("gimp xcf v011".utf8)))
    }

    @Test func gimpIsAskedTheSameWayAsInPython() throws {
        let v = try #require(try vectors("formats")["xcf"] as? [String: Any])
        #expect(Xcf.script == v["script"] as? String)
        #expect(Xcf.consoleNames == v["console_names"] as? [String])
        #expect(Xcf.arguments() == v["arguments"] as? [String])
        #expect(Xcf.needsGIMP == v["needs_gimp"] as? String)
        #expect(Xcf.signature == Data((v["signature"] as! String).utf8))
    }
}

@Suite("XCF through GIMP")
struct XcfTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("openquad-xcf-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// A stand-in for gimp-console: copies a TIFF to where GIMP would save, or saves nothing.
    func fakeGIMP(copying tiff: URL?, name: String = "gimp-console") throws -> URL {
        let script = folder.appendingPathComponent(name)
        let body = tiff.map { "cp '\($0.path)' \"$OPENQUAD_XCF_OUT\"" } ?? "echo 'GIMP-Error: Opening failed' >&2"
        try "#!/bin/sh\n[ -f \"$OPENQUAD_XCF_IN\" ] || exit 1\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    func xcf() throws -> URL {
        let url = folder.appendingPathComponent("layers.xcf")
        try Data("gimp xcf v011\0".utf8).write(to: url)
        return url
    }

    @Test func anXcfIsReadThroughGIMP() throws {
        let gimp = try fakeGIMP(copying: try vectorURL("photo-colour16.tif"))
        let decoded = try Xcf.flattened(try xcf(), gimp: gimp) { try Photos.decode($0) }
        let photo = try Photos.build(decoded, name: "layers.xcf")
        let direct = try Photos.load(try vectorURL("photo-colour16.tif"))
        #expect(photo.pixels == direct.pixels && photo.colour == direct.colour)
        // Through OPENQUAD_GIMP, as Photos.load finds it.
        let found = Xcf.findGIMP(environment: ["OPENQUAD_GIMP": gimp.path])
        #expect(found == gimp)
    }

    @Test func gimpMissingOrFailing() throws {
        let url = try xcf()
        #expect(Xcf.findGIMP(environment: ["OPENQUAD_GIMP": folder.appendingPathComponent("nowhere").path]) == nil)
        let failing = try fakeGIMP(copying: nil, name: "gimp-console-3.0")
        let error = #expect(throws: ImageFormatError.self) { try Xcf.flattened(url, gimp: failing) { $0 } }
        #expect(error?.description.hasSuffix("GIMP 3 could not open it (GIMP-Error: Opening failed)") == true)
        // On the PATH, when there is no GIMP.app; nowhere at all.
        #expect(Xcf.findGIMP(environment: ["PATH": "/nowhere:\(folder.path)"], folders: [folder]) == failing)
        #expect(Xcf.findGIMP(environment: ["PATH": "/nowhere"], folders: [folder]) == nil)
        let missing = #expect(throws: ImageFormatError.self) {
            try Xcf.flattened(url, environment: ["OPENQUAD_GIMP": "/nowhere"]) { $0 }
        }
        #expect(missing?.description.hasSuffix(Xcf.needsGIMP) == true)
    }

    @Test func aGIMPAppIsSearchedForItsConsole() throws {
        let app = folder.appendingPathComponent("Applications/GIMP.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let console = app.appendingPathComponent("gimp-console-3.2")
        try "#!/bin/sh\n".write(to: console, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: console.path)
        let gimpApp = folder.appendingPathComponent("Applications/GIMP.app")
        #expect(Xcf.findGIMP(environment: ["OPENQUAD_GIMP": gimpApp.path]) == console)
        #expect(Xcf.findGIMP(environment: [:], folders: [folder.appendingPathComponent("Applications")]) == console)
    }

    @Test(.enabled(if: Xcf.findGIMP() != nil, "GIMP 3 is not installed"))
    func aRealXcfThroughRealGIMP() throws {
        let photo = try Photos.load(try vectorURL("layers.xcf"))
        #expect(photo.width == 64 && photo.height == 48 && photo.converted)
        let colour = try #require(photo.colour)
        #expect(Array(colour[0..<3]) == [31754, 43593, 59396])
    }
}
