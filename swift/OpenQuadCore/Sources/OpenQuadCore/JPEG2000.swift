// Reading JPEG 2000 photos (.jp2, .j2k, .jpx) at their full bit depth, through the OpenJPEG
// 2.5.4 built into the app (COpenJPEG). Mirrors openquad/jpeg2000.py, which uses the same
// OpenJPEG version through Pillow: macOS's ImageIO cuts 16-bit JPEG 2000 to 8-bit, and
// Pillow's own reader turns bright 16-bit colour black, so neither is used.
//
// 1 component is grey, 2 grey and alpha, 3 RGB, 4 RGB and alpha; 8-bit when every
// component is 8 bits or fewer, else 16-bit, each scaled with rounding; signed components
// move up by half their range; the ICC profile is the file's own; the resolution is the JP2
// capture resolution ('resc'). Subsampled components and YCC or CMYK colour are refused.

import COpenJPEG
import Foundation

enum JPEG2000 {
    static let codestreamSignature: [UInt8] = [0xFF, 0x4F, 0xFF, 0x51]
    static let jp2Signature: [UInt8] = [0, 0, 0, 0x0C, 0x6A, 0x50, 0x20, 0x20, 0x0D, 0x0A, 0x87, 0x0A]
    static let maxExponent = 6  // resolutions beyond 10^6 are ignored (both sides compute them exactly)

    /// Do these first bytes of a file start a JPEG 2000 codestream or JP2 file?
    static func isJPEG2000(_ head: Data) -> Bool {
        head.starts(with: codestreamSignature) || head.starts(with: jp2Signature)
    }

    /// The OpenJPEG version built in, e.g. "2.5.4".
    static var openJPEGVersion: String { String(cString: opj_version()) }

    /// Unsigned `precision`-bit values to `bits` bits, rounding to nearest.
    static func scale(_ value: Int64, precision: Int, bits: Int) -> Int64 {
        if precision == bits { return value }
        let top = (Int64(1) << precision) - 1, full = (Int64(1) << bits) - 1
        return (value * full + top / 2) / top
    }

    /// Collects OpenJPEG's error messages (its handler is a C function with a context pointer).
    final class Messages {
        var errors: [String] = []
    }

    struct Decoded {
        var values: [UInt16]
        var width: Int
        var height: Int
        var channels: Int
        var bits: Int
        var dpi: (Double, Double)?
        var profile: Data?
    }

    /// Decode a JPEG 2000 file; `data` is its contents (for the header and resolution boxes).
    static func read(_ url: URL, data: Data) throws -> Decoded {
        let name = url.path
        let format = data.starts(with: codestreamSignature) ? OPJ_CODEC_J2K : OPJ_CODEC_JP2
        guard let stream = opj_stream_create_default_file_stream(url.path, 1) else {
            throw ImageFormatError(description: "\(name): could not open the file")
        }
        defer { opj_stream_destroy(stream) }
        guard let codec = opj_create_decompress(format) else {
            throw ImageFormatError(description: "\(name): not a readable JPEG 2000 image")
        }
        defer { opj_destroy_codec(codec) }
        let messages = Messages()
        let context = Unmanaged.passUnretained(messages).toOpaque()
        var parameters = opj_dparameters_t()
        opj_set_default_decoder_parameters(&parameters)
        opj_setup_decoder(codec, &parameters)
        opj_set_error_handler(codec, { message, client in
            guard let message, let client else { return }
            let box = Unmanaged<Messages>.fromOpaque(client).takeUnretainedValue()
            box.errors.append(String(cString: message).trimmingCharacters(in: .whitespacesAndNewlines))
        }, context)
        var image: UnsafeMutablePointer<opj_image_t>?
        defer { if let image { opj_image_destroy(image) } }
        let ok = withExtendedLifetime(messages) {
            opj_read_header(stream, codec, &image) != 0 && opj_decode(codec, stream, image) != 0
                && opj_end_decompress(codec, stream) != 0
        }
        guard ok, let image else {
            let reason = messages.errors.first ?? "could not be decoded"
            throw ImageFormatError(description: "\(name): not a readable JPEG 2000 image (\(reason))")
        }
        var decoded = try pixels(image.pointee, name: name)
        let info = image.pointee
        if info.icc_profile_len > 0, let buffer = info.icc_profile_buf {
            decoded.profile = Data(bytes: buffer, count: Int(info.icc_profile_len))
        }
        decoded.dpi = jp2DPI(data)
        return decoded
    }

    static func pixels(_ image: opj_image_t, name: String) throws -> Decoded {
        let count = Int(image.numcomps)
        guard (1...4).contains(count), let all = image.comps else {
            throw ImageFormatError(description: "\(name): unsupported JPEG 2000 image (\(count) components)")
        }
        let comps = (0..<count).map { all[$0] }
        let width = Int(comps[0].w), height = Int(comps[0].h)
        guard comps.allSatisfy({ $0.dx == 1 && $0.dy == 1 && Int($0.w) == width && Int($0.h) == height }) else {
            throw ImageFormatError(description: "\(name): unsupported JPEG 2000 image (subsampled colour)")
        }
        let allowed = [OPJ_CLRSPC_UNKNOWN, OPJ_CLRSPC_UNSPECIFIED, count <= 2 ? OPJ_CLRSPC_GRAY : OPJ_CLRSPC_SRGB]
        guard allowed.contains(image.color_space) else {
            throw ImageFormatError(description: "\(name): unsupported JPEG 2000 colour (only grey and RGB are read)")
        }
        let bits = comps.contains { $0.prec > 8 } ? 16 : 8
        var values = [UInt16](repeating: 0, count: width * height * count)
        for (k, c) in comps.enumerated() {
            guard let data = c.data else { throw ImageFormatError(description: "\(name): a JPEG 2000 component has no data") }
            let precision = Int(c.prec), top = (Int64(1) << precision) - 1
            let offset: Int64 = c.sgnd != 0 ? Int64(1) << (precision - 1) : 0
            for i in 0..<(width * height) {
                let v = min(max(Int64(data[i]) + offset, 0), top)
                values[i * count + k] = UInt16(scale(v, precision: precision, bits: bits))
            }
        }
        return Decoded(values: values, width: width, height: height, channels: count, bits: bits)
    }

    /// The (type, content start, content end) of each box in data[start..<end].
    static func boxes(_ data: Data, _ start: Int, _ end: Int) -> [(String, Int, Int)] {
        let base = data.startIndex
        func u32(_ at: Int) -> UInt64 { (0..<4).reduce(0) { $0 << 8 | UInt64(data[base + at + $1]) } }
        func u64(_ at: Int) -> UInt64 { (0..<8).reduce(0) { $0 << 8 | UInt64(data[base + at + $1]) } }
        var found: [(String, Int, Int)] = [], at = start
        while at + 8 <= end {
            var length = u32(at), header = 8
            let kind = String(decoding: data[(base + at + 4)..<(base + at + 8)], as: UTF8.self)
            if length == 1 {
                if at + 16 > end { break }
                (length, header) = (u64(at + 8), 16)
            } else if length == 0 {
                length = UInt64(end - at)
            }
            guard length >= UInt64(header), length <= UInt64(end - at) else { break }
            found.append((kind, at + header, at + Int(length)))
            at += Int(length)
        }
        return found
    }

    /// The capture resolution of a JP2 file ('jp2h' > 'res ' > 'resc'), in dots per inch.
    static func jp2DPI(_ data: Data) -> (Double, Double)? {
        let base = data.startIndex
        func u16(_ at: Int) -> Int { Int(data[base + at]) << 8 | Int(data[base + at + 1]) }
        func i8(_ at: Int) -> Int { Int(Int8(bitPattern: data[base + at])) }
        for (kind, start, end) in boxes(data, 0, data.count) where kind == "jp2h" {
            for (sub, s, e) in boxes(data, start, end) where sub == "res " {
                for (res, r, last) in boxes(data, s, e) where res == "resc" && last - r >= 10 {
                    let horizontal = perInch(u16(r + 4), u16(r + 6), i8(r + 9))
                    let vertical = perInch(u16(r), u16(r + 2), i8(r + 8))
                    if let horizontal, let vertical { return (horizontal, vertical) }
                }
            }
        }
        return nil
    }

    /// Dots per metre (numerator / denominator x 10^exponent) as dots per inch, correctly rounded.
    static func perInch(_ numerator: Int, _ denominator: Int, _ exponent: Int) -> Double? {
        guard numerator != 0, denominator != 0, abs(exponent) <= maxExponent else { return nil }
        var top = Int64(254 * numerator), bottom = Int64(10000 * denominator)
        for _ in 0..<abs(exponent) {
            if exponent > 0 { top *= 10 } else { bottom *= 10 }
        }
        return Double(top) / Double(bottom)  // both exact (under 2^53), so the division rounds once
    }
}
