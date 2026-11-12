// The Negative tab's separations. By tone: how many negatives the photo is split into, where
// the bands meet (on a step scale) and how much they blend. By colour: each coat's pigment
// colour, in print order, and how much the photo's colour is strengthened first. Then which
// negative is shown and printed, any negative's own process curve, and saving them all. Each
// negative prints in register on one sheet: its registration targets are cut clear so the
// first coat records them on the paper.

import AppKit
import OpenQuadCore
import SwiftUI
import UniformTypeIdentifiers

struct SeparationControls: View {
    @Bindable var model: AppModel

    private var count: Int { model.session.negativeCount }

    var body: some View {
        Picker("Split by", selection: Binding(get: { model.separationKind }, set: { model.setSeparationKind($0) })) {
            ForEach(AppModel.SeparationKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        if model.separationKind == .colours { colourRows } else { toneRows }
    }

    @ViewBuilder private var toneRows: some View {
        Stepper("Negatives: \(count)", value: Binding(get: { count }, set: { model.setNegativeCount($0) }),
                in: 1...SeparationPlan.maxNegatives)
        if count == 1 {
            Text("For processes that build their tones up in several coats (gum, multi-coat cyanotype): "
                 + "split the photo into negatives for its lightest tones, its middle tones and its shadows.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            BandDiagram(splits: model.separationSplits, steps: model.separationSteps,
                        overlap: model.separationOverlap, shown: model.session.layer)
                .frame(height: 46)
            Stepper("Step scale: \(model.separationSteps) steps", value: Binding(
                get: { model.separationSteps }, set: { model.setSeparationSteps($0) }), in: max(2, count)...101)
            ForEach(Array(model.separationSplits.enumerated()), id: \.offset) { index, step in
                Stepper("Negatives \(index + 1) | \(index + 2) meet at step \(step)", value: Binding(
                    get: { step }, set: { model.setSplit(index, step: $0) }), in: 1...(model.separationSteps - 1))
            }
            Stepper("Overlap: \(String(format: "%g", model.separationOverlap)) step\(model.separationOverlap == 1 ? "" : "s")", value: Binding(
                get: { model.separationOverlap }, set: { model.setSeparationOverlap($0) }),
                in: 0...Double(model.narrowestBand), step: 0.5)
            layerPicker
            Toggle("Preview all coats together", isOn: Binding(get: { model.showCoats }, set: { model.setShowCoats($0) }))
                .help("The photo with each coat in its own colour, as strong as it prints: check where the bands fall "
                      + "and that the seams blend")
            curveRow
            coatsRows
            HStack {
                Button("Use Step Test as Photo") { model.openStepTest() }
                    .help("Numbered steps 0-\(model.separationSteps) over a continuous gradient: print every negative "
                          + "of it to see where each coat's band falls and whether the seams show.")
                saveAllButton
            }
            registrationNote("Each negative prints nothing in tones lighter than its band and full strength in darker ones, "
                             + "so the coats add up. Print the lightest first: its clear targets and number expose onto the "
                             + "paper, and each later negative is lined up on them.")
        }
    }

    @ViewBuilder private var colourRows: some View {
        if let photo = model.session.photo, photo.colour == nil {
            Label("This photo has no colour, so every coat prints its greys: open a colour photo.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        ForEach(Array(model.colourCoats.enumerated()), id: \.offset) { index, coat in
            CoatRow(model: model, index: index, coat: coat)
        }
        HStack {
            Button("Add Coat", action: model.addCoat)
                .disabled(model.colourCoats.count >= ColourSeparation.maxCoats)
            if model.separatingColours { ProgressView().controlSize(.small) }
        }
        LabeledContent("Saturation") {
            HStack {
                Slider(value: Binding(get: { model.colourSaturation }, set: { model.setColourSaturation($0) }),
                       in: 0...ColourSeparation.maxSaturation)
                Text(String(format: "%.2f", model.colourSaturation)).monospacedDigit().frame(width: 36, alignment: .trailing)
            }
        }
        Text("Above 1 strengthens the photo's colours before they are split, so each coat carries more of its own "
             + "colour: for processes that print duller than the photo, like cyanotype and gum. 0 splits the tones alone.")
            .font(.caption)
            .foregroundStyle(.secondary)
        layerPicker
        Toggle("Preview the print (all coats in their colours)", isOn: Binding(get: { model.showCoats }, set: { model.setShowCoats($0) }))
            .help("The coats stacked as they print, each in its pigment's colour: check the colours before printing film")
        curveRow
        saveAllButton
        registrationNote("Each negative prints its coat's share of every colour. Print them in this order, each coat "
                         + "in its own pigment: the first coat's clear targets expose onto the paper, and each later "
                         + "negative is lined up on them.")
    }

    private var layerPicker: some View {
        Picker("Show and print", selection: Binding(get: { model.session.layer }, set: { model.setLayer($0) })) {
            ForEach(0..<count, id: \.self) { Text("\($0 + 1)").tag($0) }
        }
        .pickerStyle(.segmented)
    }

    private var saveAllButton: some View {
        Button("Save All Negatives…", action: saveAll)
            .disabled(model.session.photo == nil || model.busy || !model.session.separated)
    }

    private func registrationNote(_ registered: String) -> some View {
        Text(model.session.registration
             ? registered
             : "Turn on registration marks to line the negatives up on one sheet: their targets are cut clear, "
                + "so the first coat records them on the paper.")
            .font(.caption)
            .foregroundStyle(model.session.registration ? Color.secondary : Color.orange)
    }

    /// The shown negative's own process curve, or the shared one.
    private var curveRow: some View {
        let layer = model.session.layer
        let own = model.session.layerProcessPaths[layer]
        return LabeledContent("Curve for negative \(layer + 1)") {
            HStack {
                Text(own?.lastPathComponent ?? "same as above").foregroundStyle(own == nil ? .secondary : .primary)
                CurveMenu(model: model) { model.setLayerProcess(layer, $0) }
                if own != nil { Button("Clear") { model.setLayerProcess(layer, nil) } }
            }
        }
    }

    /// Calibrating the stacked coats as one process: print the chart through every negative,
    /// scan it, read it.
    @ViewBuilder private var coatsRows: some View {
        let path = model.session.coatsCurvePath
        LabeledContent("Coats curve") {
            HStack {
                Text(path?.lastPathComponent ?? "none").foregroundStyle(path == nil ? .secondary : .primary)
                CurveMenu(model: model) { model.setCoatsCurve($0) }
                if path != nil { Button("Clear") { model.setCoatsCurve(nil) } }
            }
        }
        HStack {
            Button("Use Chart as Photo") { model.openCoatsChart() }
            Button("Read Chart Scan…") {
                if let url = ContentView.askOpen(types: [.jpeg, .png, .tiff]) { Task { await model.readCoatsScan(url) } }
            }
            .disabled(model.busy)
        }
        Text("Calibrate the coats together: print the chart through every negative onto one sheet, coat by coat, "
             + "scan the finished print and read it. The coats curve evens out how the coats add up; "
             + "read a second print to check (each reading builds on the curve in use).")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func saveAll() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose a folder for the \(count) negatives."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task { await model.saveSeparations(to: folder) }
    }
}

/// Choose a process curve: one OpenQuad already has (a setup's, a process calibration's
/// latest, a coats curve) or another file.
struct CurveMenu: View {
    let model: AppModel
    let choose: (URL) -> Void

    var body: some View {
        let curves = model.knownCurves
        Menu("Choose") {
            ForEach(["Setups", "Process calibrations", "Coats curves"], id: \.self) { group in
                let inGroup = curves.filter { $0.group == group }
                if !inGroup.isEmpty {
                    Section(group) {
                        ForEach(inGroup, id: \.self) { curve in Button(curve.label) { choose(curve.url) } }
                    }
                }
            }
            if !curves.isEmpty { Divider() }
            Button("Other File…") {
                if let url = ContentView.askOpen(types: [UTType(filenameExtension: "oqproc")].compactMap { $0 }) { choose(url) }
            }
        }
        .fixedSize()
    }
}

/// The tone scale from paper white to full black, the bands each negative prints, the
/// blends between them, and the shown negative picked out.
struct BandDiagram: View {
    let splits: [Int]
    let steps: Int
    let overlap: Double
    let shown: Int

    var body: some View {
        Canvas { context, size in
            let barHeight = size.height - 16
            let bar = CGRect(x: 0, y: 0, width: size.width, height: barHeight)
            context.fill(Path(bar), with: .linearGradient(Gradient(colors: [.white, .black]),
                                                          startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
            context.stroke(Path(bar), with: .color(.secondary), lineWidth: 0.5)
            let x = { (step: Double) in size.width * step / Double(steps) }
            let edges = [0] + splits + [steps]
            for k in 0..<(edges.count - 1) {
                let band = CGRect(x: x(Double(edges[k])), y: barHeight + 2, width: x(Double(edges[k + 1] - edges[k])), height: 12)
                let ink = CoatsPreview.inks[k % CoatsPreview.inks.count]
                context.fill(Path(band.insetBy(dx: 1, dy: 0)),
                             with: .color(Color(.sRGB, red: ink.0, green: ink.1, blue: ink.2).opacity(k == shown ? 1 : 0.4)))
                if k == shown { context.stroke(Path(band.insetBy(dx: 1, dy: 0)), with: .color(.primary), lineWidth: 1.5) }
                context.draw(Text("\(k + 1)").font(.caption2.bold()).foregroundStyle(k == shown ? .white : .primary),
                             at: CGPoint(x: band.midX, y: band.midY))
            }
            for split in splits {
                let middle = x(Double(split))
                if overlap > 0 {
                    let blend = CGRect(x: middle - x(overlap) / 2, y: 0, width: x(overlap), height: barHeight)
                    context.fill(Path(blend), with: .color(Color.accentColor.opacity(0.3)))
                }
                var line = Path()
                line.move(to: CGPoint(x: middle, y: 0))
                line.addLine(to: CGPoint(x: middle, y: barHeight))
                context.stroke(line, with: .color(.accentColor), lineWidth: 2)
            }
        }
        .accessibilityLabel("Tone bands: \(splits.count + 1) negatives split at steps "
                            + splits.map(String.init).joined(separator: ", ") + " of \(steps)")
    }
}

/// One coat of a colour separation: its number, its pigment colour (a colour well and the
/// pigment presets), and removing it.
struct CoatRow: View {
    let model: AppModel
    let index: Int
    let coat: ColourSeparation.RGB8

    var body: some View {
        HStack {
            Text("\(index + 1)").font(.caption.bold()).frame(width: 14)
            ColorPicker("Coat \(index + 1)", selection: Binding(get: { Self.color(coat) }, set: { colour in
                if let rgb = Self.rgb(colour) { model.setCoat(index, rgb) }
            }), supportsOpacity: false)
            .labelsHidden()
            Menu(model.pigmentName(coat) ?? coat.hex) {
                ForEach(ColourSeparation.pigments, id: \.name) { pigment in
                    Button(pigment.name) { model.setCoat(index, pigment.colour) }
                }
            }
            .fixedSize()
            Spacer()
            Button { model.removeCoat(index) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .disabled(model.colourCoats.count <= ColourSeparation.minCoats)
                .help("Remove coat \(index + 1)")
        }
    }

    static func color(_ coat: ColourSeparation.RGB8) -> Color {
        Color(.sRGB, red: Double(coat.r) / 255, green: Double(coat.g) / 255, blue: Double(coat.b) / 255)
    }

    static func rgb(_ colour: Color) -> ColourSeparation.RGB8? {
        guard let srgb = NSColor(colour).usingColorSpace(.sRGB) else { return nil }
        let value = { (v: CGFloat) in min(max(Int((v * 255).rounded()), 0), 255) }
        return .init(value(srgb.redComponent), value(srgb.greenComponent), value(srgb.blueComponent))
    }
}
