// The blocking test, printing straight to a CUPS printer, and the guide.

import Foundation
import OpenQuadCore
import Testing
@testable import OpenQuadUI

@MainActor
@Suite("Blocking test, direct printing and the guide")
struct GapsTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("openquad-gaps-\(UUID().uuidString)")

    func photo() throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("ramp.tif")
        let pixels = (0..<(60 * 40)).map { UInt16(($0 % 60) * 1110) }
        try ImageFiles.saveGrey(url, GreyImage(width: 60, height: 40, pixels: pixels, dpi: (300, 300)))
        return url
    }

    @Test func blockingSheetAndUsingItsColour() throws {
        let test = BlockingTestModel(scannerHost: "", find: { [] })
        let request = test.printRequest()
        #expect(request.0.width == Blocking.sheet().width && request.1 == Double(request.0.width) / 300)
        test.mirror = true
        #expect(test.sheet().pixels != request.0.pixels)  // mirrored
        test.read()
        #expect(test.error?.hasPrefix("Choose a scanner") == true && test.best == nil)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        test.save(folder.appendingPathComponent("blocking-test.tif"))
        #expect(try Scan.load(folder.appendingPathComponent("blocking-test.tif")).width == request.0.width)

        test.mirror = false
        #expect(test.layout.colours == Negative.standardColours)
        test.chart = .mixtures
        #expect(test.layout.colours == Negative.mixtureColours && test.printRequest().4 == "OpenQuad ink-mixture chart")
        #expect(test.sheet().height > request.0.height)  // ten rows instead of six

        let app = AppModel(settingsURL: folder.appendingPathComponent("settings.json"))
        app.useBlockingColour("orange", scannerHost: "scanner.local")
        #expect(app.session.negative && app.session.negativeColour == "orange" && app.settings.scannerHost == "scanner.local")
    }

    @Test func printsStraightToTheChosenPrinter() async throws {
        let app = AppModel(settingsURL: folder.appendingPathComponent("settings.json"))
        app.loadPrinters { ["Canon_MG3600_series", "PDF"] }
        for _ in 0..<200 where app.printers.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(app.printers == ["Canon_MG3600_series", "PDF"])
        app.openPhoto(try photo())
        app.setPrinter("Canon_MG3600_series")
        #expect(AppModel(settingsURL: folder.appendingPathComponent("settings.json")).session.printer == "Canon_MG3600_series")
        var sent: [String] = []
        let job = await app.printDirect { command in
            sent = command
            return (0, "request id is Canon_MG3600_series-12 (1 file(s))\n", "")
        }
        #expect(job == "Canon_MG3600_series-12" && app.status == "Sent to Canon_MG3600_series: job Canon_MG3600_series-12.")
        #expect(sent.prefix(3) == ["lp", "-d", "Canon_MG3600_series"] && sent.contains("PageSize=Letter"))
        app.setPrinter(nil)
        #expect(app.session.printer == nil)
    }

    @Test func guideCoversEveryPart() {
        let titles = GuideView.pages.map(\.title)
        #expect(titles.count == 7 && titles.first == "Welcome to OpenQuad")
        for part in ["Print a photo", "Calibrate your printer", "Digital negatives", "Find the best blocking colour",
                     "Calibrate the process"] {
            #expect(titles.contains(part))
        }
        #expect(GuideView.pages.allSatisfy { !$0.steps.isEmpty })
    }
}
