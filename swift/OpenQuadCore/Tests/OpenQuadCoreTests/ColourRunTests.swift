// A colour calibration run from the target to a checked profile. The "printer" here is
// a perfect sRGB one: each page's own file is read back as its scan.

import Foundation
import Testing
@testable import OpenQuadCore

@Suite("Colour runs")
struct ColourRunTests {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("colour-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func targetThenRounds() throws {
        let base = try folder()
        defer { try? FileManager.default.removeItem(at: base) }
        let run = try ColourRun.start(folder: base.appendingPathComponent("run"), name: "plain", description: "MG3600 plain",
                                      printer: "Canon_MG3600_series", settings: "straight to the printer (lp)", ppi: 100)
        #expect(run.onTarget && !run.printed && run.pagesNeeded == 1)
        #expect(run.pagesToPrint.map(\.lastPathComponent) == ["plain-target.tif"])
        #expect(throws: RunError.self) { try run.measureTarget() }  // not scanned yet
        var jobs: [[String]] = []
        let ids = try run.printPages { args in
            jobs.append(args)
            return (0, "request id is Canon-7 (1 file(s))\n", "")
        }
        #expect(ids == ["Canon-7"] && run.printed)
        #expect(jobs.first?.contains("-d") == true)
        try run.useScan(run.pagesToPrint[0])
        let report = try run.measureTarget()
        #expect(report.heldOut.count == 255)
        #expect(!run.onTarget && run.current?.version == 0)
        #expect(FileManager.default.fileExists(atPath: run.profileURL!.path))
        let profile = try Data(contentsOf: run.profileURL!)
        #expect(profile[12..<24] == Data("prtrRGB Lab ".utf8))
        #expect(String(decoding: profile, as: UTF8.self).contains("MG3600 plain (OpenQuad v0)"))
        #expect(run.target?.summary?.contains("255 patches measured") == true)

        // Round 1: the verification page, printed another way, read back as its scan.
        #expect(throws: RunError.self) { try run.verification() }
        let pages = try run.makePages()
        #expect(pages.map(\.lastPathComponent) == ["plain-v0-verify.tif"])
        try run.markPrinted("print panel")
        try run.useScan(pages[0])
        let verdict = try run.measure()
        #expect(verdict.passed && verdict.mean < 1)
        #expect(run.current?.action == "done" && run.current?.assessment?["patches"] == 144)
        #expect(abs(try #require(try run.report()).mean - verdict.mean) < 1e-3)  // the saved measurement is rounded

        let again = try ColourRun.resume(run.folder)
        #expect(again.name == "plain" && again.printer == "Canon_MG3600_series" && again.rounds.count == 1)
        #expect(again.target?.scans == ["plain-target-scan1.tif"] && again.current?.job == "print panel" && again.ppi == 100)
        let next = try again.refine(damping: 0.3)
        #expect(next.version == 1 && again.current?.pages.isEmpty == true)
        #expect(FileManager.default.fileExists(atPath: run.folder.appendingPathComponent("plain-v1.icc").path))
        #expect(try ColourRun.resume(run.folder).rounds.map(\.action) == ["done", nil])  // refining keeps the verdict

        // The library lists both rounds' profiles, matches one to the printer and exports it.
        let library = CalibrationLibrary(folder: base)
        let profiles = library.colourProfiles()
        #expect(profiles.map(\.version).sorted() == [0, 1])
        #expect(profiles.first { $0.version == 0 }?.passed == true && profiles.first { $0.version == 0 }?.mean != nil)
        #expect(library.latestColourProfiles().count == 1)
        let match = try #require(library.matchColourProfile(printer: "Canon_MG3600_series", paper: "Letter"))
        #expect(match.label.hasPrefix("Canon MG3600 · Letter · v") && !match.viaPanel)
        #expect(library.matchColourProfile(printer: "Epson", paper: "Letter") == nil)
        #expect(library.colourProfile(run.profileURL!)?.version == 0 && library.colourProfile(again.profileURL!)?.version == 1)
        let exported = try library.exportToColorSync(match, folder: base.appendingPathComponent("ColorSync"))
        #expect(exported.lastPathComponent == "OpenQuad plain v\(match.version).icc")

        // Through a perfect sRGB printer's profile, sRGB colours send nearly as they are.
        let srgb: [UInt16] = [65535, 65535, 65535, 0, 0, 0, 32768, 32768, 32768, 52000, 20000, 9000]
        let device = try ColourConvert.toDevice(srgb, width: 2, height: 2, from: nil, to: try Data(contentsOf: run.folder.appendingPathComponent("plain-v0.icc")))
        let gaps = zip(srgb, device).map { abs(Int($0) - Int($1)) }
        #expect(gaps.max()! < 3000, "\(device)")
        #expect(device[0] > 64000 && device[3] < 1500 && abs(Int(device[6]) - Int(device[8])) < 600)
        #expect(ColourConvert.isRGBOutputProfile(profile) && !ColourConvert.isRGBOutputProfile(Data(count: 10)))

        #expect(throws: RunError.self) { try ColourRun.start(folder: base.appendingPathComponent("bad"), name: "a/b", printer: "x") }
        try Data("{}".utf8).write(to: base.appendingPathComponent("run.json"))
        #expect(throws: RunError.self) { try ColourRun.resume(base) }
    }

    @Test func twoPageTargetNeedsBothScans() throws {
        let base = try folder()
        defer { try? FileManager.default.removeItem(at: base) }
        let model = base.appendingPathComponent("model.json")
        let grid = linspace(0, 1, ScannerModel.curvePoints)
        let json: [String: Any] = ["kind": "matrix", "scanner": "Flatbed", "curves": [grid, grid, grid],
                                   "coefficients": [[0.4, 0.2, 0.02], [0.35, 0.7, 0.1], [0.2, 0.08, 0.7], [0, 0, 0]]]
        try JSONSerialization.data(withJSONObject: json).write(to: model)
        let run = try ColourRun.start(folder: base.appendingPathComponent("fine"), name: "glossy", printer: "Epson", scannerModel: model,
                                      grid: 9, ppi: 60)
        #expect(run.pagesNeeded == 2 && run.pagesToPrint.map(\.lastPathComponent) == ["glossy-target-1of2.tif", "glossy-target-2of2.tif"])
        #expect(try run.loadScannerModel()?.scanner == "Flatbed")
        try run.markPrinted("print panel")
        try run.useScan(run.pagesToPrint[1])
        #expect(!run.scannedAll)
        #expect(throws: RunError.self) { try run.measureTarget() }
        try run.clearScans()
        #expect(run.scansSoFar.isEmpty)
        #expect(throws: (any Error).self) { try ScannerModel.decode(Data("{\"kind\": \"lut\"}".utf8)) }
        let library = CalibrationLibrary(folder: base.appendingPathComponent("library"))
        let entry = try library.importScannerModel(model)
        #expect(entry.name == "Flatbed (model)" && library.scannerModels() == [entry])
        #expect(try library.importScannerModel(model) == entry)
        #expect(throws: (any Error).self) { try library.importScannerModel(run.folder.appendingPathComponent("run.json")) }
    }
}
