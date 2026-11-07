// Darkroom marks: a black guide line round the image and registration marks. Mirrors
// openquad/marks.py. Red and orange negatives all but vanish under a red safelight; black
// ink shows there. Both marks sit in the band round the image (a negative's safe edge, or
// a white border added round a print), so on a negative they block UV like the rest of
// the safe edge and never reach the contact print:
// - the guide line: a thin black line right against the image;
// - registration marks: a crosshair target centred on each side, and corner crop marks
//   that continue the image's edges out to the edge of the sheet.
// For separations the targets can instead be cut clear, like the F: they expose onto the
// paper with the first coat, and each later negative is lined up on them.

public enum Marks {
    /// Inches of white paper added round a print to carry its marks.
    public static let printBorder = 0.25
    /// The line is an eighth of the band, but never thicker than this (inches).
    public static let maxLine = 0.04

    /// Pixels across the guide line and the registration marks.
    public static func lineWidth(band: Int, dpi: Double) -> Int {
        max(1, min(band / 8, pyRound(maxLine * dpi)))
    }

    /// Where the marks go on a `width` x `height` sheet whose image sits `band` pixels in
    /// from every side: true for black ink, row-major.
    public static func mask(width: Int, height: Int, band: Int, dpi: Double, guide: Bool, registration: Bool) -> [Bool] {
        var mask = [Bool](repeating: false, count: width * height)
        let line = lineWidth(band: band, dpi: dpi)
        guard band > line else { return mask }  // no room round the image
        func set(_ rows: Range<Int>, _ columns: Range<Int>) {
            for y in pySlice(rows.lowerBound, rows.upperBound, height) {
                for x in pySlice(columns.lowerBound, columns.upperBound, width) { mask[y * width + x] = true }
            }
        }
        let right = width - band, bottom = height - band  // the image's far edges (exclusive)
        if guide {  // four bars round the image
            set((band - line)..<band, (band - line)..<(right + line))
            set(bottom..<(bottom + line), (band - line)..<(right + line))
            set(band..<bottom, (band - line)..<band)
            set(band..<bottom, right..<(right + line))
        }
        if registration {
            let crop = band / 2  // corner marks: the image's edges carried out to the sheet's
            for x in [band - line, right] {
                set(0..<crop, x..<(x + line))
                set((height - crop)..<height, x..<(x + line))
            }
            for y in [band - line, bottom] {
                set(y..<(y + line), 0..<crop)
                set(y..<(y + line), (width - crop)..<width)
            }
            drawTargets(&mask, width: width, height: height, band: band, line: line)
        }
        return mask
    }

    /// Just the crosshair targets of the registration marks (no crop marks).
    public static func targetMask(width: Int, height: Int, band: Int, dpi: Double) -> [Bool] {
        var mask = [Bool](repeating: false, count: width * height)
        let line = lineWidth(band: band, dpi: dpi)
        if band > line { drawTargets(&mask, width: width, height: height, band: band, line: line) }
        return mask
    }

    /// A crosshair target centred in the band on each side of the sheet.
    static func drawTargets(_ mask: inout [Bool], width: Int, height: Int, band: Int, line: Int) {
        let radius = band * 3 / 10, arm = band * 2 / 5
        if radius > line {
            let centres = [(width / 2, band / 2), (width / 2, height - 1 - band / 2),
                           (band / 2, height / 2), (width - 1 - band / 2, height / 2)]
            let low = -(line / 2), high = line - line / 2
            let reach = max(radius, arm) + line  // every mark pixel is this close to its centre
            for (cx, cy) in centres {
                for y in max(0, cy - reach)..<min(height, cy + reach + 1) {
                    let dy = y - cy
                    for x in max(0, cx - reach)..<min(width, cx + reach + 1) {
                        let dx = x - cx, distance = dx * dx + dy * dy
                        let ring = distance < radius * radius && distance >= (radius - line) * (radius - line)
                        let across = dx >= low && dx < high && abs(dy) <= arm
                        let down = dy >= low && dy < high && abs(dx) <= arm
                        if ring || across || down { mask[y * width + x] = true }
                    }
                }
            }
        }
    }

    /// A print inside a white border carrying its marks in black.
    public static func addPrintMarks(_ image: RGBImage, dpi: Double, guide: Bool, registration: Bool) -> RGBImage {
        guard guide || registration else { return image }
        let band = pyRound(printBorder * dpi)
        let width = image.width + 2 * band, height = image.height + 2 * band
        var pixels = [UInt16](repeating: UInt16(maxValue), count: width * height * 3)
        for y in 0..<image.height {
            let source = y * image.width * 3, target = ((y + band) * width + band) * 3
            pixels.replaceSubrange(target..<(target + image.width * 3), with: image.pixels[source..<(source + image.width * 3)])
        }
        for (i, on) in mask(width: width, height: height, band: band, dpi: dpi, guide: guide, registration: registration).enumerated()
        where on {
            (pixels[i * 3], pixels[i * 3 + 1], pixels[i * 3 + 2]) = (0, 0, 0)
        }
        return RGBImage(width: width, height: height, pixels: pixels)
    }
}
