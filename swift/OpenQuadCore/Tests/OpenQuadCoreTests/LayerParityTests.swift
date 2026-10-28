// Parity for colour layers, negatives, paper fitting, calibrations and process curves.
// Expected values come from src/openquad via scripts/export_swift_vectors.py.

import Foundation
import Testing
@testable import OpenQuadCore

func triple(_ value: Any?) -> (Double, Double, Double) {
    let d = doubles(value)
    return (d[0], d[1], d[2])
}

@Suite("Colour layers")
struct CompositeParity {
    @Test func presetsRenderLikePython() throws {
        let v = try vectors("composite")
        let image = ints(v["image"]).map { UInt16($0) }
        let presets = try #require(v["presets"] as? [String: [String: Any]])
        #expect(Set(presets.keys) == Set(Composite.presets.keys))
        for (name, preset) in presets {
            let expected = ints(preset["rgb"]).map { UInt16($0) }
            #expect(Composite.composite(image, layers: Composite.presets[name]!) == expected, "\(name)")

            // The exported layer definitions match the built-in ones.
            let layers = try #require(preset["layers"] as? [[String: Any]])
            let builtIn = Composite.presets[name]!
            #expect(layers.count == builtIn.count)
            for (exported, layer) in zip(layers, builtIn) {
                let tone = try #require(exported["tone"] as? [String: Any])
                let c = triple(exported["colour"])
                #expect(exported["name"] as? String == layer.name)
                #expect(c == layer.colour)
                #expect((tone["limit"] as? Double) == layer.tone.limit)
                #expect((tone["start"] as? Double) == layer.tone.start)
                #expect((tone["peak"] as? Double) == layer.tone.peak)
                #expect((tone["end"] as? Double) == layer.tone.end)
                #expect((tone["shape"] as? String) == layer.tone.shape.rawValue)
            }
        }
    }

    @Test func defaultIsNeutral() {
        #expect(Composite.defaultPreset == "neutral")
    }
}

@Suite("Digital negatives")
struct NegativeParity {
    @Test func coloursMatch() throws {
        let v = try vectors("negative")
        let colours = try #require(v["colours"] as? [String: Any])
        #expect(Set(colours.keys) == Set(Negative.colours.keys))
        for (name, value) in colours { #expect(triple(value) == Negative.colours[name]!) }
    }

    @Test func inkToRGB() throws {
        let v = try vectors("negative")
        let coverage = doubles(v["coverage"])
        let expected = try #require(v["ink_to_rgb"] as? [String: Any])
        for (name, colour) in Negative.colours {
            let got = coverage.flatMap { c -> [Int] in
                let (r, g, b) = Negative.inkToRGB(c, colour)
                return [Int(r), Int(g), Int(b)]
            }
            #expect(got == ints(expected[name]), "\(name)")
        }
    }

    @Test func negativesWithSafeEdgeMarkAndMirror() throws {
        let v = try vectors("negative")
        let photo = try #require(v["photo"] as? [String: Any])
        let width = try #require(photo["width"] as? Int), height = try #require(photo["height"] as? Int)
        let pixels = ints(photo["pixels"]).map { UInt16($0) }
        let cases = try #require(v["cases"] as? [[String: Any]])
        #expect(cases.count == 4)
        for c in cases {
            let settings = NegativeSettings(colour: c["colour"] as! String, mirror: c["mirror"] as! Bool,
                                            safeEdge: (c["safe_edge"] as! NSNumber).doubleValue, mark: c["mark"] as! Bool)
            let got = Negative.make(pixels, width: width, height: height, settings: settings,
                                    dpi: (c["dpi"] as! NSNumber).doubleValue)
            let shape = ints(c["shape"])
            #expect([got.height, got.width, 3] == shape)
            #expect(got.pixels.map(Int.init) == ints(c["rgb"]), "\(settings)")
        }
    }
}

@Suite("Paper")
struct PaperParity {
    @Test func sizes() throws {
        let v = try vectors("paper")
        let papers = try #require(v["papers"] as? [String: Any])
        #expect(Set(papers.keys) == Set(Paper.sizes.keys))
        for (name, size) in papers {
            let d = doubles(size)
            #expect(d[0] == Paper.sizes[name]!.0 && d[1] == Paper.sizes[name]!.1)
        }
    }

    @Test func fitting() throws {
        let v = try vectors("paper")
        for f in try #require(v["fit"] as? [[String: Any]]) {
            let got = try Paper.fitPPI(width: f["width"] as! Int, height: f["height"] as! Int, paper: f["paper"] as! String)
            #expect(abs(got - (f["ppi"] as! NSNumber).doubleValue) < 1e-12)
        }
        for f in try #require(v["negative"] as? [[String: Any]]) {
            let got = try Paper.negativePPI(width: f["width"] as! Int, height: f["height"] as! Int,
                                            paper: f["paper"] as! String, safeEdge: (f["edge"] as! NSNumber).doubleValue)
            #expect(abs(got - (f["ppi"] as! NSNumber).doubleValue) < 1e-12)
        }
        for f in try #require(v["box"] as? [[String: Any]]) {
            let box = doubles(f["box"]), edge = (f["edge"] as! NSNumber).doubleValue
            let w = f["width"] as! Int, h = f["height"] as! Int
            let turned = Paper.oriented((box[0], box[1]), width: w, height: h)
            #expect([turned.0, turned.1] == doubles(f["oriented"]))
            let got = try Paper.boxPPI(width: w, height: h, box: (box[0], box[1]), border: edge)
            #expect(abs(got - (f["ppi"] as! NSNumber).doubleValue) < 1e-12)
        }
        #expect(throws: Paper.FitError.self) { try Paper.boxPPI(width: 300, height: 400, box: (0.4, 0.4), border: 0.25) }
        #expect(throws: Paper.FitError.self) { try Paper.boxPPI(width: 300, height: 400, box: (0, 4)) }
        #expect(throws: Paper.FitError.self) { try Paper.fitPPI(width: 10, height: 10, paper: "Tabloid") }
        #expect(throws: Paper.FitError.self) { try Paper.fitPPI(width: 10, height: 10, paper: "4x6", margin: 2) }
    }
}

@Suite("Calibration files")
struct CalibrationParity {
    @Test func oqcalAppliesLikePython() throws {
        let v = try vectors("calibration")
        let text = try #require(v["oqcal_text"] as? String)
        let calibration = try Calibration.decode(Data(text.utf8))
        #expect(calibration.apply(ints(v["rgb"]).map { UInt16($0) }).map(Int.init) == ints(v["applied"]))
        #expect(calibration.sentFor(ints(v["levels"]).map { UInt16($0) }).map(Int.init) == ints(v["sent_for"]))

        // Swift's own encoding reads back the same calibration.
        let again = try Calibration.decode(calibration.encode())
        #expect(again.levels == calibration.levels && again.curves == calibration.curves)
        #expect(again.printer == calibration.printer && again.created == calibration.created)
    }

    @Test func oqprocAppliesLikePython() throws {
        let v = try vectors("calibration")
        let text = try #require(v["oqproc_text"] as? String)
        let curve = try ProcessCurve.decode(Data(text.utf8))
        #expect(curve.colour == "green" && curve.film == "office")
        #expect(curve.apply(ints(v["grey"]).map { UInt16($0) }).map(Int.init) == ints(v["process_applied"]))
        let again = try ProcessCurve.decode(curve.encode())
        #expect(again.levels == curve.levels && again.curve == curve.curve && again.colour == curve.colour)
    }

    @Test func rejectsOtherFiles() {
        #expect(throws: FileFormatError.self) { try Calibration.decode(Data("{\"format\": \"x\"}".utf8)) }
        #expect(throws: FileFormatError.self) { try Calibration.decode(Data("not json".utf8)) }
        #expect(throws: FileFormatError.self) { try ProcessCurve.decode(Data("{\"format\": \"openquad-process\", \"version\": 1, \"levels\": [0, 0], \"curve\": [0, 1]}".utf8)) }
    }
}
