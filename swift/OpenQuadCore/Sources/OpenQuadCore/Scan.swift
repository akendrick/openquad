// Scans as encoded sRGB values 0-1 (openquad/measure.py load_scan). Samples are kept as
// the file's integers and divided on read, exactly as Python's astype(float64) / scale.

import Foundation
import ImageIO

public struct ScanError: Error, Equatable, CustomStringConvertible {
    public let description: String
}

public struct Scan: Sendable {
    public let width: Int
    public let height: Int
    /// Interleaved R, G, B per pixel, row-major.
    public let samples: [UInt16]
    /// 255 for 8-bit files, 65535 for 16-bit.
    public let scale: Double

    public init(width: Int, height: Int, samples: [UInt16], scale: Double) {
        precondition(samples.count == width * height * 3, "samples must be width x height x 3")
        self.width = width
        self.height = height
        self.samples = samples
        self.scale = scale
    }

    @inlinable
    public func value(_ x: Int, _ y: Int, _ channel: Int) -> Double {
        Double(samples[(y * width + x) * 3 + channel]) / scale
    }

    /// Rows `range` as a scan of their own.
    public func rows(_ range: Range<Int>) -> Scan {
        Scan(width: width, height: range.count,
             samples: Array(samples[range.lowerBound * width * 3..<range.upperBound * width * 3]), scale: scale)
    }

    /// A JPEG, PNG or TIFF scan. Lossless files decode exactly as in Python; JPEG
    /// decoders differ slightly, so a JPEG reads within a level or so of Pillow.
    public static func load(_ url: URL) throws -> Scan {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ScanError(description: "\(url.lastPathComponent): not an image")
        }
        return try from(image, name: url.lastPathComponent)
    }

    static func from(_ image: CGImage, name: String) throws -> Scan {
        let bits = image.bitsPerComponent
        guard bits == 8 || bits == 16, let data = image.dataProvider?.data as Data? else {
            throw ScanError(description: "\(name): unsupported image (\(bits) bits per sample)")
        }
        let components = image.bitsPerPixel / bits
        let alpha = image.alphaInfo
        let alphaFirst = [.first, .premultipliedFirst, .noneSkipFirst].contains(alpha)
        let colours = components - (alpha == .none ? 0 : 1)
        guard colours == 3 || colours == 1 else {
            throw ScanError(description: "\(name): expected a colour scan, got \(colours) channels")
        }
        let order = image.bitmapInfo.intersection(.byteOrderMask)
        let little = order == .byteOrder16Little || order == .byteOrder32Little
        let reversed = bits == 8 && order == .byteOrder32Little  // BGRA in memory
        let width = image.width, height = image.height, stride = image.bytesPerRow
        var samples = [UInt16](repeating: 0, count: width * height * 3)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            func sample(_ offset: Int) -> UInt16 {
                if bits == 8 { return UInt16(raw[offset]) }
                let a = UInt16(raw[offset]), b = UInt16(raw[offset + 1])
                return little ? a | b << 8 : a << 8 | b
            }
            let bytes = bits / 8
            for y in 0..<height {
                for x in 0..<width {
                    var pixel = (0..<components).map { sample(y * stride + (x * components + $0) * bytes) }
                    if reversed { pixel.reverse() }
                    let first = (alphaFirst != reversed) ? 1 : 0
                    for c in 0..<3 {
                        samples[(y * width + x) * 3 + c] = pixel[first + (colours == 3 ? c : 0)]
                    }
                }
            }
        }
        return Scan(width: width, height: height, samples: samples, scale: bits == 16 ? 65535.0 : 255.0)
    }
}

/// numpy median of a non-empty list: the middle value, or the mean of the two middle ones.
func median(_ values: [Double]) -> Double {
    precondition(!values.isEmpty, "median of nothing")
    let sorted = values.sorted()
    let mid = sorted.count / 2
    return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
}
