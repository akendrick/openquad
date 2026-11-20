// The Print and Negative tabs: open a photo, choose toning (Print) or the negative's
// settings (Negative), set the page, preview, and print.

import AppKit
import OpenQuadCore
import SwiftUI
import UniformTypeIdentifiers

public struct ContentView: View {
    @Bindable var model: AppModel
    @State private var savingSetup = false
    @State private var setupName = ""
    @State private var deletingSetup: NegativeSetup?
    /// Which sidebar sections are open, remembered between launches. Options and Separations
    /// start closed (most negatives use the defaults); a separation already set opens its own.
    @AppStorage("sidebar.negative") private var openNegative = true
    @AppStorage("sidebar.toning") private var openToning = true
    @AppStorage("sidebar.separations") private var showSeparations = false
    @AppStorage("sidebar.marks") private var openMarks = false
    @AppStorage("sidebar.page") private var openPage = true
    @AppStorage("sidebar.wedges") private var openWedges = false
    @AppStorage("sidebar.position") private var openPosition = false
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
            if model.session.negativeCount > 1 || model.separationKind == .colours { showSeparations = true }
        }
    }

    // MARK: the controls

    private var controls: some View {
        VStack(spacing: 0) {
            Form {
                photoSection
                if model.session.negative {
                    FoldingSection(title: "Negative", summary: negativeSummary, open: $openNegative) { negativeControls }
                    FoldingSection(title: "Separations", summary: separationsSummary, open: $showSeparations) {
                        SeparationControls(model: model)
                    }
                } else {
                    FoldingSection(title: "Toning and calibration", summary: toningSummary, open: $openToning) { printControls }
                }
                FoldingSection(title: "Registration", summary: registrationSummary, open: $openMarks) {
                    registrationOptions
                    DarkroomMarks(guide: model.session.guide, registration: model.session.registration,
                                  negative: model.session.negative, units: model.units,
                                  setGuide: model.setGuide, setRegistration: model.setRegistration)
                }
                FoldingSection(title: "Step wedges", summary: model.wedgeDescription, open: $openWedges) { wedgeControls }
                FoldingSection(title: "Printer and size", summary: [pageSummary, sizeSummary].joined(separator: ", "),
                               open: $openPage) {
                    printerAndPaper
                    sizeControls
                    if model.session.negative {
                        DisclosureGroup(isExpanded: $openPosition) {
                            placementControls
                        } label: {
                            Text("Position on the page")
                        }
                    }
                }
            }
            .controlSize(.small)
            .formStyle(.grouped)
            if let name = model.openingInGIMP {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Opening \(name) in GIMP…").font(.callout).foregroundStyle(.secondary)
                }
                .padding(.horizontal)
            }
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

    /// The photo: its name and size on one line, with Open beside it.
    private var photoSection: some View {
        Section {
            LabeledContent {
                Button("Open…", action: openPhoto)
                    .keyboardShortcut("o")
            } label: {
                if let photo = model.session.photo, let source = model.session.source {
                    Text(source.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Text("\(photo.width) × \(photo.height) px" + (photo.dpi.map { String(format: ", %.0f ppi", $0.0) } ?? ""))
                } else {
                    Text("No photo open")
                    Text("TIFF, PNG, JPEG, JPEG 2000 or GIMP XCF")
                }
            }
            if let resolution = model.resolution { resolutionRows(resolution) }
            ForEach(model.session.notes, id: \.self) { note in
                Text(note).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    /// The resolution the print is made at, typed here when Fit to page is off, and the
    /// photo's own beside it.
    @ViewBuilder private func resolutionRows(_ resolution: Double) -> some View {
        LabeledContent("Resolution") {
            HStack(spacing: 4) {
                if !model.session.fit && model.session.ppi != nil {
                    Button("Photo's Own") { model.setPPI(nil) }
                }
                TextField("Resolution", value: Binding(get: { (resolution * 10).rounded() / 10 }, set: { model.setPPI($0) }),
                          format: .number.precision(.fractionLength(0...1)))
                    .labelsHidden()
                    .frame(width: 64)
                    .multilineTextAlignment(.trailing)
                    .disabled(model.session.fit)
                Text("ppi")
            }
        }
        if let own = model.photoResolutionDescription {
            LabeledContent("Photo's own") { Text(own).multilineTextAlignment(.trailing) }
        }
        if model.session.fit {
            Text("Fit to page (under Printer and size) sets the resolution; turn it off to type one.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Step wedges beside the print: the 31-step grey wedge (toned and calibrated like the photo,
    /// or through the process curve), and for a colour print the colour gamut wedge.
    @ViewBuilder private var wedgeControls: some View {
        let negative = model.session.negative
        Toggle(negative ? "31-step wedge" : "Black and white wedge (31 steps)",
               isOn: Binding(get: { model.session.wedge }, set: { model.setWedge($0) }))
        if !negative && model.session.printsColour {
            Toggle("Colour gamut wedge", isOn: Binding(get: { model.session.colourWedge }, set: { model.setColourWedge($0) }))
        }
        if !model.session.wedgeKinds.isEmpty {
            Picker("Side", selection: Binding(get: { model.session.wedgeSide }, set: { model.setWedgeSide($0) })) {
                ForEach(Wedge.sides, id: \.self) { Text($0.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Create wedge separately", isOn: Binding(get: { model.session.wedgeSeparate }, set: { model.setWedgeSeparate($0) }))
            if model.session.wedgeSeparate {
                LengthStepper(title: "Gap", inches: model.session.wedgeGap, range: 0...Wedge.maxGap, inchStep: 0.05, mmStep: 1,
                              units: model.units) { model.setWedgeGap($0) }
            }
        }
        Text(negative
             ? "Paper white to full black in 31 steps, made into a negative with the same process curve. It sits at the "
                + "edge of the safe edge, with no clear film between, unless made separately with a gap."
             : "Paper white to full black in 31 steps, toned and calibrated like the photo, to check every tone"
                + (model.session.printsColour ? "; the colour wedge is 31 hues as a tint, the full colour and a shade." : "."))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder private var printerAndPaper: some View {
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
        if model.session.printer == nil {
            Text("Media type and quality are set in the print panel (Media & Quality). Choose the same every time.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if model.printerMedia == nil && model.printerQuality == nil {
            Text("This printer has no media type or quality settings OpenQuad can set: it prints with its own.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            if let media = model.printerMedia { printerOptionPicker("Media type", media) }
            if let quality = model.printerQuality { printerOptionPicker("Quality", quality) }
        }
    }

    /// One of the printer's own settings, remembered for the printer; "Printer default" leaves it to the driver.
    private func printerOptionPicker(_ title: String, _ option: PrinterOption) -> some View {
        Picker(title, selection: Binding(get: { model.session.printerOptions[option.keyword] },
                                         set: { model.setPrinterOption(option.keyword, $0) })) {
            Text("Printer default" + (option.defaultValue.map { " (\(option.name(of: $0)))" } ?? "")).tag(String?.none)
            Divider()
            ForEach(option.choices, id: \.self) { Text($0.name).tag(String?.some($0.value)) }
        }
    }

    /// Fit or a set resolution, and the size that makes. The photo's own resolution is shown
    /// as soon as it's open, so you know what "the photo's own" means.
    @ViewBuilder private var sizeControls: some View {
        Toggle("Fit to page (\(model.units.length(model.session.margin)) margins)",
               isOn: Binding(get: { model.session.fit }, set: { model.setFit($0) }))
        if model.session.fit { fitWithin }
        if !model.sizeDescription.isEmpty {
            LabeledContent("Print size") { Text(model.sizeDescription).multilineTextAlignment(.trailing) }
        }
    }

    /// Where the negative goes on the page: centred, or moved (by dragging it on the page
    /// preview, or step by step here). Every negative of a separation prints in the same place.
    @ViewBuilder private var placementControls: some View {
        Toggle("Preview on the page", isOn: Binding(get: { model.showOnPage }, set: { model.setShowOnPage($0) }))
        LabeledContent("Position") {
            HStack {
                Text(model.positionDescription).multilineTextAlignment(.trailing)
                if model.session.placement != nil { Button("Centre") { model.setPlacement(nil) } }
            }
        }
        if let layout = model.pageLayout, model.session.photo != nil {
            let (paperWidth, paperHeight) = layout.paper, negative = layout.negative
            let maxLeft = paperWidth - layout.margin - negative.width, maxTop = paperHeight - layout.margin - negative.height
            if maxLeft >= layout.margin - 1e-6 && maxTop >= layout.margin - 1e-6 {
                LengthStepper(title: "From the left", inches: negative.minX, range: layout.margin...max(layout.margin, maxLeft),
                              inchStep: 0.125, mmStep: 1, units: model.units) { model.setPlacement((Double($0), Double(negative.minY))) }
                LengthStepper(title: "From the top", inches: negative.minY, range: layout.margin...max(layout.margin, maxTop),
                              inchStep: 0.125, mmStep: 1, units: model.units) { model.setPlacement((Double(negative.minX), Double($0))) }
            } else {
                Text("The negative fills the page inside its margins, so it prints centred.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
        LabeledContent("Setup") {
            HStack(spacing: 4) {
                Picker("Setup", selection: Binding(get: { model.currentSetup?.name ?? "" }, set: { name in
                    if let setup = model.setups.first(where: { $0.name == name }) { model.applySetup(setup) }
                })) {
                    Text(model.setups.isEmpty ? "None saved" : "Custom").tag("")
                    ForEach(model.setups) { Text($0.name).tag($0.name) }
                }
                .labelsHidden()
                .fixedSize()
                Menu {
                    Button("Save Setup…") {
                        setupName = model.currentSetup?.name ?? model.suggestedSetupName
                        savingSetup = true
                    }
                    if let current = model.currentSetup {
                        Button("Delete “\(current.name)”…") { deletingSetup = current }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Save or delete setups")
            }
        }
        Picker("Ink colour", selection: Binding(get: { model.session.negativeColour }, set: { model.setNegativeColour($0) })) {
            ForEach(Negative.colourOrder, id: \.self) { Text($0.capitalized).tag($0) }
        }
        .disabled(model.session.process != nil)  // the process curve decides the colour
        LabeledContent("Process curve") {
            HStack(spacing: 6) {
                Text(model.session.processPath?.deletingPathExtension().lastPathComponent ?? "none")
                    .foregroundStyle(model.session.processPath == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                CurveMenu(model: model, clear: model.session.processPath == nil ? nil : { model.setProcess(nil) },
                          calibrate: { goTo(.processCalibration) }) { model.setProcess($0) }
            }
        }
    }

    /// Mirror (both tabs), then a negative's safe edge and outline: set once per process, then left alone.
    @ViewBuilder private var registrationOptions: some View {
        Toggle("Mirror (flip left to right)", isOn: Binding(get: { model.session.mirror }, set: { model.setMirror($0) }))
        if model.session.negative { negativeEdges }
    }

    @ViewBuilder private var negativeEdges: some View {
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

    // MARK: what a closed section shows in its header

    private var negativeSummary: String {
        let curve = model.session.processPath?.deletingPathExtension().lastPathComponent
        return [model.currentSetup?.name, model.session.negativeColour.capitalized, curve].compactMap { $0 }.joined(separator: ", ")
    }

    /// Mirror, safe edge and outline (on a negative), then the darkroom marks.
    private var registrationSummary: String {
        var set = [String]()
        if model.session.mirror { set.append("mirrored") }
        if model.session.negative {
            set.append("\(model.units.length(model.session.safeEdge)) edge")
            if model.session.outline > 0 { set.append("outlined") }
        }
        if model.session.guide { set.append("guide line") }
        if model.session.registration { set.append("marks") }
        return set.isEmpty ? "none" : set.joined(separator: ", ")
    }

    private var separationsSummary: String {
        let count = model.session.negativeCount
        if model.session.colourSeparation != nil { return "\(count) coats by colour" }
        return count > 1 ? "\(count) negatives" : "none"
    }

    private var toningSummary: String {
        if model.session.printsColour { return "colour" }
        let preset = presetLabels.first { $0.0 == model.session.preset }?.1 ?? model.session.preset
        return [preset, model.currentCalibration?.label ?? "uncorrected"].joined(separator: ", ")
    }

    private var pageSummary: String {
        let media = model.printerMedia.flatMap { option in model.session.printerOptions[option.keyword].map(option.name(of:)) }
        return [model.session.paper, model.session.printer?.replacingOccurrences(of: "_", with: " "), media]
            .compactMap { $0 }.joined(separator: ", ")
    }

    private var sizeSummary: String {
        model.sizeDescription.split(separator: "\n").first.map(String.init) ?? (model.session.fit ? "fit to page" : "")
    }

    // MARK: the preview

    private var previewPane: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            if let image = model.preview {
                if model.showingPage {
                    PagePreview(model: model, image: image)
                } else {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .shadow(radius: 4)
                        .padding(24)
                }
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
        if let url = Self.askOpen(types: PhotoTypes.all, folder: model.settings.lastFolder) { model.openPhoto(url) }
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
            guard confirm("Print?", (model.summary + model.printerOptionLines).joined(separator: "\n")) else { return }
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

/// A sidebar section that folds away: its title (and, while folded, what's set in it) is the
/// first row of its box, so a folded section takes one row rather than a header and a gap.
struct FoldingSection<Content: View>: View {
    let title: String
    let summary: String
    @Binding var open: Bool
    @ViewBuilder let content: Content

    var body: some View {
        Section {
            Button {
                withAnimation(.snappy(duration: 0.2)) { open.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 10)
                    Text(title).font(.headline)
                    Spacer(minLength: 8)
                    if !open && !summary.isEmpty {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(open ? "open" : "closed: \(summary)")
            if open { content }
        }
    }
}
