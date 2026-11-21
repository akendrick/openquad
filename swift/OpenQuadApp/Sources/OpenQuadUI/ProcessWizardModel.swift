// The negative process calibration wizard's model: print a chart page on film, contact print,
// scan, read, refine.

import AppKit
import OpenQuadCore
import SwiftUI
import UniformTypeIdentifiers

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
    /// The paper the chart page is printed on (the Negative tab's).
    public var paper = "Letter"
    public private(set) var run: ProcessRun? { didSet { savedRunsCache.clear() } }
    public private(set) var readings: [(String, ChartReading)] = []
    public private(set) var result = ""
    /// Every colour's chart read this round is within the goal: its curve is ready to use.
    public private(set) var onTarget = false
    let folder: URL
    @ObservationIgnored private var savedRunsCache = Cached<[CalibrationWizardModel.SavedRun]>()
    @ObservationIgnored private var previewMemo = Memo<PreviewKey, RGBImage?>()

    public init(folder: URL, scannerHost: String, find: @escaping @Sendable () -> [(String, String)] = { ESCL.discover() }) {
        self.folder = folder
        super.init(scannerHost: scannerHost, find: find)
    }

    public var orderedColours: [String] { Negative.colourOrder.filter(colours.contains) }
    public var started: Bool { run != nil }
    public var printed: Bool { run?.current.job != nil }
    public var measured: Bool { run.map { $0.current.readings.count == $0.colours.count } ?? false }

    /// Process runs kept in the folder, newest first (read again every few seconds).
    public var savedRuns: [CalibrationWizardModel.SavedRun] { savedRunsCache.get(readSavedRuns) }

    private func readSavedRuns() -> [CalibrationWizardModel.SavedRun] {
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
            paper = run.paper
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
            let results = run.results()
            onTarget = run.colours.allSatisfy { results[$0]?.done == true }
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
        onTarget = false
        say("Put \(run.name) aside; continue it any time.")
    }

    public func start() {
        let name = self.name.trimmingCharacters(in: .whitespaces)
        do {
            let run = try ProcessRun.start(folder: folder.appendingPathComponent("\(name)-\(Self.timestamp())"), name: name,
                                           colours: orderedColours, paper: paper, scannerHost: scannerHost, mirror: mirror,
                                           film: film.trimmingCharacters(in: .whitespaces),
                                           printing: printing.trimmingCharacters(in: .whitespaces),
                                           starting: startingCurves.filter { orderedColours.contains($0.key) }, size: sheetSize,
                                           guide: guide, registration: registration)
            try run.setSmoothing(smoothing)
            let page = try run.makePage()
            self.run = run
            useColour = run.colours[0]
            onTarget = false
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

    /// What the page preview depends on.
    struct PreviewKey: Equatable {
        let run: URL?, version: Int?, colours: [String], mirror: Bool, guide: Bool, registration: Bool
        let size: [Double]?, paper: String, starting: String?
    }

    /// The chart page as it will print, small: this round's (through its curves) once
    /// started, otherwise what Start would make from the settings. Nil with no colours.
    /// Drawn again only when something it shows changes.
    public func preview() -> RGBImage? {
        let key = PreviewKey(run: run?.folder, version: run?.current.version, colours: orderedColours, mirror: mirror,
                             guide: guide, registration: registration, size: sheetSize.map { [$0.0, $0.1] }, paper: paper,
                             starting: startingName)
        return previewMemo.get(key, drawPreview)
    }

    private func drawPreview() -> RGBImage? {
        if let run {
            guard let curves = try? run.colours.map({ try run.curve($0) }) else { return nil }
            return Chart.page(colours: run.colours, processes: curves, mirror: run.mirror, dpi: Self.previewPPI,
                              scale: (try? run.scale()) ?? 1, guide: run.guide, registration: run.registration)
        }
        let colours = orderedColours
        guard (1...5).contains(colours.count) else { return nil }
        let scale = (try? ProcessRun.scale(count: colours.count, size: sheetSize, paper: paper)) ?? 1
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
            savedRunsCache.clear()
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
            self.onTarget = run.colours.allSatisfy { results[$0]?.done == true }
            self.savedRunsCache.clear()
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
            onTarget = false
            savedRunsCache.clear()
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
