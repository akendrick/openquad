// Contact sheets: up to 16 photos as thumbnails on one sheet. Mirrors
// openquad/contactsheet.py. The sheet is a greyscale image the size of the printable
// area, so it prints like any photo (an inkjet print or a digital negative). Resizing is
// an exact integer box average, so the pixels match Python's; file names are drawn with
// the system font (Python uses Pillow's), so `labels: false` gives the identical sheet.

import CoreText
import Foundation

public struct SheetLayout: Sendable, Equatable {
    public enum Background: String, CaseIterable, Sendable {
        case black, white
    }

    /// Inches.
    public var width: Double
    public var height: Double
    /// Inches between thumbnails and round the edge.
    public var gap: Double
    public var background: Background
    /// Fill each cell (cropping) instead of showing whole photos.
    public var crop: Bool
    /// A 21-step greyscale wedge along the bottom.
    public var wedge: Bool
    /// The file name under each thumbnail.
    public var labels: Bool
    public var wedgeHeight = 0.3
    public var labelHeight = 0.18

    public init(width: Double = 7.5, height: Double = 10, gap: Double = 0.15, background: Background = .black,
                crop: Bool = false, wedge: Bool = false, labels: Bool = false) {
        self.width = width
        self.height = height
        self.gap = gap
        self.background = background
        self.crop = crop
        self.wedge = wedge
        self.labels = labels
    }
}

public struct SheetCell: Sendable, Equatable {
    public let left: Int
    public let top: Int
    public let width: Int
    public let height: Int
}

public struct ContactSheetError: Error, Equatable, CustomStringConvertible {
    public let description: String
}

public enum ContactSheet {
    public static let maxPhotos = 16
    public static let wedgeSteps = 21

    /// (columns, rows) that make thumbnails of this mean aspect (width / height) largest.
    public static func grid(count: Int, aspect: Double, room: (Int, Int), gap: Int, label: Int) -> (Int, Int) {
        var best = (1, count), bestScore = -1.0
        for columns in 1...max(1, count) {
            let rows = (count + columns - 1) / columns
            let cellW = (room.0 - gap * (columns - 1)) / columns
            let boxH = (room.1 - gap * (rows - 1)) / rows - label
            if cellW < 1 || boxH < 1 { continue }
            let score = min(Double(cellW), Double(boxH) * aspect) * min(Double(cellW) / aspect, Double(boxH))
            if score > bestScore { (best, bestScore) = ((columns, rows), score) }
        }
        return best
    }

    static func px(_ inches: Double, _ dpi: Double) -> Int { pyRound(inches * dpi) }

    /// Each photo's thumbnail box, and the wedge's (left, top, step width, height), for
    /// photos of these (width, height) sizes.
    public static func cells(sizes: [(Int, Int)], layout: SheetLayout, dpi: Double) throws
        -> ([SheetCell], (Int, Int, Int, Int)?) {
        guard (1...maxPhotos).contains(sizes.count) else {
            throw ContactSheetError(description: "a contact sheet takes 1-\(maxPhotos) photos, got \(sizes.count)")
        }
        let width = px(layout.width, dpi), height = px(layout.height, dpi), gap = px(layout.gap, dpi)
        let label = layout.labels ? px(layout.labelHeight, dpi) : 0
        let wedgeH = layout.wedge ? px(layout.wedgeHeight, dpi) : 0
        let roomW = width - 2 * gap
        let roomH = height - 2 * gap - (layout.wedge ? wedgeH + gap : 0)
        let noRoom = ContactSheetError(description: "no room for photos on a sheet this small")
        guard roomW >= 1, roomH >= 1 else { throw noRoom }
        let aspect = sizes.reduce(0.0) { $0 + Double($1.0) / Double($1.1) } / Double(sizes.count)
        let (columns, rows) = grid(count: sizes.count, aspect: aspect, room: (roomW, roomH), gap: gap, label: label)
        let cellW = (roomW - gap * (columns - 1)) / columns
        let cellH = (roomH - gap * (rows - 1)) / rows
        guard cellW >= 1, cellH - label >= 1 else { throw noRoom }
        let left0 = gap + (roomW - (columns * cellW + (columns - 1) * gap)) / 2
        let top0 = gap + (roomH - (rows * cellH + (rows - 1) * gap)) / 2
        let boxes = sizes.indices.map { index in
            let (row, column) = index.quotientAndRemainder(dividingBy: columns)
            return SheetCell(left: left0 + column * (cellW + gap), top: top0 + row * (cellH + gap),
                             width: cellW, height: cellH - label)
        }
        var wedge: (Int, Int, Int, Int)?
        if layout.wedge {
            let step = roomW / wedgeSteps
            wedge = (gap + (roomW - step * wedgeSteps) / 2, height - gap - wedgeH, step, wedgeH)
        }
        return (boxes, wedge)
    }

    /// `region` (left, top, width, height) of a photo (`photoWidth` wide) resized to `size`:
    /// each output pixel is the rounded mean of the source pixels its box covers (the
    /// nearest source pixel when enlarging).
    public static func resize(_ pixels: [UInt16], photoWidth: Int, region: (Int, Int, Int, Int),
                              size: (Int, Int)) -> [UInt16] {
        let (left, top, regionW, regionH) = region
        let (outW, outH) = size
        func spans(_ start: Int, _ length: Int, _ out: Int) -> [(Int, Int)] {
            (0..<out).map { i in
                let a = start + i * length / out
                return length >= out ? (a, start + (i + 1) * length / out) : (a, a + 1)
            }
        }
        let xs = spans(left, regionW, outW), ys = spans(top, regionH, outH)
        // Sums across each output column's box, row by row (exact integers).
        var across = [Int](repeating: 0, count: regionH * outW)
        for y in 0..<regionH {
            let row = (top + y) * photoWidth
            for (i, (a, b)) in xs.enumerated() {
                var sum = 0
                for x in a..<b { sum += Int(pixels[row + x]) }
                across[y * outW + i] = sum
            }
        }
        var out = [UInt16](repeating: 0, count: outW * outH)
        for (j, (c, d)) in ys.enumerated() {
            for (i, (a, b)) in xs.enumerated() {
                var sum = 0
                for y in c..<d { sum += across[(y - top) * outW + i] }
                let count = (d - c) * (b - a)
                out[j * outW + i] = UInt16((sum + count / 2) / count)
            }
        }
        return out
    }

    /// The photo sized for its cell, its size, and its (left, top) on the sheet.
    static func thumbnail(_ pixels: [UInt16], width: Int, height: Int, cell: SheetCell, crop: Bool)
        -> ([UInt16], Int, Int, Int, Int) {
        if crop {  // the largest centred part of the photo with the cell's shape
            let (regionW, regionH) = width * cell.height > height * cell.width
                ? (max(1, height * cell.width / cell.height), height) : (width, max(1, width * cell.height / cell.width))
            let region = ((width - regionW) / 2, (height - regionH) / 2, regionW, regionH)
            return (resize(pixels, photoWidth: width, region: region, size: (cell.width, cell.height)),
                    cell.width, cell.height, cell.left, cell.top)
        }
        let (outW, outH) = width * cell.height > height * cell.width
            ? (cell.width, max(1, pyRound(Double(height * cell.width) / Double(width))))
            : (max(1, pyRound(Double(width * cell.height) / Double(height))), cell.height)
        return (resize(pixels, photoWidth: width, region: (0, 0, width, height), size: (outW, outH)), outW, outH,
                cell.left + (cell.width - outW) / 2, cell.top + (cell.height - outH) / 2)
    }

    /// The contact sheet at `dpi`: greyscale (0 black .. 65535 white), row-major, with its
    /// (width, height) in pixels. `photos` are (pixels, width, height).
    public static func make(_ photos: [([UInt16], Int, Int)], names: [String] = [], layout: SheetLayout = SheetLayout(),
                            dpi: Double = 300) throws -> (pixels: [UInt16], width: Int, height: Int) {
        let (boxes, wedge) = try cells(sizes: photos.map { ($0.1, $0.2) }, layout: layout, dpi: dpi)
        let width = px(layout.width, dpi), height = px(layout.height, dpi)
        let fill = UInt16(layout.background == .black ? 0 : maxValue)
        var sheet = [UInt16](repeating: fill, count: width * height)
        for ((pixels, w, h), cell) in zip(photos, boxes) {
            let (thumb, tw, th, left, top) = thumbnail(pixels, width: w, height: h, cell: cell, crop: layout.crop)
            for y in 0..<th {
                sheet.replaceSubrange(((top + y) * width + left)..<((top + y) * width + left + tw),
                                      with: thumb[(y * tw)..<((y + 1) * tw)])
            }
        }
        if let (left, top, step, wedgeH) = wedge {
            for (index, level) in Targets.wedgeLevels(wedgeSteps).reversed().enumerated() {  // black to white
                for y in top..<(top + wedgeH) {
                    let start = y * width + left + index * step
                    for x in start..<(start + step) { sheet[x] = level }
                }
            }
        }
        if layout.labels && !names.isEmpty {
            let size = Double(max(6, pyRound(layout.labelHeight * dpi * 0.6)))
            let texts = zip(names, boxes).map { name, cell in
                (fitted(name, width: Double(cell.width), size: size), Double(cell.left),
                 Double(cell.top + cell.height + pyRound(0.03 * dpi)))
            }
            let ink = UInt16(layout.background == .black ? maxValue : 0)
            for (i, on) in TextMask.draw(texts, size: size, width: width, height: height).enumerated() where on {
                sheet[i] = ink
            }
        }
        return (sheet, width, height)
    }

    /// The image turned a quarter turn anticlockwise (a landscape sheet for a portrait page).
    public static func turnedLeft(_ pixels: [UInt16], width: Int, height: Int) -> [UInt16] {
        var out = [UInt16](repeating: 0, count: pixels.count)  // height wide, width tall
        for y in 0..<height {
            for x in 0..<width { out[(width - 1 - x) * height + y] = pixels[y * width + x] }
        }
        return out
    }

    /// `text` shortened with "…" until it is no wider than `width` points at `size`.
    static func fitted(_ text: String, width: Double, size: Double) -> String {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        func measure(_ s: String) -> Double {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
            ]))
            return CTLineGetTypographicBounds(line, nil, nil, nil)
        }
        var shown = text
        while !shown.isEmpty && measure(shown) > width { shown.removeLast() }
        if shown != text && shown.count > 1 { shown = String(shown.dropLast()) + "…" }
        return shown
    }
}
