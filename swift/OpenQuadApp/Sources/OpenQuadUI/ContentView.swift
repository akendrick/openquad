// The print window: open a photo, choose toning or a digital negative, set the page,
// preview, and print through the macOS print panel.

import AppKit
import OpenQuadCore
import SwiftUI
import UniformTypeIdentifiers

public struct ContentView: View {
    @Bindable var model: AppModel
    @State private var ppiText = ""
    @State private var calibrationWizard: CalibrationWizardModel?
    @State private var processWizard: ProcessWizardModel?

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        HSplitView {
            controls
                .frame(minWidth: 320, idealWidth: 340, maxWidth: 420)
            previewPane
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 820, minHeight: 600)
        .sheet(item: $calibrationWizard) { wizard in
            CalibrationWizardView(model: wizard) { model.finishCalibration($0, scannerHost: wizard.scannerHost) }
        }
        .sheet(item: $processWizard) { wizard in
            ProcessWizardView(model: wizard) { model.finishProcess($0, scannerHost: wizard.scannerHost) }
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
                    Picker("Paper", selection: Binding(get: { model.session.paper }, set: { model.setPaper($0) })) {
                        ForEach(paperOrder, id: \.self) { Text($0).tag($0) }
                    }
                    Toggle("Fit to page (0.5 in margins)", isOn: Binding(get: { model.session.fit }, set: { model.setFit($0) }))
                    TextField("Resolution (ppi)", text: $ppiText, prompt: Text("photo's own"))
                        .disabled(model.session.fit)
                        .onSubmit { model.setPPI(Double(ppiText)) }
                    if !model.sizeDescription.isEmpty {
                        LabeledContent("Print size") { Text(model.sizeDescription).multilineTextAlignment(.trailing) }
                    }
                }
            }
            .formStyle(.grouped)
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

    @ViewBuilder private var printControls: some View {
        Picker("Toning", selection: Binding(get: { model.session.preset }, set: { model.setPreset($0) })) {
            ForEach(presetLabels, id: \.0) { Text($0.1).tag($0.0) }
        }
        fileRow("Calibration", model.session.calibrationPath, types: ["oqcal"],
                choose: { model.setCalibration($0) }, clear: { model.setCalibration(nil) })
        Button("Calibrate This Printer…") { calibrationWizard = model.calibrationWizard() }
    }

    @ViewBuilder private var negativeControls: some View {
        Picker("Ink colour", selection: Binding(get: { model.session.negativeColour }, set: { model.setNegativeColour($0) })) {
            ForEach(Negative.colourOrder, id: \.self) { Text($0.capitalized).tag($0) }
        }
        .disabled(model.session.process != nil)  // the process curve decides the colour
        fileRow("Process curve", model.session.processPath, types: ["oqproc"],
                choose: { model.setProcess($0) }, clear: { model.setProcess(nil) })
        Button("Calibrate a Process…") { processWizard = model.processWizard() }
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
