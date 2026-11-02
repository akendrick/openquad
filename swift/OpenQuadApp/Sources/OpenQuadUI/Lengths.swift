// Lengths in the app's chosen unit (Settings: inches or millimetres). The model always
// keeps inches; these views convert for showing and typing.

import OpenQuadCore
import SwiftUI

/// A stepper for a length kept in inches, shown and stepped in `units`.
struct LengthStepper: View {
    let title: String
    let inches: Double
    /// Allowed values, in inches.
    let range: ClosedRange<Double>
    let inchStep: Double
    let mmStep: Double
    let units: LengthUnit
    let set: (Double) -> Void

    var body: some View {
        let step = units == .millimetres ? mmStep : inchStep
        Stepper(value: Binding(get: { units.fromInches(inches) },
                               set: { set(units.toInches(($0 / step).rounded() * step)) }),
                in: units.fromInches(range.lowerBound)...units.fromInches(range.upperBound), step: step) {
            LabeledContent(title, value: units == .millimetres ? units.length(inches) : String(format: "%.2f in", inches))
        }
    }
}

/// The app's settings window (OpenQuad > Settings…).
public struct SettingsView: View {
    @Bindable var model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        Form {
            Picker("Lengths in", selection: Binding(get: { model.units }, set: { model.setUnits($0) })) {
                Text("Inches").tag(LengthUnit.inches)
                Text("Millimetres").tag(LengthUnit.millimetres)
            }
            .pickerStyle(.segmented)
            Text("Safe edge, black outline, set sizes and print sizes are shown and typed in this unit.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
    }
}
