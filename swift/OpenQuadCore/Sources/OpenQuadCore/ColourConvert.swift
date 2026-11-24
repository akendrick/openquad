// Converting a colour print through a printer's OpenQuad profile (colour calibration,
// phase 4): the photo's colours, in its own profile, become the RGB to send to the
// printer, which is then sent sRGB-tagged, exactly as the colour target was.

import CoreGraphics
import Foundation

public enum ColourConvert {
    /// Whether ICC data is an RGB output (printer) profile, the kind OpenQuad makes.
    public static func isRGBOutputProfile(_ data: Data) -> Bool {
        data.count >= 20 && data[12..<16] == Data("prtr".utf8) && data[16..<20] == Data("RGB ".utf8)
    }

    /// 16-bit RGB pixels in `source`'s colours (sRGB if nil) as the device RGB of the
    /// printer `profile` describes, by ColorSync with the given intent.
    public static func toDevice(_ pixels: [UInt16], width: Int, height: Int, from source: Data?, to profile: Data,
                                intent: CGColorRenderingIntent = .perceptual) throws -> [UInt16] {
        guard let inSpace = (source ?? ImageFiles.srgbProfile()).flatMap({ CGColorSpace(iccData: $0 as CFData) })
            ?? CGColorSpace(name: CGColorSpace.sRGB),
            let outSpace = CGColorSpace(iccData: profile as CFData), outSpace.model == .rgb else {
            throw FileFormatError(description: "the colour profile can't be used")
        }
        var bytes = [UInt8](repeating: 0, count: pixels.count * 2)
        for (i, v) in pixels.enumerated() {
            bytes[2 * i] = UInt8(v >> 8)
            bytes[2 * i + 1] = UInt8(v & 0xff)
        }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Big.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: width * 6,
                                  space: inSpace, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: intent),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: width * 8,
                                      space: outSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        else { throw FileFormatError(description: "couldn't convert the photo through the colour profile") }
        context.setRenderingIntent(intent)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { throw FileFormatError(description: "couldn't convert the photo through the colour profile") }
        let out = data.bindMemory(to: UInt16.self, capacity: width * height * 4)
        var device = [UInt16](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            device[3 * i] = UInt16(littleEndian: out[4 * i])
            device[3 * i + 1] = UInt16(littleEndian: out[4 * i + 1])
            device[3 * i + 2] = UInt16(littleEndian: out[4 * i + 2])
        }
        return device
    }
}
