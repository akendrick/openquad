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
