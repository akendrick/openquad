// Turning OpenQuad's 16-bit images into CGImages for the screen and the printer.

import CoreGraphics
import Foundation
import OpenQuadCore

extension RGBImage {
    /// A CGImage of the 16-bit sRGB pixels; `eightBit` for previews on screen.
    public func cgImage(eightBit: Bool = false) -> CGImage? {
        let space = ImageFiles.srgbProfile().flatMap { CGColorSpace(iccData: $0 as CFData) }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let data: Data
        let bits: Int
        if eightBit {
            data = Data(pixels.map { UInt8($0 >> 8) })
            bits = 8
        } else {
            var bytes = [UInt8](repeating: 0, count: pixels.count * 2)
            for (i, v) in pixels.enumerated() {
                bytes[2 * i] = UInt8(v >> 8)
                bytes[2 * i + 1] = UInt8(v & 0xff)
            }
            data = Data(bytes)
            bits = 16
        }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let order = bits == 16 ? CGBitmapInfo.byteOrder16Big.rawValue : 0
        return CGImage(width: width, height: height, bitsPerComponent: bits, bitsPerPixel: bits * 3,
                       bytesPerRow: width * 3 * bits / 8, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | order),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
