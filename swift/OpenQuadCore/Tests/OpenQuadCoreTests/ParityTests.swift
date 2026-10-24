// Parity with the Python reference: every expected value here was produced by
// src/openquad (scripts/export_swift_vectors.py). Integers must match exactly;
// floating-point values to within 1e-12 (Lab: 1e-9).

import Foundation
import Testing
@testable import OpenQuadCore

func vectors(_ name: String) throws -> [String: Any] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Vectors"))
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    return try #require(object as? [String: Any])
}

func doubles(_ value: Any?) -> [Double] { (value as? [NSNumber] ?? []).map(\.doubleValue) }
func ints(_ value: Any?) -> [Int] { (value as? [NSNumber] ?? []).map(\.intValue) }
func rows(_ flat: [Int], _ width: Int) -> [[UInt16]] {
    stride(from: 0, to: flat.count, by: width).map { flat[$0..<$0 + width].map { UInt16($0) } }
}

@Suite("Colour maths")
struct ColourParity {
    @Test func transferFunctions() throws {
        let v = try vectors("colour")
        let encoded = doubles(v["encoded"])
        for (x, expected) in zip(encoded, doubles(v["srgb_to_linear"])) {
            #expect(abs(Colour.srgbToLinear(x) - expected) < 1e-12)
        }
        for (x, expected) in zip(encoded, doubles(v["linear_to_srgb"])) {
            #expect(abs(Colour.linearToSRGB(x) - expected) < 1e-12)
        }
    }

    @Test func lab() throws {
        let v = try vectors("colour")
        let rgb = doubles(v["rgb"]), lab = doubles(v["lab"])
        #expect(rgb.count == lab.count && rgb.count == 180)
        for i in stride(from: 0, to: rgb.count, by: 3) {
            let got = Colour.linearRGBToLab(rgb[i], rgb[i + 1], rgb[i + 2])
            #expect(abs(got.l - lab[i]) < 1e-9)
            #expect(abs(got.a - lab[i + 1]) < 1e-9)
            #expect(abs(got.b - lab[i + 2]) < 1e-9)
        }
    }
}

@Suite(".quad files")
struct QuadFileParity {
    @Test func goldenFileParsesAndRoundTripsByteForByte() throws {
        let v = try vectors("quadfile")
        let text = try #require(v["golden_text"] as? String)
        let curve = try QuadCurve.parse(text)
        #expect(curve.channels == (v["golden_channels"] as? [String]))
        #expect(curve.values == rows(ints(v["golden_values"]), quadLevels))
        #expect(curve.format() == text)
    }

    @Test func commentsAndTrailerAreKept() throws {
        let v = try vectors("quadfile")
        let small = try #require(v["small_text"] as? String)
        let formatted = try QuadCurve.parse(small).format()
        #expect(formatted == (v["small_formatted"] as? String))
        let curve = try QuadCurve.parse(small)
        #expect(curve.comments == [["# K curve"], ["", "# LK curve"]])
        #expect(curve.trailer == ["# end"])
    }

    @Test func malformedFilesAreRejected() throws {
        let v = try vectors("quadfile")
        for text in try #require(v["malformed"] as? [String]) {
            #expect(throws: QuadFormatError.self) { try QuadCurve.parse(text) }
        }
    }

    @Test func windowsLineEndings() throws {
        let text = "## QuadToneRIP K\r\n" + (0..<256).map(String.init).joined(separator: "\r\n") + "\r\n"
        #expect(try QuadCurve.parse(text).values[0][10] == 10)
    }
}

@Suite("Curves")
struct CurvesParity {
    @Test func expandMatchesNumpyInterpAndRint() throws {
        let v = try vectors("curves")
        for case let item as [String: Any] in try #require(v["expand"] as? [Any]) {
            let points = ints(item["points"]).map { UInt16($0) }
            let table = Curves.expand(points)
            let sampled = ints(item["sample_indices"]).map { Int(table[$0]) }
            #expect(sampled == ints(item["table_sampled"]))
        }
    }

    @Test func scaleLimit() throws {
        let v = try vectors("curves")
        let item = try #require(v["scale_limit"] as? [String: Any])
        let points = ints(item["points"]).map { UInt16($0) }
        let limit = try #require((item["limit"] as? NSNumber)?.doubleValue)
        #expect(Curves.scaleLimit(points, limit).map(Int.init) == ints(item["result"]))
    }

    @Test func linearAndSmoothRamps() throws {
        let v = try vectors("curves")
        let ramps = try #require(v["ramps"] as? [String: Any])
        let positions = doubles(ramps["positions"])
        let specs = try #require(ramps["specs"] as? [[String: Any]])
        let values = try #require(ramps["values"] as? [Any])
        for (spec, expected) in zip(specs, values) {
            let ink = InkSpec(
                try #require(spec["channel"] as? String),
                limit: try #require((spec["limit"] as? NSNumber)?.doubleValue),
                start: try #require((spec["start"] as? NSNumber)?.doubleValue),
                peak: try #require((spec["peak"] as? NSNumber)?.doubleValue),
                end: try #require((spec["end"] as? NSNumber)?.doubleValue),
                shape: InkSpec.Shape(rawValue: try #require(spec["shape"] as? String)) ?? .linear
            )
            for (p, e) in zip(positions, doubles(expected)) {
                #expect(abs(ink.ramp(p) - e) < 1e-12)
            }
        }
    }

    @Test func buildThreeInkCurveWithGamma() throws {
        let v = try vectors("curves")
        let item = try #require(v["build_three_ink_gamma_1_2"] as? [String: Any])
        let curve = try Curves.build([
            InkSpec("LLK", limit: 30, start: 0.0, peak: 0.33, end: 0.66),
            InkSpec("LK", limit: 40, start: 0.2, peak: 0.66, end: 1.0),
            InkSpec("K", limit: 60, start: 0.5, peak: 1.0),
        ], gamma: 1.2)
        #expect(curve.channels == (item["channels"] as? [String]))
        #expect(curve.values == rows(ints(item["values"]), quadLevels))
    }

    @Test func buildSmoothCurve() throws {
        let v = try vectors("curves")
        let item = try #require(v["build_smooth_two"] as? [String: Any])
        let curve = try Curves.build([
            InkSpec("LK", limit: 45, start: 0.0, peak: 0.5, end: 1.0, shape: .smooth),
            InkSpec("K", limit: 90, start: 0.3, peak: 1.0, shape: .smooth),
        ], channels: ["K", "LK"])
        #expect(curve.values == rows(ints(item["values"]), quadLevels))
    }

    @Test func buildRejectsBadInput() {
        #expect(throws: QuadFormatError.self) {
            try Curves.build([InkSpec("Z", limit: 50, start: 0, peak: 1)])
        }
        #expect(throws: QuadFormatError.self) {
            try Curves.build([InkSpec("K", limit: 50, start: 0, peak: 1), InkSpec("K", limit: 60, start: 0, peak: 1)])
        }
        #expect(throws: QuadFormatError.self) { try Curves.build([], gamma: 0) }
    }
}

@Suite("Separation")
struct SeparateParity {
    @Test func separationMatchesPythonExactly() throws {
        let v = try vectors("separate")
        let quad = try vectors("quadfile")
        let curve = try QuadCurve.parse(try #require(quad["golden_text"] as? String))
        let width = try #require((v["width"] as? NSNumber)?.intValue)
        let height = try #require((v["height"] as? NSNumber)?.intValue)
        let image = ints(v["image"]).map { UInt16($0) }
        let channels = Separate.separate(image: image, width: width, height: height, curve: curve)
        #expect(channels.flatMap { $0 }.map(Int.init) == ints(v["separation"]))
        let total = try #require((v["max_total_ink"] as? NSNumber)?.doubleValue)
        #expect(abs(Separate.maxTotalInk(curve) - total) < 1e-12)
    }
}
