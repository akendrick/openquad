// The negative process calibration wizard's window.

import AppKit
import OpenQuadCore
import SwiftUI
import UniformTypeIdentifiers

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
