// The blocking test and the calibration wizards.

import CoreGraphics
import Foundation
import OpenQuadCore

extension AppModel {
    // MARK: the blocking test and the calibration wizards

    public func blockingTest() -> BlockingTestModel {
        let test = BlockingTestModel(scannerHost: settings.scannerHost ?? "")
        test.paper = session.paper
        test.units = settings.units
        test.sheetSize = rememberedChartSize
        test.rememberSize = { [weak self] size in self?.saveSettings { $0.chartSize = size.map { [$0.0, $0.1] } } }
        return test
    }

    /// Make negatives in the colour the blocking test found best.
    public func useBlockingColour(_ colour: String, scannerHost: String) {
        if !scannerHost.isEmpty { saveSettings { $0.scannerHost = scannerHost } }
        session.setMode(.negative)
        if let process = session.process, process.colour != colour {
            error = "The process curve is for \(process.colour) negatives; clear it to use \(colour)."
        } else {
            attempt {
                try session.setNegativeColour(colour)
                remember()
            }
        }
        refreshPreview()
    }

    public func calibrationWizard() -> CalibrationWizardModel {
        CalibrationWizardModel(folder: library.folder, paper: session.paper, scannerHost: settings.scannerHost ?? "",
                               starting: session.calibration, startingName: currentCalibration?.label,
                               printers: printers, printer: session.printer ?? printers.first ?? "")
    }

    public func processWizard() -> ProcessWizardModel {
        let wizard = ProcessWizardModel(folder: processFolder,
                                        scannerHost: settings.scannerHost ?? "")
        wizard.paper = session.paper
        wizard.units = settings.units
        wizard.sheetSize = rememberedChartSize
        wizard.rememberSize = { [weak self] size in self?.saveSettings { $0.chartSize = size.map { [$0.0, $0.1] } } }
        return wizard
    }

    /// The test sheets' remembered preferred size (nil: their own).
    var rememberedChartSize: (Double, Double)? {
        AppSettings.load(settingsURL).chartSize.flatMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
    }

    public func finishCalibration(_ path: URL, scannerHost: String) {
        if !scannerHost.isEmpty { saveSettings { $0.scannerHost = scannerHost } }
        setCalibration(path)
        if let entry = currentCalibration { status = "Using \(entry.label)." }
    }

    public func finishProcess(_ path: URL, scannerHost: String) {
        if !scannerHost.isEmpty { saveSettings { $0.scannerHost = scannerHost } }
        forgetKnownCurves()
        setProcess(path)
    }
}
