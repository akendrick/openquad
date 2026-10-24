// Parity for the scanner (eSCL), printer (lp) and TIFF code, against
// src/openquad/escl.py, printing.py and imageio.py. No network or printer is used:
// the scanner and lp are replayed from what Python saw.

import Foundation
import Testing
@testable import OpenQuadCore

func vectorURL(_ file: String) throws -> URL {
    let name = (file as NSString).deletingPathExtension, ext = (file as NSString).pathExtension
    return try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Vectors"))
}

@Suite("Scanner and printer")
struct DeviceParity {
    @Test func scanSettingsXML() throws {
        for s in try #require(try vectors("devices")["scan_settings"] as? [[String: Any]]) {
            let settings = try ScanSettings(dpi: s["dpi"] as! Int, width: s["width"] as! Int, height: s["height"] as! Int,
                                            intent: s["intent"] as! String)
            #expect(String(decoding: settings.xml(), as: UTF8.self) == s["xml"] as? String)
        }
        #expect(throws: ESCLError.self) { try ScanSettings(dpi: 250) }
        #expect(throws: ESCLError(description: "intent must be one of ('Photo', 'Document', 'TextAndGraphic', 'Preview'), got 'Magic'")) {
            try ScanSettings(intent: "Magic")
        }
    }

    @Test func scanExchangesMatchPython() throws {
        for s in try #require(try vectors("devices")["scans"] as? [[String: Any]]) {
            var responses = try #require(s["responses"] as? [[Any]])
            var calls: [[String: Any?]] = []
            var sleeps: [Double] = []
            let fetch: ESCL.Fetch = { method, url, body in
                calls.append(["method": method, "url": url, "body": body.map { String(decoding: $0, as: UTF8.self) }])
                let r = responses.removeFirst()
                let status = r[0] as! Int, location = r[1] as! String, payload = r[2] as! String
                if status == -1 { throw ESCLError(description: "gone") }
                return (status, location, payload == "jpeg" ? Data([0xff, 0xd8, 0xff, 0xe0] + Array("fake-jpeg".utf8)) : Data(payload.utf8))
            }
            let name = s["name"] as! String
            do {
                let image = try ESCL.scan(host: s["host"] as! String, fetch: fetch, sleep: { sleeps.append($0) })
                #expect(image.map { String(format: "%02x", $0) }.joined() == s["image"] as? String, "\(name)")
            } catch let error as ESCLError {
                #expect(error.description == s["error"] as? String, "\(name)")
            }
            let expected = try #require(s["calls"] as? [[String: Any]])
            #expect(calls.count == expected.count, "\(name)")
            for (got, want) in zip(calls, expected) {
                #expect(got["method"] as? String == want["method"] as? String)
                #expect(got["url"] as? String == want["url"] as? String, "\(name)")
                #expect((got["body"] ?? nil) as? String == want["body"] as? String)
            }
            #expect(sleeps == doubles(s["sleeps"]), "\(name)")
        }
    }

    @Test func discoveryParsers() throws {
        let d = try #require(try vectors("devices")["discovery"] as? [String: Any])
        let avahi = ESCL.parseAvahi(d["avahi"] as! String)
        #expect(avahi.map { [$0.0, $0.1] } == d["avahi_found"] as? [[String]])
        #expect(ESCL.parseDNSSDBrowse(d["browse"] as! String) == d["browse_found"] as? [String])
        #expect(ESCL.parseDNSSDResolve(d["resolve"] as! String) == d["resolve_found"] as? String)
        #expect(ESCL.parseDNSSDResolve("x can be reached at somewhere (if 1)") == d["resolve_odd"] as? String)
        #expect(ESCL.parseDNSSDResolve("nothing") == nil)
        let found = ESCL.discover(browse: { command, _ in command.contains("-B") ? d["browse"] as! String : d["resolve"] as! String },
                                  hasAvahi: false)
        #expect(found.map { [$0.0, $0.1] } == [["Canon MG3600 series", "876298000000.local:80"]])
        #expect(ESCL.discover(browse: { _, _ in d["avahi"] as! String }, hasAvahi: true).count == 1)
    }

    @Test func lpCommands() throws {
        for j in try #require(try vectors("devices")["jobs"] as? [[String: Any]]) {
            let job = try PrintJob(path: "/tmp/openquad/neg.tif", printer: "Canon_MG3600_series",
                                   paper: j["paper"] as? String ?? "Letter", ppi: (j["ppi"] as? NSNumber)?.doubleValue ?? 300,
                                   copies: j["copies"] as? Int ?? 1, title: j["title"] as? String,
                                   options: (j["options"] as? [[String]] ?? []).map { ($0[0], $0[1]) })
            #expect(job.command() == j["command"] as? [String])
        }
        #expect(throws: PrintError(description: "invalid printer name: 'My Printer'")) { try PrintJob(path: "x", printer: "My Printer") }
        #expect(throws: PrintError.self) { try PrintJob(path: "x", printer: "P", copies: 0) }
        #expect(throws: PrintError.self) { try PrintJob(path: "x", printer: "P", ppi: 0) }
    }

    @Test func sendingAndListing() throws {
        let v = try vectors("devices")
        let path = try vectorURL("grey8.tif").path
        for s in try #require(v["send"] as? [[String: Any]]) {
            let runner: Printing.Runner = { _ in (Int32(s["code"] as! Int), s["stdout"] as! String, s["stderr"] as! String) }
            do {
                #expect(try Printing.send(try PrintJob(path: path, printer: "Canon_MG3600_series"), runner: runner) == s["id"] as? String)
            } catch let error as PrintError {
                #expect(error.description == s["error"] as? String)
            }
        }
        #expect(throws: PrintError(description: "file not found: /nowhere/x.tif")) {
            try Printing.send(try PrintJob(path: "/nowhere/x.tif", printer: "P"), runner: { _ in (0, "", "") })
        }
        #expect(try Printing.listPrinters(runner: { _ in (0, "Canon_MG3600_series\nPDF\n\n", "") }) == v["printers"] as? [String])
        #expect(throws: PrintError.self) { try Printing.listPrinters(runner: { _ in (1, "", "no CUPS") }) }
    }

    @Test func tiffsReadAsInPython() throws {
        let v = try vectors("devices")
        for t in try #require(v["tiffs"] as? [[String: Any]]) {
            let image = try ImageFiles.loadGrey(try vectorURL(t["file"] as! String))
            #expect([image.height, image.width] == ints(t["shape"]))
            #expect(image.pixels.map(Int.init) == ints(t["pixels"]), "\(t["file"]!)")
            let dpi = t["dpi"] as? [NSNumber]
            #expect(image.dpi.map { [$0.0, $0.1] } == dpi?.map(\.doubleValue), "\(t["file"]!)")
            #expect(image.iccProfile == nil)
        }
        let rgb = try #require(v["rgb_tiff"] as? [String: Any])
        let url = try vectorURL(rgb["file"] as! String)
        let scan = try Scan.load(url)
        #expect(scan.scale == 65535 && scan.samples.map(Int.init) == ints(rgb["pixels"]))
        #expect(try ImageFiles.readDPI(url).map { [$0.0, $0.1] } == doubles(rgb["dpi"]))
        #expect(throws: ImageFormatError.self) { try ImageFiles.loadGrey(url) }  // colour is refused
    }

    @Test func tiffsRoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("openquad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pixels = (0..<35).map { UInt16(($0 * 1873) % 65536) }
        let grey = GreyImage(width: 7, height: 5, pixels: pixels, dpi: (360, 360))
        let path = folder.appendingPathComponent("grey.tif")
        try ImageFiles.saveGrey(path, grey)
        let back = try ImageFiles.loadGrey(path)
        #expect(back.pixels == pixels && back.width == 7 && back.height == 5)
        #expect(back.dpi.map { [$0.0, $0.1] } == [360, 360])

        let rgb = RGBImage(width: 3, height: 2, pixels: (0..<18).map { UInt16($0 * 3641) })
        let rgbPath = folder.appendingPathComponent("rgb.tif")
        try ImageFiles.saveRGB(rgbPath, rgb, dpi: (300, 300), iccProfile: ImageFiles.srgbProfile())
        let read = try Scan.load(rgbPath)
        #expect(read.samples == rgb.pixels && read.scale == 65535)
        #expect(try ImageFiles.readDPI(rgbPath).map { [$0.0, $0.1] } == [300, 300])
    }
}
