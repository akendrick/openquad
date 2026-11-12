// All the coats of a separation together, as a map: each tone of the photo is drawn in the
// colour of the coat that builds it up (the one ramping there), blending into the next coat's
// colour across the overlap, and darker the darker the tone. So the bands, and how their seams
// blend, can be checked on the photo before any film is printed. Only a preview: each negative
// still prints on its own. A colour separation is shown as it prints instead: its coats stacked
// in their pigments' colours.

import CoreGraphics
import Foundation
import OpenQuadCore

enum CoatsPreview {
    /// Each coat's colour (sRGB, 0-1), lightest band first; the band diagram uses the same.
    static let inks: [(Double, Double, Double)] = [
        (0.95, 0.50, 0.10),  // orange
        (0.15, 0.60, 0.30),  // green
        (0.15, 0.30, 0.85),  // blue
        (0.72, 0.22, 0.56),  // magenta
        (0.10, 0.55, 0.62),  // teal
        (0.42, 0.26, 0.14),  // brown
    ]

    /// The map of `photo` (16-bit greyscale) through `plan`, at most `maxSide` pixels on its
    /// longer side.
    static func image(_ photo: [UInt16], width: Int, height: Int, plan: SeparationPlan, maxSide: Int = 900) -> CGImage? {
        let scale = min(1.0, Double(maxSide) / Double(max(width, height)))
        let (w, h) = (max(1, Int(Double(width) * scale)), max(1, Int(Double(height) * scale)))
        let pixels = scale < 1 ? ContactSheet.resize(photo, photoWidth: width, region: (0, 0, width, height), size: (w, h)) : photo
        // A tone's colour: the coats ramping there (how fast each is building up), mixed.
        let table: [[UInt8]] = (0..<256).map { level in
            let position = 1.0 - Double(level) / 255.0
            guard position > 0 else { return [255, 255, 255] }  // paper white
            let step = 0.5 / 255.0
            var weights = plan.bands.indices.map { k in
                plan.strength(k, at: min(position + step, 1)) - plan.strength(k, at: max(position - step, 0))
            }
            if weights.allSatisfy({ $0 <= 1e-12 }) {  // past the last ramp: the darkest coat printing
                weights = plan.bands.indices.map { k in k == plan.count - 1 ? 1 : 0 }
            }
            let total = weights.reduce(0, +)
            var mix = (0.0, 0.0, 0.0)
            for (k, w) in weights.enumerated() {
                let ink = inks[k % inks.count]
                mix = (mix.0 + w / total * ink.0, mix.1 + w / total * ink.1, mix.2 + w / total * ink.2)
            }
            let depth = min(1, 0.3 + 0.7 * position)  // light tones still show their coat's colour
            return [mix.0, mix.1, mix.2].map { UInt8(((1 - depth * (1 - $0)) * 255).rounded()) }
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(w * h * 3)
        for p in pixels { bytes += table[Int(p >> 8)] }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: w * 3,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// A colour separation's coats together, as they print in their pigments' colours (each
    /// pixel's coat densities added up), at most `maxSide` pixels on its longer side.
    static func proof(_ photo: Photo, separation: ColourSeparation, maxSide: Int = 900) -> CGImage? {
        let scale = min(1.0, Double(maxSide) / Double(max(photo.width, photo.height)))
        let (w, h) = (max(1, Int(Double(photo.width) * scale)), max(1, Int(Double(photo.height) * scale)))
        let region = (0, 0, photo.width, photo.height)
        guard let colour = photo.colour else {
            let grey = scale < 1 ? ContactSheet.resize(photo.pixels, photoWidth: photo.width, region: region, size: (w, h)) : photo.pixels
            return RGBImage(width: w, height: h, pixels: separation.proof(grey, colour: false)).cgImage(eightBit: true)
        }
        var rgb = colour
        if scale < 1 {
            let planes = (0..<3).map { c in
                ContactSheet.resize(stride(from: c, to: colour.count, by: 3).map { colour[$0] }, photoWidth: photo.width,
                                    region: region, size: (w, h))
            }
            rgb = (0..<w * h).flatMap { i in planes.map { $0[i] } }
        }
        return RGBImage(width: w, height: h, pixels: separation.proof(rgb, colour: true)).cgImage(eightBit: true)
    }
}
