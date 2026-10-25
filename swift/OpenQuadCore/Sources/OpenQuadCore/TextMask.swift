// Text drawn into a pixel mask (for labels printed on test sheets).

import CoreGraphics
import CoreText
import Foundation

enum TextMask {
    /// Which pixels the text covers (more than half), for texts at (x, top) in pixels.
    static func draw(_ texts: [(String, Double, Double)], size: Double, width: Int, height: Int) -> [Bool] {
        var bytes = [UInt8](repeating: 0, count: width * height)
        bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let white = CGColor(gray: 1, alpha: 1)
            for (text, x, top) in texts {
                let attributed = NSAttributedString(string: text, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): white,
                ])
                let line = CTLineCreateWithAttributedString(attributed)
                // Core Graphics counts up from the bottom; place the text's top at `top`.
                context.textPosition = CGPoint(x: x, y: Double(height) - top - CTFontGetAscent(font))
                CTLineDraw(line, context)
            }
        }
        // The context's first row is the image's top row.
        return bytes.map { $0 > 127 }
    }
}
