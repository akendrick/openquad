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

    public init() {}

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

    /// Inches round the photo in a negative: the black outline plus the safe edge.
    var border: Double { outline + safeEdge }

    var negativeSettings: NegativeSettings {
        NegativeSettings(colour: negativeColour, mirror: mirror, safeEdge: safeEdge, outline: outline)
    }

    // MARK: size

    func currentPhoto() throws -> Photo {
        guard let photo else { throw SessionError(description: "open a photo first") }
        return photo
    }

    public func effectivePPI() throws -> Double {
        let photo = try currentPhoto()
        if fit {
            var ppi = negative
                ? try Paper.negativePPI(width: photo.width, height: photo.height, paper: paper, safeEdge: border, margin: margin)
                : try Paper.fitPPI(width: photo.width, height: photo.height, paper: paper, margin: margin)
            if let maxSize {  // smaller of the page and the box (never past the page)
                ppi = max(ppi, try Paper.boxPPI(width: photo.width, height: photo.height, box: maxSize,
                                                border: negative ? border : 0))
            }
            return ppi
        }
        if let ppi, ppi != 0 { return ppi }
        return photo.dpi?.0 ?? Self.fallbackPPI
    }

    public func sizeInches() throws -> (Double, Double) {
        let photo = try currentPhoto(), ppi = try effectivePPI()
        var (width, height) = (Double(photo.width) / ppi, Double(photo.height) / ppi)
        if negative {  // the outline and safe edge go round the photo
            width += 2 * border
            height += 2 * border
        }
        return (width, height)
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
        if negative {
            let shaped = process?.apply(pixels) ?? pixels
            return Negative.make(shaped, width: width, height: height, settings: negativeSettings, dpi: try dpi ?? effectivePPI())
        }
        let rgb = Composite.composite(pixels, layers: Composite.presets[preset]!)
        return RGBImage(width: width, height: height, pixels: calibration?.apply(rgb) ?? rgb)
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
        return RGBImage(width: width, height: height, pixels: Composite.composite(pixels, layers: Composite.presets[preset]!))
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

    /// Lines for the print confirmation.
    public func summary() throws -> [String] {
        let (width, height) = try sizeInches()
        let photoName = source?.lastPathComponent ?? "untitled"
        let size = String(format: "%.2f x %.2f in", width, height)
        var within: [String] = []
        if fit, let maxSize, let photo {
            let (w, h) = Paper.oriented(maxSize, width: photo.width, height: photo.height)
            within = [String(format: "Fit within: %g x %g in", w, h)]
        }
        if negative {
            return [
                "Photo: \(photoName)",
                "Output: digital negative",
                "Printer: \(printer ?? "not chosen")",
                "Paper: \(paper)",
            ] + within + [
                "Size: \(size) with a \(String(format: "%g", safeEdge)) in safe edge"
                    + (outline != 0 ? " and a \(String(format: "%g", outline)) in black outline" : ""),
                "Colour: \(negativeColour)",
                "Process curve: \(processPath?.lastPathComponent ?? "none (uncalibrated)")",
                "Mirrored: \(mirror ? "yes" : "no")",
            ]
        }
        return [
            "Photo: \(photoName)",
            "Printer: \(printer ?? "not chosen")",
            "Paper: \(paper)",
        ] + within + [
            "Size: \(size) at \(String(format: "%.0f", try effectivePPI())) ppi",
            "Toning: \(preset)",
            "Calibration: \(calibrationPath?.lastPathComponent ?? "none")",
        ]
    }

    // MARK: output

    /// The full-resolution file to print: toned, calibrated, tagged with the print ppi.
    public func writePrintFile(_ url: URL) throws {
        let ppi = try effectivePPI()
        try ImageFiles.saveRGB(url, try renderPrint(), dpi: (ppi, ppi), iccProfile: ImageFiles.srgbProfile())
    }

    public func printJob(_ path: URL) throws -> PrintJob {
        guard let printer, !printer.isEmpty else { throw SessionError(description: "choose a printer first") }
        guard try fitsOnPaper() else { throw SessionError(description: "the photo is larger than the paper at this size") }
        return try PrintJob(path: path.path, printer: printer, paper: paper, ppi: try effectivePPI(),
                            title: source.map { "OpenQuad: \($0.lastPathComponent)" } ?? "OpenQuad")
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
        return settings
    }

    public func save(_ url: URL = defaultURL()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let object: [String: Any] = [
            "printer": printer ?? NSNull(), "scanner_host": scannerHost ?? NSNull(), "paper": paper,
            "calibration": calibration ?? NSNull(), "last_folder": lastFolder ?? NSNull(),
            "process": process ?? NSNull(), "negative_colour": negativeColour, "max_size": maxSize ?? NSNull(),
        ]
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0a)
        try data.write(to: url, options: .atomic)
    }
}
