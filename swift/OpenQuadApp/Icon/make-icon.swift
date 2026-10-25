// Draws the OpenQuad app icon into an .iconset folder (swift/build-app.sh turns it into
// AppIcon.icns): a print with a neutral step wedge, overlapped by a green film negative.
//
//     swift make-icon.swift OUT.iconset

import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let c = NSGraphicsContext.current!.cgContext
    // Background: a dark rounded square (the macOS icon grid leaves a margin).
    let inset = s * 0.1, body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    c.addPath(CGPath(roundedRect: body, cornerWidth: s * 0.18, cornerHeight: s * 0.18, transform: nil))
    c.setFillColor(CGColor(red: 0.16, green: 0.18, blue: 0.20, alpha: 1))
    c.fillPath()
    // The print: white paper with a 7-step wedge from black to white.
    let paper = CGRect(x: s * 0.2, y: s * 0.3, width: s * 0.5, height: s * 0.5)
    c.setFillColor(CGColor(gray: 0.97, alpha: 1))
    c.fill(paper)
    let steps = 7
    for i in 0..<steps {
        let grey = CGFloat(i) / CGFloat(steps - 1) * 0.92
        c.setFillColor(CGColor(gray: grey, alpha: 1))
        let w = paper.width * 0.84 / CGFloat(steps)
        c.fill(CGRect(x: paper.minX + paper.width * 0.08 + CGFloat(i) * w, y: paper.minY + paper.height * 0.3, width: w, height: paper.height * 0.4))
    }
    // The negative: a translucent green film over the lower right.
    let film = CGRect(x: s * 0.42, y: s * 0.2, width: s * 0.38, height: s * 0.38)
    c.setFillColor(CGColor(red: 0.10, green: 0.45, blue: 0.20, alpha: 0.85))
    c.fill(film)
    c.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
    c.setLineWidth(max(1, s * 0.012))
    c.stroke(film.insetBy(dx: s * 0.03, dy: s * 0.03))
    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try draw(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try draw(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
