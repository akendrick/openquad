// The print window: open a photo, choose toning or a digital negative, set the page,
// preview, and print through the macOS print panel.

import AppKit
import OpenQuadCore
import SwiftUI
import UniformTypeIdentifiers

public struct ContentView: View {
    @Bindable var model: AppModel
    @State private var ppiText = ""
    @State private var showGuide = false
    @AppStorage("guideSeen") private var guideSeen = 0

    let guideOnLaunch: Bool

    public init(model: AppModel, guideOnLaunch: Bool = true) {
        self.model = model
        self.guideOnLaunch = guideOnLaunch
    }

    public var body: some View {
        HSplitView {
            controls
                .frame(minWidth: 320, idealWidth: 340, maxWidth: 420)
            previewPane
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 820, minHeight: 600)
        .sheet(isPresented: $showGuide) { GuideView { guideSeen = GuideView.version } }
        .toolbar {
            ToolbarItem {
                Button { showGuide = true } label: { Label("How to Use OpenQuad", systemImage: "questionmark.circle") }
                    .help("How to use OpenQuad")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: GuideView.showNotification)) { _ in showGuide = true }
        .onAppear {
            model.loadPrinters()
            if guideOnLaunch && guideSeen < GuideView.version { showGuide = true }  // first launch: walk through the app
        }
    }

    // MARK: the controls

    private var controls: some View {
        VStack(spacing: 0) {
            Form {
                Section("Photo") {
                    Button("Open Photo…", action: openPhoto)
                        .keyboardShortcut("o")
                    Text(model.photoDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Section("Output") {
                    Picker("Output", selection: Binding(get: { model.session.mode }, set: { model.setMode($0) })) {
                        Text("Print").tag(OutputMode.print)
                        Text("Digital negative").tag(OutputMode.negative)
                    }
                    .pickerStyle(.segmented)
                    if model.session.negative { negativeControls } else { printControls }
                }
                Section("Page") {
                    Picker("Printer", selection: Binding(get: { model.session.printer }, set: { model.setPrinter($0) })) {
                        Text("Choose in the print panel").tag(String?.none)
                        ForEach(model.printers, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ")).tag(String?.some($0)) }
                        if let printer = model.session.printer, !model.printers.contains(printer) {
                            Text(printer.replacingOccurrences(of: "_", with: " ")).tag(String?.some(printer))
                        }
                    }
                    Picker("Paper", selection: Binding(get: { model.session.paper }, set: { model.setPaper($0) })) {
                        ForEach(paperOrder, id: \.self) { Text($0).tag($0) }
                    }
                    Toggle("Fit to page (0.5 in margins)", isOn: Binding(get: { model.session.fit }, set: { model.setFit($0) }))
                    if model.session.fit { fitWithin }
                    TextField("Resolution (ppi)", text: $ppiText, prompt: Text("photo's own"))
                        .disabled(model.session.fit)
                        .onSubmit { model.setPPI(Double(ppiText)) }
                    if !model.sizeDescription.isEmpty {
                        LabeledContent("Print size") { Text(model.sizeDescription).multilineTextAlignment(.trailing) }
                    }
                }
            }
            .formStyle(.grouped)
            if let status = model.status {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            if let error = model.error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }
            HStack {
                Button("Save Print File…", action: savePrintFile)
                    .disabled(model.session.photo == nil || model.busy)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Print…", action: printPhoto)
                    .keyboardShortcut("p")
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canPrint)
            }
            .padding()
        }
    }

    /// Fit within the page, or a set size (for a negative: its outer edge, e.g. the tissue).
    @ViewBuilder private var fitWithin: some View {
        Picker("Fit within", selection: Binding(get: { model.session.maxSize != nil },
                                                set: { model.setMaxSize($0 ? model.rememberedMaxSize : nil) })) {
            Text("The page").tag(false)
            Text("A set size").tag(true)
        }
        if let size = model.session.maxSize {
            LabeledContent(model.session.negative ? "Outer size" : "Size") {
                HStack(spacing: 6) {
                    TextField("Width", value: Binding(get: { size.0 }, set: { model.setMaxSize(($0, size.1)) }),
                              format: .number.precision(.fractionLength(0...2)))
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                    Text("×")
                    TextField("Height", value: Binding(get: { size.1 }, set: { model.setMaxSize((size.0, $0)) }),
                              format: .number.precision(.fractionLength(0...2)))
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                    Text("in")
                    Menu("Sizes") {
                        ForEach([(4.0, 5.0), (5.0, 7.0), (6.0, 8.0), (8.0, 10.0), (11.0, 14.0)], id: \.0) { w, h in
                            Button(String(format: "%g × %g in", w, h)) { model.setMaxSize((w, h)) }
                        }
                    }
                    .fixedSize()
                }
                .labelsHidden()
            }
            Text(model.session.negative
                 ? "The negative's outer edge, safe edge included: the photo shrinks to fit inside it (e.g. your tissue). "
                    + "It turns to match the photo, and never goes past the page's margins."
                 : "The image fits inside this size (turned to match the photo), and never goes past the page's margins.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var printControls: some View {
        Picker("Toning", selection: Binding(get: { model.session.preset }, set: { model.setPreset($0) })) {
            ForEach(presetLabels, id: \.0) { Text($0.1).tag($0.0) }
        }
        Picker("Calibration", selection: Binding(get: { model.currentCalibration?.url }, set: { model.setCalibration($0) })) {
            Text("None (uncorrected)").tag(URL?.none)
            ForEach(model.calibrations) { entry in Text(entry.label).tag(URL?.some(entry.url)) }
        }
        if let current = model.currentCalibration {
            Text(current.settings)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        HStack {
            Button("Import…") {
                if let url = Self.askOpen(types: [UTType(filenameExtension: "oqcal")].compactMap { $0 }) { model.importCalibration(url) }
            }
            Button("Calibrate This Printer…", action: openCalibrationWizard)
        }
    }

    @ViewBuilder private var negativeControls: some View {
        Picker("Ink colour", selection: Binding(get: { model.session.negativeColour }, set: { model.setNegativeColour($0) })) {
            ForEach(Negative.colourOrder, id: \.self) { Text($0.capitalized).tag($0) }
        }
        .disabled(model.session.process != nil)  // the process curve decides the colour
        fileRow("Process curve", model.session.processPath, types: ["oqproc"],
                choose: { model.setProcess($0) }, clear: { model.setProcess(nil) })
        Button("Calibrate a Process…", action: openProcessWizard)
        Button("Find the Best Blocking Colour…", action: openBlockingTest)
        Toggle("Mirror (flip left to right)", isOn: Binding(get: { model.session.mirror }, set: { model.setMirror($0) }))
        Stepper(value: Binding(get: { model.session.safeEdge }, set: { model.setSafeEdge($0) }), in: 0...2, step: 0.05) {
            LabeledContent("Safe edge", value: String(format: "%.2f in", model.session.safeEdge))
        }
    }

    private func fileRow(_ title: String, _ url: URL?, types: [String], choose: @escaping (URL) -> Void,
                         clear: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            HStack {
                Text(url?.lastPathComponent ?? "none").foregroundStyle(url == nil ? .secondary : .primary)
                Button("Choose…") {
                    if let url = Self.askOpen(types: types.compactMap { UTType(filenameExtension: $0) }) { choose(url) }
                }
                if url != nil { Button("Clear", action: clear) }
            }
        }
    }

    // MARK: the preview

    private var previewPane: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            if let image = model.preview {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .shadow(radius: 4)
                    .padding(24)
            } else {
                ContentUnavailableView("Open a photo to begin", systemImage: "photo",
                                       description: Text("Greyscale or colour, any size; it's printed in the tones you choose."))
            }
        }
    }

    // MARK: actions

    private func openCalibrationWizard() {
        let wizard = model.calibrationWizard(), app = model
        WizardWindows.show("calibrate-printer", title: "Calibrate a Printer", size: CGSize(width: 980, height: 820),
                           minSize: CGSize(width: 760, height: 560)) { close in
            CalibrationWizardView(model: wizard, use: { app.finishCalibration($0, scannerHost: wizard.scannerHost) }, close: close)
        }
    }

    private func openProcessWizard() {
        let wizard = model.processWizard(), app = model
        WizardWindows.show("calibrate-process", title: "Calibrate a Process", size: CGSize(width: 980, height: 860),
                           minSize: CGSize(width: 760, height: 600)) { close in
            ProcessWizardView(model: wizard, use: { app.finishProcess($0, scannerHost: wizard.scannerHost) }, close: close)
        }
    }

    private func openBlockingTest() {
        let test = model.blockingTest(), app = model
        WizardWindows.show("blocking-test", title: "Blocking Test", size: CGSize(width: 900, height: 820),
                           minSize: CGSize(width: 700, height: 560)) { close in
            BlockingTestView(model: test, use: { app.useBlockingColour($0, scannerHost: test.scannerHost) }, close: close)
        }
    }

    private func openPhoto() {
        let types: [UTType] = [.tiff, .png, .jpeg]
        if let url = Self.askOpen(types: types, folder: model.settings.lastFolder) { model.openPhoto(url) }
    }

    private func savePrintFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.tiff]
        panel.nameFieldStringValue = (model.session.source?.deletingPathExtension().lastPathComponent ?? "print") + "-print.tif"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.savePrintFile(url) }
    }

    private func printPhoto() {
        if model.session.printer != nil {
            // Straight to the printer (lp), as calibrations made with the Python app were printed.
            guard confirm("Print?", model.summary.joined(separator: "\n")) else { return }
            Task { await model.printDirect() }
            return
        }
        Task {
            guard let (image, width, height, paper, title) = await model.printRequest(),
                  let operation = NativePrint.operation(for: image, widthInches: width, heightInches: height,
                                                        paper: paper, title: title) else { return }
            if let window = NSApp.keyWindow {
                operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
            } else {
                operation.run()
            }
        }
    }

    static func askOpen(types: [UTType], folder: String? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        if let folder { panel.directoryURL = URL(fileURLWithPath: folder) }
        return panel.runModal() == .OK ? panel.url : nil
    }
}
