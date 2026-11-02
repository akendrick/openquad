// Lengths shown in inches or millimetres. Mirrors openquad/units.py: OpenQuad works in
// inches throughout (files, settings); the unit only changes what people see and type.

import Foundation

public enum LengthUnit: String, CaseIterable, Sendable {
    case inches = "in"
    case millimetres = "mm"

    public static let mmPerInch = 25.4

    /// Inches as a number in this unit.
    public func fromInches(_ inches: Double) -> Double { self == .millimetres ? inches * Self.mmPerInch : inches }

    /// A number in this unit as inches.
    public func toInches(_ value: Double) -> Double { self == .millimetres ? value / Self.mmPerInch : value }

    static func trim(_ text: String) -> String {
        guard text.contains(".") else { return text }
        var text = text
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// A short length such as an edge: "0.25 in" or "6.35 mm" (to 0.01 mm).
    public func length(_ inches: Double) -> String {
        self == .millimetres ? "\(Self.trim(String(format: "%.2f", inches * Self.mmPerInch))) mm"
            : "\(String(format: "%g", inches)) in"
    }

    /// A set size: "8 x 10 in" or "203.2 x 254 mm".
    public func box(_ width: Double, _ height: Double) -> String {
        if self == .millimetres {
            let w = Self.trim(String(format: "%.2f", width * Self.mmPerInch))
            let h = Self.trim(String(format: "%.2f", height * Self.mmPerInch))
            return "\(w) x \(h) mm"
        }
        return String(format: "%g x %g in", width, height)
    }

    /// A printed size: "7.50 x 5.00 in" or "190.5 x 127.0 mm".
    public func size(_ width: Double, _ height: Double) -> String {
        self == .millimetres ? String(format: "%.1f x %.1f mm", width * Self.mmPerInch, height * Self.mmPerInch)
            : String(format: "%.2f x %.2f in", width, height)
    }
}
