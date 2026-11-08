// A print session: everything the print window shows and does, with no UI. Mirrors
// openquad/session.py. Colour toning is never on by default: a new session uses the
// neutral preset until the user picks another.

import CoreGraphics
import Foundation

public struct SessionError: Error, Equatable, CustomStringConvertible {
    public let description: String
}

public enum OutputMode: String, Sendable, CaseIterable {
    case print, negative
}

public struct PrintSession: Sendable {
    public static let fallbackPPI = 300.0

    public var photo: Photo?
    public var source: URL?
    public private(set) var preset = Composite.defaultPreset
    public private(set) var calibration: Calibration?
    public private(set) var calibrationPath: URL?
    public var printer: String?
    public private(set) var paper = "Letter"
    public var fit = true
    public var margin = Paper.defaultMargin
    /// Used when fit is off; nil = the photo's own resolution.
    public var ppi: Double?
    /// With fit: also keep within this (width, height) in inches, turned to match the photo;
    /// for a negative it is the outer edge, safe edge included (e.g. the carbon tissue's size).
    public var maxSize: (Double, Double)?
    public var notes: [String] = []
    public private(set) var mode = OutputMode.print
    public private(set) var negativeColour = "green"
    public private(set) var process: ProcessCurve?
    public private(set) var processPath: URL?
    public var mirror = false
    public var safeEdge = 0.25
    /// Inches of black between the safe edge and the photo (0 = none).
    public var outline = 0.0
    /// Darkroom marks in black: in a negative's safe edge, or a white border round a print.
    public var guide = false  // a guide line round the image
    public var registration = false  // crosshair targets and corner crop marks
    /// How the summary shows lengths.
    public var units = LengthUnit.inches
    /// Separations: the photo split into several negatives by tone, printed one after another
    /// in register on one sheet. nil for a single negative. `layer` is the negative shown and
    /// printed (0 = the lightest band); a negative can have its own process curve.
    public private(set) var separation: SeparationPlan?
    public private(set) var layer = 0
    public private(set) var layerProcesses: [Int: ProcessCurve] = [:]
    public private(set) var layerProcessPaths: [Int: URL] = [:]
    /// The coats curve: the whole stack of coats calibrated as one process (from a chart
    /// printed through every negative), applied to the photo before it is split.
    public private(set) var coatsCurve: ProcessCurve?
    public private(set) var coatsCurvePath: URL?

    public init() {}

    /// How many negatives the photo is printed with.
    public var negativeCount: Int { separation?.count ?? 1 }

    /// Split the negative into `plan.count` negatives by tone (nil or 1: just one).
    public mutating func setSeparation(_ plan: SeparationPlan?) {
        separation = plan.flatMap { $0.count > 1 ? $0 : nil }
        layer = min(layer, negativeCount - 1)
        for k in layerProcesses.keys where k >= negativeCount {
            layerProcesses[k] = nil
            layerProcessPaths[k] = nil
        }
    }

    public mutating func setLayer(_ layer: Int) throws {
        guard (0..<negativeCount).contains(layer) else {
            throw SessionError(description: "there is no negative \(layer + 1) of \(negativeCount)")
        }
        self.layer = layer
    }

    /// Give one negative of the separation its own process curve (nil: the shared one).
    public mutating func setLayerProcess(_ layer: Int, _ url: URL?) throws {
        guard (0..<negativeCount).contains(layer) else {
            throw SessionError(description: "there is no negative \(layer + 1) of \(negativeCount)")
        }
        guard let url else {
            (layerProcesses[layer], layerProcessPaths[layer]) = (nil, nil)
            return
        }
        layerProcesses[layer] = try ProcessCurve.decode(Data(contentsOf: url))
        layerProcessPaths[layer] = url
    }

    /// Calibrate the stacked coats: a curve read from a chart printed through every negative,
    /// applied before splitting. nil for none.
    public mutating func setCoatsCurve(_ url: URL?) throws {
        guard let url else {
            (coatsCurve, coatsCurvePath) = (nil, nil)
            return
        }
        coatsCurve = try ProcessCurve.decode(Data(contentsOf: url))
        coatsCurvePath = url
    }

    /// The process curve negative `layer` is made with: its own, or the shared one.
    public func layerProcess(_ layer: Int) -> ProcessCurve? { layerProcesses[layer] ?? process }

    func layerProcessName(_ layer: Int) -> String {
        (layerProcessPaths[layer] ?? processPath)?.lastPathComponent ?? "none (uncalibrated)"
    }

    // MARK: choosing things

    public mutating func open(_ url: URL) throws {
        photo = try Photos.load(url)
        source = url
        notes = []
        if photo!.cropped { notes.append("Transparent edges were cropped off.") }
        if photo!.converted { notes.append("This is a colour image; it was converted to greyscale.") }
    }

    public mutating func setPreset(_ name: String) throws {
        guard Composite.presets[name] != nil else { throw SessionError(description: "unknown preset \(pyRepr(name))") }
        preset = name
    }

    public mutating func setCalibration(_ url: URL?) throws {
        guard let url else {
            (calibration, calibrationPath) = (nil, nil)
            return
        }
        calibration = try Calibration.decode(Data(contentsOf: url))
        calibrationPath = url
    }

    public mutating func setMode(_ mode: OutputMode) { self.mode = mode }

    public mutating func setNegativeColour(_ colour: String) throws {
        guard Negative.colours[colour] != nil else { throw SessionError(description: "unknown negative colour \(pyRepr(colour))") }
        if let process, process.colour != colour {
            throw SessionError(description: "the process curve is for \(process.colour) negatives")
        }
        negativeColour = colour
    }

    /// Use a process curve; it decides the negative colour it was made for.
    public mutating func setProcess(_ url: URL?) throws {
        guard let url else {
            (process, processPath) = (nil, nil)
            return
        }
        let curve = try ProcessCurve.decode(Data(contentsOf: url))
        process = curve
        processPath = url
        negativeColour = curve.colour
    }

    public mutating func setPaper(_ paper: String) throws {
        guard Paper.sizes[paper] != nil else { throw SessionError(description: "unknown paper \(pyRepr(paper))") }
        self.paper = paper
    }

    public var negative: Bool { mode == .negative }

    /// Inches round the photo: in a negative the black outline plus the safe edge; in a
    /// print the white border carrying its darkroom marks (if any).
    var border: Double {
        if negative { return outline + safeEdge }
        return guide || registration ? Marks.printBorder : 0
    }

    var negativeSettings: NegativeSettings { negativeSettings(nil) }

    /// The settings for negative `layer` of the separation (nil: the whole negative).
    func negativeSettings(_ layer: Int?) -> NegativeSettings {
        let separated = separation != nil && layer != nil
        let colour = separated ? layerProcess(layer!)?.colour ?? negativeColour : negativeColour
        return NegativeSettings(colour: colour, mirror: mirror, safeEdge: safeEdge, outline: outline, guide: guide,
                                registration: registration, label: separated ? layer! + 1 : 0, clearTargets: separated)
    }

    // MARK: size

    func currentPhoto() throws -> Photo {
        guard let photo else { throw SessionError(description: "open a photo first") }
        return photo
    }

    public func effectivePPI() throws -> Double {
        let photo = try currentPhoto()
        if fit {
            var ppi = border != 0
                ? try Paper.negativePPI(width: photo.width, height: photo.height, paper: paper, safeEdge: border, margin: margin)
                : try Paper.fitPPI(width: photo.width, height: photo.height, paper: paper, margin: margin)
            if let maxSize {  // smaller of the page and the box (never past the page)
                ppi = max(ppi, try Paper.boxPPI(width: photo.width, height: photo.height, box: maxSize, border: border))
            }
            return ppi
        }
        if let ppi, ppi != 0 { return ppi }
        return photo.dpi?.0 ?? Self.fallbackPPI
    }

    public func sizeInches() throws -> (Double, Double) {
        let photo = try currentPhoto(), ppi = try effectivePPI()
        // A negative's safe edge, or a print's border for its marks, goes round the photo.
        return (Double(photo.width) / ppi + 2 * border, Double(photo.height) / ppi + 2 * border)
    }

    public func fitsOnPaper() throws -> Bool {
        let (width, height) = try sizeInches()
        let (paperWidth, paperHeight) = Paper.sizes[paper]!
        return width <= paperWidth + 1e-6 && height <= paperHeight + 1e-6
    }

    // MARK: rendering

    /// What is sent to the printer: a toned, calibrated print, or (in negative mode) the
    /// negative through the process curve, with its safe edge at `dpi`.
    public func render(_ pixels: [UInt16], width: Int, height: Int, dpi: Double? = nil) throws -> RGBImage {
        if negative { return try renderLayer(pixels, width: width, height: height, layer: layer, dpi: dpi) }
        let rgb = Composite.composite(pixels, layers: Composite.presets[preset]!)
        return Marks.addPrintMarks(RGBImage(width: width, height: height, pixels: calibration?.apply(rgb) ?? rgb),
                                   dpi: try dpi ?? effectivePPI(), guide: guide, registration: registration)
    }

    /// Negative `layer` of the separation (any layer is the whole negative without one).
    public func renderLayer(_ pixels: [UInt16], width: Int, height: Int, layer: Int, dpi: Double? = nil) throws -> RGBImage {
        var shaped = pixels
        var curve = process
        if let separation {
            shaped = separation.coatImage(coatsCurve?.apply(pixels) ?? pixels, layer: layer)
            curve = layerProcess(layer)
        }
        shaped = curve?.apply(shaped) ?? shaped
        return Negative.make(shaped, width: width, height: height, settings: negativeSettings(separation != nil ? layer : nil),
                             dpi: try dpi ?? effectivePPI())
    }

    /// The full-resolution print.
    public func renderPrint() throws -> RGBImage {
        let photo = try currentPhoto()
        return try render(photo.pixels, width: photo.width, height: photo.height)
    }

    /// A preview of the toned photo (without calibration: the print should look like this),
    /// at most `maxSide` pixels on its longer side.
    public func preview(maxSide: Int = 900) throws -> RGBImage {
        let photo = try currentPhoto()
        let scale = min(1.0, Double(maxSide) / Double(max(photo.width, photo.height)))
        var (pixels, width, height) = (photo.pixels, photo.width, photo.height)
        if scale < 1.0 {
            width = max(1, pyRound(Double(photo.width) * scale))
            height = max(1, pyRound(Double(photo.height) * scale))
            pixels = Self.resize(photo.pixels, from: (photo.width, photo.height), to: (width, height))
        }
        if negative { return try render(pixels, width: width, height: height, dpi: try effectivePPI() * scale) }
        let toned = RGBImage(width: width, height: height, pixels: Composite.composite(pixels, layers: Composite.presets[preset]!))
        return Marks.addPrintMarks(toned, dpi: try effectivePPI() * scale, guide: guide, registration: registration)
    }

    /// Smooth 16-bit greyscale resampling (for previews only).
    static func resize(_ pixels: [UInt16], from: (Int, Int), to: (Int, Int)) -> [UInt16] {
        let space = CGColorSpaceCreateDeviceGray()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        var source = pixels
        var out = [UInt16](repeating: 0, count: to.0 * to.1)
        source.withUnsafeMutableBytes { src in
            out.withUnsafeMutableBytes { dst in
                guard let input = CGContext(data: src.baseAddress, width: from.0, height: from.1, bitsPerComponent: 16,
                                            bytesPerRow: from.0 * 2, space: space, bitmapInfo: info.rawValue)?.makeImage(),
                      let output = CGContext(data: dst.baseAddress, width: to.0, height: to.1, bitsPerComponent: 16,
                                             bytesPerRow: to.0 * 2, space: space, bitmapInfo: info.rawValue) else { return }
                output.interpolationQuality = .high
                output.draw(input, in: CGRect(x: 0, y: 0, width: to.0, height: to.1))
            }
        }
        return out
    }

    var marksLine: [String] {
        let marks = [(guide, "guide line"), (registration, "registration marks")].filter(\.0).map(\.1)
        return marks.isEmpty ? [] : ["Darkroom marks: \(marks.joined(separator: " and "))"]
    }

    var separationLines: [String] {
        guard let separation else {
            return ["Colour: \(negativeColour)",
                    "Process curve: \(processPath?.lastPathComponent ?? "none (uncalibrated)")"]
        }
        let (lower, upper) = separation.bands[layer]
        let steps = Double(separation.steps)
        return [
            "Separation: \(separation.describe())",
            "This negative: \(layer + 1) of \(separation.count) (steps \(SeparationPlan.g(lower * steps))-"
                + "\(SeparationPlan.g(upper * steps)), then full strength)",
            "Colour: \(negativeSettings(layer).colour)",
            "Process curve: \(layerProcessName(layer))",
            "Coats curve: \(coatsCurvePath?.lastPathComponent ?? "none")",
        ]
    }

    /// Lines for the print confirmation.
    public func summary() throws -> [String] {
        let (width, height) = try sizeInches()
        let photoName = source?.lastPathComponent ?? "untitled"
        let size = units.size(width, height)
        var within: [String] = []
        if fit, let maxSize, let photo {
            let (w, h) = Paper.oriented(maxSize, width: photo.width, height: photo.height)
            within = ["Fit within: \(units.box(w, h))"]
        }
        if negative {
            return [
                "Photo: \(photoName)",
                "Output: digital negative",
                "Printer: \(printer ?? "not chosen")",
                "Paper: \(paper)",
            ] + within + [
                "Size: \(size) with a \(units.length(safeEdge)) safe edge"
                    + (outline != 0 ? " and a \(units.length(outline)) black outline" : ""),
            ] + separationLines + [
                "Mirrored: \(mirror ? "yes" : "no")",
            ] + marksLine
        }
        return [
            "Photo: \(photoName)",
            "Printer: \(printer ?? "not chosen")",
            "Paper: \(paper)",
        ] + within + [
            "Size: \(size) at \(String(format: "%.0f", try effectivePPI())) ppi",
            "Toning: \(preset)",
            "Calibration: \(calibrationPath?.lastPathComponent ?? "none")",
        ] + marksLine
    }

    // MARK: output

    /// The full-resolution file to print: toned, calibrated, tagged with the print ppi.
    public func writePrintFile(_ url: URL) throws {
        let ppi = try effectivePPI()
        try ImageFiles.saveRGB(url, try renderPrint(), dpi: (ppi, ppi), iccProfile: ImageFiles.srgbProfile())
    }

    /// Every negative of the separation as `<stem>-<k>of<n>.tif` in `folder`.
    @discardableResult
    public func writeSeparations(_ folder: URL, stem: String? = nil) throws -> [URL] {
        guard let separation, negative else { throw SessionError(description: "set up a separation of the negative first") }
        let photo = try currentPhoto(), ppi = try effectivePPI()
        let stem = stem ?? source?.deletingPathExtension().lastPathComponent ?? "negative"
        return try (0..<separation.count).map { k in
            let url = folder.appendingPathComponent("\(stem)-\(k + 1)of\(separation.count).tif")
            let image = try renderLayer(photo.pixels, width: photo.width, height: photo.height, layer: k, dpi: ppi)
            try ImageFiles.saveRGB(url, image, dpi: (ppi, ppi), iccProfile: ImageFiles.srgbProfile())
            return url
        }
    }

    /// The print job's title, naming the negative of a separation.
    public var jobTitle: String {
        let title = source.map { "OpenQuad: \($0.lastPathComponent)" } ?? "OpenQuad"
        guard negative, let separation else { return title }
        return title + " (negative \(layer + 1) of \(separation.count))"
    }

    public func printJob(_ path: URL) throws -> PrintJob {
        guard let printer, !printer.isEmpty else { throw SessionError(description: "choose a printer first") }
        guard try fitsOnPaper() else { throw SessionError(description: "the photo is larger than the paper at this size") }
        return try PrintJob(path: path.path, printer: printer, paper: paper, ppi: try effectivePPI(), title: jobTitle)
    }

    /// Render into `scratch` and send to the printer through lp; returns the CUPS job id.
    public func print(scratch: URL, runner: Printing.Runner = Printing.runCommand) throws -> String {
        guard let printer, !printer.isEmpty else { throw SessionError(description: "choose a printer first") }
        let path = scratch.appendingPathComponent("openquad-print.tif")
        try writePrintFile(path)
        return try Printing.send(try printJob(path), runner: runner)
    }
}

/// Remembered app settings, in the same file as the Python app. The toning preset is
/// deliberately not remembered: every session starts neutral.
public struct AppSettings: Sendable, Equatable {
    public var printer: String?
    public var scannerHost: String?
    public var paper = "Letter"
    public var calibration: String?
    public var lastFolder: String?
    public var process: String?
    public var negativeColour = "green"
    /// Fit within (width, height) inches, e.g. the carbon tissue; nil for the page.
    public var maxSize: [Double]?
    /// Lengths shown in the app.
    public var units = LengthUnit.inches
    /// The Negative tab's own printer and paper (nil: the ones above).
    public var negativePrinter: String?
    public var negativePaper: String?
    /// The test sheets' preferred size (the blocking test and process charts): fit within
    /// (width, height) inches; nil for their own size.
    public var chartSize: [Double]?

    public init() {}

    public static func defaultURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["OPENQUAD_SETTINGS"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OpenQuad/settings.json")
    }

    /// Where the app keeps its own files (calibrations, scans), next to the settings.
    public static func dataDirectory() -> URL { defaultURL().deletingLastPathComponent() }

    public static func load(_ url: URL = defaultURL()) -> AppSettings {
        var settings = AppSettings()
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return settings }
        settings.printer = object["printer"] as? String
        settings.scannerHost = object["scanner_host"] as? String
        settings.paper = object["paper"] as? String ?? "Letter"
        settings.calibration = object["calibration"] as? String
        settings.lastFolder = object["last_folder"] as? String
        settings.process = object["process"] as? String
        settings.negativeColour = object["negative_colour"] as? String ?? "green"
        if let size = object["max_size"] as? [NSNumber], size.count == 2 { settings.maxSize = size.map(\.doubleValue) }
        settings.units = (object["units"] as? String).flatMap(LengthUnit.init(rawValue:)) ?? .inches
        settings.negativePrinter = object["negative_printer"] as? String
        settings.negativePaper = (object["negative_paper"] as? String).flatMap { Paper.sizes[$0] != nil ? $0 : nil }
        if let size = object["chart_size"] as? [NSNumber], size.count == 2 { settings.chartSize = size.map(\.doubleValue) }
        return settings
    }

    public func save(_ url: URL = defaultURL()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let object: [String: Any] = [
            "printer": printer ?? NSNull(), "scanner_host": scannerHost ?? NSNull(), "paper": paper,
            "calibration": calibration ?? NSNull(), "last_folder": lastFolder ?? NSNull(),
            "process": process ?? NSNull(), "negative_colour": negativeColour, "max_size": maxSize ?? NSNull(),
            "units": units.rawValue,
            "negative_printer": negativePrinter ?? NSNull(), "negative_paper": negativePaper ?? NSNull(),
            "chart_size": chartSize ?? NSNull(),
        ]
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0a)
        try data.write(to: url, options: .atomic)
    }
}
