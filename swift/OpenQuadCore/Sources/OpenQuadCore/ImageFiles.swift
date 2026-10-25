// 16-bit TIFFs with their resolution and ICC profile, through ImageIO. Mirrors
// openquad/imageio.py (load_grey, read_dpi, save_grey, save_rgb).

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ImageFormatError: Error, Equatable, CustomStringConvertible {
    public let description: String
}

/// A greyscale image: 0 = black, 65535 = white, row-major.
public struct GreyImage: Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [UInt16]
    public var dpi: (Double, Double)?
    public var iccProfile: Data?

    public init(width: Int, height: Int, pixels: [UInt16], dpi: (Double, Double)? = nil, iccProfile: Data? = nil) {
        precondition(pixels.count == width * height, "pixels must be width x height")
        self.width = width
        self.height = height
        self.pixels = pixels
        self.dpi = dpi
        self.iccProfile = iccProfile
    }
}

public enum ImageFiles {
    static let cmPerInch = 2.54
    public static let srgbProfilePath = "/System/Library/ColorSync/Profiles/sRGB Profile.icc"

    /// The system's sRGB ICC profile, if present.
    public static func srgbProfile() -> Data? { FileManager.default.contents(atPath: srgbProfilePath) }

    static func source(_ url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw ImageFormatError(description: "\(url.path): not a readable image")
        }
        return source
    }

    /// The resolution from the TIFF tags (centimetres converted), or nil without an absolute unit.
    public static func readDPI(_ url: URL) throws -> (Double, Double)? {
        dpi(try source(url))
    }

    static func dpi(_ source: CGImageSource) -> (Double, Double)? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        guard let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
              let x = (tiff[kCGImagePropertyTIFFXResolution] as? NSNumber)?.doubleValue,
              let y = (tiff[kCGImagePropertyTIFFYResolution] as? NSNumber)?.doubleValue, x > 0, y > 0
        else { return nil }
        switch (tiff[kCGImagePropertyTIFFResolutionUnit] as? NSNumber)?.intValue ?? 2 {
        case 2: return (x, y)
        case 3: return (x * cmPerInch, y * cmPerInch)
        default: return nil
        }
    }

    /// The first page of a TIFF as 16-bit greyscale (8-bit scaled x257; min-is-white
    /// turned so 0 is black). Colour images are refused rather than converted.
    public static func loadGrey(_ url: URL) throws -> GreyImage {
        let source = try source(url)
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageFormatError(description: "\(url.path): no readable image page")
        }
        guard image.colorSpace?.model == .monochrome, image.bitsPerPixel == image.bitsPerComponent else {
            throw ImageFormatError(description: "\(url.path): expected a single-channel greyscale image "
                                   + "(convert colour images to greyscale first)")
        }
        let bits = image.bitsPerComponent
        guard bits == 8 || bits == 16, let data = image.dataProvider?.data as Data? else {
            throw ImageFormatError(description: "\(url.path): expected 8- or 16-bit pixels, got \(bits)-bit")
        }
        let little = image.bitmapInfo.intersection(.byteOrderMask) == .byteOrder16Little
        let width = image.width, height = image.height, stride = image.bytesPerRow
        var pixels = [UInt16](repeating: 0, count: width * height)
        data.withUnsafeBytes { raw in
            for y in 0..<height {
                for x in 0..<width {
                    if bits == 8 {
                        pixels[y * width + x] = UInt16(raw[y * stride + x]) * 257
                    } else {
                        let a = UInt16(raw[y * stride + 2 * x]), b = UInt16(raw[y * stride + 2 * x + 1])
                        pixels[y * width + x] = little ? a | b << 8 : a << 8 | b
                    }
                }
            }
        }
        // ImageIO hands min-is-white samples back as stored, so turn them here as Python does.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        if (tiff[kCGImagePropertyTIFFPhotometricInterpretation] as? NSNumber)?.intValue == 0 {
            pixels = pixels.map { UInt16(maxValue) - $0 }
        }
        let embedded = properties[kCGImagePropertyProfileName] != nil ? image.colorSpace?.copyICCData() as Data? : nil
        return GreyImage(width: width, height: height, pixels: pixels, dpi: dpi(source), iccProfile: embedded)
    }

    static func write(_ url: URL, width: Int, height: Int, samples: [UInt16], channels: Int,
                      dpi: (Double, Double)?, iccProfile: Data?, compression: Int) throws {
        var bytes = [UInt8](repeating: 0, count: samples.count * 2)
        for (i, v) in samples.enumerated() {
            bytes[2 * i] = UInt8(v >> 8)
            bytes[2 * i + 1] = UInt8(v & 0xff)
        }
        let space = iccProfile.flatMap { CGColorSpace(iccData: $0 as CFData) }
            ?? (channels == 1 ? CGColorSpace(name: CGColorSpace.genericGrayGamma2_2) : CGColorSpace(name: CGColorSpace.sRGB))
        guard let space, let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 16 * channels,
                                  bytesPerRow: width * channels * 2, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Big.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil)
        else { throw ImageFormatError(description: "\(url.path): can't write a TIFF here") }
        var properties: [CFString: Any] = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: compression]]
        if let dpi {
            properties[kCGImagePropertyDPIWidth] = dpi.0
            properties[kCGImagePropertyDPIHeight] = dpi.1
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageFormatError(description: "\(url.path): writing the TIFF failed") }
    }

    /// Save a 16-bit min-is-black greyscale TIFF with the image's resolution and profile.
    public static func saveGrey(_ url: URL, _ image: GreyImage) throws {
        try write(url, width: image.width, height: image.height, samples: image.pixels, channels: 1,
                  dpi: image.dpi, iccProfile: image.iccProfile, compression: 1)
    }

    /// Save a 16-bit RGB TIFF (zlib, as Python writes it) with optional resolution and ICC profile.
    public static func saveRGB(_ url: URL, _ image: RGBImage, dpi: (Double, Double)? = nil, iccProfile: Data? = nil) throws {
        try write(url, width: image.width, height: image.height, samples: image.pixels, channels: 3,
                  dpi: dpi, iccProfile: iccProfile, compression: 8)
    }
}
