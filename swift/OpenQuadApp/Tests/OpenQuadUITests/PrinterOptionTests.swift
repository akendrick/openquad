// Printing straight to a printer: its media type and quality, chosen in the app, remembered
// for that printer (per tab) and sent to lp.

import Foundation
import OpenQuadCore
import Testing
@testable import OpenQuadUI

@MainActor
@Suite("Printer media type and quality")
struct PrinterOptionTests {
    let folder: URL
    static let ppd = """
    *OpenUI *CNIJMediaType/Media Type: PickOne
    *DefaultCNIJMediaType: 0
    *CNIJMediaType 0/Plain Paper: ""
    *CNIJMediaType 28/Matte Photo Paper: ""
    *CloseUI: *CNIJMediaType
    *OpenUI *CNIJPrintQuality/Quality: PickOne
    *DefaultCNIJPrintQuality: 10
    *CNIJPrintQuality 0/Super Fine: ""
    *CNIJPrintQuality 10/Normal(Fine): ""
    *CloseUI: *CNIJPrintQuality
    """

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("openquad-printer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func model(_ role: TabRole = .print) -> AppModel {
        let m = AppModel(settingsURL: folder.appendingPathComponent("settings.json"), role: role)
        m.readPrinterOptions = { $0 == "Canon" ? Printing.parsePPD(Self.ppd) : [] }
        return m
    }

    @Test func aPrintersOwnSettingsAreOfferedAndRemembered() throws {
        let m = model()
        #expect(m.printerMedia == nil && m.printerOptionLines.isEmpty)  // the print panel has its own
        m.setPrinter("Canon")
        #expect(m.printerMedia?.keyword == "CNIJMediaType" && m.printerQuality?.keyword == "CNIJPrintQuality")
        #expect(m.printerOptionLines == ["Media type: printer default (Plain Paper)", "Quality: printer default (Normal(Fine))"])
        m.setPrinterOption("CNIJMediaType", "28")
        m.setPrinterOption("CNIJPrintQuality", "0")
        #expect(m.printerOptionLines == ["Media type: Matte Photo Paper", "Quality: Super Fine"])
        let photo = folder.appendingPathComponent("grey.tif")
        try ImageFiles.saveGrey(photo, GreyImage(width: 30, height: 40, pixels: Array(repeating: 30000, count: 1200), dpi: (100, 100)))
        m.openPhoto(photo)
        let job = try m.session.printJob(URL(fileURLWithPath: "/tmp/x.tif"))
        #expect(job.options.map { "\($0.0)=\($0.1)" } == ["CNIJMediaType=28", "CNIJPrintQuality=0"])

        let again = model()  // a new launch: the printer's settings come back
        again.setPrinter("Canon")
        #expect(again.session.printerOptions == ["CNIJMediaType": "28", "CNIJPrintQuality": "0"])
        again.setPrinterOption("CNIJPrintQuality", nil)
        #expect(again.session.printerOptions == ["CNIJMediaType": "28"])
        let negatives = model(.negative)  // the Negative tab keeps its own
        negatives.setPrinter("Canon")
        #expect(negatives.session.printerOptions.isEmpty)
        negatives.setPrinter("Other")
        #expect(negatives.printerMedia == nil && negatives.session.printerOptions.isEmpty)
        negatives.setPrinter(nil)
        #expect(negatives.printerOptionLines.isEmpty)
    }

    @Test func choicesThePrinterNoLongerOffersAreDropped() throws {
        var settings = AppSettings()
        settings.printer = "Canon"
        settings.printerOptions = ["Canon": ["CNIJMediaType": "99", "Gone": "1", "CNIJPrintQuality": "0"]]
        try settings.save(folder.appendingPathComponent("settings.json"))
        let m = model()
        m.setPrinter("Canon")
        #expect(m.session.printerOptions == ["CNIJPrintQuality": "0"])
    }
}
