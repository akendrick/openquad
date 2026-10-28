// Parity for loading photos of every kind and for print sessions, against
// src/openquad/photo.py and session.py.

import Foundation
import Testing
@testable import OpenQuadCore

@Suite("Photos and print sessions")
struct SessionParity {
    @Test func photosLoadAsInPython() throws {
        for p in try #require(try vectors("session")["photos"] as? [[String: Any]]) {
            let file = p["file"] as! String
            let photo = try Photos.load(try vectorURL(file))
            #expect([photo.height, photo.width] == ints(p["shape"]), "\(file)")
            #expect(photo.pixels.map(Int.init) == ints(p["pixels"]), "\(file)")
            #expect(photo.converted == p["converted"] as? Bool, "\(file)")
            #expect(photo.cropped == p["cropped"] as? Bool, "\(file)")
            let dpi = (p["dpi"] as? [NSNumber])?.map(\.doubleValue)
            #expect(photo.dpi.map { [$0.0, $0.1] } == dpi, "\(file)")
        }
    }

    @Test func sessionsRenderAndReportAsInPython() throws {
        let v = try vectors("session")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("openquad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let calibrationURL = folder.appendingPathComponent("canon-plain.oqcal")
        try (v["calibration"] as! String).write(to: calibrationURL, atomically: true, encoding: .utf8)

        for c in try #require(v["sessions"] as? [[String: Any]]) {
            var session = PrintSession()
            try session.open(try vectorURL(c["photo"] as! String))
            try session.setPreset(c["preset"] as? String ?? "neutral")
            if c["calibration"] as? Bool == true { try session.setCalibration(calibrationURL) }
            try session.setPaper(c["paper"] as? String ?? "Letter")
            session.fit = c["fit"] as? Bool ?? true
            session.ppi = (c["ppi"] as? NSNumber)?.doubleValue
            session.setMode(OutputMode(rawValue: c["mode"] as? String ?? "print")!)
            if c["process"] as? Bool == true {
                try session.setProcess(try vectorURL("session-process.oqproc"))
            } else if let colour = c["negative_colour"] as? String {
                try session.setNegativeColour(colour)
            }
            session.mirror = c["mirror"] as? Bool ?? false
            session.safeEdge = (c["safe_edge"] as? NSNumber)?.doubleValue ?? 0.25
            if let box = c["max_size"] as? [NSNumber] { session.maxSize = (box[0].doubleValue, box[1].doubleValue) }
            session.printer = "Canon_MG3600_series"

            #expect(abs(try session.effectivePPI() - (c["ppi_used"] as! NSNumber).doubleValue) < 1e-9)
            let size = try session.sizeInches(), expected = doubles(c["size"])
            #expect(abs(size.0 - expected[0]) < 1e-9 && abs(size.1 - expected[1]) < 1e-9)
            #expect(try session.fitsOnPaper() == c["fits"] as? Bool)
            #expect(try session.summary() == c["summary"] as? [String])
            #expect(session.notes == c["notes"] as? [String])
            let rendered = try session.renderPrint()
            #expect([rendered.height, rendered.width, 3] == ints(c["rendered_shape"]))
            #expect(rendered.pixels.map(Int.init) == ints(c["rendered"]))
        }
    }

    @Test func sessionRulesAndOutput() throws {
        var session = PrintSession()
        #expect(session.preset == "neutral")  // toning is never on by default
        #expect(throws: SessionError(description: "open a photo first")) { try session.effectivePPI() }
        #expect(throws: SessionError.self) { try session.setPreset("sepia-ish") }
        try session.setProcess(try vectorURL("session-process.oqproc"))
        #expect(session.negativeColour == "orange")
        #expect(throws: SessionError(description: "the process curve is for orange negatives")) { try session.setNegativeColour("green") }

        try session.open(try vectorURL("photo-grey16.tif"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("openquad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: SessionError(description: "choose a printer first")) { try session.print(scratch: folder) }
        session.printer = "Canon_MG3600_series"
        var sent: [String] = []
        let id = try session.print(scratch: folder) { command in
            sent = command
            return (0, "request id is Canon_MG3600_series-9 (1 file(s))\n", "")
        }
        #expect(id == "Canon_MG3600_series-9")
        #expect(sent.contains("PageSize=Letter") && sent.last!.hasSuffix("openquad-print.tif"))
        let written = try Scan.load(folder.appendingPathComponent("openquad-print.tif"))
        #expect(written.samples == (try session.renderPrint()).pixels)

        let preview = try session.preview(maxSide: 12)
        #expect(max(preview.width, preview.height) <= 12 + 2 * 1)  // a negative keeps its (scaled) safe edge
    }

    @Test func settingsRoundTripWithoutToning() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("openquad-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(AppSettings.load(url) == AppSettings())
        var settings = AppSettings()
        settings.printer = "Canon_MG3600_series"
        settings.scannerHost = "876298000000.local:80"
        settings.negativeColour = "orange"
        try settings.save(url)
        #expect(AppSettings.load(url) == settings)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"scanner_host\"") && !text.contains("preset"))
    }
}
