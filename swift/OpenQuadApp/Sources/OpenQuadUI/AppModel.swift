// The print window's state: a thin layer over OpenQuadCore's PrintSession, like the
// Python app's window over openquad.session. Slow work (previews, full renders) runs
// off the main thread; toning is never remembered, so every launch starts neutral.

import CoreGraphics
import Foundation
import Observation
import OpenQuadCore

public let presetLabels: [(String, String)] = [
    ("neutral", "Neutral (no toning)"),
    ("black-red", "Black + red duotone"),
    ("red-only", "Red only"),
    ("warm-split", "Warm split tone"),
]

public let paperOrder = ["Letter", "Legal", "A4", "A5", "4x6", "5x7", "8x10"]

@MainActor
@Observable
public final class AppModel {
    public private(set) var session = PrintSession()
    public private(set) var settings: AppSettings
    public private(set) var preview: CGImage?
    public private(set) var busy = false
    public var error: String?
    let settingsURL: URL
    private var previewToken = 0

    public init(settingsURL: URL = AppSettings.defaultURL()) {
        self.settingsURL = settingsURL
        settings = AppSettings.load(settingsURL)
        restore()
    }

    private func restore() {
        try? session.setPaper(settings.paper)
        if let path = settings.calibration, FileManager.default.fileExists(atPath: path) {
            try? session.setCalibration(URL(fileURLWithPath: path))
        }
        if let path = settings.process, FileManager.default.fileExists(atPath: path) {
            try? session.setProcess(URL(fileURLWithPath: path))
        } else {
            try? session.setNegativeColour(settings.negativeColour)
        }
        session.printer = settings.printer
    }

    private func remember() {
        settings.paper = session.paper
        settings.calibration = session.calibrationPath?.path
        settings.process = session.processPath?.path
        settings.negativeColour = session.negativeColour
        settings.lastFolder = session.source?.deletingLastPathComponent().path ?? settings.lastFolder
        try? settings.save(settingsURL)
    }

    private func attempt(_ work: () throws -> Void) {
        do {
            try work()
            error = nil
        } catch {
            self.error = String(describing: error)
        }
    }

    // MARK: choosing things

    public func openPhoto(_ url: URL) {
        attempt {
            try session.open(url)
            remember()
        }
        refreshPreview()
    }

    public func setPreset(_ name: String) {
        attempt { try session.setPreset(name) }
        refreshPreview()
    }

    public func setCalibration(_ url: URL?) {
        attempt {
            try session.setCalibration(url)
            remember()
        }
    }

    public func setMode(_ mode: OutputMode) {
        session.setMode(mode)
        refreshPreview()
    }

    public func setNegativeColour(_ colour: String) {
        attempt {
            try session.setNegativeColour(colour)
            remember()
        }
        refreshPreview()
    }

    public func setProcess(_ url: URL?) {
        attempt {
            try session.setProcess(url)
            remember()
        }
        refreshPreview()
    }

    public func setMirror(_ on: Bool) {
        session.mirror = on
        refreshPreview()
    }

    public func setSafeEdge(_ inches: Double) {
        session.safeEdge = min(max(inches, 0), 2)
        refreshPreview()
    }

    public func setPaper(_ paper: String) {
        attempt {
            try session.setPaper(paper)
            remember()
        }
        refreshPreview()
    }

    public func setFit(_ on: Bool) {
        session.fit = on
        refreshPreview()
    }

    public func setPPI(_ ppi: Double?) {
        session.ppi = ppi.flatMap { $0 > 0 ? $0 : nil }
        refreshPreview()
    }

    // MARK: the calibration wizards

    public func calibrationWizard() -> CalibrationWizardModel {
        CalibrationWizardModel(folder: AppSettings.dataDirectory().appendingPathComponent("calibrations"), paper: session.paper,
                               scannerHost: settings.scannerHost ?? "", starting: session.calibration,
                               startingName: session.calibrationPath?.lastPathComponent)
    }

    public func processWizard() -> ProcessWizardModel {
        ProcessWizardModel(folder: AppSettings.dataDirectory().appendingPathComponent("processes"),
                           scannerHost: settings.scannerHost ?? "")
    }

    public func finishCalibration(_ path: URL, scannerHost: String) {
        if !scannerHost.isEmpty { settings.scannerHost = scannerHost }
        setCalibration(path)
    }

    public func finishProcess(_ path: URL, scannerHost: String) {
        if !scannerHost.isEmpty { settings.scannerHost = scannerHost }
        setProcess(path)
    }

    // MARK: what the window shows

    public var photoDescription: String {
        guard let photo = session.photo, let source = session.source else { return "No photo open" }
        var text = "\(source.lastPathComponent): \(photo.width) x \(photo.height) px"
        if let dpi = photo.dpi { text += String(format: ", %.0f ppi", dpi.0) }
        return ([text] + session.notes).joined(separator: "\n")
    }

    public var sizeDescription: String {
        guard session.photo != nil, let (width, height) = try? session.sizeInches(),
              let ppi = try? session.effectivePPI() else { return "" }
        var text = String(format: "%.2f x %.2f in at %.0f ppi", width, height, ppi)
        if (try? session.fitsOnPaper()) == false { text += "\nLarger than the paper: turn on Fit or lower the size." }
        return text
    }

    public var summary: [String] { (try? session.summary()) ?? [] }

    public var canPrint: Bool { session.photo != nil && ((try? session.fitsOnPaper()) ?? false) && !busy }

    // MARK: work off the main thread

    public func refreshPreview() {
        guard session.photo != nil else {
            preview = nil
            return
        }
        previewToken += 1
        let token = previewToken, snapshot = session
        Task.detached(priority: .userInitiated) {
            let image = (try? snapshot.preview())?.cgImage(eightBit: true)
            await MainActor.run {
                if token == self.previewToken { self.preview = image }  // a newer preview wins
            }
        }
    }

    /// The full-resolution print, rendered off the main thread.
    public func renderedPrint() async throws -> RGBImage {
        busy = true
        defer { busy = false }
        let snapshot = session
        return try await Task.detached(priority: .userInitiated) { try snapshot.renderPrint() }.value
    }

    public func savePrintFile(_ url: URL) async {
        busy = true
        defer { busy = false }
        let snapshot = session
        do {
            try await Task.detached(priority: .userInitiated) { try snapshot.writePrintFile(url) }.value
            error = nil
        } catch {
            self.error = String(describing: error)
        }
    }

    /// Everything the native print panel needs: the rendered image, its size and a title.
    public func printRequest() async -> (RGBImage, Double, Double, String, String)? {
        guard canPrint, let (width, height) = try? session.sizeInches() else { return nil }
        do {
            let image = try await renderedPrint()
            let title = session.source.map { "OpenQuad: \($0.lastPathComponent)" } ?? "OpenQuad"
            return (image, width, height, session.paper, title)
        } catch {
            self.error = String(describing: error)
            return nil
        }
    }
}
