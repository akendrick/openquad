// The blocking test: print a sheet of every negative colour on film, contact print it
// (carbon), scan the print, and see which colour blocks UV fully with the most steps.

import AppKit
import Charts
import OpenQuadCore
import SwiftUI

@MainActor
@Observable
public final class BlockingTestModel: WizardModel {
    public var mirror = false
    public var safeEdge = 0.25
    public private(set) var report: BlockingReport?
    public private(set) var scanName: String?

    public override init(scannerHost: String, find: @escaping @Sendable () -> [(String, String)] = { ESCL.discover() }) {
        super.init(scannerHost: scannerHost, find: find)
    }

    /// The sheet at 300 ppi, for the print panel or a file.
    public func sheet() -> RGBImage { Blocking.sheet(dpi: 300, mirror: mirror, safeEdge: safeEdge) }

    public func printRequest() -> (RGBImage, Double, Double, String, String) {
        let sheet = sheet()
        return (sheet, Double(sheet.width) / 300, Double(sheet.height) / 300, "Letter", "OpenQuad blocking test")
    }

    public func save(_ url: URL) {
        do {
            try ImageFiles.saveRGB(url, sheet(), dpi: (300, 300), iccProfile: ImageFiles.srgbProfile())
            say("Saved \(url.lastPathComponent). Print it on film at 100% (300 ppi).")
        } catch {
            self.error = "\(error)"
        }
    }

    /// Read a scan of the contact print: from the scanner, or from a file.
    public func read(fetch: @escaping ESCL.Fetch = ESCL.httpFetch, file: URL? = nil) {
        let host = scannerHost
        if file == nil && host.isEmpty {
            error = "Choose a scanner first (Find looks on the network)."
            return
        }
        say(file == nil ? "Scanning the contact print…" : "Reading \(file!.lastPathComponent)…")
        nonisolated(unsafe) let fetch = fetch
        step("read", { () -> (BlockingReport, String) in
            let url: URL
            if let file {
                url = file
            } else {
                url = FileManager.default.temporaryDirectory.appendingPathComponent("openquad-blocking-scan.jpg")
                try ESCL.scan(host: host, settings: try ScanSettings(), fetch: fetch).write(to: url)
            }
            return (try Blocking.analyse(try Scan.load(url)), url.lastPathComponent)
        }) { report, name in
            self.report = report
            self.scanName = name
            self.say("Read the print (\(report.orientation)). " + (report.lines().last ?? ""))
        }
    }

    public var best: String? { report?.best()?.name }
}

/// L* of each colour's wedge, 0% to 100% ink, with the process white for reference.
struct BlockingChart: View {
    let report: BlockingReport

    var body: some View {
        Chart {
            RuleMark(y: .value("Process white", report.white))
                .foregroundStyle(.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .annotation(position: .top, alignment: .leading) { Text("process white").font(.caption2).foregroundStyle(.secondary) }
            ForEach(report.results, id: \.name) { result in
                ForEach(Array(result.wedge.enumerated()), id: \.offset) { step, value in
                    LineMark(x: .value("Ink", step * 10), y: .value("L*", value))
                        .foregroundStyle(by: .value("Colour", result.name))
                }
            }
        }
        .chartForegroundStyleScale(domain: report.results.map(\.name), range: report.results.map { ToneChartView.swatch($0.name) })
        .chartXAxisLabel("ink on the film (%)")
        .chartYAxisLabel("L* in the print")
        .chartYScale(domain: 0...100)
    }
}

public struct BlockingTestView: View {
    @Bindable var model: BlockingTestModel
    let use: (String) -> Void
    let close: () -> Void

    public init(model: BlockingTestModel, use: @escaping (String) -> Void, close: @escaping () -> Void = {}) {
        self.model = model
        self.use = use
        self.close = close
    }

    public var body: some View {
        WizardScaffold(title: "Find the best blocking colour", log: model.log) {
            EmptyView()
        } content: {
            Text("Print the test sheet on film, expose it on your tissue at your usual time, develop it, then scan the print. "
                 + "The best colour blocks UV fully (its full patch prints as white as the process allows) and gives the most "
                 + "distinct steps.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                Toggle("Mirror the sheet", isOn: $model.mirror)
                Stepper(value: $model.safeEdge, in: 0...1, step: 0.05) {
                    LabeledContent("Safe edge", value: String(format: "%.2f in", model.safeEdge))
                }
                LabeledContent("Scanner") { ScannerField(model: model) }
            }
            .formStyle(.grouped)
            .frame(height: 170)
            HStack {
                Button("1. Print Test Sheet…") {
                    if printWithPanel(model.printRequest()) { model.say("Printed the test sheet. Contact print it, then scan the print.") }
                }
                Button("…or Save It", action: save)
                Button("2. Scan the Print") {
                    if confirm("Scan?", "Is the dry contact print face down on the scanner glass?") { model.read() }
                }
                .disabled(model.busy)
                Button("…or Read a Scan File") {
                    if let url = ContentView.askOpen(types: [.jpeg, .png, .tiff]) { model.read(file: url) }
                }
                .disabled(model.busy)
                if model.busy { ProgressView().controlSize(.small) }
            }
            if let report = model.report {
                BlockingChart(report: report).frame(minHeight: 240, maxHeight: .infinity)
                Text(report.lines().joined(separator: "\n"))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ContentUnavailableView("No print read yet", systemImage: "square.grid.3x3.square")
                    .frame(minHeight: 240)
            }
            if let error = model.error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Close", action: close)
                Button(model.best.map { "Use \($0.capitalized) for Negatives" } ?? "Use the Best Colour") {
                    if let best = model.best { use(best) }
                    close()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.best == nil)
            }
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.tiff]
        panel.nameFieldStringValue = "blocking-test.tif"
        if panel.runModal() == .OK, let url = panel.url { model.save(url) }
    }
}
