// The process wizard's smoothing setting (kept with the run) and exporting its curves
// for other software.

import Foundation
import OpenQuadCore
import Testing
@testable import OpenQuadUI

@MainActor
@Suite("Curve export")
struct CurveExportTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("openquad-export-\(UUID().uuidString)")

    @Test func smoothingIsKeptWithTheRunAndCurvesExport() throws {
        let wizard = ProcessWizardModel(folder: folder, scannerHost: "")
        #expect(wizard.smoothing == Smoothing.standard)
        wizard.smoothing = 9
        wizard.colours = ["green"]
        wizard.start()
        let run = try #require(wizard.run)
        #expect(run.smoothing == 9)
        wizard.smoothing = 3
        #expect(try ProcessRun.resume(run.folder).smoothing == 3)

        let later = ProcessWizardModel(folder: folder, scannerHost: "")
        later.resume(run.folder)
        #expect(later.smoothing == 3)

        for format in CurveExport.formats {
            let url = folder.appendingPathComponent("green.\(format)")
            later.exportCurve(to: url)
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        #expect(try Data(contentsOf: folder.appendingPathComponent("green.amp")) == Data(0...255))
        later.exportCurve(to: folder.appendingPathComponent("green.txt"))
        #expect(later.error?.contains("can't export") == true)
    }
}
