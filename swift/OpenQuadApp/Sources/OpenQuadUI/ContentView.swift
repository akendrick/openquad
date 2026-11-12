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
    /// The negative's Options section, and Separations inside it, are closed until wanted (or a
    /// separation is already set).
    @State private var showOptions = false
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
            Text("Remembers the process curve, ink colour, mirror, safe edge, black outline, darkroom marks, printer and paper, "
                 + "and any separation with its curves. A setup with the same name is replaced.")
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
            model.loadProofProfiles()
            if model.session.negativeCount > 1 || model.separationKind == .colours { showOptions = true; showSeparations = true }
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
                    // Closed until wanted: most negatives use the defaults.
                    Section(isExpanded: $showOptions) {
                        negativeOptions
                    } header: {
                        Text(optionsHeader)
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
        if model.canPrintColour {
            Toggle("Print in colour (colour-managed printer)",
                   isOn: Binding(get: { model.session.colourPrint }, set: { model.setColourPrint($0) }))
        }
        if model.session.printsColour { colourControls } else { greyControls }
    }

    /// A colour print: no toning or calibration; macOS matches the colours to the printer.
    @ViewBuilder private var colourControls: some View {
        Text("The photo keeps its colours and its own colour profile (sRGB if it has none). Choose the printer's "
             + "paper type or profile in the print panel: macOS colour-manages the print.")
            .font(.caption)
            .foregroundStyle(.secondary)
        Picker("Soft-proof with", selection: Binding(get: { model.proofProfile }, set: { model.setProofProfile($0) })) {
            Text("None (the photo's colours)").tag(URL?.none)
            ForEach(model.proofProfiles) { Text($0.name).tag(URL?.some($0.url)) }
            if let url = model.proofProfile, !model.proofProfiles.contains(where: { $0.url == url }) {
                Text(url.deletingPathExtension().lastPathComponent).tag(URL?.some(url))
            }
        }
        Button("Choose Profile…") {
            let types = ["icc", "icm"].compactMap { UTType(filenameExtension: $0) }
            if let url = Self.askOpen(types: types, folder: "/Library/ColorSync/Profiles") { model.setProofProfile(url) }
        }
    }

    @ViewBuilder private var greyControls: some View {
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
        LabeledContent("Process curve") {
            HStack {
                Text(model.session.processPath?.lastPathComponent ?? "none")
                    .foregroundStyle(model.session.processPath == nil ? .secondary : .primary)
                CurveMenu(model: model) { model.setProcess($0) }
                if model.session.processPath != nil { Button("Clear") { model.setProcess(nil) } }
            }
        }
        Button("Calibrate a Process…") { goTo(.processCalibration) }
    }

    /// Mirror, the safe edge, the outline and separations: set once per process, then left alone.
    @ViewBuilder private var negativeOptions: some View {
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
        DisclosureGroup(isExpanded: $showSeparations) {
            SeparationControls(model: model)
        } label: {
            Text(model.session.colourSeparation != nil ? "Separations: \(model.session.negativeCount) coats by colour"
                 : model.session.negativeCount > 1 ? "Separations: \(model.session.negativeCount) negatives" : "Separations")
        }
    }

    /// "Options", with what's set when it's closed: e.g. "Options: mirrored, 3 negatives".
    private var optionsHeader: String {
        var set = [String]()
        if model.session.mirror { set.append("mirrored") }
        if model.session.outline > 0 { set.append("outlined") }
        if model.session.negativeCount > 1 { set.append("\(model.session.negativeCount) negatives") }
        return set.isEmpty ? "Options" : "Options: " + set.joined(separator: ", ")
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
                if let caption = model.previewCaption {
                    VStack {
                        Spacer()
                        Text(caption)
                            .font(.callout)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.regularMaterial, in: Capsule())
                            .padding(8)
                    }
                }
            } else {
                ContentUnavailableView("Open a photo to begin", systemImage: "photo",
                                       description: Text("Greyscale or colour, any size; printed in the tones you choose, or in colour."))
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
                                                        paper: paper, title: title,
                                                        iccProfile: model.session.printProfile()) else { return }
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
