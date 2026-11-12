// Parity for colour separations (against src/openquad/colour_separations.py and the session's
// colour-separated negatives). The split goes through log10, cbrt and pow, whose last bits
// can differ between numpy and the system library, so strengths are matched to 1e-9 and
// 16-bit pixels to within 1.

import Foundation
import Testing
@testable import OpenQuadCore

struct ColourSeparationParity {
    func separation(_ s: [String: Any]) throws -> ColourSeparation {
        let coats = (s["coats"] as! [[NSNumber]]).map { ColourSeparation.RGB8($0[0].intValue, $0[1].intValue, $0[2].intValue) }
        return try ColourSeparation(coats: coats, saturation: (s["saturation"] as! NSNumber).doubleValue)
    }

    func colourPhoto() throws -> Photo {
        try Photos.load(try vectorURL("photo-colour16.tif"))
    }

    /// The largest difference between two lists of 16-bit values.
    func worst(_ a: [UInt16], _ b: [Int]) -> Int {
        let differences: [Int] = zip(a, b).map { abs(Int($0) - $1) }
        return differences.max() ?? 0
    }

    @Test func pigmentsAndDefaults() throws {
        let v = try vectors("colour-separations")
        #expect((v["grid"] as! NSNumber).intValue == ColourSeparation.grid)
        let pigments = v["pigments"] as! [String: [NSNumber]]
        #expect(pigments.count == ColourSeparation.pigments.count)
        for (name, colour) in ColourSeparation.pigments {
            let expected: [Int] = pigments[name]!.map(\.intValue)
            #expect([colour.r, colour.g, colour.b] == expected, "\(name)")
        }
        #expect(v["default"] as! [String] == ColourSeparation.defaultCoats)
    }

    @Test func densitiesAndTheSplit() throws {
        for s in try vectors("colour-separations")["separations"] as! [[String: Any]] {
            let sep = try separation(s)
            #expect(sep.describe() == s["describe"] as? String)
            for (coat, expected) in zip(sep.coats, s["density"] as! [[NSNumber]]) {
                let density: [Double] = ColourSeparation.density(coat)
                let gaps: [Double] = zip(density, expected).map { abs($0 - $1.doubleValue) }
                #expect(gaps.max()! < 1e-12)
            }
            let grid: [Double] = sep.strengthLUT(grid: 5)
            let expected: [Double] = doubles(s["grid5"])
            #expect(grid.count == expected.count)
            let gaps: [Double] = zip(grid, expected).map { abs($0 - $1) }
            #expect(gaps.max()! < 1e-9, "\(sep.describe())")
        }
    }

    @Test func coatImagesAndProofOfAColourPhoto() throws {
        let photo = try colourPhoto()
        let colour = try #require(photo.colour)
        for s in try vectors("colour-separations")["separations"] as! [[String: Any]] {
            let sep = try separation(s)
            for (k, expected) in (s["coat_images"] as! [[NSNumber]]).enumerated() {
                let image: [UInt16] = sep.coatImage(colour, colour: true, coat: k)
                #expect(image.count == expected.count)
                #expect(worst(image, expected.map(\.intValue)) <= 1, "\(sep.describe()) coat \(k + 1)")
            }
            let proof: [UInt16] = sep.proof(colour, colour: true)
            #expect(worst(proof, ints(s["proof"])) <= 1, "\(sep.describe()) proof")
        }
    }

    @Test func greyIsReadAsNeutral() throws {
        let sep = ColourSeparation.makeDefault()
        let grey: [UInt16] = [0, 30000, 65535]
        let neutral: [UInt16] = grey.flatMap { [$0, $0, $0] }
        for k in 0..<3 {
            #expect(sep.coatImage(grey, colour: false, coat: k) == sep.coatImage(neutral, colour: true, coat: k))
        }
        #expect(sep.proof(grey, colour: false) == sep.proof(neutral, colour: true))
    }

    @Test func badSeparationsAndColours() throws {
        let cyan = ColourSeparation.pigment("Cyanotype blue")!
        #expect(throws: BuildError.self) { try ColourSeparation(coats: [cyan]) }
        #expect(throws: BuildError.self) { try ColourSeparation(coats: Array(repeating: cyan, count: 5)) }
        #expect(throws: BuildError.self) { try ColourSeparation(coats: [cyan, .init(300, 0, 0)]) }
        #expect(throws: BuildError.self) { try ColourSeparation(coats: [cyan, .init(255, 254, 255)]) }
        #expect(throws: BuildError.self) { try ColourSeparation(coats: [cyan, cyan], saturation: 2.5) }
        #expect(try ColourSeparation.RGB8(hex: "#b0306a") == .init(176, 48, 106))
        #expect(try ColourSeparation.RGB8(hex: " B0306A ").hex == "#B0306A")
        for bad in ["#B0306", "B0306AZ", "#GG306A"] {
            #expect(throws: BuildError.self) { try ColourSeparation.RGB8(hex: bad) }
        }
    }

    @Test func sessionSummariesAndNegatives() throws {
        let v = try vectors("colour-separations")
        var session = PrintSession()
        try session.open(try vectorURL("photo-colour16.tif"))
        session.setMode(.negative)
        (session.fit, session.ppi, session.registration) = (false, 40, true)
        session.setColourSeparation(ColourSeparation.makeDefault())
        #expect(session.negativeCount == 3 && session.separated)
        for (k, expected) in ((v["session"] as! [String: Any])["summaries"] as! [[String]]).enumerated() {
            try session.setLayer(k)
            #expect(try session.summary() == expected)
        }
        #expect(session.jobTitle == "OpenQuad: photo-colour16.tif (negative 3 of 3)")
        let print = try session.renderPrint()
        let photo = try #require(session.photo)
        let byHand = try session.renderLayer(photo.colour!, width: photo.width, height: photo.height, layer: 2, colour: true)
        #expect(print.pixels == byHand.pixels)
        #expect(try session.preview(maxSide: 10).width <= 20)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let written = try session.writeSeparations(folder, stem: "sep")
        #expect(written.map(\.lastPathComponent) == ["sep-1of3.tif", "sep-2of3.tif", "sep-3of3.tif"])
    }

    @Test func oneSeparationAtATime() throws {
        var session = PrintSession()
        session.setColourSeparation(ColourSeparation.makeDefault())
        try session.setLayer(2)
        session.setSeparation(try SeparationPlan.even(2))
        #expect(session.colourSeparation == nil && session.negativeCount == 2 && session.layer == 1)
        session.setColourSeparation(try ColourSeparation(coats: [.init(34, 74, 140), .init(242, 194, 48)]))
        #expect(session.separation == nil && session.negativeCount == 2)
        session.setColourSeparation(nil)
        #expect(session.negativeCount == 1 && !session.separated && session.layer == 0)
        let photo = try Photos.load(try vectorURL("photo-colour16.tif"))
        #expect(throws: SessionError.self) {
            try session.renderLayer(photo.colour!, width: photo.width, height: photo.height, layer: 0, colour: true)
        }
    }
}
