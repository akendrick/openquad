// The printer calibration wizard for colour prints (colour calibration, phase 4): print the
// colour target, scan it, build a printer profile, then rounds of printing a verification
// page through the profile and refining it until it meets the goals.

import AppKit
import OpenQuadCore
import SwiftUI
import UniformTypeIdentifiers

public enum CalibrationKind: String, CaseIterable, Sendable {
    case blackAndWhite = "Black and white"
    case colour = "Colour"
}

extension CalibrationWizardModel {
    func startColour(printer: String) {
        let name = runName
        let model = scannerModel
        let grid = fineTarget ? 9 : 6
        let description = "\(LibraryEntry.printerName(printer)) \(paperLabel)"
        let folder = self.folder.appendingPathComponent("\(name)-\(Self.timestamp())")
        say("Making the colour target…")
        let (paper, label, settings, host, ppi) = (paper, paperLabel, printSettings, scannerHost, colourPPI)
        step("start", {
            try ColourRun.start(folder: folder, name: name, description: description, printer: printer, paper: paper,
                                paperLabel: label, settings: settings, scannerHost: host, scannerModel: model, grid: grid, ppi: ppi)
        }) { run in
            self.colourRun = run
            self.profileSummary = nil
            self.verification = nil
            self.say("Started \(name) in \(run.folder.path)")
        }
    }

    func resumeColour(_ saved: URL) {
        do {
            let run = try ColourRun.resume(saved)
            colourRun = run
            kind = .colour
            printer = run.printer
            paper = run.paper
            paperType = run.paperLabel.hasPrefix(run.paper)
                ? run.paperLabel.dropFirst(run.paper.count).trimmingCharacters(in: .whitespaces) : paperType
            method = run.settings.contains("print panel") ? .panel : .direct
            fineTarget = run.target?.grid == 9
            if !run.scannerHost.isEmpty { scannerHost = run.scannerHost }
            profileSummary = run.target?.summary
            verification = try? run.report()
            error = nil
            say("Continuing \(run.name), round \(round).")
        } catch {
            self.error = "Couldn't continue that run: \(error)"
        }
    }

    /// The pages to print now, by lp.
    func printColourDirect(runner: @escaping Printing.Runner = Printing.runCommand) {
        guard let run = colourRun else { return }
        say("Printing \(run.onTarget ? "the colour target" : "the verification page") on \(LibraryEntry.printerName(run.printer))…")
        nonisolated(unsafe) let runner = runner
        step("print", { try run.printPages(runner: runner) }) { jobs in
            self.colourRun = run
            self.say("Sent to the printer: job \(jobs.joined(separator: ", ")). Let it dry, then scan it.")
        }
    }

    /// The pages rendered for the print panel at the run's resolution.
    public func colourPagesForPrinting() throws -> [(RGBImage, Double, Double, String, String)] {
        guard let run = colourRun else { return [] }
        let pages = try run.makePages()
        return try pages.enumerated().map { i, url in
            let page = try Scan.load(url)
            let image = RGBImage(width: page.width, height: page.height, pixels: page.samples)
            let what = run.onTarget ? "colour target" : "colour check v\(run.current!.version)"
            return (image, Double(page.width) / run.ppi, Double(page.height) / run.ppi, run.paper,
                    "OpenQuad \(what): \(run.name)" + (pages.count > 1 ? " page \(i + 1) of \(pages.count)" : ""))
        }
    }

    func colourPrinted(_ note: String) {
        guard let run = colourRun else { return }
        do {
            try run.markPrinted(note)
            colourRun = run
            say("Printed (\(note)). Let it dry, then scan it.")
        } catch {
            self.error = "\(error)"
        }
    }

    enum ColourScanResult: Sendable {
        case needMore(Int, Int)
        case profile(String)
        case verified(VerificationReport)
    }

    /// Scan a page (or read a scan file); once every page is in, measure: the target builds
    /// the first profile, a verification page is judged against the goals.
    func scanColour(fetch: @escaping ESCL.Fetch = ESCL.httpFetch, file: URL? = nil) {
        guard let run = colourRun else { return }
        if file == nil {
            guard !scannerHost.isEmpty else {
                error = "Choose a scanner first (Find looks on the network)."
                return
            }
            run.scannerHost = scannerHost
        }
        let building = run.onTarget && run.scansSoFar.count + 1 >= run.pagesNeeded
        say(file == nil ? "Scanning…" : "Reading \(file!.lastPathComponent)…")
        if building { say("Measuring the target and building the profile (this takes a few seconds)…") }
        nonisolated(unsafe) let fetch = fetch
        step(building ? "build" : "measure", { () -> ColourScanResult in
            if let file { try run.useScan(file) } else { try run.scanPage(fetch: fetch) }
            guard run.scannedAll else { return .needMore(run.scansSoFar.count, run.pagesNeeded) }
            if run.onTarget {
                do {
                    let report = try run.measureTarget()
                    return .profile(report.summary())
                } catch {
                    try? run.clearScans()  // a wrong or poor scan: scan the pages again
                    throw error
                }
            }
            return .verified(try run.measure())
        }) { result in
            self.colourRun = run
            switch result {
            case .needMore(let done, let all):
                self.say("Scanned page \(done) of \(all). Now scan page \(done + 1).")
            case .profile:
                self.profileSummary = run.target?.summary
                self.verification = nil
                self.say("Built profile v0. Print a verification page to check it.")
            case .verified(let report):
                self.verification = report
                self.say(report.passed ? "Measured: the goals are met." : "Measured: refine the profile.")
            }
        }
    }

    func refineColour() {
        guard let run = colourRun else { return }
        say("Refining the profile…")
        step("refine", { try run.refine() }) { round in
            self.colourRun = run
            self.verification = nil
            self.say("Built profile v\(round.version). Print a verification page to check it.")
        }
    }

    /// Start this page's scans again.
    func rescanColour() {
        guard let run = colourRun else { return }
        do {
            try run.clearScans()
            colourRun = run
            verification = nil
        } catch {
            self.error = "\(error)"
        }
    }

    /// Add a scanner model (made by `openquad scanner-profile`) to the library and use it.
    public func addScannerModel(_ url: URL) {
        do {
            let entry = try CalibrationLibrary(folder: folder).importScannerModel(url)
            scannerModels = CalibrationLibrary(folder: folder).scannerModels()
            scannerModel = entry.url
            say("Added the scanner model \(entry.name).")
        } catch {
            self.error = "Couldn't add the scanner model: \(error)"
        }
    }

    public struct ColourRoundSummary: Identifiable, Equatable {
        public let round: Int
        public let profile: String
        public let mean: Double?, p95: Double?, cast: Double?, tone: Double?
        public let then: String
        public var id: Int { round }
    }

    /// Every verification round so far (round 1 is the target).
    public var colourRounds: [ColourRoundSummary] {
        guard let run = colourRun else { return [] }
        let target = ColourRoundSummary(round: 1, profile: "target", mean: nil, p95: nil, cast: nil, tone: nil,
                                        then: run.onTarget ? (run.printed ? "To scan" : "To print") : "Built v0")
        return [target] + run.rounds.map { r in
            let a = r.assessment, latest = r.version == run.rounds.count - 1
            let then: String
            if !latest {
                then = "Refined"
            } else if r.measurement != nil {
                then = r.action == "done" ? "Goals met" : "Measured"
            } else {
                then = r.job == nil ? "To print" : "To scan"
            }
            return ColourRoundSummary(round: r.version + 2, profile: "v\(r.version)", mean: a?["mean"], p95: a?["p95"],
                                      cast: a?["worst_cast"], tone: a?["worst_tone"], then: then)
        }
    }
}

// MARK: - views

/// The colour setup's own rows: the target and the scanner model.
struct ColourSetupRows: View {
    @Bindable var model: CalibrationWizardModel

    var body: some View {
        GridRow {
            Text("Target")
            Picker("Target", selection: $model.fineTarget) {
                Text("One page (255 colours)").tag(false)
                Text("Two pages, finer (768 colours, for photo papers)").tag(true)
            }
            .labelsHidden()
            Text("Scanner model")
            HStack {
                Picker("Scanner model", selection: $model.scannerModel) {
                    Text("None (read the scan as sRGB)").tag(URL?.none)
                    ForEach(model.scannerModels) { Text($0.name).tag(URL?.some($0.url)) }
                }
                .labelsHidden()
                Button("Add…") {
                    if let url = ContentView.askOpen(types: [.json]) { model.addScannerModel(url) }
                }
                .help("A scanner model made from an IT8.7/2 target with `openquad scanner-profile`")
            }
        }
    }
}

/// What to do now in a colour calibration, with the button that does it.
struct ColourNextStepCard: View {
    @Bindable var model: CalibrationWizardModel
    let actions: NextStepActions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(Array(["Print", "Scan", "Result"].enumerated()), id: \.offset) { n, name in
                    StepChip(number: n + 1, name: name, state: chipState(n))
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

    var run: ColourRun? { model.colourRun }
    var onTarget: Bool { run?.onTarget ?? true }
    var version: Int { run?.current?.version ?? 0 }

    func chipState(_ n: Int) -> StepChip.State {
        let now = [CalibrationWizardModel.Step.setup: -1, .print: 0, .scan: 1, .result: 2][model.step]!
        return n < now ? .done : (n == now ? .current : .later)
    }

    var title: String {
        switch model.step {
        case .setup: return "Set up, then start"
        case .print: return onTarget ? "Step 1: print the colour target" : "Step 1: print a page to check profile v\(version)"
        case .scan:
            let pages = run?.pagesNeeded ?? 1, done = run?.scansSoFar.count ?? 0
            return pages > 1 ? "Step 2: scan page \(min(done + 1, pages)) of \(pages)" : "Step 2: scan the printed page"
        case .result:
            return model.verification?.passed == true ? "Done: profile v\(version) meets the goals" : "Step 3: refine the profile"
        }
    }

    var explanation: String {
        switch model.step {
        case .setup:
            let scanner = model.scannerModel == nil
                ? "\n\nThere's no scanner model, so the scan is read as sRGB: prints will match each other, but how close they "
                    + "come to the photo's real colours rests on the scanner. A model made from an IT8.7/2 target "
                    + "(`openquad scanner-profile`) makes the scanner a measuring instrument; Add it here."
                : ""
            return "Choose the printer and paper you'll print colour photos on, how you'll print (the same way every time), "
                + "and the scanner. Round 1 prints the colour target and builds a profile from it; each round after prints "
                + "colours the profile wasn't built from and checks them." + scanner
        case .print:
            if onTarget {
                return "The target is \(run?.pagesNeeded == 2 ? "two pages" : "one page") of colour patches inside a black frame. "
                    + "Print it the same way you'll print photos, at 100% (no scaling), with the driver's colour settings "
                    + "left as they are."
            }
            let built = version == 0 ? (model.profileSummary.map { "Profile v0 is built.\n" + summaryLines($0) + "\n\n" } ?? "")
                : "Profile v\(version) is built from what round \(model.round - 1) measured.\n\n"
            return built + "The verification page has 144 colours sent through profile v\(version): a colour checker's, "
                + "skin tones, greys and photo colours. Use the same paper and settings as for the target."
        case .scan:
            let wait = onTarget ? "Let the ink dry for at least an hour (dye inks shift as they dry), then put" : "When it's dry, put"
            return "\(wait) the page face down on the scanner glass (either way round) and close the lid. "
                + "Or scan it some other way, at 300 ppi or more, and read the file."
        case .result:
            guard let v = model.verification else { return "Measured." }
            let mean = String(format: "Mean %.1f ΔE00 (goal under 3) %@, 95%% %.1f (goal under 6) %@", v.mean,
                              v.mean < 3 ? "✓" : "✗", v.p95, v.p95 < 6 ? "✓" : "✗")
            let greys = String(format: "Greys: cast %.1f (goal under 3) %@, tone %.1f L* (goal under 2) %@", v.worstCast,
                               v.worstCast < 3 ? "✓" : "✗", v.worstTone, v.worstTone < 2 ? "✓" : "✗")
            let next = v.passed
                ? "Use this profile for colour prints. Refining again can still bring it closer."
                : "Refine Profile builds v\(version + 1) from this page's measurements. Then print again to check it."
            return "\(mean). \(greys).\n\(next)"
        }
    }

    func summaryLines(_ text: String) -> String {
        text.split(separator: "\n").filter { $0.hasPrefix("Patches left out") || $0.hasPrefix("Greys through") || $0.hasPrefix("Black:") }
            .joined(separator: "\n")
    }

    @ViewBuilder var buttons: some View {
        switch model.step {
        case .setup:
            Button("Start", action: actions.start).buttonStyle(.borderedProminent).disabled(model.busy)
        case .print:
            let what = onTarget ? "Print Colour Target" : "Print Verification Page"
            Button(model.method == .direct ? what : what + "…", action: actions.print).buttonStyle(.borderedProminent).disabled(model.busy)
            Button("I Printed It Another Way", action: actions.printedElsewhere).disabled(model.busy)
        case .scan:
            Button(run?.pagesNeeded == 2 ? "Scan Page \(min((run?.scansSoFar.count ?? 0) + 1, 2))" : "Scan and Measure", action: actions.scan)
                .buttonStyle(.borderedProminent).disabled(model.busy)
            Button("Read a Scan File…", action: actions.readFile).disabled(model.busy)
            if !(run?.scansSoFar.isEmpty ?? true) { Button("Scan Again") { model.rescanColour() }.disabled(model.busy) }
            Button("Print Again", action: actions.print).disabled(model.busy)
        case .result:
            let passed = model.verification?.passed == true
            if passed {
                Button("Use This Profile", action: actions.use).buttonStyle(.borderedProminent)
                Button("Refine Anyway") { actions.improve("refine") }.disabled(model.busy)
            } else {
                Button("Refine Profile") { actions.improve("refine") }.buttonStyle(.borderedProminent).disabled(model.busy)
                Button("Use As It Is", action: actions.use)
            }
        }
    }
}

/// Every colour round's verification, so progress (or not) is plain.
struct ColourRoundsTable: View {
    let rounds: [CalibrationWizardModel.ColourRoundSummary]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
            GridRow {
                Text("Round"); Text("Profile"); Text("Mean ΔE00 (< 3)"); Text("95% (< 6)"); Text("Grey cast (< 3)"); Text("Grey tone (< 2)")
                Text("Then")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(rounds) { r in
                GridRow {
                    Text("\(r.round)").monospacedDigit()
                    Text(r.profile)
                    value(r.mean, goal: 3)
                    value(r.p95, goal: 6)
                    value(r.cast, goal: 3)
                    value(r.tone, goal: 2)
                    Text(r.then).foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder func value(_ v: Double?, goal: Double) -> some View {
        if let v {
            HStack(spacing: 4) {
                Text(String(format: "%.1f", v)).monospacedDigit()
                Image(systemName: v < goal ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(v < goal ? Color.green : Color.orange)
            }
        } else {
            Text("–").foregroundStyle(.tertiary)
        }
    }
}

/// The latest result in words: the verification's report, or the profile's.
struct ColourResultView: View {
    let model: CalibrationWizardModel

    var body: some View {
        if let text = model.verification?.summary() ?? model.profileSummary {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.verification != nil ? "Verification, round \(model.round)" : "The target and profile v0")
                    .font(.headline)
                Text(text)
                    .font(.callout.monospacedDigit())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let v = model.verification { WorstColours(report: v) }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// The colours furthest off: wanted beside measured, as swatches.
struct WorstColours: View {
    let report: VerificationReport

    var worst: [Int] {
        report.deltaE.indices.filter { report.verification.printable[$0] }.sorted { report.deltaE[$0] > report.deltaE[$1] }
            .prefix(8).map { $0 }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(worst, id: \.self) { i in
                VStack(spacing: 2) {
                    HStack(spacing: 0) {
                        swatch(report.verification.wanted[i])
                        swatch(report.measured[i])
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    Text(String(format: "%.1f", report.deltaE[i])).font(.caption.monospacedDigit())
                }
                .help("\(report.verification.names[i]): wanted (left), printed (right)")
            }
        }
    }

    func swatch(_ lab: [Double]) -> some View {
        let xyz = Colour.labToXYZ(lab, white: Colour.d50White)
        return Rectangle()
            .fill(Color(cgColor: CGColor(colorSpace: CGColorSpace(name: CGColorSpace.genericXYZ)!,
                                         components: [xyz[0], xyz[1], xyz[2], 1]) ?? .black))
            .frame(width: 22, height: 30)
    }
}
