// Loading a photo for printing: any greyscale image, whatever it was saved as.
// Mirrors openquad/photo.py: transparent edges are cropped, partly transparent pixels
// go onto paper white, greyscale stored as RGB is read as grey, and a true colour image
// is converted by luminance (`converted` says so).

import CoreGraphics
import Foundation
import ImageIO

public struct Photo: Sendable {
    public var width: Int
    public var height: Int
    /// 16-bit greyscale, 0 black .. 65535 white, row-major.
    public var pixels: [UInt16]
    public var dpi: (Double, Double)?
    /// Was a colour image, converted by luminance.
    public var converted = false
    /// Transparent edges were removed.
    public var cropped = false

    public var size: (width: Int, height: Int) { (width, height) }
}

public enum Photos {
    static let greyTolerance = 2.0 / 255.0  // channels within this count as grey (JPEG noise)

    /// Load a photo as 16-bit greyscale.
    public static func load(_ url: URL) throws -> Photo {
        let name = url.path
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageFormatError(description: "\(name): not a readable image")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let isTIFF = ["tif", "tiff"].contains(url.pathExtension.lowercased())
        let (values, channels, scale) = try samples(image, isTIFF: isTIFF, name: name)
        let width = image.width, height = image.height
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let minIsWhite = isTIFF && (tiff[kCGImagePropertyTIFFPhotometricInterpretation] as? NSNumber)?.intValue == 0
        let premultiplied = isTIFF && [.premultipliedLast, .premultipliedFirst].contains(image.alphaInfo)
        let pixels = values.map { Double($0) / scale }
        let hasAlpha = channels == 2 || channels == 4
        let colours = hasAlpha ? channels - 1 : channels

        var top = 0, bottom = height, left = 0, right = width, cropped = false
        if hasAlpha {
            func alpha(_ y: Int, _ x: Int) -> Double { pixels[(y * width + x) * channels + channels - 1] }
            let rows = (0..<height).filter { y in (0..<width).contains { alpha(y, $0) > 0 } }
            let columns = (0..<width).filter { x in (0..<height).contains { alpha($0, x) > 0 } }
            guard let first = rows.first else { throw ImageFormatError(description: "\(name): the image is fully transparent") }
            if rows.count < height || columns.count < width {
                cropped = true
                top = first
                bottom = rows.last! + 1
                left = columns.first!
                right = columns.last! + 1
            }
        }
        let outWidth = right - left, outHeight = bottom - top
        func at(_ y: Int, _ x: Int, _ c: Int) -> Double { pixels[((y + top) * width + x + left) * channels + c] }

        var converted = false
        if colours == 3 {
            var spread = 0.0
            for y in 0..<outHeight {
                for x in 0..<outWidth {
                    let r = at(y, x, 0), g = at(y, x, 1), b = at(y, x, 2)
                    spread = max(spread, max(r, g, b) - min(r, g, b))
                }
            }
            converted = spread > greyTolerance
        }
        var out = [UInt16](repeating: 0, count: outWidth * outHeight)
        for y in 0..<outHeight {
            for x in 0..<outWidth {
                var grey: Double
                if colours == 3 {
                    let r = at(y, x, 0), g = at(y, x, 1), b = at(y, x, 2)
                    grey = converted
                        ? Colour.linearToSRGB(Colour.luminance(Colour.srgbToLinear(r), Colour.srgbToLinear(g), Colour.srgbToLinear(b)))
                        : (r + g + b) / 3
                } else {
                    grey = at(y, x, 0)
                }
                if minIsWhite { grey = 1.0 - grey }
                if hasAlpha {
                    let a = at(y, x, channels - 1)
                    grey = premultiplied ? grey + (1.0 - a) : grey * a + (1.0 - a)
                }
                out[y * outWidth + x] = UInt16(rint(clip(grey, 0.0, 1.0) * Double(maxValue)))
            }
        }
        return Photo(width: outWidth, height: outHeight, pixels: out, dpi: dpi(properties, isTIFF: isTIFF, source: source),
                     converted: converted, cropped: cropped)
    }

    /// The resolution as Python reads it: TIFF tags, or a PNG's pixels per metre x 0.0254.
    static func dpi(_ properties: [CFString: Any], isTIFF: Bool, source: CGImageSource) -> (Double, Double)? {
        if isTIFF { return ImageFiles.dpi(source) }
        if let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any],
           let x = (png[kCGImagePropertyPNGXPixelsPerMeter] as? NSNumber)?.doubleValue,
           let y = (png[kCGImagePropertyPNGYPixelsPerMeter] as? NSNumber)?.doubleValue, x > 0, y > 0 {
            return (x * 0.0254, y * 0.0254)
        }
        if let x = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue,
           let y = (properties[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue,
           properties[kCGImagePropertyPNGDictionary] == nil {
            return (x, y)
        }
        return nil
    }

    /// The decoded samples (interleaved, alpha last), channels per pixel and their scale,
    /// matching what Python gets from tifffile or Pillow.
    static func samples(_ image: CGImage, isTIFF: Bool, name: String) throws -> ([UInt16], Int, Double) {
        let bits = image.bitsPerComponent
        guard bits == 8 || bits == 16, let data = image.dataProvider?.data as Data? else {
            throw ImageFormatError(description: "\(name): expected 8- or 16-bit pixels, got \(bits)-bit")
        }
        let width = image.width, height = image.height, stride = image.bytesPerRow, bytes = bits / 8
        let order = image.bitmapInfo.intersection(.byteOrderMask)
        let little = order == .byteOrder16Little || order == .byteOrder32Little
        let reversed = bits == 8 && order == .byteOrder32Little

        if image.colorSpace?.model == .indexed, let table = image.colorSpace?.colorTable, bits == 8 {
            // Pillow reads a palette image as greyscale through its own luma (ITU-R 601).
            var out = [UInt16](repeating: 0, count: width * height)
            data.withUnsafeBytes { raw in
                for y in 0..<height {
                    for x in 0..<width {
                        let i = Int(raw[y * stride + x]) * 3
                        let r: Int = Int(table[i]) * 19595, g: Int = Int(table[i + 1]) * 38470, b: Int = Int(table[i + 2]) * 7471
                        out[y * width + x] = UInt16((r + g + b + 0x8000) >> 16)
                    }
                }
            }
            return (out, 1, 255)
        }

        let components = image.bitsPerPixel / bits
        let alpha = image.alphaInfo
        let hasAlpha = [.last, .first, .premultipliedLast, .premultipliedFirst].contains(alpha)
        let skips = [.noneSkipLast, .noneSkipFirst].contains(alpha)
        let alphaFirst = [.first, .premultipliedFirst, .noneSkipFirst].contains(alpha)
        let colours = components - (hasAlpha || skips ? 1 : 0)
        guard colours == 1 || colours == 3 else { throw ImageFormatError(description: "\(name): unsupported image (\(components) channels)") }
        let channels = colours + (hasAlpha ? 1 : 0)
        // Pillow reads 16-bit colour (and grey with alpha) PNGs as 8-bit, from the high byte.
        let downTo8 = !isTIFF && bits == 16 && (colours == 3 || hasAlpha)
        var out = [UInt16](repeating: 0, count: width * height * channels)
        data.withUnsafeBytes { raw in
            func sample(_ offset: Int) -> UInt16 {
                if bits == 8 { return UInt16(raw[offset]) }
                let a = UInt16(raw[offset]), b = UInt16(raw[offset + 1])
                let v = little ? a | b << 8 : a << 8 | b
                return downTo8 ? v >> 8 : v
            }
            for y in 0..<height {
                for x in 0..<width {
                    var pixel = (0..<components).map { sample(y * stride + (x * components + $0) * bytes) }
                    if reversed { pixel.reverse() }
                    let leading = alphaFirst != reversed
                    let colour = leading ? Array(pixel[1...colours]) : Array(pixel[0..<colours])
                    let k = (y * width + x) * channels
                    for c in 0..<colours { out[k + c] = colour[c] }
                    if hasAlpha { out[k + colours] = leading ? pixel[0] : pixel[components - 1] }
                }
            }
        }
        return (out, channels, bits == 16 && !downTo8 ? 65535 : 255)
    }
}
