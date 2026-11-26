// Colour calibration (target, measuring, profile, verification) against the Python
// reference. The random numbers and layouts match exactly; the fits use LAPACK, so the
// model and the tables searched from it match to small tolerances, not to the bit.

import Foundation
import Testing
@testable import OpenQuadCore

private func triples(_ flat: [Double]) -> [[Double]] {
    stride(from: 0, to: flat.count, by: 3).map { Array(flat[$0..<$0 + 3]) }
}

private func close(_ a: [Double], _ b: [Double], _ tolerance: Double) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
}

private func section(_ name: String) throws -> [String: Any] {
    try #require(try vectors("colour-calibration")[name] as? [String: Any])
}

/// The simulated printer's measurement of the 6-level target, from the vectors.
private func targetMeasurement() throws -> ColourMeasurement {
    let p = try section("profile")
    let target = try ColourTargets.make()
    return ColourMeasurement(sent: target.sent, xyz: target.sent.map { _ in [0, 0, 0] }, lab: triples(doubles(p["measured_lab"])),
                             paperXYZ: doubles(p["paper"]))
}

@Suite("Colour calibration")
struct ColourCalibrationParity {
    @Test func maths() throws {
        let m = try section("maths")
        let xyz = triples(doubles(m["xyz"]))
        #expect(close(xyz.flatMap { Colour.xyzToLab($0, white: Colour.d50White) }, doubles(m["lab_d50"]), 1e-9))
        #expect(close(xyz.flatMap { Colour.labToXYZ(Colour.xyzToLab($0, white: Colour.d50White), white: Colour.d50White) },
                      doubles(m["back"]), 1e-12))
        #expect(close(xyz.flatMap(Colour.d65ToD50), doubles(m["d50"]), 1e-12))
        let de = zip(triples(doubles(m["lab1"])), triples(doubles(m["lab2"]))).map { Colour.deltaE2000($0, $1) }
        #expect(close(de, doubles(m["delta_e"]), 1e-9))
        var rng = NumpyRandom(seed: 7)
        #expect(rng.permutation(300) == ints(m["permutation"]))
        var uniform = NumpyRandom(seed: 13)
        #expect(uniform.uniform(0.03, 0.97, count: 30) == doubles(m["uniform"]))
    }

    @Test func targetLayoutAndPage() throws {
        let t = try section("target")
        let small = try ColourTargets.make(), fine = try ColourTargets.make(grid: 9)
        #expect(small.sent.flatMap { $0.map(Int.init) } == ints(t["sent"]))
        #expect(small.columns == t["columns"] as? Int && small.pages.count == t["pages"] as? Int)
        #expect(fine.sent.flatMap { $0.map(Int.init) } == ints(t["fine_sent"]))
        #expect(fine.columns == t["fine_columns"] as? Int && fine.pages.map(\.count) == ints(t["fine_pages"]))
        // The Python layout's JSON reads back as the same target.
        let json = try #require(t["json"] as? String)
        #expect(try ColourTarget.decode(Data(json.utf8)) == small)
        #expect(try ColourTarget.decode(Data(try small.json().utf8)) == small)
        let page = small.page(0, dpi: 60)
        #expect([page.width, page.height] == ints(t["page_size"]))
        let rowSums = (0..<page.height).map { y in (0..<(page.width * 3)).reduce(0) { $0 + Int(page.pixels[y * page.width * 3 + $1]) } }
        #expect(rowSums == ints(t["page_rows"]))
        let columnSums = (0..<page.width).map { x in
            (0..<page.height).reduce(0) { sum, y in sum + (0..<3).reduce(0) { $0 + Int(page.pixels[(y * page.width + x) * 3 + $1]) } }
        }
        #expect(columnSums == ints(t["page_columns"]))
    }

    @Test func measuringAPage() throws {
        let t = try section("target")
        let target = try ColourTargets.make()
        let page = target.page(0, dpi: 60)
        let scan = Scan(width: page.width, height: page.height, samples: page.pixels, scale: 65535)
        let plain = try ColourMeasure.measure([scan], target: target)
        #expect(close(plain.xyz.flatMap { $0 }, doubles(t["plain_xyz"]), 1e-12))
        #expect(close(plain.lab.flatMap { $0 }, doubles(t["plain_lab"]), 1e-9))
        #expect(close(plain.paperXYZ, doubles(t["plain_paper"]), 1e-12))
        #expect(plain.summary() == t["plain_summary"] as? String)
        // Upside down, through a scanner model.
        let model = try ScannerModel.decode(Data(try #require(t["scanner_model"] as? String).utf8))
        let modelled = try ColourMeasure.measure([scan.turned()], target: target, model: model)
        #expect(close(modelled.xyz.flatMap { $0 }, doubles(t["modelled_xyz"]), 1e-12))
        #expect(close(modelled.lab.flatMap { $0 }, doubles(t["modelled_lab"]), 1e-9))
        #expect(modelled.colourimetry == "scanner model for Test scanner, D50")
        #expect(throws: MeasureError.self) { try ColourMeasure.measure([scan, scan], target: target) }
        #expect(throws: MeasureError.self) { try ColourMeasure.measure([], target: target) }
    }

    /// The page with paper round it, each row shifted rint(y * tan) pixels, as the vectors' was.
    func sheared(_ page: RGBImage, degrees: Double, margin: Int = 40) -> Scan {
        let width = page.width + 2 * margin, height = page.height + 2 * margin
        var samples = [UInt16](repeating: 65535, count: width * height * 3)
        let slope = tan(degrees * .pi / 180)
        for y in 0..<page.height {
            let x = margin + Int((Double(y) * slope).rounded(.toNearestOrEven))
            for i in 0..<(page.width * 3) {
                samples[((margin + y) * width + x) * 3 + i] = page.pixels[y * page.width * 3 + i]
            }
        }
        return Scan(width: width, height: height, samples: samples, scale: 65535)
    }

    @Test func labelledSheetsSayWhatTheyAreAndStillMeasure() throws {
        let target = try ColourTargets.make()
        let page = target.page(0, dpi: 60)
        let sheet = ColourTargets.labelled(page, text: "OpenQuad colour target · page 1 of 1", dpi: 60)
        #expect(sheet.width == page.width && sheet.height == page.height + Int((ColourTargets.labelStrip * 60).rounded()))
        #expect(Array(sheet.pixels.prefix(page.pixels.count)) == page.pixels)
        #expect(sheet.pixels.dropFirst(page.pixels.count).contains { $0 < 20000 })  // the text is there
        let plain = try ColourMeasure.measure([Scan(width: page.width, height: page.height, samples: page.pixels, scale: 65535)],
                                              target: target)
        let labelledScan = Scan(width: sheet.width, height: sheet.height, samples: sheet.pixels, scale: 65535)
        let measured = try ColourMeasure.measure([labelledScan], target: target)
        #expect(close(measured.lab.flatMap { $0 }, plain.lab.flatMap { $0 }, 1e-9))
    }

    @Test func tiltedPagesAreStraightenedOrRefused() throws {
        let t = try section("target")
        let target = try ColourTargets.make()
        let padded = sheared(target.page(0, dpi: 60), degrees: 0)
        let centre = (Double(padded.width) / 2, Double(padded.height) / 2)
        let cases = try #require(t["tilts"] as? [[String: Any]])
        #expect(cases.count == 4)
        for c in cases {
            let degrees = try #require(c["degrees"] as? Double)
            let scan = ColourMeasure.straightened(padded, degrees: -degrees, pivot: centre)
            let frame = try #require(try ColourMeasure.frames(scan).first)
            #expect([frame.left, frame.top, frame.right, frame.bottom] == ints(c["frame"]))
            #expect(abs(ColourMeasure.tilt(scan, frame, target) - (try #require(c["tilt"] as? Double))) < 1e-8)
            if let message = c["result"] as? String {
                #expect(throws: MeasureError(description: message)) { try ColourMeasure.locate(scan, target) }
            } else {
                let (page, _, straight) = try ColourMeasure.locate(scan, target)
                #expect(page == c["result"] as? Int)
                #expect(straight.samples.reduce(0) { $0 + Int($1) } == c["straight_sum"] as? Int)
                let measured = try ColourMeasure.measure([scan], target: target)
                #expect(close(measured.xyz.flatMap { $0 }, doubles(c["xyz"]), 1e-12))
            }
        }
    }

    @Test func forwardModelAndReport() throws {
        let p = try section("profile")
        let report = try ProfileReport.build([try targetMeasurement()])
        #expect(report.model.smoothing == p["smoothing"] as? Double)
        #expect(close(report.model.nodes, doubles(p["nodes"]), 1e-6))
        #expect(close(report.heldOut, doubles(p["held_out"]), 1e-6))
        #expect(close(report.fitted, doubles(p["fitted"]), 1e-6))
        #expect(close(report.neutralCast, doubles(p["neutral_cast"]), 0.05))
        #expect(report.summary() == p["summary"] as? String)
        // The model Python saved reads back as the same model.
        let saved = try ForwardModel.decode(Data(try #require(p["model_json"] as? String).utf8))
        #expect(close(saved.nodes, report.model.nodes, 1e-4) && saved.size == 9)
    }

    @Test func inverseAndTables() throws {
        let p = try section("profile")
        let model = try ForwardModel.decode(Data(try #require(p["model_json"] as? String).utf8))
        let wanted = triples(doubles(p["wanted"]))
        let found = ColourProfiles.invert(model, wanted)
        // Each RGB found prints as close to what was wanted as Python's (to 0.05 ΔE76).
        for (rgb, (want, theirs)) in zip(found, zip(wanted, triples(doubles(p["inverse"])))) {
            #expect(Colour.deltaE76(model.lab(rgb), want) <= Colour.deltaE76(model.lab(theirs), want) + 0.05)
        }
        let black = ColourProfiles.blackPoint(model)
        #expect(close(black, doubles(p["black"]), 1e-6))
        #expect(close(wanted.flatMap { ColourProfiles.compensateBlack($0, black: black) }, doubles(p["compensated"]), 1e-4))
        let tables = ProfileTables.build(model)
        #expect(close(tables.a2b.flatMap { $0 }, doubles(p["a2b"]), 1e-3))
        let every = try #require(p["every"] as? Int)
        let picked = stride(from: 0, to: tables.gamut.count, by: every).map { $0 }
        for (name, table) in [("b2a_perceptual", tables.b2aPerceptual), ("b2a_colourimetric", tables.b2aColourimetric)] {
            let theirs = triples(doubles(p[name]))
            // Within the gamut both searches land on the same RGB; outside it, on equally near ones.
            let gaps = zip(picked.map { table[$0] }, theirs).map { mine, py in zip(mine, py).map { abs($0 - $1) }.max()! }
            #expect(gaps.filter { $0 > 0.01 }.count < gaps.count / 50, "\(name): \(gaps.filter { $0 > 0.01 }.count) of \(gaps.count) differ")
        }
        let gamut = doubles(p["gamut"])
        #expect(zip(picked.map { tables.gamut[$0] }, gamut).allSatisfy { abs($0 - $1) < 0.05 + 0.002 * $1 })
    }

    @Test func iccProfileLayout() throws {
        let p = try section("profile")
        let model = try ForwardModel.decode(Data(try #require(p["model_json"] as? String).utf8))
        var parts = DateComponents()
        (parts.year, parts.month, parts.day, parts.hour) = (2026, 11, 24, 12)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let profile = ColourProfiles.iccProfile(model, description: "Test printer", created: try #require(calendar.date(from: parts)))
        #expect(profile.count == p["icc_size"] as? Int)
        let head = ints(p["icc_head"])
        // Header and tag table match, except the black point's bytes (a fitted value).
        let mine = [UInt8](profile.prefix(head.count)).map(Int.init)
        #expect(mine.count == head.count && zip(mine, head).filter { $0 != $1 }.count == 0)
        #expect(profile[36..<40] == Data("acsp".utf8))
    }

    @Test func verificationPage() throws {
        let v = try section("verify")
        let (names, groups, wanted) = ColourVerification.colours()
        #expect(names == v["names"] as? [String] && groups == v["groups"] as? [String])
        #expect(close(wanted.flatMap { $0 }, doubles(v["wanted"]), 1e-9))
        let json = try #require(v["json"] as? String)
        let page = try VerificationTarget.decode(Data(json.utf8))
        #expect(page.names == v["page_names"] as? [String])
        #expect(page.target.sent.flatMap { $0.map(Int.init) } == ints(v["page_sent"]))
        #expect(page.printable == v["printable"] as? [Bool])
        let model = try ForwardModel.decode(Data(try #require(try section("profile")["model_json"] as? String).utf8))
        let made = try ColourVerification.make(model)
        #expect(made.names == page.names && made.printable == page.printable)
        let sentGaps = zip(made.target.sent.flatMap { $0 }, page.target.sent.flatMap { $0 }).map { abs(Int($0) - Int($1)) }
        #expect(sentGaps.filter { $0 > 64 }.isEmpty, "largest difference \(sentGaps.max()!)")
        // Judging Python's page against its measurement gives Python's verdict.
        let lab = triples(doubles(v["measured_lab"]))
        let measurement = ColourMeasurement(sent: page.target.sent, xyz: lab, lab: lab, paperXYZ: Colour.d50White)
        let report = try ColourVerification.verify(measurement, page)
        #expect(close(report.deltaE, doubles(v["delta_e"]), 1e-9))
        let assessment = try #require(v["assessment"] as? [String: NSNumber]).mapValues(\.doubleValue)
        #expect(report.assessment == assessment)
        #expect(report.passed == v["passed"] as? Bool)
        #expect(report.summary() == v["summary"] as? String)
        let refined = try ColourVerification.refine(model, measurement)
        #expect(close(refined.nodes, doubles(v["refined"]), 1e-4))
    }
}
