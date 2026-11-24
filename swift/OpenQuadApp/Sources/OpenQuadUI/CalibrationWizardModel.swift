// The printer calibration wizard's model: print a comparison page, scan, measure, improve.
// For black-and-white prints it calibrates grey balance and tone; for colour prints it
// builds a printer profile (ColourCalibrationWizard.swift has that part).

import AppKit
import OpenQuadCore
import SwiftUI
import UniformTypeIdentifiers

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
    /// What's calibrated: black-and-white prints, or colour prints (a printer profile).
    public var kind = CalibrationKind.blackAndWhite
    /// Colour: the two-page target with a finer grid (for photo papers).
    public var fineTarget = false
    /// Colour: the scanner model scans are read through (nil: the scan is taken as sRGB).
    public var scannerModel: URL?
    public internal(set) var scannerModels: [ScannerModelEntry] = []
    /// Colour: the pages' resolution (tests use less).
    var colourPPI = ColourRun.pagePPI
    public internal(set) var colourRun: ColourRun? { didSet { savedRunsCache.clear() } }
    /// Colour: what the target measured and the profile built from it.
    public internal(set) var profileSummary: String?
    /// Colour: this round's verification, once measured.
    public internal(set) var verification: VerificationReport?
    public private(set) var run: CalibrationRun? { didSet { savedRunsCache.clear() } }
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
        scannerModels = CalibrationLibrary(folder: folder).scannerModels()
        scannerModel = scannerModels.first?.url
    }

    /// "canon-mg3600-letter-plain" unless a name was typed.
    public var runName: String {
        let typed = name.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty { return typed }
        let parts = [LibraryEntry.printerName(printer.isEmpty ? "printer" : printer), paper, paperType]
            + (kind == .colour ? ["colour"] : [])
        return parts.joined(separator: "-").lowercased().replacingOccurrences(of: " ", with: "-")
    }

    public var paperLabel: String {
        let type = paperType.trimmingCharacters(in: .whitespaces)
        return type.isEmpty ? paper : "\(paper) \(type)"
    }

    public var started: Bool { run != nil || colourRun != nil }
    public var printed: Bool { colourRun?.printed ?? (run?.current.job != nil) }
    public var measured: Bool { colourRun?.measured ?? (run?.current.measurements.count == 2) }
    public var canUse: Bool { colourRun.map { !$0.onTarget } ?? (measured || (run?.current.version ?? 0) > 0) }

    /// Where a round is: each round prints a page, scans it, then shows the result.
    public enum Step: Equatable { case setup, print, scan, result }

    public var step: Step {
        if let colourRun {
            if !colourRun.printed { return .print }
            return colourRun.measured ? .result : .scan
        }
        guard let run else { return .setup }
        if run.current.job == nil { return .print }
        if run.current.measurements.count != 2 { return .scan }
        return .result
    }

    /// Round 1 is the first page printed (with no correction, or the calibration started from).
    public var round: Int {
        if let colourRun { return colourRun.current.map { $0.version + 2 } ?? 1 }
        return (run?.current.version ?? 0) + 1
    }

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

    @ObservationIgnored private var savedRunsCache = Cached<[SavedRun]>()

    /// The most recent runs in the folder, newest first (read again every few seconds).
    public var savedRuns: [SavedRun] { savedRunsCache.get(readSavedRuns) }

    private func readSavedRuns() -> [SavedRun] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let runs = folders.compactMap { url -> SavedRun? in
            let log = url.appendingPathComponent("run.json")
            if let colour = try? ColourRun.resume(url),
               let modified = (try? log.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                let format = DateFormatter()
                format.dateFormat = "d MMM, HH:mm"
                let round = colour.current.map { $0.version + 2 } ?? 1
                let label = "\(LibraryEntry.printerName(colour.printer)), \(colour.paperLabel), colour: round \(round) "
                    + "(\(format.string(from: modified)))"
                return SavedRun(folder: url, label: label, modified: modified)
            }
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
        if (try? ColourRun.resume(saved)) != nil {
            resumeColour(saved)
            return
        }
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
        if kind == .colour {
            startColour(printer: printer)
            return
        }
        let name = runName
        do {
            run = try CalibrationRun.start(folder: folder.appendingPathComponent("\(name)-\(Self.timestamp())"), name: name,
                                           printer: printer, paper: paper, scannerHost: scannerHost,
                                           starting: startFromCurrent ? starting : nil,
                                           settings: printSettings, paperLabel: paperLabel)
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

    public var calibrationPath: URL? { colourRun?.profileURL ?? run?.calibrationPath }

    /// How the pages are printed, in the words the calibration records.
    var printSettings: String {
        "\(method == .direct ? "default quality, straight to the printer (lp)" : "macOS print panel"); eSCL Document intent"
    }

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
