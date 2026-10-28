// Parity for what the calibration wizards print, save and judge, and the two runs'
// workflows (against src/openquad/calibrate.py, process_run.py and chart.py).

import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OpenQuadCore

func digest(_ pixels: [UInt16]) -> String {
    var bytes = [UInt8]()
    bytes.reserveCapacity(pixels.count * 2)
    for v in pixels { bytes += [UInt8(v & 0xff), UInt8(v >> 8)] }
    return SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
}

func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("openquad-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A JPEG of a vector scan, as the scanner would send it.
func jpeg(of file: String) throws -> Data {
    let source = try #require(CGImageSourceCreateWithURL(try vectorURL(file) as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

/// A fake eSCL scanner that hands back one image.
func scanner(_ image: Data) -> ESCL.Fetch {
    { method, _, _ in
        switch method {
        case "POST": return (201, "/eSCL/ScanJobs/1", Data())
        case "GET": return (200, "", image)
        default: return (200, "", Data())
        }
    }
}

@Suite("Calibration wizards")
struct WizardParity {
    @Test func pagesRenderAsInPython() throws {
        let v = try vectors("wizards")
        let renders = try #require(v["renders"] as? [String: [String: Any]])
        let oqcal = try #require(try vectors("calibration")["oqcal_text"] as? String)
        let canon = try Calibration.decode(Data(oqcal.utf8))
        let levels: [UInt16] = OpenQuadCore.linspace(0, 65535, 257).map { UInt16($0.rounded(.toNearestOrEven)) }
        let shaped: [UInt16] = levels.map { level -> UInt16 in
            let value: Double = 65535 * Foundation.pow(Double(level) / 65535, 1.2)
            return UInt16(value.rounded(.toNearestOrEven))
        }
        let green = ProcessCurve(levels: levels, curve: shaped)
        let darker = ProcessCurve(levels: [0, 65535], curve: [0, 32768], colour: "orange")
        func check(_ key: String, _ shape: [Int], _ pixels: [UInt16]) {
            #expect(shape == ints(renders[key]?["shape"]), "\(key)")
            #expect(digest(pixels) == renders[key]?["sha256"] as? String, "\(key)")
        }
        let target = Targets.framedTarget(dpi: 50)
        check("framed_target", [target.height, target.width, 3], target.pixels)
        let plain = GreyBalance.comparisonPage(.identity(), dpi: 50)
        check("comparison_identity", [plain.height, plain.width, 3], plain.pixels)
        let corrected = GreyBalance.comparisonPage(canon, dpi: 50)
        check("comparison_canon", [corrected.height, corrected.width, 3], corrected.pixels)
        let photo = Chart.photo(dpi: 50)
        check("chart_photo", [photo.height, photo.width], photo.pixels)
        let compact = Chart.photo(layout: .compact(), dpi: 50, index: 2)
        check("chart_photo_compact_2", [compact.height, compact.width], compact.pixels)
        let negative = Chart.negative(colour: "green", process: green, mirror: true, dpi: 50)
        check("chart_negative", [negative.height, negative.width, 3], negative.pixels)
        let page = Chart.page(colours: ["green", "orange"], processes: [nil, darker], dpi: 60)
        check("chart_page", [page.height, page.width, 3], page.pixels)

        let sheet = Blocking.sheet(dpi: 50, labels: false)
        check("blocking_sheet", [sheet.height, sheet.width, 3], sheet.pixels)
        let mirrored = Blocking.sheet(dpi: 60, mirror: true, safeEdge: 0.3, labels: false)
        check("blocking_sheet_mirrored", [mirrored.height, mirrored.width, 3], mirrored.pixels)
        #expect(Negative.standardColours == v["standard_colours"] as? [String])
        #expect(Negative.mixtureColours == v["mixture_colours"] as? [String])
        let mixtures = Blocking.sheet(layout: BlockingLayout(colours: Negative.mixtureColours), dpi: 50, labels: false)
        check("blocking_sheet_mixtures", [mixtures.height, mixtures.width, 3], mixtures.pixels)
        let labelled = Blocking.sheet(dpi: 50)
        let inked = zip(labelled.pixels, sheet.pixels).filter { $0 != $1 }.count
        #expect(inked > 0 && labelled.pixels.count == sheet.pixels.count)  // the names are drawn, nothing else changes

        let identity = Calibration.identity()
        #expect(identity.levels.map(Int.init) == ints(v["identity_levels"]))
        #expect(identity.curves.flatMap { $0 }.map(Int.init) == ints(v["identity_curves"]))
    }

    @Test func assessmentsOfRealRounds() throws {
        for a in try #require(try vectors("wizards")["assessments"] as? [[String: Any]]) {
            let plain = try Measurement.decode(Data((a["uncorrected"] as! String).utf8))
            let corrected = try Measurement.decode(Data((a["corrected"] as! String).utf8))
            let result = Assessment.assess(uncorrected: plain, corrected: corrected)
            for (got, key) in [(result.worstCast, "worst_cast"), (result.meanCast, "mean_cast"), (result.worstTone, "worst_tone"),
                               (result.meanTone, "mean_tone"), (result.uncorrectedCast, "uncorrected_cast")] {
                #expect(abs(got - (a[key] as! NSNumber).doubleValue) < 1e-12, "\(key)")
            }
            #expect(result.nextStep == a["next_step"] as? String)
            #expect(result.summary() == a["summary"] as? String)
            // Swift writes the measurement as Python does (values rounded alike).
            let mine = try Measurement.decode(Data(try corrected.json().utf8))
            let theirs = try Measurement.decode(Data((a["measurement_json"] as! String).utf8))
            #expect(mine.levels == theirs.levels && mine.sent == theirs.sent && mine.rgb == theirs.rgb && mine.lab == theirs.lab)
        }
    }

    @Test func chartResultsAndReadingFiles() throws {
        let v = try vectors("wizards")
        let page = try #require(try vectors("reading")["page"] as? [String: Any])
        for (entry, expected) in zip(try #require(page["readings"] as? [[String: Any]]), try #require(v["chart_results"] as? [[String: Any]])) {
            let reading = ChartReading(levels: ints(entry["levels"]).map { UInt16($0) }, lightness: doubles(entry["lightness"]),
                                       strip: doubles(entry["strip"]), orientation: entry["orientation"] as! String,
                                       paper: (entry["paper"] as! NSNumber).doubleValue)
            let result = ProcessResult(reading)
            #expect(abs(result.worst - (expected["worst"] as! NSNumber).doubleValue) < 1e-12)
            #expect(abs(result.mean - (expected["mean"] as! NSNumber).doubleValue) < 1e-12)
            let mine = try ChartReading.decode(Data(try reading.json().utf8))
            let theirs = try ChartReading.decode(Data((expected["json"] as! String).utf8))
            #expect(mine.levels == theirs.levels && mine.lightness == theirs.lightness && mine.strip == theirs.strip
                    && mine.orientation == theirs.orientation && mine.paper == theirs.paper)
            #expect(try ChartReading.decode(Data(try reading.json().utf8)).levels == reading.levels)
        }
    }

    @Test func calibrationRunFromStartToANewVersion() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let run = try CalibrationRun.start(folder: folder, name: "canon-letter-plain", printer: "Canon_MG3600_series",
                                           scannerHost: "scanner.local")
        #expect(throws: RunError.self) { try CalibrationRun.start(folder: folder, name: "a/b", printer: "P") }
        #expect(run.current.version == 0 && run.current.calibration == "canon-letter-plain-v0.oqcal")
        #expect(throws: RunError(description: "scan the printed page first")) { try run.measure() }

        var command: [String] = []
        let id = try run.printPage { command = $0; return (0, "request id is Canon_MG3600_series-7 (1 file(s))\n", "") }
        #expect(id == "Canon_MG3600_series-7" && command.contains("ppi=300"))
        let page = try Scan.load(try #require(run.pageURL))
        #expect(page.width == GreyBalance.comparisonPage(.identity()).width)

        try run.scanPage(fetch: scanner(try jpeg(of: "wedge-pair-v5.png")))
        let (_, corrected, assessment) = try run.measure()
        #expect(corrected.levels.count == 21 && run.current.measurements.count == 2)
        #expect(run.current.assessment?["worst_cast"] == assessment.worstCast)

        try run.improve("grey balance")
        #expect(run.current.version == 1 && run.rounds[0].action == "grey balance")
        let again = try CalibrationRun.resume(folder)
        #expect(again.rounds == run.rounds && again.scannerHost == "scanner.local")
        #expect(try again.calibration().printer == "Canon_MG3600_series")
        try again.markPrinted("print panel")
        #expect(again.current.job == "print panel" && again.current.page != nil)
    }

    @Test func processRunReadsAPageAndRefines() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: RunError.self) { try ProcessRun.start(folder: folder, name: "x", colours: ["purple"]) }
        let run = try ProcessRun.start(folder: folder, name: "carbon-office", colours: ["green", "orange"], film: "office")
        try run.makePage()
        try run.markPrinted("printed from GIMP")
        #expect(run.current.job == "printed from GIMP")
        try run.useScan(try vectorURL("chart-page.png"))
        let results = try run.measure()
        let expected = try #require(try vectors("wizards")["chart_results"] as? [[String: Any]])
        for (colour, e) in zip(run.colours, expected) {
            #expect(abs(results[colour]!.worst - (e["worst"] as! NSNumber).doubleValue) < 1e-9, "\(colour)")
        }
        #expect(run.bestColour() == "orange")
        try run.refine()
        #expect(run.current.version == 1 && run.rounds[0].refined)
        let again = try ProcessRun.resume(folder)
        #expect(again.rounds == run.rounds && again.film == "office")
        #expect(try again.curve("orange").film == "office")
    }
}
