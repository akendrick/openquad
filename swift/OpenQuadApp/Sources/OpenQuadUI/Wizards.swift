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

@MainActor
@Observable
public final class CalibrationWizardModel: WizardModel {
    public var name: String
    public var paper: String
    public var startFromCurrent: Bool
    public var shadowStrength = 0.5
    public private(set) var run: CalibrationRun?
    public private(set) var uncorrected: Measurement?
    public private(set) var corrected: Measurement?
    public private(set) var assessment: Assessment?
    public private(set) var result = ""
    let folder: URL
    let starting: Calibration?
    let startingName: String?

    public init(folder: URL, paper: String, scannerHost: String, starting: Calibration?, startingName: String?,
                find: @escaping @Sendable () -> [(String, String)] = { ESCL.discover() }) {
        self.folder = folder
        self.paper = paper
        self.starting = starting
        self.startingName = startingName
        startFromCurrent = starting != nil
        name = "printer-\(paper.lowercased())-plain"
        super.init(scannerHost: scannerHost, find: find)
    }

    public var started: Bool { run != nil }
    public var printed: Bool { run?.current.job != nil }
    public var measured: Bool { run?.current.measurements.count == 2 }
    public var canUse: Bool { measured || (run?.current.version ?? 0) > 0 }

    public func start() {
        let name = self.name.trimmingCharacters(in: .whitespaces)
        do {
            run = try CalibrationRun.start(folder: folder.appendingPathComponent("\(name)-\(Self.timestamp())"), name: name,
                                           printer: "print panel", paper: paper, scannerHost: scannerHost,
                                           starting: startFromCurrent ? starting : nil,
                                           settings: "macOS print panel; eSCL Document intent")
            say("Started \(name) in \(run!.folder.path)")
        } catch {
            self.error = "Couldn't start: \(error)"
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
}

// MARK: - negative process calibration

@MainActor
@Observable
public final class ProcessWizardModel: WizardModel {
    public static let defaultPrinting = "Fine glossy paper, Extra detail, Diffusion, 600 x 600"
    public var name = "carbon-office-film"
    public var colours: Set<String> = ["green", "orange"]
    public var mirror = false
    public var film = "inkjet-coated office transparency"
    public var printing = defaultPrinting
    public var useColour = "green"
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

    public func start() {
        let name = self.name.trimmingCharacters(in: .whitespaces)
        do {
            let run = try ProcessRun.start(folder: folder.appendingPathComponent("\(name)-\(Self.timestamp())"), name: name,
                                           colours: orderedColours, scannerHost: scannerHost, mirror: mirror,
                                           film: film.trimmingCharacters(in: .whitespaces),
                                           printing: printing.trimmingCharacters(in: .whitespaces))
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
            self.result = lines.joined(separator: "; ") + String(format: ". Goal: every patch within %g L*. Best: %@.",
                                                                  ProcessResult.toneGoal, best ?? "none")
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

    public var curvePath: URL? { run?.curvePath(useColour) }
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

struct ScannerRow: View {
    @Bindable var model: WizardModel

    var body: some View {
        LabeledContent("Scanner") {
            HStack {
                TextField("Scanner", text: $model.scannerHost, prompt: Text("host:port"))
                    .labelsHidden()
                Menu("Found") {
                    ForEach(model.scanners, id: \.host) { s in Button("\(s.name) (\(s.host))") { model.scannerHost = s.host } }
                }
                .disabled(model.scanners.isEmpty)
                .fixedSize()
                Button("Find", action: model.findScanners).disabled(model.busy)
            }
        }
    }
}

struct LogView: View {
    let lines: [String]
    var body: some View {
        ScrollView {
            Text(lines.joined(separator: "\n"))
                .font(.caption.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(height: 80)
        .padding(6)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }
}

public struct CalibrationWizardView: View {
    @Bindable var model: CalibrationWizardModel
    let use: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    public init(model: CalibrationWizardModel, use: @escaping (URL) -> Void) {
        self.model = model
        self.use = use
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Calibrate a printer").font(.title2.bold())
            Form {
                TextField("Name", text: $model.name).disabled(model.started)
                Picker("Paper", selection: $model.paper) { ForEach(paperOrder, id: \.self) { Text($0) } }.disabled(model.started)
                ScannerRow(model: model)
                if model.starting != nil {
                    Picker("Start from", selection: $model.startFromCurrent) {
                        Text("No correction").tag(false)
                        Text("Current calibration (\(model.startingName ?? "loaded"))").tag(true)
                    }
                    .disabled(model.started)
                }
            }
            .formStyle(.grouped)
            .frame(height: model.starting != nil ? 210 : 170)
            HStack {
                Button("Start", action: model.start).disabled(model.started)
                Button("1. Print Comparison Page…", action: printPage).disabled(!model.started || model.busy)
                Button("2. Scan and Measure", action: scan).disabled(!model.printed || model.busy)
                Button("…or Read a Scan File", action: readFile).disabled(!model.printed || model.busy)
                if model.busy { ProgressView().controlSize(.small) }
            }
            WedgeChartView(uncorrected: model.uncorrected, corrected: model.corrected)
                .frame(minHeight: 280)
            if !model.result.isEmpty { Text(model.result).fixedSize(horizontal: false, vertical: true) }
            if let error = model.error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Improve Grey Balance") { model.improve("grey balance") }
                    .disabled(!model.measured)
                    .buttonStyle(.bordered)
                    .tint(model.assessment?.nextStep == "grey balance" ? .accentColor : nil)
                Stepper(value: $model.shadowStrength, in: 0...1, step: 0.1) {
                    Text(String(format: "shadow strength %.1f", model.shadowStrength))
                }
                .fixedSize()
                Button("Even Out Tone") { model.improve("linearize") }
                    .disabled(!model.measured)
                    .tint(model.assessment?.nextStep == "linearize" ? .accentColor : nil)
                Spacer()
                Button("Close") { dismiss() }
                Button("Use This Calibration") {
                    if let path = model.calibrationPath { use(path) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canUse)
            }
            LogView(lines: model.log)
        }
        .padding(20)
        .frame(width: 780)
    }

    private func printPage() {
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

public struct ProcessWizardView: View {
    @Bindable var model: ProcessWizardModel
    let use: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    public init(model: ProcessWizardModel, use: @escaping (URL) -> Void) {
        self.model = model
        self.use = use
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Calibrate a negative process").font(.title2.bold())
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
                ScannerRow(model: model)
                Toggle("Mirror the negatives", isOn: $model.mirror)
                TextField("Film", text: $model.film)
                TextField("Print settings", text: $model.printing)
            }
            .formStyle(.grouped)
            .frame(height: 290)
            .disabled(model.started)
            HStack {
                Button("Start", action: model.start).disabled(model.started || model.colours.isEmpty || model.colours.count > 5)
                Button("1. Print Chart Page…", action: printPage).disabled(!model.started || model.busy)
                Button("…or I Printed It Elsewhere") { model.printed("printed elsewhere") }.disabled(!model.started || model.busy)
                if model.busy { ProgressView().controlSize(.small) }
            }
            HStack {
                Button("2. Scan the Contact Print and Read It", action: scan).disabled(!model.printed || model.busy)
                Button("…or Read a Scan File", action: readFile).disabled(!model.printed || model.busy)
                Button("3. Refine the Curves", action: model.refine).disabled(!model.measured || model.busy)
            }
            ToneChartView(readings: model.readings)
                .frame(minHeight: 260)
            if !model.result.isEmpty { Text(model.result).fixedSize(horizontal: false, vertical: true) }
            if let error = model.error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                Picker("Use", selection: $model.useColour) {
                    ForEach(model.run?.colours ?? [], id: \.self) { Text($0.capitalized).tag($0) }
                }
                .fixedSize()
                .disabled(!model.started)
                Button("Use This Colour's Curve") {
                    if let path = model.curvePath { use(path) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.started)
            }
            LogView(lines: model.log)
        }
        .padding(20)
        .frame(width: 820)
    }

    private func printPage() {
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
