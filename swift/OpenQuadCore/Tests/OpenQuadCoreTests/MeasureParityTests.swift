// Parity for reading wedge scans: real Canon scans (reduced, lossless PNG) measured by
// src/openquad/measure.py.

import CryptoKit
import Foundation
import Testing
@testable import OpenQuadCore

func scan(_ name: String) throws -> Scan {
    let base = (name as NSString).deletingPathExtension
    let url = try #require(Bundle.module.url(forResource: base, withExtension: "png", subdirectory: "Vectors"))
    return try Scan.load(url)
}

func expectMeasurement(_ m: OpenQuadCore.Measurement, _ expected: Any?) throws {
    let e = try #require(expected as? [String: Any])
    #expect(m.levels.map(Int.init) == ints(e["levels"]))
    #expect(m.sent.flatMap { $0 }.map(Int.init) == ints(e["sent"]))
    for (got, want) in zip(m.rgb.flatMap { $0 }, doubles(e["rgb"])) { #expect(abs(got - want) < 1e-12) }
    for (got, want) in zip(m.lab.flatMap { $0 }, doubles(e["lab"])) { #expect(abs(got - want) < 1e-9) }
}

@Suite("Wedge scans")
struct MeasureParity {
    @Test func wedgeLevels() throws {
        #expect(Targets.wedgeLevels(21).map(Int.init) == ints(try vectors("measure")["wedge_levels"]))
    }

    @Test func scansDecodeExactlyAsInPython() throws {
        for entry in try #require(try vectors("measure")["scans"] as? [[String: Any]]) {
            let s = try scan(entry["file"] as! String)
            #expect([s.height, s.width, 3] == ints(entry["shape"]))
            let digest = SHA256.hash(data: Data(s.samples.map { UInt8($0) }))
            #expect(digest.map { String(format: "%02x", $0) }.joined() == entry["sha256"] as? String)
        }
    }

    @Test func singleTarget() throws {
        let entry = try #require(try vectors("measure")["scans"] as? [[String: Any]])[0]
        let s = try scan(entry["file"] as! String)
        let frame = try Measure.locateFrame(s)
        #expect([frame.left, frame.top, frame.right, frame.bottom] == ints(entry["frame"]))
        #expect(Measure.countMarks(s, frame: frame) == entry["marks"] as? Int)
        try expectMeasurement(try Measure.measure(s), entry["measurement"])
    }

    @Test func comparisonPages() throws {
        let entries = try #require(try vectors("measure")["scans"] as? [[String: Any]])
        for entry in entries.dropFirst() {
            let s = try scan(entry["file"] as! String)
            #expect(try Measure.splitRow(s) == entry["split"] as? Int)
            let (top, bottom) = try Measure.splitPair(s)
            let frames = try [top, bottom].map { try Measure.locateFrame($0) }
            #expect(frames.flatMap { [$0.left, $0.top, $0.right, $0.bottom] } == (entry["frames"] as? [[Int]] ?? []).flatMap { $0 })
            #expect(zip([top, bottom], frames).map { Measure.countMarks($0, frame: $1) } == ints(entry["marks"]))
            let sent = rows(ints(entry["sent"]), 3)
            let (plain, corrected) = try Measure.measurePair(s, sent: sent)
            try expectMeasurement(plain, entry["uncorrected"])
            try expectMeasurement(corrected, entry["corrected"])
        }
    }

    @Test func blankScansAreRejected() {
        let white = Scan(width: 40, height: 30, samples: [UInt16](repeating: 255, count: 40 * 30 * 3), scale: 255)
        #expect(throws: MeasureError.self) { try Measure.locateFrame(white) }
        #expect(throws: MeasureError.self) { try Measure.splitPair(white) }
    }
}
