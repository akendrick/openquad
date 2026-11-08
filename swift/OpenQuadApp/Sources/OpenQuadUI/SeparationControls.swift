// The Negative tab's separations: how many negatives the photo is split into by tone, where
// the bands meet (on a step scale), how much they blend, which negative is shown and printed,
// any negative's own process curve, and saving them all. Each negative prints in register on
// one sheet: its registration targets are cut clear so the first coat records them on the paper.

import AppKit
import OpenQuadCore
import SwiftUI
import UniformTypeIdentifiers

struct SeparationControls: View {
    @Bindable var model: AppModel

    private var count: Int { model.session.negativeCount }

    var body: some View {
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
            Picker("Show and print", selection: Binding(get: { model.session.layer }, set: { model.setLayer($0) })) {
                ForEach(0..<count, id: \.self) { Text("\($0 + 1)").tag($0) }
            }
            .pickerStyle(.segmented)
            curveRow
            HStack {
                Button("Use Step Test as Photo") { model.openStepTest() }
                    .help("Numbered steps 0-\(model.separationSteps) over a continuous gradient: print every negative "
                          + "of it to see where each coat's band falls and whether the seams show.")
                Button("Save All Negatives…", action: saveAll)
                    .disabled(model.session.photo == nil || model.busy)
            }
            Text(model.session.registration
                 ? "Each negative prints nothing in tones lighter than its band and full strength in darker ones, "
                    + "so the coats add up. Print the lightest first: its clear targets and number expose onto the "
                    + "paper, and each later negative is lined up on them."
                 : "Turn on registration marks to line the negatives up on one sheet: their targets are cut clear, "
                    + "so the first coat records them on the paper.")
                .font(.caption)
                .foregroundStyle(model.session.registration ? Color.secondary : Color.orange)
        }
    }

    /// The shown negative's own process curve, or the shared one.
    private var curveRow: some View {
        let layer = model.session.layer
        let own = model.session.layerProcessPaths[layer]
        return LabeledContent("Curve for negative \(layer + 1)") {
            HStack {
                Text(own?.lastPathComponent ?? "same as above").foregroundStyle(own == nil ? .secondary : .primary)
                Button("Choose…") {
                    if let url = ContentView.askOpen(types: [UTType(filenameExtension: "oqproc")].compactMap { $0 }) {
                        model.setLayerProcess(layer, url)
                    }
                }
                if own != nil { Button("Clear") { model.setLayerProcess(layer, nil) } }
            }
        }
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
                context.fill(Path(band.insetBy(dx: 1, dy: 0)),
                             with: .color(k == shown ? Color.accentColor : Color.secondary.opacity(0.35)))
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
