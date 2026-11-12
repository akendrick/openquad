// The calibration wizards: printer calibration (print a comparison page, scan, measure,
// improve) and negative process calibration (print a chart page on film, contact print,
// scan, read, refine). Thin views over OpenQuadCore's CalibrationRun and ProcessRun;
// every step that uses paper, film or the scanner asks first, and slow steps run off
// the main thread.

import AppKit
import OpenQuadCore
import SwiftUI
import UniformTypeIdentifiers

/// Shared by both wizards: the log, the busy flag, scanners and running a step.
@MainActor
@Observable
public class WizardModel: Identifiable {
    public var log: [String] = []
    public var busy = false
    public var error: String?
    public var scannerHost: String
    public var scanners: [(name: String, host: String)] = []
    let find: @Sendable () -> [(String, String)]

    init(scannerHost: String, find: @escaping @Sendable () -> [(String, String)]) {
        self.scannerHost = scannerHost
        self.find = find
    }

    func say(_ line: String) { log.append(line) }

    /// Run `work` off the main thread, then `done` with its result (errors are shown).
    func step<T: Sendable>(_ name: String, _ work: @escaping @Sendable () throws -> T, done: @escaping (T) -> Void) {
        busy = true
        error = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try work() } }.value
            busy = false
            switch result {
            case .success(let value): done(value)
            case .failure(let failure): error = "\(name.capitalized) failed: \(failure)"
            }
        }
    }

    public func findScanners() {
        say("Looking for scanners…")
        let find = self.find
        step("find", { find().map { (name: $0.0, host: $0.1) } }) { found in
            self.scanners = found
            if self.scannerHost.isEmpty, let first = found.first { self.scannerHost = first.host }
            self.say("Found \(found.count) scanner(s).")
        }
    }

    static func timestamp() -> String {
        let format = DateFormatter()
        format.dateFormat = "yyyyMMdd-HHmm"
        return format.string(from: Date())
    }
}

// MARK: - printer calibration

/// How the wizard's pages are printed: the same way photos will be, or the calibration won't fit.
public enum PrintMethod: String, CaseIterable, Sendable {
    case direct = "Straight to the printer (lp)"
    case panel = "Through the macOS print panel"
}

@MainActor
@Observable
public final class CalibrationWizardModel: WizardModel {
    public var name: String
    public var paper: String
    /// What kind of paper, for the calibration's label ("plain", "matte photo").
    public var paperType = "plain"
    /// The CUPS printer being calibrated.
    public var printer: String
    public var method: PrintMethod
    public var startFromCurrent: Bool
    public var shadowStrength = 0.5
    public private(set) var run: CalibrationRun?
    public private(set) var uncorrected: Measurement?
    public private(set) var corrected: Measurement?
    public private(set) var assessment: Assessment?
    public private(set) var result = ""
    public private(set) var printers: [String]
    let folder: URL
    let starting: Calibration?
    let startingName: String?

    public init(folder: URL, paper: String, scannerHost: String, starting: Calibration?, startingName: String?,
                printers: [String] = [], printer: String = "",
                find: @escaping @Sendable () -> [(String, String)] = { ESCL.discover() }) {
        self.folder = folder
        self.paper = paper
        self.starting = starting
        self.startingName = startingName
        self.printers = printers
        self.printer = printer
        method = printer.isEmpty ? .panel : .direct
        startFromCurrent = starting != nil
        name = ""
        super.init(scannerHost: scannerHost, find: find)
    }

    /// "canon-mg3600-letter-plain" unless a name was typed.
    public var runName: String {
        let typed = name.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty { return typed }
        let parts = [LibraryEntry.printerName(printer.isEmpty ? "printer" : printer), paper, paperType]
        return parts.joined(separator: "-").lowercased().replacingOccurrences(of: " ", with: "-")
    }

    public var paperLabel: String {
        let type = paperType.trimmingCharacters(in: .whitespaces)
        return type.isEmpty ? paper : "\(paper) \(type)"
    }

    public var started: Bool { run != nil }
    public var printed: Bool { run?.current.job != nil }
    public var measured: Bool { run?.current.measurements.count == 2 }
    public var canUse: Bool { measured || (run?.current.version ?? 0) > 0 }

    /// Where a round is: each round prints a page, scans it, then shows the result.
    public enum Step: Equatable { case setup, print, scan, result }

    public var step: Step {
        guard let run else { return .setup }
        if run.current.job == nil { return .print }
        if run.current.measurements.count != 2 { return .scan }
        return .result
    }

    /// Round 1 is the first page printed (with no correction, or the calibration started from).
    public var round: Int { (run?.current.version ?? 0) + 1 }

    public struct RoundSummary: Identifiable, Equatable {
        public let round: Int
        public let calibration: String
        public let worstCast: Double?, meanCast: Double?, worstTone: Double?, meanTone: Double?
        public let then: String

        public var id: Int { round }
        public var castMet: Bool? { worstCast.map { $0 < Assessment.castGoal && (meanCast ?? 0) <= Assessment.meanCastGoal } }
        public var toneMet: Bool? { worstTone.map { $0 < Assessment.toneGoal } }
    }

    /// Every round so far, with what it measured and what was done next.
    public var rounds: [RoundSummary] {
        guard let run else { return [] }
        return run.rounds.map { r in
            let a = r.assessment
            let then: String
            switch r.action {
            case "grey balance": then = "Improved grey balance"
            case "linearize": then = "Evened out tone"
            default: then = r.version == run.current.version ? (r.measurements.count == 2 ? "Measured" : (r.job == nil ? "To print" : "To scan")) : ""
            }
            return RoundSummary(round: r.version + 1, calibration: "v\(r.version)", worstCast: a?["worst_cast"], meanCast: a?["mean_cast"],
                                worstTone: a?["worst_tone"], meanTone: a?["mean_tone"], then: then)
        }
    }

    /// A run kept in the calibrations folder, to continue.
    public struct SavedRun: Identifiable, Hashable {
        public let folder: URL
        public let label: String
        public let modified: Date
        public var id: URL { folder }
    }

    /// The most recent runs in the folder, newest first.
    public var savedRuns: [SavedRun] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let runs = folders.compactMap { url -> SavedRun? in
            let log = url.appendingPathComponent("run.json")
            guard let run = try? CalibrationRun.resume(url),
                  let modified = (try? log.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { return nil }
            let format = DateFormatter()
            format.dateFormat = "d MMM, HH:mm"
            let label = "\(LibraryEntry.printerName(run.printer)), \(run.paper): round \(run.current.version + 1) (\(format.string(from: modified)))"
            return SavedRun(folder: url, label: label, modified: modified)
        }
        return Array(runs.sorted { $0.modified > $1.modified }.prefix(6))
    }

    /// Pick up a run where it was left: its settings, rounds and latest measurement.
    public func resume(_ saved: URL) {
        do {
            let run = try CalibrationRun.resume(saved)
            self.run = run
            printer = run.printer
            paper = run.paper
            let calibration = try run.calibration()
            paperType = calibration.paper.hasPrefix(run.paper)
                ? calibration.paper.dropFirst(run.paper.count).trimmingCharacters(in: .whitespaces) : paperType
            method = calibration.settings.contains("print panel") ? .panel : .direct
            if !run.scannerHost.isEmpty { scannerHost = run.scannerHost }
            if let (plain, corrected) = try? run.measurements() {
                uncorrected = plain
                self.corrected = corrected
                assessment = Assessment.assess(uncorrected: plain, corrected: corrected)
            }
            error = nil
            say("Continuing \(run.name), round \(run.current.version + 1).")
        } catch {
            self.error = "Couldn't continue that run: \(error)"
        }
    }

    public func start() {
        let printer = self.printer.trimmingCharacters(in: .whitespaces)
        guard !printer.isEmpty else {
            error = "Choose the printer you're calibrating."
            return
        }
        let name = runName
        let how = method == .direct ? "default quality, straight to the printer (lp)" : "macOS print panel"
        do {
            run = try CalibrationRun.start(folder: folder.appendingPathComponent("\(name)-\(Self.timestamp())"), name: name,
                                           printer: printer, paper: paper, scannerHost: scannerHost,
                                           starting: startFromCurrent ? starting : nil,
                                           settings: "\(how); eSCL Document intent", paperLabel: paperLabel)
            error = nil
            say("Started \(name) in \(run!.folder.path)")
        } catch {
            self.error = "Couldn't start: \(error)"
        }
    }

    /// Print the page straight to the printer (lp); the panel route is in the view.
    public func printDirect(runner: @escaping Printing.Runner = Printing.runCommand) {
        guard let run else { return }
        say("Printing round \(run.current.version) on \(LibraryEntry.printerName(run.printer))…")
        nonisolated(unsafe) let runner = runner
        step("print", { try run.printPage(runner: runner) }) { job in
            self.say("Sent to the printer: job \(job). Let it dry, then scan it.")
        }
    }

    /// The comparison page, rendered for the print panel at 300 ppi.
    public func pageForPrinting() throws -> (RGBImage, Double, Double, String, String)? {
        guard let run else { return nil }
        let page = try Scan.load(try run.pageURL ?? run.makePage())
        let image = RGBImage(width: page.width, height: page.height, pixels: page.samples)
        return (image, Double(page.width) / CalibrationRun.pagePPI, Double(page.height) / CalibrationRun.pagePPI, run.paper,
                "OpenQuad calibration: \(run.name) v\(run.current.version)")
    }

    public func printed(_ note: String) {
        guard let run else { return }
        do {
            try run.markPrinted(note)
            say("Printed round \(run.current.version) (\(note)). Let it dry, then scan it.")
        } catch {
            self.error = "\(error)"
        }
    }

    public func scanAndMeasure(fetch: @escaping ESCL.Fetch = ESCL.httpFetch, file: URL? = nil) {
        guard let run else { return }
        if file == nil {
            guard !scannerHost.isEmpty else {
                error = "Choose a scanner first (Find looks on the network)."
                return
            }
            run.scannerHost = scannerHost
        }
        say(file == nil ? "Scanning and measuring…" : "Reading \(file!.lastPathComponent)…")
        nonisolated(unsafe) let fetch = fetch
        step("measure", {
            if let file { try run.useScan(file) } else { try run.scanPage(fetch: fetch) }
            return try run.measure()
        }) { (plain, corrected, assessment) in
            self.uncorrected = plain
            self.corrected = corrected
            self.assessment = assessment
            let advice = ["grey balance": "Next: improve grey balance.", "linearize": "Next: even out tone.",
                          "done": "Both goals are met: use this calibration."][assessment.nextStep]!
            self.result = "\(assessment.summary()) \(advice)"
            self.say("Measured: \(advice)")
        }
    }

    public func improve(_ action: String) {
        guard let run else { return }
        do {
            let path = try run.improve(action, shadowDamping: shadowStrength)
            uncorrected = nil
            corrected = nil
            assessment = nil
            result = "Built \(path.lastPathComponent). Print a new comparison page to check it."
            say("\(action.capitalized): built \(path.lastPathComponent)")
        } catch {
            self.error = "Couldn't build the calibration: \(error)"
        }
    }

    public var calibrationPath: URL? { run?.calibrationPath }

    /// The CUPS printers, once looked up (the wizard can be made before they are): before
    /// a run starts, offer them and pick the first if none is chosen.
    public func offerPrinters(_ found: [String]) {
        guard run == nil, !found.isEmpty else { return }
        printers = found
        if printer.isEmpty || !found.contains(printer) {
            printer = found[0]
            method = .direct
        }
    }
}

// MARK: - negative process calibration

@MainActor
@Observable
public final class ProcessWizardModel: WizardModel {
    public var name = "carbon-office-film"
    public var colours: Set<String> = ["green", "orange"]
    public var mirror = false
    public var film = "inkjet-coated office transparency"
    /// A note of how the film is printed (the print panel's paper type, quality and
    /// resolution), kept with the run so every round is printed the same way.
    public var printing = ""
    public var useColour = "green"
    /// Patches each side the curves even out (Smoothing.reaches); kept with the run.
    public var smoothing = Smoothing.standard {
        didSet {
            guard let run, run.smoothing != smoothing else { return }
            do { try run.setSmoothing(smoothing) } catch { self.error = "\(error)" }
        }
    }
    /// Darkroom marks in black in the charts' safe edges.
    public var guide = false
    public var registration = false
    /// Fit the chart page within (width, height) inches (never past the paper's margins);
    /// nil for the charts' own size. Shared with the blocking test and remembered.
    public var sheetSize: (Double, Double)? { didSet { rememberSize?(sheetSize) } }
    @ObservationIgnored var rememberSize: (((Double, Double)?) -> Void)?
    /// Lengths shown in the window (the app's setting).
    public var units = LengthUnit.inches
    /// Curves the next run starts from, by colour (an earlier run's latest round or
    /// .oqproc files), so a finished calibration can be adjusted further; empty for none.
    public private(set) var startingCurves: [String: ProcessCurve] = [:]
    public private(set) var startingName: String?
    public private(set) var run: ProcessRun?
    public private(set) var readings: [(String, ChartReading)] = []
    public private(set) var result = ""
    let folder: URL

    public init(folder: URL, scannerHost: String, find: @escaping @Sendable () -> [(String, String)] = { ESCL.discover() }) {
        self.folder = folder
        super.init(scannerHost: scannerHost, find: find)
    }

    public var orderedColours: [String] { Negative.colourOrder.filter(colours.contains) }
    public var started: Bool { run != nil }
    public var printed: Bool { run?.current.job != nil }
    public var measured: Bool { run.map { $0.current.readings.count == $0.colours.count } ?? false }

    /// Process runs kept in the folder, newest first.
    public var savedRuns: [CalibrationWizardModel.SavedRun] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        let format = DateFormatter()
        format.dateFormat = "d MMM, HH:mm"
        let runs = folders.compactMap { url -> CalibrationWizardModel.SavedRun? in
            guard let run = try? ProcessRun.resume(url),
                  let modified = (try? url.appendingPathComponent("run.json").resourceValues(
                      forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
            let label = "\(run.name), \(run.colours.joined(separator: " over ")): round \(run.current.version) "
                + "(\(format.string(from: modified)))"
            return CalibrationWizardModel.SavedRun(folder: url, label: label, modified: modified)
        }
        return Array(runs.sorted { $0.modified > $1.modified }.prefix(10))
    }

    /// Carry on with a kept run: its settings, its latest round and any readings.
    public func resume(_ saved: URL) {
        do {
            let run = try ProcessRun.resume(saved)
            self.run = run
            name = run.name
            colours = Set(run.colours)
            mirror = run.mirror
            film = run.film
            printing = run.printing
            guide = run.guide
            registration = run.registration
            smoothing = run.smoothing
            let remember = rememberSize
            rememberSize = nil  // the run's own size, not a new preference
            sheetSize = run.size
            rememberSize = remember
            if !run.scannerHost.isEmpty { scannerHost = run.scannerHost }
            let read = (try? run.readings()) ?? [:]
            readings = run.colours.compactMap { c in read[c].map { (c, $0) } }
            useColour = run.bestColour() ?? run.colours[0]
            result = ""
            error = nil
            say("Continuing \(run.name), round \(run.current.version).")
        } catch {
            self.error = "Couldn't continue that run: \(error)"
        }
    }

    /// Start the next run from a kept run's latest curves (its colours chosen too).
    public func startFrom(run saved: URL) {
        do {
            let run = try ProcessRun.resume(saved)
            startingCurves = Dictionary(uniqueKeysWithValues: try run.colours.map { ($0, try run.curve($0)) })
            startingName = "\(run.name) round \(run.current.version)"
            colours = Set(run.colours)
            if film.isEmpty { film = run.film }
            say("Starting from \(startingName!): \(run.colours.joined(separator: ", ")).")
        } catch {
            self.error = "Couldn't read that run's curves: \(error)"
        }
    }

    /// Start the next run from .oqproc process curves (one per colour; a later file wins).
    public func startFrom(files: [URL]) {
        do {
            let curves = try files.map { try ProcessCurve.decode(Data(contentsOf: $0)) }
            guard !curves.isEmpty else { return }
            startingCurves = Dictionary(curves.map { ($0.colour, $0) }) { _, later in later }
            startingName = files.count == 1 ? files[0].deletingPathExtension().lastPathComponent : "\(files.count) curve files"
            colours.formUnion(startingCurves.keys)
            say("Starting from \(startingName!): \(Negative.colourOrder.filter(startingCurves.keys.contains).joined(separator: ", ")).")
        } catch {
            self.error = "Couldn't read those curves: \(error)"
        }
    }

    public func startFromScratch() {
        startingCurves = [:]
        startingName = nil
    }

    /// Back to the settings to start another run (this one stays kept, to continue).
    public func closeRun() {
        guard let run else { return }
        self.run = nil
        readings = []
        result = ""
        say("Put \(run.name) aside; continue it any time.")
    }

    public func start() {
        let name = self.name.trimmingCharacters(in: .whitespaces)
        do {
            let run = try ProcessRun.start(folder: folder.appendingPathComponent("\(name)-\(Self.timestamp())"), name: name,
                                           colours: orderedColours, scannerHost: scannerHost, mirror: mirror,
                                           film: film.trimmingCharacters(in: .whitespaces),
                                           printing: printing.trimmingCharacters(in: .whitespaces),
                                           starting: startingCurves.filter { orderedColours.contains($0.key) }, size: sheetSize,
                                           guide: guide, registration: registration)
            try run.setSmoothing(smoothing)
            let page = try run.makePage()
            self.run = run
            useColour = run.colours[0]
            result = "Chart page: \(page.lastPathComponent) (\(run.colours.joined(separator: " over "))). Print it on film at 100% "
                + "(300 ppi) with: \(run.printing.isEmpty ? "your usual settings" : run.printing)."
            say("Started \(name): \(run.colours.joined(separator: ", "))")
        } catch {
            self.error = "Couldn't start: \(error)"
        }
    }

    public func pageForPrinting() throws -> (RGBImage, Double, Double, String, String)? {
        guard let run else { return nil }
        let page = try Scan.load(try run.pageURL ?? run.makePage())
        let image = RGBImage(width: page.width, height: page.height, pixels: page.samples)
        return (image, Double(page.width) / ProcessRun.pagePPI, Double(page.height) / ProcessRun.pagePPI, run.paper,
                "OpenQuad process chart: \(run.name) v\(run.current.version)")
    }

    /// Pixels per inch of `preview()`.
    public static let previewPPI = 30.0

    /// The chart page as it will print, small: this round's (through its curves) once
    /// started, otherwise what Start would make from the settings. Nil with no colours.
    public func preview() -> RGBImage? {
        if let run {
            guard let curves = try? run.colours.map({ try run.curve($0) }) else { return nil }
            return Chart.page(colours: run.colours, processes: curves, mirror: run.mirror, dpi: Self.previewPPI,
                              scale: (try? run.scale()) ?? 1, guide: run.guide, registration: run.registration)
        }
        let colours = orderedColours
        guard (1...5).contains(colours.count) else { return nil }
        let scale = (try? ProcessRun.scale(count: colours.count, size: sheetSize)) ?? 1
        return Chart.page(colours: colours, processes: colours.map { startingCurves[$0] }, mirror: mirror, dpi: Self.previewPPI, scale: scale, guide: guide,
                          registration: registration)
    }

    /// Keep an edited print-settings note with the run.
    public func savePrinting() {
        guard let run, run.printing != printing.trimmingCharacters(in: .whitespaces) else { return }
        do {
            try run.setPrinting(printing)
            say("Print settings: \(run.printing.isEmpty ? "none noted" : run.printing)")
        } catch {
            self.error = "\(error)"
        }
    }

    public func printed(_ note: String) {
        guard let run else { return }
        do {
            try run.markPrinted(note)
            say("Printed the chart page (\(note)). Contact print it, then scan the print.")
        } catch {
            self.error = "\(error)"
        }
    }

    public func scanAndRead(fetch: @escaping ESCL.Fetch = ESCL.httpFetch, file: URL? = nil) {
        guard let run else { return }
        if file == nil {
            guard !scannerHost.isEmpty else {
                error = "Choose a scanner first (Find looks on the network)."
                return
            }
            run.scannerHost = scannerHost
        }
        say(file == nil ? "Scanning and reading the charts…" : "Reading \(file!.lastPathComponent)…")
        nonisolated(unsafe) let fetch = fetch
        step("read", {
            if let file { try run.useScan(file) } else { try run.scanPage(fetch: fetch) }
            let results = try run.measure()
            return (results, try run.readings())
        }) { (results, readings) in
            self.readings = run.colours.compactMap { c in readings[c].map { (c, $0) } }
            let lines = run.colours.compactMap { c in
                results[c].map { r in String(format: "%@: worst %.1f L*, mean %.2f (%@)", c, r.worst, r.mean, r.done ? "on target" : "refine") }
            }
            let best = run.bestColour()
            if let best { self.useColour = best }
            let warnings = run.colours.compactMap { c in results[c]?.advice.map { "\(c.capitalized): \($0)" } }
            self.result = ([lines.joined(separator: "; ") + String(format: ". Goal: every patch within %g L*. Best: %@.",
                                                                   ProcessResult.toneGoal, best ?? "none")] + warnings)
                .joined(separator: "\n")
            for warning in warnings { self.say("Warning: " + warning) }
            self.say("Read: " + lines.joined(separator: "; "))
        }
    }

    public func refine() {
        guard let run else { return }
        do {
            try run.refine()
            let page = try run.makePage()
            readings = []
            result = "Round \(run.current.version): print the new chart page (\(page.lastPathComponent))."
            say("Refined the curves (round \(run.current.version)).")
        } catch {
            self.error = "Couldn't refine: \(error)"
        }
    }

    /// The chosen colour's curve (nil if this run has no such colour).
    public var curvePath: URL? {
        guard let run, run.colours.contains(useColour) else { return nil }
        return run.curvePath(useColour)
    }

    /// Save the chosen colour's current curve for other software (.amp, .acv, .cube, .csv).
    public func exportCurve(to url: URL) {
        guard let run else { return }
        guard run.colours.contains(useColour) else {
            error = "This run has no \(useColour) curve; choose one of \(run.colours.joined(separator: ", "))."
            return
        }
        do {
            try CurveExport.write(try run.curve(useColour), to: url)
            say("Exported the \(useColour) curve (round \(run.current.version)) to \(url.lastPathComponent).")
        } catch {
            self.error = "Couldn't export the curve: \(error)"
        }
    }
}

// MARK: - views

/// Print an image through the print panel at its real size; true if it was printed.
@MainActor
func printWithPanel(_ request: (RGBImage, Double, Double, String, String)) -> Bool {
    guard let operation = NativePrint.operation(for: request.0, widthInches: request.1, heightInches: request.2,
                                                paper: request.3, title: request.4) else { return false }
    return operation.run()
}

@MainActor
func confirm(_ title: String, _ question: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = question
    alert.addButton(withTitle: "Continue")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
}

public struct CalibrationWizardView: View {
    @Bindable var model: CalibrationWizardModel
    let use: (URL) -> Void
    /// Closes the window it is in; nil inside a tab (no Close button).
    let close: (() -> Void)?
    @State private var editingSetup = false

    public init(model: CalibrationWizardModel, use: @escaping (URL) -> Void, close: (() -> Void)? = nil) {
        self.model = model
        self.use = use
        self.close = close
    }

    public var body: some View {
        WizardScaffold(title: "Calibrate a printer", log: model.log) {
            EmptyView()
        } content: {
            setup
            NextStepCard(model: model, actions: actions)
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.rounds.isEmpty { RoundsTable(rounds: model.rounds) }
            ScrollView {
                WedgeChartView(uncorrected: model.uncorrected, corrected: model.corrected, round: model.round)
                    .frame(minHeight: 380)
            }
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                if let close { Button("Close", action: close) }
            }
        }
    }

    // MARK: setup: compact, and one line once started

    @ViewBuilder private var setup: some View {
        if model.started {
            HStack(spacing: 8) {
                Image(systemName: "printer").foregroundStyle(.secondary)
                Text([LibraryEntry.printerName(model.printer), model.paperLabel,
                      model.method == .direct ? "straight to the printer" : "print panel",
                      "scanner \(model.scannerHost.isEmpty ? "not set" : model.scannerHost)"].joined(separator: " · "))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Change Scanner…") { editingSetup.toggle() }.controlSize(.small)
            }
            if editingSetup && model.started {
                HStack { ScannerField(model: model) }
            }
        } else {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Printer").gridColumnAlignment(.trailing)
                    if model.printers.isEmpty {
                        TextField("Printer", text: $model.printer, prompt: Text("CUPS queue, e.g. Canon_MG3600_series")).labelsHidden()
                    } else {
                        Picker("Printer", selection: $model.printer) {
                            ForEach(model.printers, id: \.self) { Text(LibraryEntry.printerName($0)).tag($0) }
                        }
                        .labelsHidden()
                    }
                    Text("Paper").gridColumnAlignment(.trailing)
                    HStack {
                        Picker("Paper", selection: $model.paper) { ForEach(paperOrder, id: \.self) { Text($0) } }
                            .labelsHidden().fixedSize()
                        TextField("Type", text: $model.paperType, prompt: Text("plain, matte…")).labelsHidden().frame(width: 110)
                    }
                }
                GridRow {
                    Text("Print with")
                    Picker("Print with", selection: $model.method) {
                        ForEach(PrintMethod.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    Text("Scanner")
                    ScannerField(model: model)
                }
                if model.starting != nil {
                    GridRow {
                        Text("Start from")
                        Picker("Start from", selection: $model.startFromCurrent) {
                            Text("No correction").tag(false)
                            Text("Current calibration (\(model.startingName ?? "loaded"))").tag(true)
                        }
                        .labelsHidden()
                        .gridCellColumns(3)
                    }
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            let saved = model.savedRuns
            if !saved.isEmpty {
                HStack {
                    Text("Or carry on where you left off:").foregroundStyle(.secondary)
                    Menu("Continue a Previous Run") {
                        ForEach(saved) { run in Button(run.label) { model.resume(run.folder) } }
                    }
                    .fixedSize()
                }
            }
        }
    }

    // MARK: the actions the next-step card offers

    private var actions: NextStepActions {
        NextStepActions(
            start: { model.start() },
            print: printPage,
            printedElsewhere: { model.printed("printed another way") },
            scan: scan,
            readFile: readFile,
            improve: { model.improve($0) },
            use: {
                if let path = model.calibrationPath { use(path) }
                close?()
            })
    }

    private func printPage() {
        if model.method == .direct, let run = model.run {
            if confirm("Print?", "Print a comparison page on \(LibraryEntry.printerName(run.printer)) (\(run.paper))? "
                       + "It uses one sheet and about a quarter page of ink.") {
                model.printDirect()
            }
            return
        }
        do {
            guard let request = try model.pageForPrinting() else { return }
            if printWithPanel(request) { model.printed("print panel") }
        } catch {
            model.error = "\(error)"
        }
    }

    private func scan() {
        if confirm("Scan?", "Is the printed page dry, face down on the scanner glass, with the lid closed?") {
            model.scanAndMeasure()
        }
    }

    private func readFile() {
        if let url = ContentView.askOpen(types: [.jpeg, .png, .tiff]) { model.scanAndMeasure(file: url) }
    }
}

struct ScannerField: View {
    @Bindable var model: WizardModel

    var body: some View {
        HStack {
            TextField("Scanner", text: $model.scannerHost, prompt: Text("host:port, or Find")).labelsHidden()
            Menu("Found") {
                ForEach(model.scanners, id: \.host) { s in Button("\(s.name) (\(s.host))") { model.scannerHost = s.host } }
            }
            .disabled(model.scanners.isEmpty)
            .fixedSize()
            Button("Find", action: model.findScanners).disabled(model.busy)
        }
    }
}

struct NextStepActions {
    let start: () -> Void
    let print: () -> Void
    let printedElsewhere: () -> Void
    let scan: () -> Void
    let readFile: () -> Void
    let improve: (String) -> Void
    let use: () -> Void
}

/// What to do now, in words, with the one button that does it (and the alternatives).
struct NextStepCard: View {
    @Bindable var model: CalibrationWizardModel
    let actions: NextStepActions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(Array(["Print", "Scan", "Result"].enumerated()), id: \.offset) { n, name in
                    let index = [CalibrationWizardModel.Step.print, .scan, .result][n]
                    StepChip(number: n + 1, name: name, state: chipState(index))
                    if n < 2 { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                }
                Spacer()
                if model.started { Text("Round \(model.round)").font(.headline).foregroundStyle(.secondary) }
            }
            Text(title).font(.title3.bold())
            Text(explanation).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) { buttons }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.25)))
    }

    func chipState(_ step: CalibrationWizardModel.Step) -> StepChip.State {
        let order: [CalibrationWizardModel.Step] = [.setup, .print, .scan, .result]
        let now = order.firstIndex(of: model.step)!, this = order.firstIndex(of: step)!
        return this < now ? .done : (this == now ? .current : .later)
    }

    var title: String {
        switch model.step {
        case .setup: return "Set up, then start"
        case .print: return model.round == 1 ? "Step 1: print the comparison page" : "Step 1: print a page to check calibration v\(model.round - 1)"
        case .scan: return "Step 2: scan the printed page"
        case .result:
            switch model.assessment?.nextStep {
            case "grey balance": return "Step 3: colours still lean, so improve grey balance"
            case "linearize": return "Step 3: grey balance is good; now even out the tone"
            case "done": return "Done: both goals are met"
            default: return "Step 3: the result"
            }
        }
    }

    var explanation: String {
        switch model.step {
        case .setup:
            return "Choose the printer and paper you'll print photos on, how you'll print (the same way every time), and the "
                + "scanner (Find looks on your network). Each round prints a test page, scans it and corrects what it measures."
        case .print:
            return model.round == 1
                ? "The page has two step wedges: the top one printed as is (one square beside it), the bottom one through "
                    + "the calibration being tested (two squares). In round 1 both are uncorrected."
                : "The bottom wedge (two squares) now prints through calibration v\(model.round - 1); the top one stays "
                    + "uncorrected for comparison. Use the same paper and settings as before."
        case .scan:
            return "When the ink is dry, put the page face down on the scanner glass (either way round) and close the lid. "
                + "Or scan it some other way and read the file."
        case .result:
            guard let a = model.assessment else { return "Measured. Choose what to do next." }
            let cast = String(format: "Colour cast: worst %.1f (goal under 3) %@", a.worstCast, a.worstCast < 3 && a.meanCast <= 1 ? "✓" : "✗")
            let tone = String(format: "Tone: worst %.1f L* off (goal under 2) %@", a.worstTone, a.worstTone < 2 ? "✓" : "✗")
            let next: String
            switch a.nextStep {
            case "grey balance": next = "Improve Grey Balance builds calibration v\(model.round) from this scan. Then print again to check it."
            case "linearize": next = "Even Out Tone builds calibration v\(model.round) so every grey prints at the right lightness. "
                + "Then print again to check it."
            default: next = "Use this calibration. It's saved under the printer's name."
            }
            return "\(cast). \(tone).\n\(next)"
        }
    }

    @ViewBuilder var buttons: some View {
        switch model.step {
        case .setup:
            Button("Start", action: actions.start).buttonStyle(.borderedProminent).disabled(model.busy)
        case .print:
            Button(model.method == .direct ? "Print Comparison Page" : "Print Comparison Page…", action: actions.print)
                .buttonStyle(.borderedProminent).disabled(model.busy)
            Button("I Printed It Another Way", action: actions.printedElsewhere).disabled(model.busy)
        case .scan:
            Button("Scan and Measure", action: actions.scan).buttonStyle(.borderedProminent).disabled(model.busy)
            Button("Read a Scan File…", action: actions.readFile).disabled(model.busy)
            Button("Print Again", action: actions.print).disabled(model.busy)
        case .result:
            let next = model.assessment?.nextStep
            if next == "done" {
                Button("Use This Calibration", action: actions.use).buttonStyle(.borderedProminent)
                Button("Even Out Tone Anyway") { actions.improve("linearize") }
            } else {
                Button("Improve Grey Balance") { actions.improve("grey balance") }
                    .prominent(next == "grey balance")
                Button("Even Out Tone") { actions.improve("linearize") }
                    .prominent(next == "linearize")
                Button("Use As It Is", action: actions.use)
            }
            if next != "done" && next != "linearize" {
                Stepper(value: $model.shadowStrength, in: 0...1, step: 0.1) {
                    Text(String(format: "shadow strength %.1f", model.shadowStrength)).foregroundStyle(.secondary)
                }
                .help("How much of the correction to apply in the darkest steps (where printers switch inks)")
                .fixedSize()
            }
        }
    }
}

extension View {
    /// The recommended button stands out; the others stay plain.
    @ViewBuilder func prominent(_ on: Bool) -> some View {
        if on { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
    }
}

struct StepChip: View {
    enum State { case done, current, later }
    let number: Int
    let name: String
    let state: State

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: state == .done ? "checkmark.circle.fill" : "\(number).circle\(state == .current ? ".fill" : "")")
            Text(name)
        }
        .font(.callout.weight(state == .current ? .semibold : .regular))
        .foregroundStyle(state == .later ? Color.secondary : (state == .done ? Color.green : Color.accentColor))
    }
}

/// Every round's measurements, so progress (or not) is plain.
struct RoundsTable: View {
    let rounds: [CalibrationWizardModel.RoundSummary]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
            GridRow {
                Text("Round"); Text("Calibration"); Text("Colour cast (worst, goal < 3)"); Text("Tone (worst, goal < 2 L*)"); Text("Then")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(rounds) { r in
                GridRow {
                    Text("\(r.round)").monospacedDigit()
                    Text(r.calibration == "v0" ? "starting point" : r.calibration)
                    value(r.worstCast, met: r.castMet)
                    value(r.worstTone, met: r.toneMet)
                    Text(r.then).foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder func value(_ v: Double?, met: Bool?) -> some View {
        if let v {
            HStack(spacing: 4) {
                Text(String(format: "%.1f", v)).monospacedDigit()
                Image(systemName: met == true ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(met == true ? Color.green : Color.orange)
            }
        } else {
            Text("–").foregroundStyle(.tertiary)
        }
    }
}

public struct ProcessWizardView: View {
    @Bindable var model: ProcessWizardModel
    let use: (URL) -> Void
    /// Closes the window it is in; nil inside a tab (no Close button).
    let close: (() -> Void)?

    public init(model: ProcessWizardModel, use: @escaping (URL) -> Void, close: (() -> Void)? = nil) {
        self.model = model
        self.use = use
        self.close = close
    }

    public var body: some View {
        WizardScaffold(title: "Calibrate a negative process", log: model.log) {
            EmptyView()
        } content: {
            if model.started {
                Text([model.run?.colours.joined(separator: " over ") ?? "", model.film, model.mirror ? "mirrored" : "not mirrored",
                      "scanner \(model.scannerHost.isEmpty ? "not set" : model.scannerHost)"].joined(separator: " · "))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Form {
                    printSettings
                    smoothingPicker
                }
                .formStyle(.grouped)
                .frame(height: 150)
            } else {
            previousRuns
            Form {
                TextField("Name", text: $model.name)
                LabeledContent("Colours") {
                    HStack {
                        ForEach(Negative.colourOrder, id: \.self) { colour in
                            Toggle(colour.capitalized, isOn: Binding(
                                get: { model.colours.contains(colour) },
                                set: { on in if on { model.colours.insert(colour) } else { model.colours.remove(colour) } }))
                        }
                    }
                }
                LabeledContent("Scanner") { ScannerField(model: model) }
                Toggle("Mirror the negatives", isOn: $model.mirror)
                TextField("Film", text: $model.film)
                smoothingPicker
                LabeledContent("Start from") {
                    HStack {
                        Text(model.startingName.map { "\($0) (adjusted further)" } ?? "No correction")
                            .lineLimit(1).truncationMode(.middle)
                        Menu("Change") {
                            Button("No Correction", action: model.startFromScratch)
                            let saved = model.savedRuns
                            if !saved.isEmpty {
                                Section("A previous run's latest curves") {
                                    ForEach(saved) { run in Button(run.label) { model.startFrom(run: run.folder) } }
                                }
                            }
                            Button("Process Curve Files…", action: chooseCurves)
                        }
                        .fixedSize()
                    }
                }
                printSettings
                SheetSize(size: model.sheetSize, units: model.units) { model.sheetSize = $0 }
                DarkroomMarks(guide: model.guide, registration: model.registration, negative: true, units: model.units,
                              setGuide: { model.guide = $0 }, setRegistration: { model.registration = $0 })
            }
            .formStyle(.grouped)
            .frame(height: 330)  // the form scrolls
            }
            HStack {
                Button("Start", action: model.start).disabled(model.started || model.colours.isEmpty || model.colours.count > 5)
                Button("1. Print Chart Page…", action: printPage).disabled(!model.started || model.busy)
                Button("…or I Printed It Elsewhere") { model.printed("printed elsewhere") }.disabled(!model.started || model.busy)
                if model.started { Button("New Run…", action: model.closeRun).disabled(model.busy) }
                if model.busy { ProgressView().controlSize(.small) }
            }
            HStack {
                Button("2. Scan the Contact Print and Read It", action: scan).disabled(!model.printed || model.busy)
                Button("…or Read a Scan File", action: readFile).disabled(!model.printed || model.busy)
                Button("3. Refine the Curves", action: model.refine).disabled(!model.measured || model.busy)
            }
            HStack(alignment: .top, spacing: 16) {
                SheetPreview(image: model.preview(), ppi: ProcessWizardModel.previewPPI, units: model.units,
                             title: model.started ? "This round's page" : "The page Start makes")
                    .frame(width: 220)
                ToneChartView(readings: model.readings)
            }
            .frame(minHeight: 260, maxHeight: .infinity, alignment: .top)
            if !model.result.isEmpty { Text(model.result).fixedSize(horizontal: false, vertical: true) }
            if let error = model.error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                if let close { Button("Close", action: close) }
                Picker("Use", selection: $model.useColour) {
                    ForEach(model.run?.colours ?? [], id: \.self) { Text($0.capitalized).tag($0) }
                }
                .fixedSize()
                .disabled(!model.started)
                Button("Export Curve…", action: exportCurve).disabled(!model.started)
                Button("Use This Colour's Curve") {
                    if let path = model.curvePath { use(path) }
                    close?()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.started)
            }
        }
    }

    /// Kept runs to carry on with (another round, or adjust an earlier calibration further).
    @ViewBuilder private var previousRuns: some View {
        let saved = model.savedRuns
        if !saved.isEmpty {
            HStack {
                Text("Or carry on with a kept run:").foregroundStyle(.secondary)
                Menu("Continue a Previous Run") {
                    ForEach(saved) { run in Button(run.label) { model.resume(run.folder) } }
                }
                .fixedSize()
            }
        }
    }

    private var smoothingPicker: some View {
        Picker("Smoothing", selection: $model.smoothing) {
            ForEach(Smoothing.reaches, id: \.1) { name, reach in Text(name.capitalized).tag(reach) }
        }
        .help("How much the curves even out patch-to-patch noise from the print and the scan (used at Refine)")
    }

    /// Save this colour's curve as Photoshop Curves (.acv), an arbitrary map (.amp), a LUT
    /// (.cube) or CSV, to make negatives in other software as with ChartThrob.
    private func exportCurve() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = CurveExport.formats.compactMap { UTType(filenameExtension: $0) }
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = "\(model.run?.name ?? "process")-\(model.useColour).acv"
        panel.message = "Photoshop Curves (.acv, up to 16 points), arbitrary map (.amp, exact), LUT (.cube) or CSV. "
            + "Apply it to the greyscale photo, then invert it, to make the negative."
        if panel.runModal() == .OK, let url = panel.url { model.exportCurve(to: url) }
    }

    private func chooseCurves() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "oqproc") ?? .data]
        panel.allowsMultipleSelection = true
        panel.directoryURL = model.folder
        panel.message = "Choose process curves to adjust further (one per colour)"
        if panel.runModal() == .OK { model.startFrom(files: panel.urls) }
    }

    /// The print-settings note: editable before and after Start.
    private var printSettings: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Print settings", text: $model.printing,
                      prompt: Text("e.g. Glossy film, Highest quality, 2400 x 1200"))
                .onSubmit(model.savePrinting)
            Text("A note of the paper type, quality and resolution you choose in the print panel (it opens at Print "
                 + "Chart Page…), so every round prints the same way. OpenQuad doesn't set them; the page itself is 300 ppi.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func printPage() {
        model.savePrinting()
        do {
            guard let request = try model.pageForPrinting() else { return }
            if printWithPanel(request) { model.printed("print panel") }
        } catch {
            model.error = "\(error)"
        }
    }

    private func scan() {
        if confirm("Scan?", "Is the dry contact print face down on the scanner glass?") { model.scanAndRead() }
    }

    private func readFile() {
        if let url = ContentView.askOpen(types: [.jpeg, .png, .tiff]) { model.scanAndRead(file: url) }
    }
}
