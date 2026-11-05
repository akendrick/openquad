// Parity for building corrections: grey balance and linearization from the real Canon
// measurements, and process curves from simulated chart readings.

import Foundation
import Testing
@testable import OpenQuadCore

@Suite("Building corrections")
struct BuildParity {
    @Test func lightnessTargets() throws {
        let v = try vectors("builds")
        let probe = doubles(v["probe"])
        for (level, expected) in zip(probe, doubles(v["srgb_lightness"])) {
            #expect(abs(Linearize.srgbLightness(level) - expected) < 1e-9)
        }
        for (level, expected) in zip(probe, doubles(v["target_lightness"])) {
            #expect(abs(Linearize.targetLightness(level, paper: 92.5, black: 23.5) - expected) < 1e-9)
        }
    }

    @Test func greyBalanceFromRealMeasurements() throws {
        let v = try vectors("builds")
        let cases = try #require(v["grey_balance"] as? [[String: Any]])
        #expect(cases.count == 3)
        for c in cases {
            let m = try Measurement.decode(Data((c["measurement"] as! String).utf8))
            let built = try GreyBalance.build(m, damping: (c["damping"] as! NSNumber).doubleValue,
                                              shadowDamping: (c["shadow_damping"] as? NSNumber)?.doubleValue)
            #expect(built.levels.map(Int.init) == ints(c["levels"]))
            #expect(built.curves.flatMap { $0 }.map(Int.init) == ints(c["curves"]))
        }
    }

    @Test func linearizationFromRealMeasurements() throws {
        let v = try vectors("builds")
        let cases = try #require(v["linearize"] as? [[String: Any]])
        #expect(cases.count == 2)
        for c in cases {
            let calibration = try Calibration.decode(Data((c["calibration"] as! String).utf8))
            let m = try Measurement.decode(Data((c["measurement"] as! String).utf8))
            for (got, expected) in zip(try Linearize.toneCurve(m), doubles(c["tone_curve"])) {
                #expect(abs(got - expected) < 1e-9)
            }
            let result = try Linearize.linearize(calibration, m)
            #expect(result.levels.map(Int.init) == ints(c["levels"]))
            #expect(result.curves.flatMap { $0 }.map(Int.init) == ints(c["curves"]))
            #expect(result.settings == c["settings"] as? String)
        }
    }

    @Test func linearizeRejectsTheWrongCalibration() throws {
        let v = try vectors("builds")
        let cases = try #require(v["linearize"] as? [[String: Any]])
        let other = try Calibration.decode(Data((cases[1]["calibration"] as! String).utf8))
        let m = try Measurement.decode(Data((cases[0]["measurement"] as! String).utf8))
        #expect(throws: BuildError.self) { try Linearize.linearize(other, m) }
    }

    @Test func processCurvePasses() throws {
        let v = try vectors("builds")
        let levels = ints(v["patch_levels"]).map { UInt16($0) }
        let passes = try #require(v["process"] as? [[String: Any]])
        var previous: ProcessCurve?
        for p in passes {
            let reading = ChartReading(levels: levels, lightness: doubles(p["lightness"]))
            for (got, expected) in zip(reading.toneErrors(), doubles(p["tone_errors"])) {
                #expect(abs(got - expected) < 1e-9)
            }
            let curve = try ProcessCurve.build(reading, previous: previous, film: "office")
            #expect(curve.levels.map(Int.init) == ints(p["levels"]))
            #expect(curve.curve.map(Int.init) == ints(p["curve"]))
            #expect(curve.film == "office" && curve.colour == "green")
            previous = curve
        }
    }

    @Test func smoothingAndAscendingFit() throws {
        let v = try vectors("builds")
        let levels = ints(v["patch_levels"]).map { UInt16($0) }
        let cases = try #require(v["smoothing"] as? [[String: Any]])
        #expect(cases.map { $0["reach"] as! Int } == Smoothing.reaches.map(\.1))
        let noisy = try #require(v["smoothing_input"] as? [Double])
        let x = linspace(0, 65535, levels.count)
        for c in cases {
            let reach = c["reach"] as! Int
            for (got, expected) in zip(Smoothing.response(x, noisy, reach: reach), doubles(c["smoothed"])) {
                #expect(abs(got - expected) <= 1e-9 * max(1, abs(expected)))
            }
            let reading = ChartReading(levels: levels, lightness: noisy, paper: 90)
            #expect(try ProcessCurve.build(reading, smoothing: reach).curve.map(Int.init) == ints(c["curve"]))
        }
        for c in try #require(v["ascending"] as? [[String: Any]]) {
            #expect(Smoothing.ascending(doubles(c["input"])) == doubles(c["output"]))
        }
    }

    @Test func lostTones() throws {
        let v = try vectors("builds")
        let levels = ints(v["patch_levels"]).map { UInt16($0) }
        for c in try #require(v["clipped"] as? [[String: Any]]) {
            let lost = Clipping.lost(ChartReading(levels: levels, lightness: doubles(c["lightness"]), paper: 90))
            let counts = ints(c["counts"])
            #expect([lost.0, lost.1] == counts)
            #expect(Clipping.advice(highlights: lost.0, shadows: lost.1) == c["advice"] as? String)
        }
    }

    @Test func exportedCurveFiles() throws {
        let v = try vectors("builds")
        let e = try #require(v["export"] as? [String: Any])
        let curve = ProcessCurve(levels: ints(e["levels"]).map { UInt16($0) }, curve: ints(e["curve"]).map { UInt16($0) })
        #expect([UInt8](CurveExport.amp(curve)) == ints(e["amp"]).map { UInt8($0) })
        #expect([UInt8](CurveExport.acv(curve)) == ints(e["acv"]).map { UInt8($0) })
        let spline = stride(from: 0, to: 256, by: 5).map { CurveExport.spline([0, 40, 130, 255], [0, 70, 150, 255], $0) }
        for (got, expected) in zip(spline, doubles(e["spline"])) { #expect(abs(got - expected) < 1e-9) }
        #expect(CurveExport.csv(curve) == e["csv"] as? String)
        #expect(CurveExport.cube(curve, size: 5) == e["cube"] as? String)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oq-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for format in CurveExport.formats {
            let url = folder.appendingPathComponent("c.\(format)")
            try CurveExport.write(curve, to: url)
            #expect(try Data(contentsOf: url).count > 50)
        }
        #expect(throws: BuildError.self) { try CurveExport.write(curve, to: folder.appendingPathComponent("c.txt")) }
    }

    @Test func badInputIsRejected() throws {
        let flat = ChartReading(levels: [0, 32768, 65535], lightness: [50, 51, 52])
        #expect(throws: BuildError.self) { try ProcessCurve.build(flat) }
        let v = try vectors("builds")
        let cases = try #require(v["grey_balance"] as? [[String: Any]])
        let m = try Measurement.decode(Data((cases[0]["measurement"] as! String).utf8))
        #expect(throws: BuildError.self) { try GreyBalance.build(m, damping: 1.5) }
        #expect(throws: FileFormatError.self) { try Measurement.decode(Data("{\"format\": \"x\"}".utf8)) }
    }
}
