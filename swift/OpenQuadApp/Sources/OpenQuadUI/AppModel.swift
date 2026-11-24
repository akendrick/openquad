// The print window's state: a thin layer over OpenQuadCore's PrintSession, like the
// Python app's window over openquad.session. Slow work (previews, full renders) runs
// off the main thread; toning is never remembered, so every launch starts neutral.

import CoreGraphics
import Foundation
import Observation
import OpenQuadCore

public let presetLabels: [(String, String)] = [
    ("neutral", "Neutral (no toning)"),
    ("black-red", "Black + red duotone"),
    ("red-only", "Red only"),
    ("warm-split", "Warm split tone"),
]

public let paperOrder = ["Letter", "Legal", "A4", "A5", "4x6", "5x7", "8x10"]

/// Which tab a model serves: the Print tab or the Negative tab. Each keeps its own photo,
/// printer and paper; the rest of the settings are shared.
public enum TabRole: Sendable {
    case print, negative
}

@MainActor
@Observable
public final class AppModel {
    public let role: TabRole
    public internal(set) var session = PrintSession()
    public private(set) var settings: AppSettings
    public private(set) var preview: CGImage?
    public internal(set) var busy = false
    public var error: String?
    /// The last thing that happened (e.g. a print job sent), for the status line.
    public var status: String?
    /// A new process curve is in use: offer to save it as a setup (Negative tab).
    public var setupOffer: String?
    /// CUPS printers on this Mac, for printing without the print panel.
    public private(set) var printers: [String] = []
    /// Printer and paper ICC profiles on this Mac, to soft-proof a colour print with.
    public private(set) var proofProfiles: [ProofProfile] = []
    /// Saved calibrations to choose from: the newest of each printer and paper.
    public private(set) var calibrations: [LibraryEntry] = []
    /// OpenQuad printer profiles for colour prints: the newest of each printer and paper.
    public private(set) var colourProfiles: [ColourProfileEntry] = []
    public let library: CalibrationLibrary
    /// Saved negative setups (process curve, colour, mirror, edges, printer, paper).
    public let setupLibrary: SetupLibrary
    public internal(set) var setups: [NegativeSetup] = []
    let settingsURL: URL
    private var previewToken = 0

    public init(settingsURL: URL = AppSettings.defaultURL(), libraryFolder: URL? = nil, setupsFolder: URL? = nil,
                role: TabRole = .print) {
        self.role = role
        self.settingsURL = settingsURL
        library = CalibrationLibrary(folder: libraryFolder
            ?? settingsURL.deletingLastPathComponent().appendingPathComponent("calibrations"))
        setupLibrary = SetupLibrary(folder: setupsFolder
            ?? settingsURL.deletingLastPathComponent().appendingPathComponent("setups"))
        setups = setupLibrary.all()
        settings = AppSettings.load(settingsURL)
        restore()
        refreshLibrary()
        session.setMode(role == .negative ? .negative : .print)
    }

    /// Change the settings file: re-read it first, as the other tab may have changed it.
    func saveSettings(_ change: (inout AppSettings) -> Void) {
        settings = AppSettings.load(settingsURL)
        change(&settings)
        try? settings.save(settingsURL)
    }

    /// Re-read the calibrations folder (after a wizard or an import).
    public func refreshLibrary() {
        var entries = library.latest()
        if let path = session.calibrationPath, let current = CalibrationLibrary.entry(path),
           !entries.contains(where: { $0.url == current.url }) {
            entries.append(current)  // an older version, or a file kept elsewhere
        }
        calibrations = entries
        var profiles = library.latestColourProfiles()
        if let path = session.colourProfilePath, let current = library.colourProfile(path),
           !profiles.contains(where: { $0.url == current.url }) {
            profiles.append(current)
        }
        colourProfiles = profiles
    }

    /// The library entry for the calibration in use, if any.
    public var currentCalibration: LibraryEntry? {
        session.calibrationPath.flatMap { path in
            let resolved = path.resolvingSymlinksInPath()
            return calibrations.first { $0.url == resolved } ?? CalibrationLibrary.entry(path)
        }
    }

    /// Copy a calibration file into the library and use it.
    public func importCalibration(_ url: URL) {
        attempt {
            let entry = try library.importFile(url)
            try session.setCalibration(entry.url)
            remember()
            status = "Added \(entry.label) to your calibrations."
        }
        refreshLibrary()
    }

    /// When printing straight to a printer, use the newest calibration made for it and
    /// this paper; drop a calibration made for another printer.
    func matchCalibration() {
        guard role == .print, let printer = session.printer else { return }  // negatives use process curves
        if let match = library.match(printer: printer, paper: session.paper) {
            if match.url != session.calibrationPath?.resolvingSymlinksInPath() {
                attempt { try session.setCalibration(match.url) }
                status = "Using \(match.label) for this printer."
            }
        } else if let current = session.calibration, current.printer != printer {
            attempt { try session.setCalibration(nil) }
            status = "No calibration for \(LibraryEntry.printerName(printer)) on \(session.paper) yet: it will print uncorrected."
        }
        matchColourProfile(printer)
        remember()
        refreshLibrary()
    }

    /// Told the CUPS printers when they have been looked up (for the printer calibration).
    @ObservationIgnored var printersLoaded: (([String]) -> Void)?

    /// Look up the CUPS printers (off the main thread; none if CUPS isn't there).
    public func loadPrinters(_ list: @escaping @Sendable () throws -> [String] = { try Printing.listPrinters() }) async {
        let found = await Task.detached { (try? list()) ?? [] }.value
        printers = found
        printersLoaded?(found)
    }

    public func loadPrinters() { Task { await loadPrinters { try Printing.listPrinters() } } }

    /// Look up the printer and paper ICC profiles (off the main thread).
    public func loadProofProfiles(_ list: @escaping @Sendable () -> [ProofProfile] = { SoftProof.profiles() }) {
        Task {
            proofProfiles = await Task.detached { list() }.value
        }
    }

    func restore() {
        try? session.setPaper(role == .negative ? settings.negativePaper ?? settings.paper : settings.paper)
        session.landscape = role == .negative ? settings.negativeLandscape : settings.landscape
        if let path = settings.calibration, FileManager.default.fileExists(atPath: path) {
            try? session.setCalibration(URL(fileURLWithPath: path))
        }
        if role == .print, let path = settings.colourProfile, FileManager.default.fileExists(atPath: path) {
            try? session.setColourProfile(URL(fileURLWithPath: path))
        }
        if let path = settings.process, FileManager.default.fileExists(atPath: path) {
            try? session.setProcess(URL(fileURLWithPath: path))
        } else {
            try? session.setNegativeColour(settings.negativeColour)
        }
        session.printer = role == .negative ? settings.negativePrinter ?? settings.printer : settings.printer
        loadPrinterOptions()
        if let wedge = role == .negative ? settings.negativeWedge : settings.printWedge {
            session.wedge = wedge.grey
            session.colourWedge = wedge.colour
            try? session.setWedgeSide(wedge.side)
            try? session.setWedgeGap(wedge.gap)
            session.wedgeSeparate = wedge.separate
            try? session.setWedgeSteps(wedge.steps)
            try? session.setWedgeWidth(wedge.width)
            try? session.setWedgeStyle(wedge.style)
            session.wedgeLabels = wedge.labels
            try? session.setWedgeBackground(wedge.background)
        }
        session.marksInFit = role == .negative ? settings.negativeMarksInFit : settings.marksInFit
        if let size = settings.maxSize, size.count == 2 { session.maxSize = (size[0], size[1]) }
        session.units = settings.units
    }

    /// Lengths shown and typed in the app (the session keeps inches). Remembered.
    public var units: LengthUnit { settings.units }

    public func setUnits(_ units: LengthUnit) {
        session.units = units
        saveSettings { $0.units = units }
    }

    /// Take up the unit the other tab chose.
    public func followUnits() { session.units = AppSettings.load(settingsURL).units }

    func remember() {
        let session = session
        saveSettings { settings in
            if session.negative {
                settings.negativePaper = session.paper
                settings.negativeLandscape = session.landscape
                settings.process = session.processPath?.path
                settings.negativeColour = session.negativeColour
            } else {
                settings.paper = session.paper
                settings.landscape = session.landscape
                settings.calibration = session.calibrationPath?.path
            }
            settings.lastFolder = session.source?.deletingLastPathComponent().path ?? settings.lastFolder
        }
    }

    func attempt(_ work: () throws -> Void) {
        do {
            try work()
            error = nil
        } catch {
            self.error = String(describing: error)
        }
    }

    // State the feature extensions keep (stored properties must be declared here).

    /// The separation as shown: split points and overlap counted on a step scale.
    public internal(set) var separationSteps = SeparationPlan.defaultSteps

    public internal(set) var separationSplits: [Int] = []

    public internal(set) var separationOverlap = 0.0

    /// Split the negative by tone (bands of the greyscale) or by colour (one negative per pigment).
    public internal(set) var separationKind = SeparationKind.tones

    /// The colour separation as shown: each coat's pigment colour, in print order, and the saturation.
    public internal(set) var colourCoats: [ColourSeparation.RGB8] = ColourSeparation.defaultCoats.map { ColourSeparation.pigment($0)! }

    public internal(set) var colourSaturation = 1.0

    /// The colour separation is being worked out (off the main thread).
    public internal(set) var separatingColours = false

    var colourToken = 0

    /// The negative to show once the colour separation is worked out.
    var pendingLayer: Int?

    /// Show every coat of the separation together on the photo, each in its own colour,
    /// instead of the negative that prints.
    public internal(set) var showCoats = false

    /// Show the negative on its page, where it will print, to move it about.
    public internal(set) var showOnPage = false

    @ObservationIgnored var knownCurvesCache = Cached<[KnownCurve]>()

    /// The chosen printer's media type and quality options (from its PPD), when printing
    /// straight to it; nil for the print panel, which has its own, or a printer without them.
    public internal(set) var printerMedia: PrinterOption?

    public internal(set) var printerQuality: PrinterOption?

    /// Reads a printer's options; replaced in tests.
    @ObservationIgnored var readPrinterOptions: (String) -> [PrinterOption] = { (try? Printing.printerOptions($0)) ?? [] }

    // MARK: choosing things

    public func openPhoto(_ url: URL) {
        guard Xcf.isXcf(url) else {
            attempt {
                try session.open(url)
                remember()
            }
            refreshPreview()
            return
        }
        // GIMP takes a few seconds to merge an XCF: do it off the main thread.
        let token = UUID()
        openingToken = token
        openingInGIMP = url.lastPathComponent
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try Photos.load(url) } }.value
            guard openingToken == token else { return }
            openingInGIMP = nil
            attempt {
                session.open(url, photo: try result.get())
                remember()
            }
            refreshPreview()
        }
    }

    /// The XCF being opened through GIMP, if any (its file name).
    public private(set) var openingInGIMP: String?
    private var openingToken: UUID?

    public func setPreset(_ name: String) {
        attempt { try session.setPreset(name) }
        refreshPreview()
    }

    public func setCalibration(_ url: URL?) {
        attempt {
            try session.setCalibration(url)
            remember()
        }
        refreshLibrary()
    }

    /// The photo is colour and this is the Print tab: it can be printed in colour.
    public var canPrintColour: Bool { role == .print && session.photo?.colour != nil }

    /// Print the colour photo in colour on a colour-managed printer, or in greyscale.
    public func setColourPrint(_ on: Bool) {
        attempt { try session.setColourPrint(on) }
        refreshPreview()
    }

    /// The profile colour prints are soft-proofed with in the preview (nil: none). Remembered.
    public var proofProfile: URL? { settings.proofProfile.map { URL(fileURLWithPath: $0) } }

    public func setProofProfile(_ url: URL?) {
        saveSettings { $0.proofProfile = url?.path }
        refreshPreview()
    }

    // MARK: colour profiles (colour calibration)

    /// The library entry for the printer profile colour prints go through, if any.
    public var currentColourProfile: ColourProfileEntry? {
        session.colourProfilePath.flatMap { path in
            colourProfiles.first { $0.url == path.resolvingSymlinksInPath() } ?? library.colourProfile(path)
        }
    }

    /// The profiles to offer: this printer's (all of them when printing through the panel).
    public var colourProfileChoices: [ColourProfileEntry] {
        guard let printer = session.printer else { return colourProfiles }
        return colourProfiles.filter { $0.printer == printer || $0.url == currentColourProfile?.url }
    }

    /// Convert colour prints through an OpenQuad printer profile (nil: macOS's). Remembered.
    public func setColourProfile(_ url: URL?) {
        attempt {
            try session.setColourProfile(url)
            saveSettings { $0.colourProfile = url?.path }
        }
        refreshLibrary()
        refreshPreview()
    }

    /// Use the newest profile made for this printer and paper; drop one made for another printer.
    func matchColourProfile(_ printer: String) {
        if let match = library.matchColourProfile(printer: printer, paper: session.paper) {
            if match.url != session.colourProfilePath?.resolvingSymlinksInPath() {
                attempt { try session.setColourProfile(match.url) }
                saveSettings { $0.colourProfile = match.url.path }
            }
        } else if let current = currentColourProfile, current.printer != printer {
            attempt { try session.setColourProfile(nil) }
            saveSettings { $0.colourProfile = nil }
        }
    }

    /// Copy the profile in use to ~/Library/ColorSync/Profiles, for other apps.
    public func exportColourProfile(folder: URL? = nil) {
        guard let entry = currentColourProfile else { return }
        attempt {
            let url = try library.exportToColorSync(entry, folder: folder)
            status = "Copied to \(url.deletingLastPathComponent().path) as \(url.lastPathComponent): other apps can use it now."
        }
        loadProofProfiles()
    }

    /// A finished colour calibration: colour prints go through its profile.
    public func finishColourProfile(_ path: URL, scannerHost: String) {
        if !scannerHost.isEmpty { saveSettings { $0.scannerHost = scannerHost } }
        refreshLibrary()
        setColourProfile(path)
        if let entry = currentColourProfile { status = "Colour prints now go through \(entry.label)." }
    }

    /// What the preview shows, when it isn't simply the print: a colour print, soft-proofed or not.
    public var previewCaption: String? {
        if showingPage {
            if session.placement != nil && !session.placed { return "On the page: too big to move inside the margins" }
            return "On the page: drag the negative to move it (it stays inside the margins)"
        }
        if showingCoats {
            if session.colourSeparation != nil {
                return "All \(session.negativeCount) coats together, in their pigments' colours (prints one negative at a time)"
            }
            return "All \(session.negativeCount) coats together, each in its own colour (prints one negative at a time)"
        }
        guard session.printsColour else { return nil }
        if let current = currentColourProfile {
            return "Soft-proof: through \(current.label), as it will print"
        }
        guard let url = proofProfile else { return "Colour print: the photo's own colours, colour-managed by macOS" }
        let name = proofProfiles.first { $0.url == url }?.name ?? url.deletingPathExtension().lastPathComponent
        return "Soft-proof: \(name)"
    }

    public func setMode(_ mode: OutputMode) {
        session.setMode(mode)
        refreshPreview()
    }

    public func setNegativeColour(_ colour: String) {
        attempt {
            try session.setNegativeColour(colour)
            remember()
        }
        refreshPreview()
    }

    public func setProcess(_ url: URL?) {
        attempt {
            try session.setProcess(url)
            remember()
        }
        refreshPreview()
    }

    public func setMirror(_ on: Bool) {
        session.mirror = on
        refreshPreview()
    }

    /// Fit the marks' border (safe edge, outline, a print's white border) within the printable
    /// area with the photo, or fit the photo alone and let the border lie outside it. Remembered.
    public func setMarksInFit(_ on: Bool) {
        session.marksInFit = on
        let negative = role == .negative
        saveSettings { if negative { $0.negativeMarksInFit = on } else { $0.marksInFit = on } }
        refreshPreview()
    }

    public func setSafeEdge(_ inches: Double) {
        session.safeEdge = min(max(inches, 0), 2)
        refreshPreview()
    }

    /// The black guide line round the image (in a negative's safe edge, or a white border
    /// round a print), visible under a red safelight.
    public func setGuide(_ on: Bool) {
        session.guide = on
        refreshPreview()
    }

    /// Crosshair targets and corner crop marks, for lining the sheet up in the darkroom.
    public func setRegistration(_ on: Bool) {
        session.registration = on
        refreshPreview()
    }

    /// The black outline's width, kept while it is turned off so turning it back on restores it.
    public internal(set) var outlineSize = 0.1

    /// Turn the black outline (between the safe edge and the photo) on or off.
    public func setOutline(_ on: Bool) {
        session.outline = on ? outlineSize : 0
        refreshPreview()
    }

    public func setOutlineSize(_ inches: Double) {
        outlineSize = min(max(inches, 0.01), 1)
        if session.outline > 0 { session.outline = outlineSize }
        refreshPreview()
    }

    // MARK: what the window shows

    public var photoDescription: String {
        guard let photo = session.photo, let source = session.source else { return "No photo open" }
        var text = "\(source.lastPathComponent): \(photo.width) x \(photo.height) px"
        if let dpi = photo.dpi { text += String(format: ", %.0f ppi", dpi.0) }
        return ([text] + session.notes).joined(separator: "\n")
    }

    /// The photo's own resolution and the size it makes, e.g. "300 ppi (4 x 2.66 in)", or
    /// that it has none (and what's used instead). Nil with no photo open.
    /// The resolution the print is made at: the fit's when fitting, else the one set or the photo's own.
    public var resolution: Double? {
        guard session.photo != nil else { return nil }
        return try? session.effectivePPI()
    }

    public var photoResolutionDescription: String? {
        guard let photo = session.photo else { return nil }
        guard let dpi = photo.dpi, dpi.0 > 0 else {
            return String(format: "none set (%.0f ppi is used)", PrintSession.fallbackPPI)
        }
        let size = units.size(Double(photo.width) / dpi.0, Double(photo.height) / dpi.1)
        return String(format: "%.0f ppi", dpi.0) + " (\(size))"
    }

    public var sizeDescription: String {
        guard session.photo != nil, let (width, height) = try? session.sizeInches(),
              let ppi = try? session.effectivePPI() else { return "" }
        var text = "\(units.size(width, height)) at \(String(format: "%.0f", ppi)) ppi"
        if (try? session.fitsOnPaper()) == false { text += "\nLarger than the paper: turn on Fit or lower the size." }
        return text
    }

    public var summary: [String] { (try? session.summary()) ?? [] }

    public var canPrint: Bool { session.photo != nil && ((try? session.fitsOnPaper()) ?? false) && !busy }

    // MARK: work off the main thread

    public func refreshPreview() {
        guard session.photo != nil else {
            preview = nil
            return
        }
        previewToken += 1
        let token = previewToken, snapshot = session
        if showingCoats, let separation = snapshot.colourSeparation, let photo = snapshot.photo {
            Task.detached(priority: .userInitiated) {
                let image = CoatsPreview.proof(photo, separation: separation)
                await MainActor.run { if token == self.previewToken { self.preview = image } }
            }
            return
        }
        if showingCoats, let plan = snapshot.separation, let photo = snapshot.photo {
            Task.detached(priority: .userInitiated) {
                let image = CoatsPreview.image(photo.pixels, width: photo.width, height: photo.height, plan: plan)
                await MainActor.run { if token == self.previewToken { self.preview = image } }
            }
            return
        }
        let proof = snapshot.printsColour ? (snapshot.colourProfilePath ?? proofProfile) : nil
        Task.detached(priority: .userInitiated) {
            // A colour print is shown in its own profile; soft-proofed if a profile is chosen.
            var image = (try? snapshot.preview())?.cgImage(eightBit: true, iccProfile: snapshot.printProfile())
            if let proof, let shown = image { image = SoftProof.proof(shown, with: proof) ?? shown }
            await MainActor.run {
                if token == self.previewToken { self.preview = image }  // a newer preview wins
            }
        }
    }

    /// The full-resolution print, rendered off the main thread.
    public func renderedPrint() async throws -> RGBImage {
        busy = true
        defer { busy = false }
        let snapshot = session
        return try await Task.detached(priority: .userInitiated) { try snapshot.renderPrint() }.value
    }

    public func savePrintFile(_ url: URL) async {
        busy = true
        defer { busy = false }
        let snapshot = session
        do {
            try await Task.detached(priority: .userInitiated) { try snapshot.writePrintFile(url) }.value
            error = nil
        } catch {
            self.error = String(describing: error)
        }
    }

    /// Print straight to the chosen CUPS printer (lp), as the Python app does; the job id.
    public func printDirect(runner: @escaping Printing.Runner = Printing.runCommand) async -> String? {
        guard canPrint else { return nil }
        busy = true
        defer { busy = false }
        let snapshot = session
        nonisolated(unsafe) let runner = runner
        do {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("openquad-print-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }  // lp has spooled its own copy
            let job = try await Task.detached(priority: .userInitiated) { try snapshot.print(scratch: scratch, runner: runner) }.value
            status = "Sent to \(snapshot.printer ?? "the printer"): job \(job)."
            error = nil
            return job
        } catch {
            self.error = String(describing: error)
            return nil
        }
    }

    /// Everything the native print panel needs: the rendered image, its size and a title.
    public func printRequest() async -> (RGBImage, Double, Double, String, String)? {
        guard canPrint, var (width, height) = try? session.sizeInches() else { return nil }
        do {
            let image = try await renderedPrint()
            if session.placed, let ppi = try? session.effectivePPI() {  // the page inside its margins
                (width, height) = (Double(image.width) / ppi, Double(image.height) / ppi)
            }
            return (image, width, height, session.paper, session.jobTitle)
        } catch {
            self.error = String(describing: error)
            return nil
        }
    }
}
