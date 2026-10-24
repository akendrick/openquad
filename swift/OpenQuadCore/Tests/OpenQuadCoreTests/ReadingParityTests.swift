// Parity for reading contact prints: two real carbon prints of the blocking sheet
// (tilted, sideways, mirrored) and simulated process-chart prints, read by
// src/openquad/blocking.py and chart.py.

import CryptoKit
import Foundation
import Testing
@testable import OpenQuadCore

func readingScan(_ entry: [String: Any]) throws -> Scan {
    let s = try scan(entry["file"] as! String)
    #expect([s.height, s.width, 3] == ints(entry["shape"]))
    let digest = SHA256.hash(data: Data(s.samples.map { UInt8($0) }))
    #expect(digest.map { String(format: "%02x", $0) }.joined() == entry["sha256"] as? String)
    return s
}

func close(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9) -> Bool {
    a.isNaN ? b.isNaN : abs(a - b) <= tolerance * max(1, abs(b))
}

func expectSteps(_ map: LightnessMap, _ layout: SheetSpec, dark: [(Double, Double)], light: [(Double, Double)], _ steps: Any?) throws {
    let s = try #require(steps as? [String: Any])
    let rough = try Reader.findSheets(map, aspect: layout.width / layout.height)[0]
    #expect([rough.top, rough.left, rough.bottom, rough.right] == ints(s["rough"]))
    let (turned, tilt) = Reader.deskew(map, rough)
    #expect(close(tilt, (s["tilt"] as! NSNumber).doubleValue, 1e-12))
    let (box, fit, score) = Reader.fitLayout(turned, rough, layout, dark: dark, light: light)
    #expect([box.top, box.left, box.bottom, box.right] == ints(s["box"]))
    #expect([fit.k, fit.rs, fit.cs] == ints(s["fit"]))
    #expect(close(score, (s["score"] as! NSNumber).doubleValue))
}

func expectReading(_ r: ChartReading, _ expected: Any?) throws {
    let e = try #require(expected as? [String: Any])
    #expect(r.levels.map(Int.init) == ints(e["levels"]))
    #expect(zip(r.lightness, doubles(e["lightness"])).allSatisfy { close($0, $1) })
    #expect(zip(r.strip, doubles(e["strip"])).allSatisfy { close($0, $1) })
    #expect(r.orientation == e["orientation"] as? String)
    #expect(close(r.paper, (e["paper"] as! NSNumber).doubleValue))
}

@Suite("Reading prints")
struct ReadingParity {
    @Test func pillowRotate() throws {
        let v = try vectors("reading")
        let shape = ints(v["rotate_shape"])
        let image = FloatImage(width: shape[1], height: shape[0], pixels: doubles(v["rotate_input"]).map { Float($0) })
        for r in try #require(v["rotations"] as? [[String: Any]]) {
            let centre = (r["centre"] as? [NSNumber]).map { ($0[0].doubleValue, $0[1].doubleValue) }
            let turned = pilRotate(image, angle: (r["angle"] as! NSNumber).doubleValue, centre: centre,
                                   fill: (r["fill"] as! NSNumber).doubleValue)
            #expect(turned.pixels.map(Double.init) == doubles(r["pixels"]), "angle \(r["angle"]!)")
        }
    }

    @Test func lightnessAndPercentiles() throws {
        let entry = try #require(try vectors("reading")["blocking"] as? [[String: Any]])[0]
        let map = LightnessMap(try readingScan(entry))
        var sample: [Double] = []
        for y in stride(from: 0, to: map.height, by: 97) { for x in stride(from: 0, to: map.width, by: 89) { sample.append(map[y, x]) } }
        #expect(zip(sample, doubles(entry["lightness_sample"])).allSatisfy { close($0, $1, 1e-12) })
        let p = percentile(map.values, [98, 2, 99, 50, 37.5])
        #expect(zip(p, doubles(entry["percentiles"])).allSatisfy { close($0, $1, 1e-12) })
    }

    @Test func realBlockingPrints() throws {
        for entry in try #require(try vectors("reading")["blocking"] as? [[String: Any]]) {
            let s = try readingScan(entry)
            let layout = BlockingLayout()
            try expectSteps(LightnessMap(s), layout, dark: layout.darkPoints(), light: layout.lightPoints(), entry["steps"])
            let report = try Blocking.analyse(s)
            let e = try #require(entry["report"] as? [String: Any])
            #expect(report.orientation == e["orientation"] as? String)
            #expect(close(report.paper, (e["paper"] as! NSNumber).doubleValue))
            #expect(close(report.edge, (e["edge"] as! NSNumber).doubleValue))
            #expect(close(report.white, (e["white"] as! NSNumber).doubleValue))
            #expect(zip(report.results.map(\.full), doubles(e["full"])).allSatisfy { close($0, $1) })
            let wedges = try #require(e["wedge"] as? [[NSNumber]])
            for (result, wedge) in zip(report.results, wedges) {
                #expect(zip(result.wedge, wedge.map(\.doubleValue)).allSatisfy { close($0, $1) })
            }
            #expect(report.lines() == e["lines"] as? [String])
        }
    }

    @Test func simulatedCharts() throws {
        let layout = ChartLayout()
        let (dark, light) = layout.points()
        for entry in try #require(try vectors("reading")["charts"] as? [[String: Any]]) {
            let s = try readingScan(entry)
            try expectSteps(LightnessMap(s), layout, dark: dark, light: light, entry["steps"])
            try expectReading(try Chart.read(s), entry["reading"])
        }
    }

    @Test func pageOfTwoCharts() throws {
        let page = try #require(try vectors("reading")["page"] as? [String: Any])
        let readings = try Chart.readPage(try readingScan(page), count: 2)
        let expected = try #require(page["readings"] as? [Any])
        #expect(readings.count == 2)
        for (r, e) in zip(readings, expected) { try expectReading(r, e) }
    }

    @Test func blankScansAreRefused() {
        let grey = Scan(width: 60, height: 50, samples: [UInt16](repeating: 128, count: 60 * 50 * 3), scale: 255)
        #expect(throws: BlockingError.self) { try Blocking.analyse(grey) }
        #expect(throws: BlockingError.self) { try Chart.read(grey) }
    }
}
