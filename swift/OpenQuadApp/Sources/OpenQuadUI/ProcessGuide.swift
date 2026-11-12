// Process Calibration as a wizard: one step at a time, from the blocking test to a finished
// process curve, with the one button that does the next thing (and the alternatives). The same
// models as the Advanced view, so switching between them keeps the work.

import AppKit
import OpenQuadCore
import SwiftUI

extension AppRoot {
    /// Where the process calibration is, from the blocking test to the finished curve.
    public enum GuideStage: Int, CaseIterable, Sendable {
        case blockingPrint, blockingScan, blockingChoose, curveStart, curvePrint, curveScan, curveResult

        /// The chip it lights up: test sheet, best colour, chart page, read, result.
        var chip: Int { [0, 0, 1, 2, 2, 3, 4][rawValue] }
    }

    public var guideStage: GuideStage {
        if processStep == .blocking {
            guard let blocking else { return .blockingPrint }
            if blocking.report != nil { return .blockingChoose }
            return blocking.printed ? .blockingScan : .blockingPrint
        }
        guard let process, process.started else { return .curveStart }
        if !process.printed { return .curvePrint }
        return process.measured ? .curveResult : .curveScan
    }
}

struct ProcessGuideView: View {
    @Bindable var root: AppRoot

    var body: some View {
        if let blocking = root.blocking, let process = root.process {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    card(blocking, process)
                    if let error = root.processStep == .blocking ? blocking.error : process.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    results(blocking, process)
                }
                .padding(20)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: the card: where you are, what to do, the button that does it

    func card(_ blocking: BlockingTestModel, _ process: ProcessWizardModel) -> some View {
        let stage = root.guideStage
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(Array(["Test sheet", "Best colour", "Chart page", "Read", "Result"].enumerated()), id: \.offset) { n, name in
                    StepChip(number: n + 1, name: name,
                             state: n < stage.chip ? .done : (n == stage.chip ? .current : .later))
                    if n < 4 { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                }
                Spacer()
                if let run = process.run, root.processStep == .curve {
                    Text("Round \(run.current.version + 1)").font(.headline).foregroundStyle(.secondary)
                }
            }
            Text(title(stage, blocking, process)).font(.title3.bold())
            Text(explanation(stage, blocking, process)).fixedSize(horizontal: false, vertical: true)
            if [.blockingScan, .curveScan].contains(stage) || (stage == .blockingPrint && blocking.scannerHost.isEmpty) {
                LabeledContent("Scanner") {
                    ScannerField(model: root.processStep == .blocking ? blocking as WizardModel : process)
                }
            }
            if stage == .curveStart {
                RunFields(model: process).frame(maxWidth: 520)
            }
            HStack(spacing: 10) { buttons(stage, blocking, process) }
                .disabled(blocking.busy || process.busy)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.25)))
    }

    func title(_ stage: AppRoot.GuideStage, _ blocking: BlockingTestModel, _ process: ProcessWizardModel) -> String {
        switch stage {
        case .blockingPrint: return "Step 1: print the blocking test on film"
        case .blockingScan: return "Step 1: contact print it, then scan the print"
        case .blockingChoose: return "Step 2: use the colour that blocks UV best"
        case .curveStart: return "Step 3: make a chart page in \(process.orderedColours.joined(separator: " and "))"
        case .curvePrint: return "Step 3: print the chart page on film"
        case .curveScan: return "Step 4: contact print it, then scan the print"
        case .curveResult:
            return process.onTarget ? "Done: every patch is on target" : "Step 5: refine the curve, then print again"
        }
    }

    func explanation(_ stage: AppRoot.GuideStage, _ blocking: BlockingTestModel, _ process: ProcessWizardModel) -> String {
        switch stage {
        case .blockingPrint:
            return "A sheet of every negative colour, to find the one that blocks UV fully with the most steps. Print it "
                + "on your transparency film (on \(blocking.paper)), at your usual settings. Already know your colour? "
                + "Skip to the chart."
        case .blockingScan:
            return "Expose the film on your tissue or paper at your usual time, develop and dry it, then put the print "
                + "face down on the scanner glass. Or scan it another way and read the file."
        case .blockingChoose:
            return blocking.best.map {
                "\($0.capitalized) blocks UV best on your process. Negatives will print in it, and the chart is made in it."
            } ?? "No colour blocks UV fully: try a longer print time or another film, and print the test again."
        case .curveStart:
            return "The chart has 101 tones, printed through the curve being made (none yet in round 1). Name the run "
                + "(e.g. carbon-pictorico) and note the print panel settings you'll use, so every round prints the same way."
        case .curvePrint:
            return "Print it at 100% on film (\(process.paper)) with: "
                + (process.printing.isEmpty ? "your usual settings" : process.printing) + "."
        case .curveScan:
            return "Contact print the chart at your usual exposure, develop and dry it, then scan the print."
        case .curveResult:
            return process.result.isEmpty ? "Read." : process.result
        }
    }

    @ViewBuilder func buttons(_ stage: AppRoot.GuideStage, _ blocking: BlockingTestModel, _ process: ProcessWizardModel) -> some View {
        switch stage {
        case .blockingPrint:
            Button("Print Test Sheet…") { if printWithPanel(blocking.printRequest()) { blocking.sheetPrinted("print panel") } }
                .buttonStyle(.borderedProminent)
            Button("Save It to Print Elsewhere…") { saveSheet(blocking) }
            Button("Skip: I Know My Colour", action: root.skipBlocking)
        case .blockingScan:
            Button("Scan the Print") {
                if confirm("Scan?", "Is the dry contact print face down on the scanner glass?") { blocking.read() }
            }
            .buttonStyle(.borderedProminent)
            Button("Read a Scan File…") { if let url = readFile() { blocking.read(file: url) } }
            Button("Print Again…") { if printWithPanel(blocking.printRequest()) { blocking.sheetPrinted("print panel") } }
        case .blockingChoose:
            if let best = blocking.best {
                Button("Use \(best.capitalized) for Negatives") { root.useBlockingColour(best, scannerHost: blocking.scannerHost) }
                    .buttonStyle(.borderedProminent)
            }
            Button("Read Another Scan…") { if let url = readFile() { blocking.read(file: url) } }
            Button("Skip: I Know My Colour", action: root.skipBlocking)
        case .curveStart:
            Button("Make the Chart Page", action: process.start)
                .buttonStyle(.borderedProminent)
                .disabled(process.colours.isEmpty || process.name.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Back to the Blocking Test") { root.processStep = .blocking }
        case .curvePrint:
            Button("Print Chart Page…") { printChart(process) }.buttonStyle(.borderedProminent)
            Button("I Printed It Elsewhere") { process.printed("printed elsewhere") }
        case .curveScan:
            Button("Scan the Print") {
                if confirm("Scan?", "Is the dry contact print face down on the scanner glass?") { process.scanAndRead() }
            }
            .buttonStyle(.borderedProminent)
            Button("Read a Scan File…") { if let url = readFile() { process.scanAndRead(file: url) } }
            Button("Print Again…") { printChart(process) }
        case .curveResult:
            if process.onTarget {
                Button("Use This Curve") { use(process) }.buttonStyle(.borderedProminent)
                Button("Refine Anyway", action: process.refine)
            } else {
                Button("Refine the Curve", action: process.refine).buttonStyle(.borderedProminent)
                Button("Use It As It Is") { use(process) }
            }
        }
        if blocking.busy || process.busy { ProgressView().controlSize(.small) }
    }

    // MARK: what was printed and read

    @ViewBuilder func results(_ blocking: BlockingTestModel, _ process: ProcessWizardModel) -> some View {
        if root.processStep == .blocking {
            if let report = blocking.report {
                BlockingHeatMap(report: report)
            }
        } else {
            HStack(alignment: .top, spacing: 16) {
                SheetPreview(image: process.preview(), ppi: ProcessWizardModel.previewPPI, units: process.units,
                             title: process.started ? "This round's page" : "The page it makes")
                    .frame(width: 220)
                if !process.readings.isEmpty { ToneChartView(readings: process.readings).frame(minHeight: 280) }
            }
        }
    }

    // MARK: actions

    private func use(_ process: ProcessWizardModel) {
        if let path = process.curvePath { root.useProcess(path, scannerHost: process.scannerHost) }
    }

    private func printChart(_ process: ProcessWizardModel) {
        process.savePrinting()
        do {
            guard let request = try process.pageForPrinting() else { return }
            if printWithPanel(request) { process.printed("print panel") }
        } catch {
            process.error = "\(error)"
        }
    }

    private func saveSheet(_ blocking: BlockingTestModel) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.tiff]
        panel.nameFieldStringValue = "blocking-test.tif"
        if panel.runModal() == .OK, let url = panel.url { blocking.save(url) }
    }

    private func readFile() -> URL? { ContentView.askOpen(types: [.jpeg, .png, .tiff]) }
}

/// The run's name and print-settings note, before it starts.
struct RunFields: View {
    @Bindable var model: ProcessWizardModel

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Name").gridColumnAlignment(.trailing)
                TextField("Name", text: $model.name).labelsHidden()
            }
            GridRow {
                Text("Print settings")
                TextField("Print settings", text: $model.printing,
                          prompt: Text("e.g. Glossy film, Highest quality, 2400 x 1200")).labelsHidden()
            }
        }
    }
}
