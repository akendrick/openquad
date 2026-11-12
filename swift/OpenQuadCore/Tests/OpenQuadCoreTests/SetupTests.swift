// Saved negative setups: saving with a copy of the curve, listing, replacing, deleting.

import Foundation
import Testing
@testable import OpenQuadCore

@Suite("Negative setups")
struct SetupTests {
    @Test func savesWithItsOwnCopyOfTheCurve() throws {
        let folder = try temporaryFolder()
        let library = SetupLibrary(folder: folder.appendingPathComponent("setups"))
        #expect(library.all().isEmpty)
        let curveFile = folder.appendingPathComponent("cyanotype.oqproc")
        try ProcessCurve.identity(colour: "orange").encode().write(to: curveFile)
        let setup = NegativeSetup(name: "  Cyanotype on Pictorico ", colour: "orange", mirror: true, safeEdge: 0.3,
                                  outline: 0.08, printer: "Epson_ET_2900", paper: "A4")
        let saved = try library.save(setup, process: curveFile)
        #expect(saved.name == "Cyanotype on Pictorico" && saved.process == "cyanotype-on-pictorico.oqproc" && !saved.created.isEmpty)
        try FileManager.default.removeItem(at: curveFile)  // the setup keeps working without the original
        let listed = try #require(library.all().first)
        #expect(listed == saved)
        let copy = try #require(library.processURL(listed))
        #expect(try ProcessCurve.decode(Data(contentsOf: copy)).colour == "orange")

        var black = NegativeSetup(name: "Carbon", colour: "black")
        black = try library.save(black, process: nil)
        #expect(library.all().map(\.name) == ["Carbon", "Cyanotype on Pictorico"] && black.process == nil)
        var changed = listed
        changed.mirror = false
        try library.save(changed, process: copy)  // re-saving with its own curve
        #expect(library.all().count == 2 && library.all()[1].mirror == false)
        #expect(FileManager.default.fileExists(atPath: copy.path))
        try library.delete(library.all()[1])
        #expect(library.all().map(\.name) == ["Carbon"] && !FileManager.default.fileExists(atPath: copy.path))
    }

    @Test func keepsASeparationWithItsCurves() throws {
        let folder = try temporaryFolder()
        let library = SetupLibrary(folder: folder.appendingPathComponent("setups"))
        let curve = { (name: String) -> URL in
            let url = folder.appendingPathComponent(name)
            try? ProcessCurve.identity(colour: "green").encode().write(to: url)
            return url
        }
        let gum = NegativeSetup(name: "Gum, 3 coats", colour: "green", registration: true,
                                separation: SetupSeparation(steps: 30, splits: [8, 19], overlap: 1.5))
        let saved = try library.save(gum, process: curve("base.oqproc"), layerProcesses: [2: curve("deep.oqproc")],
                                     coats: curve("coats-2.oqproc"))
        let separation = try #require(saved.separation)
        #expect(separation.curves == [2: "gum-3-coats.neg3.oqproc"] && separation.coats == "gum-3-coats.coats.oqproc")
        let listed = try #require(library.all().first)
        #expect(listed == saved && listed.separation?.splits == [8, 19] && listed.separation?.overlap == 1.5)
        #expect(try listed.separation?.plan().describe() == "3 negatives, split at steps 8 and 19 of 30, overlap 1.5 steps")
        let (curves, coats) = library.separationURLs(listed)
        #expect(curves[2].map { FileManager.default.fileExists(atPath: $0.path) } == true)
        #expect(coats.map { FileManager.default.fileExists(atPath: $0.path) } == true)
        // Saved again without the third negative's own curve or a coats curve: their copies go.
        try library.save(listed, process: library.processURL(listed))
        #expect(library.all().first?.separation?.curves.isEmpty == true && library.all().first?.separation?.coats == nil)
        #expect(!FileManager.default.fileExists(atPath: curves[2]!.path) && !FileManager.default.fileExists(atPath: coats!.path))
        // A setup with a similar name keeps its own curve when this one is deleted.
        try library.save(NegativeSetup(name: "Gum 3 coats neg", colour: "green"), process: curve("other.oqproc"))
        try library.delete(library.all().first { $0.name == "Gum, 3 coats" }!)
        #expect(library.all().map(\.name) == ["Gum 3 coats neg"])
        #expect(library.processURL(library.all()[0]).map { FileManager.default.fileExists(atPath: $0.path) } == true)
        // A one-negative setup stays as it was saved before separations.
        let plain = try NegativeSetup(name: "x", colour: "green").encode()
        #expect(!String(decoding: plain, as: UTF8.self).contains("separation"))
    }

    @Test func keepsAColourSeparationWithItsCurves() throws {
        let folder = try temporaryFolder()
        let library = SetupLibrary(folder: folder.appendingPathComponent("setups"))
        let curve = folder.appendingPathComponent("gum.oqproc")
        try ProcessCurve.identity(colour: "green").encode().write(to: curve)
        let tricolour = NegativeSetup(name: "Tricolour gum", colour: "green", registration: true,
                                      separation: SetupSeparation(steps: 30, splits: [], curves: [:],
                                                                  colours: ["#224A8C", "#B0306A", "#F2C230"], saturation: 1.5))
        let saved = try library.save(tricolour, process: nil, layerProcesses: [2: curve])
        #expect(saved.separation?.curves == [2: "tricolour-gum.neg3.oqproc"])
        let listed = try #require(library.all().first)
        #expect(listed == saved && listed.separation?.count == 3 && listed.separation?.saturation == 1.5)
        #expect(try listed.separation?.coatColours() == [.init(34, 74, 140), .init(176, 48, 106), .init(242, 194, 48)])
        #expect(try SetupSeparation(steps: 30, splits: [10]).coatColours() == nil)
    }

    @Test func badSeparationsAreRefused() throws {
        var json = try JSONSerialization.jsonObject(with: NegativeSetup(name: "x", colour: "green").encode()) as! [String: Any]
        for bad: [String: Any] in [["steps": 30, "splits": [20, 10], "overlap": 0],
                                   ["steps": 30, "splits": [10], "overlap": 0, "curves": ["3": "a.oqproc"]],
                                   ["steps": 30, "splits": [10, 20], "overlap": 11],
                                   ["steps": 30, "splits": [], "overlap": 0, "colours": ["#224A8C"]],
                                   ["steps": 30, "splits": [], "overlap": 0, "colours": ["#224A8C", "#FFFFFF"]],
                                   ["steps": 30, "splits": [], "overlap": 0, "colours": ["#224A8C", "nope"]],
                                   ["steps": 30, "splits": [], "overlap": 0, "colours": ["#224A8C", "#B0306A"], "saturation": 3],
                                   ["steps": 30, "splits": [], "overlap": 0, "colours": ["#224A8C", "#B0306A"],
                                    "curves": ["3": "a.oqproc"]]] {
            json["separation"] = bad
            #expect(throws: FileFormatError.self) { try NegativeSetup.decode(JSONSerialization.data(withJSONObject: json)) }
        }
    }

    @Test func badSetupsAreRefused() throws {
        let library = SetupLibrary(folder: try temporaryFolder())
        #expect(throws: FileFormatError.self) { try library.save(NegativeSetup(name: " ", colour: "green"), process: nil) }
        let good = try NegativeSetup(name: "x", colour: "green").encode()
        let text = String(decoding: good, as: UTF8.self)
        for (from, to) in [("\"green\"", "\"purple\""), ("\"Letter\"", "\"Tabloid\""), ("openquad-setup", "other")] {
            #expect(throws: FileFormatError.self) { try NegativeSetup.decode(Data(text.replacingOccurrences(of: from, with: to).utf8)) }
        }
        #expect(SetupLibrary.slug("B&W / 8×10!") == "b-w-8-10")
    }
}
