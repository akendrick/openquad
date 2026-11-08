// The Print and Negative tabs: open a photo, choose toning (Print) or the negative's
// settings (Negative), set the page, preview, and print.

import AppKit
import OpenQuadCore
import SwiftUI
import UniformTypeIdentifiers

public struct ContentView: View {
    @Bindable var model: AppModel
    @State private var ppiText = ""
    @State private var savingSetup = false
    @State private var setupName = ""
    @State private var deletingSetup: NegativeSetup?
    /// The Separations section is closed until wanted (or a separation is already set).
    @State private var showSeparations = false
    /// Switch to another tab (e.g. to calibrate).
    let goTo: (AppTab) -> Void

    public init(model: AppModel, goTo: @escaping (AppTab) -> Void = { _ in }) {
        self.model = model
        self.goTo = goTo
    }

    public var body: some View {
        HSplitView {
            controls
                .frame(minWidth: 320, idealWidth: 340, maxWidth: 420)
            previewPane
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 820, minHeight: 600)
        .alert("Save Negative Setup", isPresented: $savingSetup) {
            TextField("Name", text: $setupName)
            Button("Save") { model.saveSetup(named: setupName) }
                .disabled(setupName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remembers the process curve, ink colour, mirror, safe edge, black outline, darkroom marks, printer and paper. "
                 + "A setup with the same name is replaced.")
        }
        .confirmationDialog("Delete the setup “\(deletingSetup?.name ?? "")”?", isPresented: Binding(
            get: { deletingSetup != nil }, set: { if !$0 { deletingSetup = nil } })) {
            Button("Delete", role: .destructive) {
                if let setup = deletingSetup { model.deleteSetup(setup) }
            }
        } message: {
            Text("Its copy of the process curve goes too. Your own curve files are not touched.")
        }
        .onAppear {
            model.loadPrinters()
            if model.session.negativeCount > 1 { showSeparations = true }
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
                Section(model.session.negative ? "Negative" : "Toning and calibration") {
                    if model.session.negative { negativeControls } else { printControls }
                }
                if model.session.negative {
                    // Closed until wanted: most negatives are one negative.
                    Section(isExpanded: $showSeparations) {
                        SeparationControls(model: model)
                    } header: {
                        Text(model.session.negativeCount > 1 ? "Separations: \(model.session.negativeCount) negatives"
                                                              : "Separations")
                    }
                }
                Section("Darkroom marks") {
                    DarkroomMarks(guide: model.session.guide, registration: model.session.registration,
                                  negative: model.session.negative, units: model.units,
                                  setGuide: model.setGuide, setRegistration: model.setRegistration)
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
                    Toggle("Fit to page (\(model.units.length(model.session.margin)) margins)", isOn: Binding(get: { model.session.fit }, set: { model.setFit($0) }))
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
            let units = model.units
            LabeledContent(model.session.negative ? "Outer size" : "Size") {
                HStack(spacing: 6) {
                    TextField("Width", value: Binding(get: { units.fromInches(size.0) },
                                                      set: { model.setMaxSize((units.toInches($0), size.1)) }),
                              format: .number.precision(.fractionLength(0...2)))
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                    Text("×")
                    TextField("Height", value: Binding(get: { units.fromInches(size.1) },
                                                       set: { model.setMaxSize((size.0, units.toInches($0))) }),
                              format: .number.precision(.fractionLength(0...2)))
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                    Text(units.rawValue)
                    Menu("Sizes") {
                        ForEach(Self.setSizes(units), id: \.0) { w, h in
                            Button(units == .millimetres ? String(format: "%g × %g mm", w, h) : String(format: "%g × %g in", w, h)) {
                                model.setMaxSize((units.toInches(w), units.toInches(h)))
                            }
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
            Button("Calibrate This Printer…") { goTo(.printerCalibration) }
        }
    }

    /// Usual tissue and paper sizes to offer, in the app's unit.
    static func setSizes(_ units: LengthUnit) -> [(Double, Double)] {
        units == .millimetres ? [(100, 125), (130, 180), (180, 240), (210, 297), (240, 300)]
            : [(4, 5), (5, 7), (6, 8), (8, 10), (11, 14)]
    }

    @ViewBuilder private var negativeControls: some View {
        if let offer = model.setupOffer {
            HStack {
                Text(offer).font(.callout)
                Spacer()
                Button("Save Setup…") {
                    setupName = model.suggestedSetupName
                    savingSetup = true
                    model.setupOffer = nil
                }
                Button("Not Now") { model.setupOffer = nil }
            }
            .padding(8)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        }
        Picker("Setup", selection: Binding(get: { model.currentSetup?.name ?? "" }, set: { name in
            if let setup = model.setups.first(where: { $0.name == name }) { model.applySetup(setup) }
        })) {
            Text(model.setups.isEmpty ? "None saved" : "Custom").tag("")
            ForEach(model.setups) { Text($0.name).tag($0.name) }
        }
        HStack {
            Button("Save Setup…") {
                setupName = model.currentSetup?.name ?? model.suggestedSetupName
                savingSetup = true
            }
            if let current = model.currentSetup {
                Button("Delete Setup…") { deletingSetup = current }
            }
        }
        Picker("Ink colour", selection: Binding(get: { model.session.negativeColour }, set: { model.setNegativeColour($0) })) {
            ForEach(Negative.colourOrder, id: \.self) { Text($0.capitalized).tag($0) }
        }
        .disabled(model.session.process != nil)  // the process curve decides the colour
        fileRow("Process curve", model.session.processPath, types: ["oqproc"],
                choose: { model.setProcess($0) }, clear: { model.setProcess(nil) })
        Button("Calibrate a Process…") { goTo(.processCalibration) }
        Toggle("Mirror (flip left to right)", isOn: Binding(get: { model.session.mirror }, set: { model.setMirror($0) }))
        LengthStepper(title: "Safe edge", inches: model.session.safeEdge, range: 0...2, inchStep: 0.05, mmStep: 1,
                      units: model.units) { model.setSafeEdge($0) }
        Toggle("Outline in black", isOn: Binding(get: { model.session.outline > 0 }, set: { model.setOutline($0) }))
        if model.session.outline > 0 {
            LengthStepper(title: "Outline width", inches: model.outlineSize, range: 0.01...1, inchStep: 0.01, mmStep: 0.5,
                          units: model.units) { model.setOutlineSize($0) }
            Text("A black border inside the safe edge, so photos with white or light edges still print with a frame.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
