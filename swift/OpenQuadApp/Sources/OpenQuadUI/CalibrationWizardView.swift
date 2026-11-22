// The printer calibration wizard's window.

import AppKit
import OpenQuadCore
import SwiftUI
import UniformTypeIdentifiers

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
