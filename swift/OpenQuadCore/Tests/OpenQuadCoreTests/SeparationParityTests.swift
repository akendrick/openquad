// Parity for tonal separations (against src/openquad/separations.py, the numbered negatives
// and clear targets in negative.py and marks.py, and the session's separated negatives).

import CryptoKit
import Foundation
import Testing
@testable import OpenQuadCore

/// SHA-256 of float64s, little-endian (JSON floats don't round-trip exactly).
func floatDigest(_ values: [Double]) -> String {
    var bytes = [UInt8]()
    for v in values { withUnsafeBytes(of: v.bitPattern.littleEndian) { bytes += $0 } }
    return SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
}

struct SeparationParity {
    @Test func bandsStrengthsAndCoatLUTs() throws {
        let v = try vectors("separations")
        let positions = (0...210).map { Double($0) / 210 }
        for p in v["plans"] as! [[String: Any]] {
            let plan = try SeparationPlan.fromSteps((p["splits"] as! [NSNumber]).map(\.doubleValue),
                                                    steps: (p["steps"] as! NSNumber).intValue,
                                                    overlap: (p["overlap"] as! NSNumber).doubleValue)
            #expect(plan.describe() == p["describe"] as? String)
            let bands = (p["bands"] as! [[NSNumber]]).map { ($0[0].doubleValue, $0[1].doubleValue) }
            #expect(plan.bands.map(\.0) == bands.map(\.0) && plan.bands.map(\.1) == bands.map(\.1))
            for (k, expected) in (p["strength"] as! [String]).enumerated() {
                #expect(floatDigest(positions.map { plan.strength(k, at: $0) }) == expected, "\(plan.describe()) #\(k + 1)")
            }
            for (k, lut) in (p["luts"] as! [[String: Any]]).enumerated() {
                #expect(digest(plan.coatLUT(k)) == lut["sha256"] as? String, "\(plan.describe()) #\(k + 1)")
            }
        }
        for (n, splits) in (v["even"] as! [[NSNumber]]).enumerated() {
            #expect(try SeparationPlan.even(n + 1).splits == splits.map(\.doubleValue))
        }
    }

    @Test func stepTests() throws {
        for t in try vectors("separations")["step_tests"] as! [[String: Any]] {
            let test = try SeparationPlan.stepTest(steps: (t["steps"] as! NSNumber).intValue, dpi: (t["dpi"] as! NSNumber).doubleValue)
            #expect([test.height, test.width] == (t["shape"] as! [NSNumber]).map(\.intValue))
            #expect(digest(test.pixels) == t["sha256"] as? String, "\(t["steps"]!) steps at \(t["dpi"]!) dpi")
        }
        #expect(throws: BuildError.self) { try SeparationPlan.stepTest(steps: 1) }
        #expect(throws: BuildError.self) { try SeparationPlan.stepTest(dpi: 0) }
    }

    @Test func badPlans() {
        #expect(throws: BuildError.self) { try SeparationPlan(splits: [0.2, 0.2]) }
        #expect(throws: BuildError.self) { try SeparationPlan(splits: [0]) }
        #expect(throws: BuildError.self) { try SeparationPlan(splits: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6]) }
        #expect(throws: BuildError.self) { try SeparationPlan(splits: [0.5], steps: 1) }
        #expect(throws: BuildError.self) { try SeparationPlan.fromSteps([10, 20], steps: 30, overlap: 11) }
        #expect(throws: BuildError.self) { try SeparationPlan.even(7) }
    }

    @Test func numbersAndClearTargets() throws {
        let v = try vectors("separations")
        for row in v["labels"] as! [[Any]] {
            let n = row.map { ($0 as? NSNumber)?.intValue }
            #expect(Negative.labelLeft(width: n[0]!, edge: n[1]!, cell: n[2]!, label: n[3]!) == n[4])
        }
        for t in v["targets"] as! [[String: Any]] {
            let mask = Marks.targetMask(width: (t["width"] as! NSNumber).intValue, height: (t["height"] as! NSNumber).intValue,
                                        band: (t["band"] as! NSNumber).intValue, dpi: (t["dpi"] as! NSNumber).doubleValue)
            #expect(mask.indices.filter { mask[$0] } == (t["on"] as! [NSNumber]).map(\.intValue))
        }
        let photo = v["photo"] as! [String: Any]
        let pixels = (photo["pixels"] as! [NSNumber]).map { UInt16($0.intValue) }
        for c in v["negatives"] as! [[String: Any]] {
            let settings = NegativeSettings(colour: c["colour"] as! String, mirror: c["mirror"] as! Bool,
                                            safeEdge: (c["safe_edge"] as! NSNumber).doubleValue, guide: true,
                                            registration: c["registration"] as! Bool, label: (c["label"] as! NSNumber).intValue,
                                            clearTargets: c["clear"] as! Bool)
            let negative = Negative.make(pixels, width: (photo["width"] as! NSNumber).intValue,
                                         height: (photo["height"] as! NSNumber).intValue, settings: settings, dpi: 100)
            #expect([negative.height, negative.width, 3] == (c["shape"] as! [NSNumber]).map(\.intValue))
            #expect(digest(negative.pixels) == c["sha256"] as? String, "\(c)")
        }
    }

    @Test func sessionRendersEveryNegative() throws {
        let v = try vectors("separations")["session"] as! [String: Any]
        var session = PrintSession()
        try session.open(try vectorURL("photo-grey16.tif"))
        session.setMode(.negative)
        session.fit = false
        session.ppi = 40
        session.registration = true
        try session.setProcess(try vectorURL("session-process.oqproc"))
        session.setSeparation(try SeparationPlan.fromSteps([10, 20], steps: 30, overlap: 1))
        let photo = try #require(session.photo)
        for (k, expected) in (v["rendered"] as! [[String: Any]]).enumerated() {
            let negative = try session.renderLayer(photo.pixels, width: photo.width, height: photo.height, layer: k)
            #expect(digest(negative.pixels) == expected["sha256"] as? String, "negative \(k + 1)")
        }
        for (k, lines) in (v["summaries"] as! [[String]]).enumerated() {
            try session.setLayer(k)
            #expect(try session.summary() == lines)
        }
        // The shown negative is the one printed, and each can have its own curve.
        try session.setLayer(1)
        let shown = try session.renderPrint()
        #expect(shown == (try session.renderLayer(photo.pixels, width: photo.width, height: photo.height, layer: 1)))
        try session.setLayerProcess(2, try vectorURL("session-process.oqproc"))
        #expect(session.layerProcessPaths[2] != nil)
        session.printer = "Canon"
        #expect(try session.printJob(URL(fileURLWithPath: "/tmp/x.tif")).title?.hasSuffix("(negative 2 of 3)") == true)
        let folder = try temporaryFolder()
        let written = try session.writeSeparations(folder)
        #expect(written.map(\.lastPathComponent) == ["photo-grey16-1of3.tif", "photo-grey16-2of3.tif", "photo-grey16-3of3.tif"])
        // Fewer negatives forget what no longer exists.
        session.setSeparation(try SeparationPlan.even(2))
        #expect(session.layer == 1 && session.layerProcesses.isEmpty)
        session.setSeparation(nil)
        #expect(session.negativeCount == 1 && session.layer == 0)
        #expect(throws: SessionError.self) { try session.setLayer(1) }
        #expect(throws: SessionError.self) { try session.writeSeparations(folder) }
    }
}
