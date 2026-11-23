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
        await app.loadPrinters { ["Canon_MG3600_series", "PDF"] }
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
        // The print file was only for lp, which keeps its own copy: it isn't left behind.
        #expect(sent.last?.hasSuffix("openquad-print.tif") == true && !FileManager.default.fileExists(atPath: sent.last ?? ""))
        app.setPrinter(nil)
        #expect(app.session.printer == nil)
    }

    @Test func guideHasAWalkthroughPageForEveryTab() {
        let pages = GuideView.pages
        #expect(pages.first?.tab == nil && pages.first?.name == "Start Here")
        for tab in AppTab.allCases {  // every tab has its own page, and the ? opens it
            let index = GuideView.pageIndex(for: tab)
            #expect(pages[index].tab == tab && pages[index].name == tab.title)
        }
        #expect(GuideView.pageIndex(for: nil) == 0)
        for tab in AppTab.allCases { #expect(GuideView.page(for: tab).tab == tab) }  // each tab's own, for its panel
        #expect(pages.count == AppTab.allCases.count + 1)
        for page in pages {
            #expect(!page.purpose.isEmpty)
            #expect(page.walkthroughs.count >= 2, "\(page.name) needs a variety of walkthroughs")
            for walkthrough in page.walkthroughs {
                #expect(walkthrough.steps.count >= 3, "\(page.name): \(walkthrough.title)")
                #expect(walkthrough.steps.allSatisfy { !$0.action.isEmpty && !$0.detail.isEmpty })
            }
        }
        let titles = pages.flatMap { $0.walkthroughs.map(\.title) }
        #expect(Set(titles).count == titles.count)  // no two walkthroughs share a title
        for part in ["Print a colour photo", "Split by tone: multi-coat negatives", "Split by colour: tricolour negatives",
                     "Make one negative of many photos", "Calibrate a printer, round by round",
                     "Step 1: find the best blocking colour", "Step 2: calibrate the process curve"] {
            #expect(titles.contains(part))
        }
        let text = pages.flatMap { [$0.purpose] + $0.walkthroughs.flatMap { $0.steps.map { $0.action + $0.detail } } }.joined()
        #expect(!text.lowercased().contains("color") || text.contains("ColorSync"))  // always "colour"
    }
}
