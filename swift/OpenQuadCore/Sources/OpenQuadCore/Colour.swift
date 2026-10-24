// Colour maths: sRGB transfer functions and CIE L*a*b* (D65). Mirrors openquad/colour.py.

import Foundation

public enum Colour {
    /// Linear sRGB (D65) to CIE XYZ, row by row.
    static let rgbToXYZ: [[Double]] = [
        [0.4124564, 0.3575761, 0.1804375],
        [0.2126729, 0.7151522, 0.0721750],
        [0.0193339, 0.1191920, 0.9503041],
    ]

    /// XYZ of the D65 white (each row of the matrix summed).
    static let d65White: [Double] = rgbToXYZ.map { ($0[0] + $0[1]) + $0[2] }

    /// sRGB-encoded 0-1 value to linear light.
    public static func srgbToLinear(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// Linear light 0-1 value to sRGB encoding (clipped to 0-1 first).
    public static func linearToSRGB(_ value: Double) -> Double {
        let v = clip(value, 0.0, 1.0)
        return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1.0 / 2.4) - 0.055
    }

    /// Relative luminance Y (0-1) of linear sRGB.
    public static func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        r * rgbToXYZ[1][0] + g * rgbToXYZ[1][1] + b * rgbToXYZ[1][2]
    }

    /// Linear sRGB to CIE L*a*b* (D65 white).
    public static func linearRGBToLab(_ r: Double, _ g: Double, _ b: Double) -> (l: Double, a: Double, b: Double) {
        func f(_ row: Int) -> Double {
            let m = rgbToXYZ[row]
            let t = (r * m[0] + g * m[1] + b * m[2]) / d65White[row]
            return labF(t)
        }
        let fx = f(0), fy = f(1), fz = f(2)
        return (116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz))
    }

    // Constants computed as Python does (delta**3 and 3 * delta**2 call pow).
    static let labDelta = 6.0 / 29.0
    static let labCube = pow(labDelta, 3)
    static let labSlope = 3 * pow(labDelta, 2)

    static func labF(_ t: Double) -> Double {
        t > labCube ? cbrt(t) : t / labSlope + 4.0 / 29.0
    }

    /// L* alone (the first value of linearRGBToLab), for whole scans.
    public static func lightness(_ r: Double, _ g: Double, _ b: Double) -> Double {
        let m = rgbToXYZ[1]
        return 116.0 * labF((r * m[0] + g * m[1] + b * m[2]) / d65White[1]) - 16.0
    }
}
