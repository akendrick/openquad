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

/// Which tab a model serves: the Print tab or the Negative tab. Each keeps its own photo,
/// printer and paper; the rest of the settings are shared.
public enum TabRole: Sendable {
    case print, negative
}

@MainActor
@Observable
public final class AppModel {
    public let role: TabRole
    public private(set) var session = PrintSession()
    public private(set) var settings: AppSettings
    public private(set) var preview: CGImage?
    public private(set) var busy = false
    public var error: String?
    /// The last thing that happened (e.g. a print job sent), for the status line.
    public var status: String?
    /// A new process curve is in use: offer to save it as a setup (Negative tab).
    public var setupOffer: String?
    /// CUPS printers on this Mac, for printing without the print panel.
    public private(set) var printers: [String] = []
    /// Printer and paper ICC profiles on this Mac, to soft-proof a colour print with.
    public private(set) var proofProfiles: [ProofProfile] = []
    /// Saved calibrations to choose from: the newest of each printer and paper.
    public private(set) var calibrations: [LibraryEntry] = []
    public let library: CalibrationLibrary
    /// Saved negative setups (process curve, colour, mirror, edges, printer, paper).
    public let setupLibrary: SetupLibrary
    public private(set) var setups: [NegativeSetup] = []
    let settingsURL: URL
    private var previewToken = 0

    public init(settingsURL: URL = AppSettings.defaultURL(), libraryFolder: URL? = nil, setupsFolder: URL? = nil,
                role: TabRole = .print) {
        self.role = role
        self.settingsURL = settingsURL
        library = CalibrationLibrary(folder: libraryFolder
            ?? settingsURL.deletingLastPathComponent().appendingPathComponent("calibrations"))
        setupLibrary = SetupLibrary(folder: setupsFolder
            ?? settingsURL.deletingLastPathComponent().appendingPathComponent("setups"))
        setups = setupLibrary.all()
        settings = AppSettings.load(settingsURL)
        restore()
        refreshLibrary()
        session.setMode(role == .negative ? .negative : .print)
    }

    /// Change the settings file: re-read it first, as the other tab may have changed it.
    private func saveSettings(_ change: (inout AppSettings) -> Void) {
        settings = AppSettings.load(settingsURL)
        change(&settings)
        try? settings.save(settingsURL)
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

    /// Look up the printer and paper ICC profiles (off the main thread).
    public func loadProofProfiles(_ list: @escaping @Sendable () -> [ProofProfile] = { SoftProof.profiles() }) {
        Task {
            proofProfiles = await Task.detached { list() }.value
        }
    }

    private func restore() {
        try? session.setPaper(role == .negative ? settings.negativePaper ?? settings.paper : settings.paper)
        if let path = settings.calibration, FileManager.default.fileExists(atPath: path) {
            try? session.setCalibration(URL(fileURLWithPath: path))
        }
        if let path = settings.process, FileManager.default.fileExists(atPath: path) {
            try? session.setProcess(URL(fileURLWithPath: path))
        } else {
            try? session.setNegativeColour(settings.negativeColour)
        }
        session.printer = role == .negative ? settings.negativePrinter ?? settings.printer : settings.printer
        if let size = settings.maxSize, size.count == 2 { session.maxSize = (size[0], size[1]) }
        session.units = settings.units
    }

    /// Lengths shown and typed in the app (the session keeps inches). Remembered.
    public var units: LengthUnit { settings.units }

    public func setUnits(_ units: LengthUnit) {
        session.units = units
        saveSettings { $0.units = units }
    }

    /// Take up the unit the other tab chose.
    public func followUnits() { session.units = AppSettings.load(settingsURL).units }

    private func remember() {
        let session = session
        saveSettings { settings in
            if session.negative {
                settings.negativePaper = session.paper
                settings.process = session.processPath?.path
                settings.negativeColour = session.negativeColour
            } else {
                settings.paper = session.paper
                settings.calibration = session.calibrationPath?.path
            }
            settings.lastFolder = session.source?.deletingLastPathComponent().path ?? settings.lastFolder
        }
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

    /// The photo is colour and this is the Print tab: it can be printed in colour.
    public var canPrintColour: Bool { role == .print && session.photo?.colour != nil }

    /// Print the colour photo in colour on a colour-managed printer, or in greyscale.
    public func setColourPrint(_ on: Bool) {
        attempt { try session.setColourPrint(on) }
        refreshPreview()
    }

    /// The profile colour prints are soft-proofed with in the preview (nil: none). Remembered.
    public var proofProfile: URL? { settings.proofProfile.map { URL(fileURLWithPath: $0) } }

    public func setProofProfile(_ url: URL?) {
        saveSettings { $0.proofProfile = url?.path }
        refreshPreview()
    }

    /// What the preview shows, when it isn't simply the print: a colour print, soft-proofed or not.
    public var previewCaption: String? {
        guard session.printsColour else { return nil }
        guard let url = proofProfile else { return "Colour print: the photo's own colours, colour-managed by macOS" }
        let name = proofProfiles.first { $0.url == url }?.name ?? url.deletingPathExtension().lastPathComponent
        return "Soft-proof: \(name)"
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

    /// The black guide line round the image (in a negative's safe edge, or a white border
    /// round a print), visible under a red safelight.
    public func setGuide(_ on: Bool) {
        session.guide = on
        refreshPreview()
    }

    /// Crosshair targets and corner crop marks, for lining the sheet up in the darkroom.
    public func setRegistration(_ on: Bool) {
        session.registration = on
        refreshPreview()
    }

    /// The black outline's width, kept while it is turned off so turning it back on restores it.
    public private(set) var outlineSize = 0.1

    /// Turn the black outline (between the safe edge and the photo) on or off.
    public func setOutline(_ on: Bool) {
        session.outline = on ? outlineSize : 0
        refreshPreview()
    }

    public func setOutlineSize(_ inches: Double) {
        outlineSize = min(max(inches, 0.01), 1)
        if session.outline > 0 { session.outline = outlineSize }
        refreshPreview()
    }

    // MARK: separations

    /// The separation as shown: split points and overlap counted on a step scale.
    public private(set) var separationSteps = SeparationPlan.defaultSteps
    public private(set) var separationSplits: [Int] = []
    public private(set) var separationOverlap = 0.0

    /// Split the negative into `count` negatives with even bands (1: no separation).
    public func setNegativeCount(_ count: Int) {
        let count = min(max(count, 1), SeparationPlan.maxNegatives)
        separationSplits = (1..<count).map { Int((Double($0 * separationSteps) / Double(count)).rounded()) }
        applySeparation()
    }

    /// Count the split points on a scale of `steps` steps, keeping them where they were.
    public func setSeparationSteps(_ steps: Int) {
        let steps = min(max(steps, separationSplits.count + 1, 2), 101)
        let scale = Double(steps) / Double(separationSteps)
        separationSplits = Self.spread(separationSplits.map { Int((Double($0) * scale).rounded()) }, steps: steps)
        separationOverlap = (separationOverlap * scale * 2).rounded() / 2
        separationSteps = steps
        applySeparation()
    }

    /// Move split point `index` (0 = between the first two negatives), within its neighbours.
    public func setSplit(_ index: Int, step: Int) {
        guard separationSplits.indices.contains(index) else { return }
        let low = index == 0 ? 1 : separationSplits[index - 1] + 1
        let high = index == separationSplits.count - 1 ? separationSteps - 1 : separationSplits[index + 1] - 1
        separationSplits[index] = min(max(step, low), high)
        applySeparation()
    }

    /// How many steps neighbouring bands blend over (up to the narrowest band).
    public func setSeparationOverlap(_ steps: Double) {
        separationOverlap = min(max(steps, 0), Double(narrowestBand))
        applySeparation()
    }

    /// The narrowest band, in steps.
    public var narrowestBand: Int {
        let edges = [0] + separationSplits + [separationSteps]
        return zip(edges, edges.dropFirst()).map { $1 - $0 }.min() ?? separationSteps
    }

    /// Split points made distinct and in order within 1..<steps (after rescaling).
    static func spread(_ splits: [Int], steps: Int) -> [Int] {
        var result: [Int] = []
        for (k, split) in splits.enumerated() {
            let low = (result.last ?? 0) + 1, high = steps - (splits.count - k)
            result.append(min(max(split, low), high))
        }
        return result
    }

    private func applySeparation() {
        separationOverlap = min(separationOverlap, Double(narrowestBand))
        attempt {
            let plan = separationSplits.isEmpty ? nil
                : try SeparationPlan.fromSteps(separationSplits.map(Double.init), steps: separationSteps,
                                               overlap: separationOverlap)
            session.setSeparation(plan)
        }
        refreshPreview()
    }

    /// Show (and print) negative `layer` of the separation.
    public func setLayer(_ layer: Int) {
        attempt { try session.setLayer(layer) }
        refreshPreview()
    }

    /// Give negative `layer` its own process curve (nil: the shared one).
    public func setLayerProcess(_ layer: Int, _ url: URL?) {
        attempt { try session.setLayerProcess(layer, url) }
        refreshPreview()
    }

    /// Use the step test as the photo: the step scale's numbered steps over a continuous
    /// gradient, to print through the separation and see where each coat's band falls. It is
    /// kept in the app's separations folder; the last photo folder is left as it was.
    public func openStepTest() {
        attempt {
            try FileManager.default.createDirectory(at: separationFolder, withIntermediateDirectories: true)
            let url = separationFolder.appendingPathComponent("step-test-\(separationSteps).tif")
            try ImageFiles.saveGrey(url, try SeparationPlan.stepTest(steps: separationSteps))
            try session.open(url)
        }
        refreshPreview()
    }

    // MARK: curves already in OpenQuad

    /// A process curve OpenQuad already has, to choose from a menu instead of a file panel.
    public struct KnownCurve: Hashable, Sendable {
        /// Where it came from: "Setups", "Process calibrations" or "Coats curves".
        public let group: String
        public let label: String
        public let url: URL
    }

    /// Where the Process Calibration tab keeps its runs.
    var processFolder: URL { settingsURL.deletingLastPathComponent().appendingPathComponent("processes") }

    /// Every saved setup's curve, each process calibration's latest curve per colour (newest
    /// run first) and the coats curves, e.g. "Cyanotype, blue: round 2".
    public var knownCurves: [KnownCurve] {
        let fm = FileManager.default
        var curves = setups.compactMap { setup in
            setupLibrary.processURL(setup).map { KnownCurve(group: "Setups", label: setup.name, url: $0) }
        }
        let folders = (try? fm.contentsOfDirectory(at: processFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let runs = folders.compactMap { url -> (ProcessRun, Date)? in
            guard let run = try? ProcessRun.resume(url) else { return nil }
            let modified = (try? url.appendingPathComponent("run.json").resourceValues(
                forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return (run, modified)
        }
        for (run, _) in runs.sorted(by: { $0.1 > $1.1 }) {
            for colour in run.colours where run.current.curves[colour] != nil {
                let url = run.curvePath(colour)
                guard fm.fileExists(atPath: url.path) else { continue }
                curves.append(KnownCurve(group: "Process calibrations",
                                         label: "\(run.name), \(colour): round \(run.current.version)", url: url))
            }
        }
        let coats = ((try? fm.contentsOfDirectory(at: separationFolder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "oqproc" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        curves += coats.map { KnownCurve(group: "Coats curves", label: $0.deletingPathExtension().lastPathComponent, url: $0) }
        return curves
    }

    // MARK: calibrating the coats together

    /// Where the step test, the coats chart and the coats curves are kept.
    var separationFolder: URL { settingsURL.deletingLastPathComponent().appendingPathComponent("separations") }

    /// Use the process chart as the photo, to print through every negative of the separation
    /// onto one sheet; a scan of that print calibrates the coats together (`readCoatsScan`).
    public func openCoatsChart() {
        attempt {
            try FileManager.default.createDirectory(at: separationFolder, withIntermediateDirectories: true)
            let url = separationFolder.appendingPathComponent("coats-chart.tif")
            let chart = Chart.photo()
            try ImageFiles.saveGrey(url, GreyImage(width: chart.width, height: chart.height, pixels: chart.pixels,
                                                   dpi: (300, 300)))
            try session.open(url)
        }
        refreshPreview()
    }

    /// Calibrate the stacked coats with this curve (nil: none).
    public func setCoatsCurve(_ url: URL?) {
        attempt { try session.setCoatsCurve(url) }
        refreshPreview()
    }

    /// Read a scan of the coats chart printed through every negative: build the next coats
    /// curve from it (through the current one), save it beside the chart and use it.
    public func readCoatsScan(_ scan: URL) async {
        busy = true
        defer { busy = false }
        let previous = session.coatsCurve, folder = separationFolder
        do {
            let (curve, reading) = try await Task.detached(priority: .userInitiated) {
                let reading = try Chart.read(try Scan.load(scan))
                return (try ProcessCurve.build(reading, previous: previous), reading)
            }.value
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let round = (1...).first { !FileManager.default.fileExists(atPath: folder.appendingPathComponent("coats-\($0).oqproc").path) }!
            let url = folder.appendingPathComponent("coats-\(round).oqproc")
            try curve.encode().write(to: url)
            try session.setCoatsCurve(url)
            let errors = reading.toneErrors().map(abs)
            let (highlights, shadows) = Clipping.lost(reading)
            status = String(format: "Read the chart: %.1f L* off on average, %.1f at worst. ", errors.reduce(0, +) / Double(errors.count),
                            errors.max() ?? 0)
                + "Saved \(url.lastPathComponent) and using it; print the chart again to check."
                + (Clipping.advice(highlights: highlights, shadows: shadows).map { " " + $0 } ?? "")
            error = nil
        } catch {
            self.error = String(describing: error)
        }
        refreshPreview()
    }

    /// Every negative of the separation as TIFFs in `folder`.
    public func saveSeparations(to folder: URL) async {
        busy = true
        defer { busy = false }
        let snapshot = session
        do {
            let written = try await Task.detached(priority: .userInitiated) { try snapshot.writeSeparations(folder) }.value
            status = "Saved \(written.map(\.lastPathComponent).joined(separator: ", "))."
            error = nil
        } catch {
            self.error = String(describing: error)
        }
    }

    // MARK: contact sheets

    /// The printable room (width, height) in inches: the page inside its margins, less the
    /// safe edge and outline for a negative, and within a set size if one is on.
    public var printableRoom: (Double, Double) {
        let (paperW, paperH) = Paper.sizes[session.paper] ?? (8.5, 11)
        let border = session.negative ? session.safeEdge + session.outline : 0
        var width = paperW - 2 * session.margin - 2 * border, height = paperH - 2 * session.margin - 2 * border
        if session.fit, let box = session.maxSize {
            let (short, long) = (min(box.0, box.1) - 2 * border, max(box.0, box.1) - 2 * border)
            (width, height) = (min(width, short), min(height, long))
        }
        return (max(width, 0.5), max(height, 0.5))
    }

    /// Where made contact sheets are kept.
    public var contactSheetFolder: URL { settingsURL.deletingLastPathComponent().appendingPathComponent("contact-sheets") }

    public func contactSheet() -> ContactSheetModel {
        ContactSheetModel(room: printableRoom, units: units, folder: contactSheetFolder)
    }

    /// Print a made sheet: it becomes the photo, fitted to the page it was made for.
    public func useContactSheet(_ url: URL) {
        openPhoto(url)
        setFit(true)
    }

    // MARK: saved negative setups

    /// The saved setup the negative settings match right now, if any.
    public var currentSetup: NegativeSetup? {
        setups.first { setup in
            let curve = setupLibrary.processURL(setup)?.resolvingSymlinksInPath()
            return setup.colour == session.negativeColour && setup.mirror == session.mirror
                && abs(setup.safeEdge - session.safeEdge) < 1e-9 && abs(setup.outline - session.outline) < 1e-9
                && setup.guide == session.guide && setup.registration == session.registration
                && curve == session.processPath?.resolvingSymlinksInPath()
                && setup.printer == session.printer && setup.paper == session.paper
        }
    }

    /// Switch to a saved setup: its curve, colour, mirror, edges, printer and paper.
    public func applySetup(_ setup: NegativeSetup) {
        setMode(.negative)
        setPaper(setup.paper)
        setPrinter(setup.printer)
        if let curve = setupLibrary.processURL(setup) {
            setProcess(curve)
        } else {
            setProcess(nil)
            setNegativeColour(setup.colour)
        }
        session.mirror = setup.mirror
        session.guide = setup.guide
        session.registration = setup.registration
        setSafeEdge(setup.safeEdge)
        if setup.outline > 0 { outlineSize = setup.outline }
        setOutline(setup.outline > 0)
    }

    /// A name to offer when saving: "Carbon, green, Letter".
    public var suggestedSetupName: String {
        let process = session.process.map(\.process).flatMap { $0.isEmpty ? nil : $0.capitalized } ?? "Negative"
        return "\(process), \(session.negativeColour), \(session.paper)"
    }

    /// Save the negative settings as a setup (replacing one of the same name).
    public func saveSetup(named name: String) {
        attempt {
            let setup = NegativeSetup(name: name, colour: session.negativeColour, mirror: session.mirror,
                                      safeEdge: session.safeEdge, outline: session.outline, guide: session.guide,
                                      registration: session.registration, printer: session.printer, paper: session.paper)
            try setupLibrary.save(setup, process: session.processPath)
            setups = setupLibrary.all()
            // Point at the setup's own copy of the curve, so the setup shows as chosen.
            if let saved = setups.first(where: { $0.name == name.trimmingCharacters(in: .whitespacesAndNewlines) }),
               let curve = setupLibrary.processURL(saved) {
                try session.setProcess(curve)
                remember()
            }
        }
    }

    public func deleteSetup(_ setup: NegativeSetup) {
        attempt {
            try setupLibrary.delete(setup)
            setups = setupLibrary.all()
        }
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
        let negative = role == .negative
        saveSettings { if negative { $0.negativePrinter = name } else { $0.printer = name } }
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
        saveSettings { $0.maxSize = size.map { [$0.0, $0.1] } }
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

    public func blockingTest() -> BlockingTestModel {
        let test = BlockingTestModel(scannerHost: settings.scannerHost ?? "")
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
        var text = "\(units.size(width, height)) at \(String(format: "%.0f", ppi)) ppi"
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
        let proof = snapshot.printsColour ? proofProfile : nil
        Task.detached(priority: .userInitiated) {
            // A colour print is shown in its own profile; soft-proofed if a profile is chosen.
            var image = (try? snapshot.preview())?.cgImage(eightBit: true, iccProfile: snapshot.printProfile())
            if let proof, let shown = image { image = SoftProof.proof(shown, with: proof) ?? shown }
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
            return (image, width, height, session.paper, session.jobTitle)
        } catch {
            self.error = String(describing: error)
            return nil
        }
    }
}
