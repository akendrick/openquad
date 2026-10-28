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
    /// The last thing that happened (e.g. a print job sent), for the status line.
    public var status: String?
    /// CUPS printers on this Mac, for printing without the print panel.
    public private(set) var printers: [String] = []
    /// Saved calibrations to choose from: the newest of each printer and paper.
    public private(set) var calibrations: [LibraryEntry] = []
    public let library: CalibrationLibrary
    let settingsURL: URL
    private var previewToken = 0

    public init(settingsURL: URL = AppSettings.defaultURL(), libraryFolder: URL? = nil) {
        self.settingsURL = settingsURL
        library = CalibrationLibrary(folder: libraryFolder
            ?? settingsURL.deletingLastPathComponent().appendingPathComponent("calibrations"))
        settings = AppSettings.load(settingsURL)
        restore()
        refreshLibrary()
    }

    /// Re-read the calibrations folder (after a wizard or an import).
    public func refreshLibrary() {
        var entries = library.latest()
        if let path = session.calibrationPath, let current = CalibrationLibrary.entry(path),
           !entries.contains(where: { $0.url == current.url }) {
            entries.append(current)  // an older version, or a file kept elsewhere
        }
        calibrations = entries
    }

    /// The library entry for the calibration in use, if any.
    public var currentCalibration: LibraryEntry? {
        session.calibrationPath.flatMap { path in
            let resolved = path.resolvingSymlinksInPath()
            return calibrations.first { $0.url == resolved } ?? CalibrationLibrary.entry(path)
        }
    }

    /// Copy a calibration file into the library and use it.
    public func importCalibration(_ url: URL) {
        attempt {
            let entry = try library.importFile(url)
            try session.setCalibration(entry.url)
            remember()
            status = "Added \(entry.label) to your calibrations."
        }
        refreshLibrary()
    }

    /// When printing straight to a printer, use the newest calibration made for it and
    /// this paper; drop a calibration made for another printer.
    func matchCalibration() {
        guard let printer = session.printer else { return }
        if let match = library.match(printer: printer, paper: session.paper) {
            if match.url != session.calibrationPath?.resolvingSymlinksInPath() {
                attempt { try session.setCalibration(match.url) }
                status = "Using \(match.label) for this printer."
            }
        } else if let current = session.calibration, current.printer != printer {
            attempt { try session.setCalibration(nil) }
            status = "No calibration for \(LibraryEntry.printerName(printer)) on \(session.paper) yet: it will print uncorrected."
        }
        remember()
        refreshLibrary()
    }

    /// Look up the CUPS printers (off the main thread; none if CUPS isn't there).
    public func loadPrinters(_ list: @escaping @Sendable () throws -> [String] = { try Printing.listPrinters() }) {
        Task {
            let found = await Task.detached { (try? list()) ?? [] }.value
            printers = found
        }
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
        if let size = settings.maxSize, size.count == 2 { session.maxSize = (size[0], size[1]) }
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
        refreshLibrary()
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
        matchCalibration()
        refreshPreview()
    }

    /// A CUPS printer to print to directly, or nil to choose in the macOS print panel.
    public func setPrinter(_ name: String?) {
        session.printer = name
        settings.printer = name
        try? settings.save(settingsURL)
        matchCalibration()
    }

    public func setFit(_ on: Bool) {
        session.fit = on
        refreshPreview()
    }

    /// Fit within a set size (inches; the tissue's, for a negative), or nil for the page.
    /// Remembered, as the tissue rarely changes.
    public func setMaxSize(_ size: (Double, Double)?) {
        if let size, !(size.0 > 0 && size.1 > 0) { return }
        session.maxSize = size
        settings.maxSize = size.map { [$0.0, $0.1] }
        try? settings.save(settingsURL)
        refreshPreview()
    }

    /// The last set size, to offer when switching from the page to a set size.
    public var rememberedMaxSize: (Double, Double) {
        session.maxSize ?? settings.maxSize.flatMap { $0.count == 2 ? ($0[0], $0[1]) : nil } ?? (8, 10)
    }

    public func setPPI(_ ppi: Double?) {
        session.ppi = ppi.flatMap { $0 > 0 ? $0 : nil }
        refreshPreview()
    }

    // MARK: the blocking test and the calibration wizards

    public func blockingTest() -> BlockingTestModel { BlockingTestModel(scannerHost: settings.scannerHost ?? "") }

    /// Make negatives in the colour the blocking test found best.
    public func useBlockingColour(_ colour: String, scannerHost: String) {
        if !scannerHost.isEmpty { settings.scannerHost = scannerHost }
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
        ProcessWizardModel(folder: AppSettings.dataDirectory().appendingPathComponent("processes"),
                           scannerHost: settings.scannerHost ?? "")
    }

    public func finishCalibration(_ path: URL, scannerHost: String) {
        if !scannerHost.isEmpty { settings.scannerHost = scannerHost }
        setCalibration(path)
        if let entry = currentCalibration { status = "Using \(entry.label)." }
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

    /// Print straight to the chosen CUPS printer (lp), as the Python app does; the job id.
    public func printDirect(runner: @escaping Printing.Runner = Printing.runCommand) async -> String? {
        guard canPrint else { return nil }
        busy = true
        defer { busy = false }
        let snapshot = session
        nonisolated(unsafe) let runner = runner
        do {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("openquad-print-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let job = try await Task.detached(priority: .userInitiated) { try snapshot.print(scratch: scratch, runner: runner) }.value
            status = "Sent to \(snapshot.printer ?? "the printer"): job \(job)."
            error = nil
            return job
        } catch {
            self.error = String(describing: error)
            return nil
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
