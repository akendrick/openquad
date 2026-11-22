// Contact sheets, and saved negative setups (with their printer options and sizes).

import CoreGraphics
import Foundation
import OpenQuadCore

extension AppModel {
    // MARK: contact sheets

    /// The printable room (width, height) in inches: the page inside its margins, less the
    /// safe edge and outline for a negative, and within a set size if one is on.
    public var printableRoom: (Double, Double) {
        let (paperW, paperH) = session.page
        let border = session.negative ? session.safeEdge + session.outline : 0
        var width = paperW - 2 * session.margin - 2 * border, height = paperH - 2 * session.margin - 2 * border
        if session.fit, let box = session.maxSize {
            let (short, long) = (min(box.0, box.1) - 2 * border, max(box.0, box.1) - 2 * border)
            (width, height) = (min(width, short), min(height, long))
        }
        return (max(width, 0.5), max(height, 0.5))
    }

    /// Where made contact sheets are kept.
    public var contactSheetFolder: URL { settingsURL.deletingLastPathComponent().appendingPathComponent("contact-sheets") }

    public func contactSheet() -> ContactSheetModel {
        ContactSheetModel(room: printableRoom, units: units, folder: contactSheetFolder)
    }

    /// Print a made sheet: it becomes the photo, fitted to the page it was made for.
    public func useContactSheet(_ url: URL) {
        openPhoto(url)
        setFit(true)
    }

    // MARK: saved negative setups

    /// The saved setup the negative settings match right now, if any.
    public var currentSetup: NegativeSetup? {
        setups.first { setup in
            let curve = setupLibrary.processURL(setup)?.resolvingSymlinksInPath()
            return setup.colour == session.negativeColour && setup.mirror == session.mirror
                && abs(setup.safeEdge - session.safeEdge) < 1e-9 && abs(setup.outline - session.outline) < 1e-9
                && setup.guide == session.guide && setup.registration == session.registration
                && curve == session.processPath?.resolvingSymlinksInPath()
                && setup.printer == session.printer && setup.paper == session.paper
                && (session.printer == nil || setup.printerOptions == session.printerOptions)
                && matchesSeparation(setup)
        }
    }

    /// The separation as set now, for saving in a setup (nil for one negative).
    var currentSeparation: SetupSeparation? {
        if separationKind == .colours {
            return SetupSeparation(steps: separationSteps, splits: [], colours: colourCoats.map(\.hex),
                                   saturation: colourSaturation)
        }
        return separationSplits.isEmpty ? nil
            : SetupSeparation(steps: separationSteps, splits: separationSplits, overlap: separationOverlap)
    }

    /// Whether the separation (bands, overlap, its negatives' own curves, the coats curve) is the setup's.
    func matchesSeparation(_ setup: NegativeSetup) -> Bool {
        let resolved = { (url: URL?) in url?.resolvingSymlinksInPath() }
        guard let s = setup.separation else { return separationKind == .tones && separationSplits.isEmpty }
        let (curves, coats) = setupLibrary.separationURLs(setup)
        let same = if let colours = s.colours {
            separationKind == .colours && colours == colourCoats.map(\.hex) && abs(s.saturation - colourSaturation) < 1e-9
        } else {
            separationKind == .tones && s.steps == separationSteps && s.splits == separationSplits
                && abs(s.overlap - separationOverlap) < 1e-9
        }
        return same
            && curves.mapValues { $0.resolvingSymlinksInPath() } == session.layerProcessPaths.mapValues { $0.resolvingSymlinksInPath() }
            && resolved(coats) == resolved(session.coatsCurvePath)
    }

    /// Switch to a saved setup: its curve, colour, mirror, edges, printer and paper.
    public func applySetup(_ setup: NegativeSetup) {
        setMode(.negative)
        setPaper(setup.paper)
        setPrinter(setup.printer)
        if setup.printer != nil, !setup.printerOptions.isEmpty {
            for (keyword, value) in setup.printerOptions { setPrinterOption(keyword, value) }
        }
        if let curve = setupLibrary.processURL(setup) {
            setProcess(curve)
        } else {
            setProcess(nil)
            setNegativeColour(setup.colour)
        }
        session.mirror = setup.mirror
        session.guide = setup.guide
        session.registration = setup.registration
        setSafeEdge(setup.safeEdge)
        if setup.outline > 0 { outlineSize = setup.outline }
        setOutline(setup.outline > 0)
        applySeparation(of: setup)
    }

    /// The setup's separation (or one negative), with its negatives' own curves and the coats curve.
    func applySeparation(of setup: NegativeSetup) {
        let (curves, coats) = setupLibrary.separationURLs(setup)
        if let s = setup.separation, let colours = try? s.coatColours() {
            // Worked out here and now, so its negatives are there for their curves.
            (separationKind, colourCoats, colourSaturation) = (.colours, colours, s.saturation)
            colourToken += 1
            separatingColours = false
            attempt { session.setColourSeparation(try ColourSeparation(coats: colours, saturation: s.saturation)) }
        } else {
            separationKind = .tones
            if let s = setup.separation {
                (separationSteps, separationSplits, separationOverlap) = (s.steps, s.splits, s.overlap)
            } else {
                separationSplits = []
            }
            applySeparation()
        }
        attempt {
            for k in 0..<session.negativeCount { try session.setLayerProcess(k, curves[k]) }
            try session.setCoatsCurve(coats)
        }
        refreshPreview()
    }

    /// A name to offer when saving: "Carbon, green, Letter".
    public var suggestedSetupName: String {
        let process = session.process.map(\.process).flatMap { $0.isEmpty ? nil : $0.capitalized } ?? "Negative"
        return "\(process), \(session.negativeColour), \(session.paper)"
    }

    /// Save the negative settings as a setup (replacing one of the same name).
    public func saveSetup(named name: String) {
        attempt {
            let setup = NegativeSetup(name: name, colour: session.negativeColour, mirror: session.mirror,
                                      safeEdge: session.safeEdge, outline: session.outline, guide: session.guide,
                                      registration: session.registration, printer: session.printer,
                                      printerOptions: session.printer == nil ? [:] : session.printerOptions, paper: session.paper,
                                      separation: currentSeparation)
            let separated = session.separated || separationKind == .colours
            try setupLibrary.save(setup, process: session.processPath,
                                  layerProcesses: separated ? session.layerProcessPaths : [:],
                                  coats: separated ? session.coatsCurvePath : nil)
            setups = setupLibrary.all()
            forgetKnownCurves()
            // Point at the setup's own copies of the curves, so the setup shows as chosen.
            if let saved = setups.first(where: { $0.name == name.trimmingCharacters(in: .whitespacesAndNewlines) }) {
                if let curve = setupLibrary.processURL(saved) {
                    try session.setProcess(curve)
                    remember()
                }
                let (curves, coats) = setupLibrary.separationURLs(saved)
                for (k, url) in curves { try session.setLayerProcess(k, url) }
                if let coats { try session.setCoatsCurve(coats) }
            }
        }
    }

    public func deleteSetup(_ setup: NegativeSetup) {
        attempt {
            try setupLibrary.delete(setup)
            setups = setupLibrary.all()
            forgetKnownCurves()
        }
    }

    public func setPaper(_ paper: String) {
        attempt {
            try session.setPaper(paper)
            remember()
        }
        matchCalibration()
        refreshPreview()
    }

    /// The page turned on its side (landscape), or upright (portrait).
    public func setLandscape(_ on: Bool) {
        session.landscape = on
        if session.placed { try? session.setPlacement(try session.pagePosition()) }  // kept inside the margins
        remember()
        refreshPreview()
    }

    /// A CUPS printer to print to directly, or nil to choose in the macOS print panel.
    public func setPrinter(_ name: String?) {
        session.printer = name
        let negative = role == .negative
        saveSettings { if negative { $0.negativePrinter = name } else { $0.printer = name } }
        loadPrinterOptions()
        matchCalibration()
    }


    /// Look up the printer's options and use what was last chosen for it (for this tab).
    func loadPrinterOptions() {
        guard let printer = session.printer else {
            (printerMedia, printerQuality, session.printerOptions) = (nil, nil, [:])
            return
        }
        (printerMedia, printerQuality) = Printing.mediaAndQuality(readPrinterOptions(printer))
        let saved = (role == .negative ? settings.negativePrinterOptions : settings.printerOptions)[printer] ?? [:]
        let options = [printerMedia, printerQuality].compactMap { $0 }
        session.printerOptions = saved.filter { keyword, value in  // only what this printer still offers
            options.contains { $0.keyword == keyword && $0.choices.contains { $0.value == value } }
        }
    }

    /// Choose a media type or quality for the printer (nil: the printer's own default). Remembered for the printer.
    public func setPrinterOption(_ keyword: String, _ value: String?) {
        guard let printer = session.printer else { return }
        session.printerOptions[keyword] = value
        let chosen = session.printerOptions, negative = role == .negative
        saveSettings {
            if negative { $0.negativePrinterOptions[printer] = chosen } else { $0.printerOptions[printer] = chosen }
        }
    }

    /// "Media type: Matte Photo Paper", "Quality: High": what's chosen for printing straight to the printer.
    public var printerOptionLines: [String] {
        [("Media type", printerMedia), ("Quality", printerQuality)].compactMap { title, option in
            guard let option else { return nil }
            let value = session.printerOptions[option.keyword]
            return "\(title): " + (value.map(option.name(of:)) ?? "printer default" + (option.defaultValue.map { " (\(option.name(of: $0)))" } ?? ""))
        }
    }

    public func setFit(_ on: Bool) {
        session.fit = on
        refreshPreview()
    }

    /// Fit within a set size (inches; the tissue's, for a negative), or nil for the page.
    /// Remembered, as the tissue rarely changes.
    public func setMaxSize(_ size: (Double, Double)?) {
        if let size, !(size.0 > 0 && size.1 > 0) { return }
        session.maxSize = size
        saveSettings { $0.maxSize = size.map { [$0.0, $0.1] } }
        refreshPreview()
    }

    /// The last set size, to offer when switching from the page to a set size.
    public var rememberedMaxSize: (Double, Double) {
        session.maxSize ?? settings.maxSize.flatMap { $0.count == 2 ? ($0[0], $0[1]) : nil } ?? (8, 10)
    }

    public func setPPI(_ ppi: Double?) {
        session.ppi = ppi.flatMap { $0 > 0 ? $0 : nil }
        refreshPreview()
    }
}
