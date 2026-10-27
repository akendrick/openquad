// Draws the OpenQuad app icon into an .iconset folder (swift/build-app.sh turns it into
// AppIcon.icns): a stylized printer on a light tile, blank paper going in at the top and a
// print with a black-to-white step wedge coming out of the front. Drawn on the 1024 px macOS icon grid and scaled for each size.
//
//     swift make-icon.swift OUT.iconset            the icon set
//     swift make-icon.swift --preview OUT.png      one 1024 px PNG

import AppKit

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }

func rounded(_ c: CGContext, _ r: CGRect, _ radius: CGFloat, _ fill: CGColor) {
    c.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
    c.setFillColor(fill)
    c.fillPath()
}

/// The icon in 1024 x 1024 units (y up).
func drawIcon(_ c: CGContext) {
    // The tile: an 824 px rounded square, light grey with a soft top-to-bottom shade.
    let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185,
                      transform: nil)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0, 0, 0, 0.3))
    c.addPath(tile)
    c.setFillColor(rgb(0.80, 0.82, 0.85))
    c.fillPath()
    c.restoreGState()
    c.saveGState()
    c.addPath(tile)
    c.clip()
    let shade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [rgb(0.94, 0.95, 0.96), rgb(0.79, 0.81, 0.84)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(shade, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
    c.restoreGState()

    // Blank paper going in at the top, behind the printer.
    rounded(c, CGRect(x: 318, y: 560, width: 388, height: 270), 18, rgb(1, 1, 1))
    c.setStrokeColor(CGColor(gray: 0.84, alpha: 1))
    c.setLineWidth(3)
    c.addPath(CGPath(roundedRect: CGRect(x: 318, y: 560, width: 388, height: 270), cornerWidth: 18, cornerHeight: 18, transform: nil))
    c.strokePath()

    // The printer: a wide body with a lighter top, a status light, and the output slot.
    rounded(c, CGRect(x: 176, y: 330, width: 672, height: 300), 56, rgb(0.20, 0.22, 0.25))
    rounded(c, CGRect(x: 176, y: 560, width: 672, height: 70), 34, rgb(0.31, 0.33, 0.37))
    rounded(c, CGRect(x: 690, y: 500, width: 100, height: 26), 13, rgb(0.35, 0.85, 0.55))
    rounded(c, CGRect(x: 236, y: 400, width: 552, height: 30), 15, rgb(0.09, 0.10, 0.11))

    // The print coming out of the front, with a 7-step wedge from black to white.
    let sheet = CGRect(x: 266, y: 150, width: 492, height: 266)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: rgb(0, 0, 0, 0.25))
    rounded(c, sheet, 20, rgb(1, 1, 1))
    c.restoreGState()
    rounded(c, CGRect(x: sheet.minX, y: sheet.maxY - 24, width: sheet.width, height: 24), 0, rgb(0.93, 0.93, 0.94))  // in the slot's shadow
    let steps = 7
    let wedge = CGRect(x: sheet.minX + 30, y: sheet.minY + 34, width: sheet.width - 60, height: 172)
    let step = wedge.width / CGFloat(steps)
    for i in 0..<steps {
        c.setFillColor(CGColor(gray: CGFloat(i) / CGFloat(steps - 1) * 0.94, alpha: 1))
        c.fill(CGRect(x: wedge.minX + CGFloat(i) * step, y: wedge.minY, width: step + 0.5, height: wedge.height))
    }
    c.setStrokeColor(CGColor(gray: 0.82, alpha: 1))
    c.setLineWidth(3)
    c.stroke(wedge)
}

func png(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let c = NSGraphicsContext.current!.cgContext
    c.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawIcon(c)
    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

let arguments = CommandLine.arguments
if arguments.count == 3 && arguments[1] == "--preview" {
    try png(1024).write(to: URL(fileURLWithPath: arguments[2]))
} else {
    let out = URL(fileURLWithPath: arguments[1])
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    for size in [16, 32, 128, 256, 512] {
        try png(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
        try png(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
    }
}
