// Contact sheets matched against openquad/contactsheet.py: grids, cells, resizing and
// whole sheets (without file names, which each side draws with its own font).

import CryptoKit
import Foundation
import Testing
@testable import OpenQuadCore

/// The made-up photo export_swift_vectors.py builds the same way.
func sheetPhoto(_ width: Int, _ height: Int, _ seed: Int) -> [UInt16] {
    var pixels = [UInt16](repeating: 0, count: width * height)
    for y in 0..<height {
        for x in 0..<width { pixels[y * width + x] = UInt16((x * 977 + y * 613 + seed * 4999) % 65536) }
    }
    return pixels
}

func sha256(_ pixels: [UInt16]) -> String {
    let bytes = pixels.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }
    return SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
}

@Suite("Contact sheet parity")
struct ContactSheetParityTests {
    @Test func resizingMatches() throws {
        let v = try vectors("contactsheet")
        let sample = sheetPhoto(7, 5, 3)
        #expect(sample.map(Int.init) == (v["sample"] as! [NSNumber]).map(\.intValue))
        for r in v["resizes"] as! [[String: Any]] {
            let region = (r["region"] as! [NSNumber]).map(\.intValue), size = (r["size"] as! [NSNumber]).map(\.intValue)
            let out = ContactSheet.resize(sample, photoWidth: 7, region: (region[0], region[1], region[2], region[3]),
                                          size: (size[0], size[1]))
            #expect(out.map(Int.init) == (r["pixels"] as! [NSNumber]).map(\.intValue), "\(region) -> \(size)")
        }
    }

    @Test func gridsMatch() throws {
        for g in try vectors("contactsheet")["grids"] as! [[String: Any]] {
            let room = (g["room"] as! [NSNumber]).map(\.intValue)
            let found = ContactSheet.grid(count: (g["count"] as! NSNumber).intValue, aspect: (g["aspect"] as! NSNumber).doubleValue,
                                          room: (room[0], room[1]), gap: (g["gap"] as! NSNumber).intValue,
                                          label: (g["label"] as! NSNumber).intValue)
            #expect([found.0, found.1] == (g["grid"] as! [NSNumber]).map(\.intValue))
        }
    }

    @Test func sheetsMatch() throws {
        let cases = try vectors("contactsheet")["cases"] as! [[String: Any]]
        #expect(cases.count == 5)
        for c in cases {
            let sizes = (c["sizes"] as! [[NSNumber]]).map { ($0[0].intValue, $0[1].intValue) }
            let l = c["layout"] as! [String: Any]
            var layout = SheetLayout(width: (l["width"] as! NSNumber).doubleValue, height: (l["height"] as! NSNumber).doubleValue)
            if let gap = l["gap"] as? NSNumber { layout.gap = gap.doubleValue }
            if let background = l["background"] as? String { layout.background = SheetLayout.Background(rawValue: background)! }
            layout.crop = l["crop"] as? Bool ?? false
            layout.wedge = l["wedge"] as? Bool ?? false
            layout.labels = l["labels"] as? Bool ?? false
            let dpi = (c["dpi"] as! NSNumber).doubleValue
            let (boxes, wedge) = try ContactSheet.cells(sizes: sizes, layout: layout, dpi: dpi)
            #expect(boxes.map { [$0.left, $0.top, $0.width, $0.height] } == (c["cells"] as! [[NSNumber]]).map { $0.map(\.intValue) })
            let expectedWedge = (c["wedge"] as? [NSNumber])?.map(\.intValue)
            #expect(wedge.map { [$0.0, $0.1, $0.2, $0.3] } == expectedWedge)
            layout.labels = false
            let photos = sizes.enumerated().map { i, size in (sheetPhoto(size.0, size.1, i), size.0, size.1) }
            let sheet = try ContactSheet.make(photos, layout: layout, dpi: dpi)
            let digest = c["sheet"] as! [String: Any]
            #expect([sheet.height, sheet.width] == (digest["shape"] as! [NSNumber]).map(\.intValue))
            #expect(sha256(sheet.pixels) == digest["sha256"] as? String)
        }
    }

    @Test func labelsTooManyPhotosAndNoRoom() throws {
        let photo = (sheetPhoto(30, 20, 0), 30, 20)
        let named = try ContactSheet.make([photo], names: ["frame-01.tif"], layout: SheetLayout(width: 3, height: 3, labels: true),
                                          dpi: 100)
        #expect(named.pixels.contains(65535))
        #expect(ContactSheet.turnedLeft([1, 2, 3, 4, 5, 6], width: 3, height: 2) == [3, 6, 2, 5, 1, 4])
        #expect(ContactSheet.fitted(String(repeating: "x", count: 200), width: 50, size: 10).hasSuffix("…"))
        #expect(throws: ContactSheetError.self) { try ContactSheet.make(Array(repeating: photo, count: 17)) }
        #expect(throws: ContactSheetError.self) {
            try ContactSheet.make([photo], layout: SheetLayout(width: 0.2, height: 0.2, gap: 0.1), dpi: 100)
        }
    }
}
