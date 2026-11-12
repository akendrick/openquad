// Controls shared by the Print and Negative tabs and the calibration wizards: darkroom
// marks (a black guide line and registration marks, which show under a red safelight)
// and a test sheet's preferred size.

import OpenQuadCore
import SwiftUI

/// The two darkroom-mark checkboxes, with what they do.
struct DarkroomMarks: View {
    let guide: Bool
    let registration: Bool
    /// On a negative they go in the safe edge; on a print, in a white border round it.
    let negative: Bool
    let units: LengthUnit
    let setGuide: (Bool) -> Void
    let setRegistration: (Bool) -> Void

    var body: some View {
        Toggle("Guide line in black", isOn: Binding(get: { guide }, set: setGuide))
        Toggle("Registration marks", isOn: Binding(get: { registration }, set: setRegistration))
        if guide || registration {
            Text(negative
                 ? "In black ink in the safe edge, so you can see where the image is under a red safelight (red and orange "
                    + "negatives all but vanish there). Black blocks UV like the safe edge, so the marks don't print."
                 : "In black in a \(units.length(Marks.printBorder)) white border round the print, for lining it up in the "
                    + "darkroom. The border counts towards the print's size.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// A test sheet's preferred size: its own, or enlarged or shrunk to fit within W x H.
struct SheetSize: View {
    let size: (Double, Double)?
    let units: LengthUnit
    let set: ((Double, Double)?) -> Void

    /// What a set size starts at.
    static let usual = (8.0, 10.0)

    var body: some View {
        // Only real sizes: a width or height of 0 (or less) is ignored.
        let set = { (size: (Double, Double)?) in if size.map({ $0.0 > 0 && $0.1 > 0 }) ?? true { self.set(size) } }
        Picker("Size", selection: Binding(get: { size != nil }, set: { set($0 ? Self.usual : nil) })) {
            Text("Standard").tag(false)
            Text("Fit within a set size").tag(true)
        }
        if let size {
            LabeledContent("Fit within") {
                HStack(spacing: 6) {
                    TextField("Width", value: Binding(get: { units.fromInches(size.0) }, set: { set((units.toInches($0), size.1)) }),
                              format: .number.precision(.fractionLength(0...2)))
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                    Text("×")
                    TextField("Height", value: Binding(get: { units.fromInches(size.1) }, set: { set((size.0, units.toInches($0))) }),
                              format: .number.precision(.fractionLength(0...2)))
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                    Text(units.rawValue)
                    Menu("Sizes") {
                        ForEach(ContentView.setSizes(units), id: \.0) { w, h in
                            Button(String(format: "%g × %g %@", w, h, units.rawValue)) { set((units.toInches(w), units.toInches(h))) }
                        }
                    }
                    .fixedSize()
                }
                .labelsHidden()
            }
            Text("The sheet grows or shrinks to fit (turned to match), safe edge included, and never goes past the page's "
                 + "margins. The patches keep their shape, so the scan reads the same.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// A small picture of a sheet as it will print, with its size.
struct SheetPreview: View {
    let image: RGBImage?
    /// Pixels per inch of `image`.
    let ppi: Double
    let units: LengthUnit
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if let image, let picture = image.cgImage(eightBit: true) {
                Image(decorative: picture, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 360, alignment: .topLeading)
                    .overlay(Rectangle().stroke(.separator))
                Text("\(units.size(Double(image.width) / ppi, Double(image.height) / ppi)) on film")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Choose 1 to 5 colours to see the page.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
