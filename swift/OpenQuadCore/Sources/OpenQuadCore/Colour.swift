// Colour maths: sRGB transfer functions, CIE XYZ and L*a*b*, and CIEDE2000. Mirrors
// openquad/colour.py.

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

    /// The ICC profile connection space white (D50), as XYZ with Y = 1.
    public static let d50White: [Double] = [0.9642, 1.0, 0.8249]

    /// Bradford chromatic adaptation, D65 to D50 (as ICC profiles adapt sRGB).
    static let d65ToD50Matrix: [[Double]] = [
        [1.0478112, 0.0228866, -0.0501270],
        [0.0295424, 0.9904844, -0.0170491],
        [-0.0092345, 0.0150436, 0.7521316],
    ]

    static func times(_ m: [[Double]], _ v: [Double]) -> [Double] {
        m.map { row in (v[0] * row[0] + v[1] * row[1]) + v[2] * row[2] }
    }

    /// Linear sRGB to CIE XYZ (D65, Y = 1 for white).
    public static func linearRGBToXYZ(_ rgb: [Double]) -> [Double] { times(rgbToXYZ, rgb) }

    /// CIE XYZ seen under D65 adapted to D50 (Bradford).
    public static func d65ToD50(_ xyz: [Double]) -> [Double] { times(d65ToD50Matrix, xyz) }

    /// Encoded sRGB (0-1) to D50 XYZ, as a scan taken as sRGB is read.
    public static func srgbToD50(_ rgb: [Double]) -> [Double] { d65ToD50(linearRGBToXYZ(rgb.map(srgbToLinear))) }

    /// CIE XYZ to L*a*b* relative to `white`.
    public static func xyzToLab(_ xyz: [Double], white: [Double]) -> [Double] {
        let f = (0..<3).map { labF(xyz[$0] / white[$0]) }
        return [116.0 * f[1] - 16.0, 500.0 * (f[0] - f[1]), 200.0 * (f[1] - f[2])]
    }

    /// CIE L*a*b* relative to `white` back to XYZ.
    public static func labToXYZ(_ lab: [Double], white: [Double]) -> [Double] {
        let fy = (lab[0] + 16.0) / 116.0
        let f = [fy + lab[1] / 500.0, fy, fy - lab[2] / 200.0]
        return (0..<3).map { i in
            (f[i] > labDelta ? f[i] * f[i] * f[i] : labSlope * (f[i] - 4.0 / 29.0)) * white[i]
        }
    }

    /// The CIEDE2000 colour difference (kL = kC = kH = 1), after Sharma, Wu and Dalal (2005).
    public static func deltaE2000(_ lab1: [Double], _ lab2: [Double]) -> Double {
        let (l1, a1, b1) = (lab1[0], lab1[1], lab1[2]), (l2, a2, b2) = (lab2[0], lab2[1], lab2[2])
        let cMean = (hypot(a1, b1) + hypot(a2, b2)) / 2
        let g = 0.5 * (1 - sqrt(pow(cMean, 7) / (pow(cMean, 7) + pow(25.0, 7))))
        let a1p = (1 + g) * a1, a2p = (1 + g) * a2
        let c1p = hypot(a1p, b1), c2p = hypot(a2p, b2)
        func degrees(_ y: Double, _ x: Double) -> Double { pyMod(atan2(y, x) * 180 / .pi, 360) }
        let h1p = degrees(b1, a1p), h2p = degrees(b2, a2p)
        let dl = l2 - l1, dc = c2p - c1p
        var dh = h2p - h1p
        dh = dh > 180 ? dh - 360 : (dh < -180 ? dh + 360 : dh)
        if c1p * c2p == 0 { dh = 0 }
        let dhh = 2 * sqrt(c1p * c2p) * sin(dh / 2 * .pi / 180)
        let lMean = (l1 + l2) / 2, cpMean = (c1p + c2p) / 2, hSum = h1p + h2p
        var hMean = abs(h1p - h2p) <= 180 ? hSum / 2 : (hSum < 360 ? (hSum + 360) / 2 : (hSum - 360) / 2)
        if c1p * c2p == 0 { hMean = hSum }
        func cosd(_ x: Double) -> Double { cos(x * .pi / 180) }
        let t = 1 - 0.17 * cosd(hMean - 30) + 0.24 * cosd(2 * hMean) + 0.32 * cosd(3 * hMean + 6) - 0.20 * cosd(4 * hMean - 63)
        let sl = 1 + 0.015 * pow(lMean - 50, 2) / sqrt(20 + pow(lMean - 50, 2))
        let sc = 1 + 0.045 * cpMean, sh = 1 + 0.015 * cpMean * t
        let rc = 2 * sqrt(pow(cpMean, 7) / (pow(cpMean, 7) + pow(25.0, 7)))
        let rt = -sin(60 * exp(-pow((hMean - 275) / 25, 2)) * .pi / 180) * rc
        return sqrt(pow(dl / sl, 2) + pow(dc / sc, 2) + pow(dhh / sh, 2) + rt * (dc / sc) * (dhh / sh))
    }

    /// Euclidean (ΔE76) distance between two L*a*b* colours.
    public static func deltaE76(_ lab1: [Double], _ lab2: [Double]) -> Double {
        sqrt(pow(lab1[0] - lab2[0], 2) + pow(lab1[1] - lab2[1], 2) + pow(lab1[2] - lab2[2], 2))
    }
}
