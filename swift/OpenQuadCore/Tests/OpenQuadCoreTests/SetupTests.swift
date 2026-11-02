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
