// A print session: everything the print window shows and does, with no UI. Mirrors
// openquad/session.py. Colour toning is never on by default: a new session uses the
// neutral preset until the user picks another.

import CoreGraphics
import Foundation

public struct SessionError: Error, Equatable, CustomStringConvertible {
    public let description: String
}

/// `value` if it is one of `choices`, else a SessionError naming them (as the Python app words it).
func oneOf(_ value: String, _ choices: [String], _ what: String) throws -> String {
    guard choices.contains(value) else {
        throw SessionError(description: "unknown \(what) \(pyRepr(value)); choose from \(choices.joined(separator: ", "))")
    }
    return value
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
    /// Driver options for printing straight to the printer (lp -o), e.g. its media type and
    /// quality: ["CNIJMediaType": "28"]. The print panel has its own.
    public var printerOptions: [String: String] = [:]
    public private(set) var paper = "Letter"
    /// The page turned on its side (wider than tall).
    public var landscape = false
    /// The page (width, height) in inches as it lies: portrait or landscape.
    public var page: (Double, Double) { Paper.page(paper, landscape: landscape)! }
    var paperName: String { landscape ? "\(paper), landscape" : paper }
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
    /// Fit the darkroom marks' border (a print's white border, a negative's safe edge and
    /// outline) within the printable area with the photo; if not, the photo alone fits and the
    /// border lies outside it, into the margins.
    public var marksInFit = true
    public var safeEdge = 0.25
    /// Inches of black between the safe edge and the photo (0 = none).
    public var outline = 0.0
    /// Darkroom marks in black: in a negative's safe edge, or a white border round a print.
    public var guide = false  // a guide line round the image
    public var registration = false  // crosshair targets and corner crop marks
    /// Step wedges beside the print on `wedgeSide`: the 31-step grey wedge (through the same
    /// toning, calibration or process curve as the photo), and for a colour print a colour
    /// gamut wedge. Joined to the print (on a negative, inside its safe edge with no clear film
    /// between), or made separately `wedgeGap` inches away.
    public var wedge = false
    public var colourWedge = false
    public private(set) var wedgeSide = "bottom"
    public private(set) var wedgeGap = Wedge.defaultGap
    public var wedgeSeparate = false
    public private(set) var wedgeSteps = Wedge.steps
    public private(set) var wedgeWidth = Wedge.width
    public private(set) var wedgeStyle = "strip"
    public var wedgeLabels = false
    public private(set) var wedgeBackground = "colour"
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
    /// Or the photo split by colour: one negative per coat of a coloured pigment, from the
    /// photo's own colour. Only one of the two separations is set at a time.
    public private(set) var colourSeparation: ColourSeparation?
    /// Where a negative goes on the page: its outer top-left corner, in inches from the paper's
    /// left and top edges, kept inside the margins. nil = centred (as a print always is).
    public private(set) var placement: (Double, Double)?
    /// Print a colour photo in colour, on a colour-managed printer: its own colour and ICC
    /// profile go to macOS, with no toning or calibration. Off (greyscale) for each new photo.
    public private(set) var colourPrint = false

    public init() {}

    /// Print the photo in its own colour (colour-managed), or in greyscale.
    public mutating func setColourPrint(_ on: Bool) throws {
        if on && photo?.colour == nil { throw SessionError(description: "only a colour photo can be printed in colour") }
        colourPrint = on
    }

    /// The print is the photo's own colour: colour print on, in print mode.
    public var printsColour: Bool { colourPrint && !negative && photo?.colour != nil }

    /// How many negatives the photo is printed with.
    public var negativeCount: Int { colourSeparation?.count ?? separation?.count ?? 1 }

    /// Split into several negatives, by tone or by colour.
    public var separated: Bool { negativeCount > 1 }

    /// Split the negative into `plan.count` negatives by tone (nil or 1: just one).
    public mutating func setSeparation(_ plan: SeparationPlan?) {
        separation = plan.flatMap { $0.count > 1 ? $0 : nil }
        if separation != nil { colourSeparation = nil }
        fitLayers()
    }

    /// Split the negative by colour, one negative per coat (nil: no colour separation).
    public mutating func setColourSeparation(_ separation: ColourSeparation?) {
        colourSeparation = separation
        if separation != nil { self.separation = nil }
        fitLayers()
    }

    /// Keep the shown negative and the negatives' own curves within the count.
    private mutating func fitLayers() {
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
        open(url, photo: try Photos.load(url))
    }

    /// Use a photo already loaded from `url` (e.g. an XCF, which GIMP takes a few seconds over).
    public mutating func open(_ url: URL, photo loaded: Photo) {
        photo = loaded
        source = url
        notes = []
        colourPrint = false
        if photo!.cropped { notes.append("Transparent edges were cropped off.") }
        if photo!.converted { notes.append("This is a colour image; it is converted to greyscale unless printed in colour.") }
    }

    public mutating func setWedgeSide(_ side: String) throws {
        wedgeSide = try oneOf(side, Wedge.sides, "side")
    }

    public mutating func setWedgeGap(_ gap: Double) throws {
        guard gap.isFinite, (0...Wedge.maxGap).contains(gap) else {
            throw SessionError(description: "the gap must be 0 to \(String(format: "%g", Wedge.maxGap)) in, got \(gap)")
        }
        wedgeGap = gap
    }

    public mutating func setWedgeSteps(_ steps: Int) throws {
        guard Wedge.stepChoices.contains(steps) else {
            let choices = Wedge.stepChoices.map(String.init).joined(separator: ", ")
            throw SessionError(description: "a step wedge has \(choices) steps, not \(steps)")
        }
        wedgeSteps = steps
    }

    public mutating func setWedgeWidth(_ width: Double) throws {
        guard width.isFinite, (Wedge.minWidth...Wedge.maxWidth).contains(width) else {
            let (low, high) = (String(format: "%g", Wedge.minWidth), String(format: "%g", Wedge.maxWidth))
            throw SessionError(description: "the wedge's width must be \(low) to \(high) in, got \(width)")
        }
        wedgeWidth = width
    }

    public mutating func setWedgeBackground(_ background: String) throws {
        wedgeBackground = try oneOf(background, Wedge.backgrounds, "background")
    }

    /// What fills the space round the wedges: black, or white (paper; clear film).
    var wedgeFill: UInt16 { wedgeBackground == "black" ? 0 : UInt16(maxValue) }

    public mutating func setWedgeStyle(_ style: String) throws {
        wedgeStyle = try oneOf(style, Wedge.styles, "wedge style")
    }

    /// The wedges printed, nearest the print first: grey, and colour on a colour print.
    public var wedgeKinds: [Wedge.Kind] {
        var kinds: [Wedge.Kind] = wedge ? [.grey] : []
        if colourWedge && !negative && printsColour { kinds.append(.colour) }
        return kinds
    }

    func wedgeExtra() -> (Double, Double) {
        let border = negative ? safeEdge : 0
        let (width, height) = Wedge.extra(wedgeKinds, side: layoutWedgeSide, gap: wedgeGap, border: border,
                                          width: wedgeWidth, labels: wedgeLabels)
        if wedgeSeparate || !negative { return (width, height) }
        // Joined: a negative's wedge shares the photo's safe edge on its inner side.
        let shared = border * Double(wedgeKinds.count)
        return width != 0 ? (width - shared, height) : (width, height - shared)
    }

    /// The steps the wedge is made with: ChartThrob's style always has 21.
    public var shownWedgeSteps: Int { wedgeStyle == "chartthrob" ? Wedge.chartThrobSteps : wedgeSteps }

    /// The grey wedge as chosen, at `dpi`, to go on `side` (its numbers on the far side).
    func greyWedge(length: Int, dpi: Double, side: String) -> ([UInt16], Int, Int) {
        Wedge.grey(length: length, thickness: max(1, pyRound(wedgeWidth * dpi)), horizontal: side == "top" || side == "bottom",
                   steps: shownWedgeSteps, calibration: wedgeStyle == "calibration", frame: pyRound(Wedge.frame * dpi),
                   band: wedgeLabels ? pyRound(Wedge.labelBand * dpi) : 0, bandFirst: side == "top" || side == "left",
                   gradient: wedgeStyle == "chartthrob")
    }

    /// The side as laid out before a negative is mirrored, so it prints on the side chosen.
    var layoutWedgeSide: String {
        guard negative && mirror else { return wedgeSide }
        return ["left": "right", "right": "left"][wedgeSide] ?? wedgeSide
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
    /// The border the fit allows for: none when the marks lie outside the printable area.
    var fitBorder: Double { marksInFit ? border : 0.0 }

    var border: Double {
        if negative { return outline + safeEdge }
        return guide || registration ? Marks.printBorder : 0
    }

    var negativeSettings: NegativeSettings { negativeSettings(nil) }

    /// The settings for negative `layer` of the separation (nil: the whole negative).
    func negativeSettings(_ layer: Int?) -> NegativeSettings {
        let separated = self.separated && layer != nil
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
            let (extraWidth, extraHeight) = wedgeExtra()
            var ppi = extraWidth != 0 || extraHeight != 0 ? try pagePPI(extraWidth, extraHeight)
                : fitBorder != 0
                ? try Paper.negativePPI(width: photo.width, height: photo.height, paper: paper, safeEdge: fitBorder, margin: margin,
                                               landscape: landscape)
                : try Paper.fitPPI(width: photo.width, height: photo.height, paper: paper, margin: margin, landscape: landscape)
            if let maxSize {  // smaller of the page and the box (never past the page)
                ppi = max(ppi, try Paper.boxPPI(width: photo.width, height: photo.height, box: maxSize, border: fitBorder))
            }
            return ppi
        }
        if let ppi, ppi != 0 { return ppi }
        return photo.dpi?.0 ?? Self.fallbackPPI
    }

    /// The resolution that fits the photo, its border and its wedges within the margins.
    func pagePPI(_ extraWidth: Double, _ extraHeight: Double) throws -> Double {
        let photo = try currentPhoto()
        let (paperWidth, paperHeight) = page
        let roomWidth = paperWidth - 2 * margin - 2 * fitBorder - extraWidth
        let roomHeight = paperHeight - 2 * margin - 2 * fitBorder - extraHeight
        guard roomWidth > 0, roomHeight > 0 else {
            throw SessionError(description: "no room for the photo and its wedge on \(paperName)")
        }
        return max(Double(photo.width) / roomWidth, Double(photo.height) / roomHeight)
    }

    public func sizeInches() throws -> (Double, Double) {
        let photo = try currentPhoto(), ppi = try effectivePPI()
        // A negative's safe edge, or a print's border for its marks, goes round the photo;
        // any wedges sit beside it.
        let (extraWidth, extraHeight) = wedgeExtra()
        return (Double(photo.width) / ppi + 2 * border + extraWidth, Double(photo.height) / ppi + 2 * border + extraHeight)
    }

    public func fitsOnPaper() throws -> Bool {
        let (width, height) = try sizeInches()
        let (paperWidth, paperHeight) = page
        return width <= paperWidth + 1e-6 && height <= paperHeight + 1e-6
    }

    // MARK: placing a negative on the page

    /// Put the negative's top-left corner at (left, top) inches on the page; nil centres it.
    public mutating func setPlacement(_ placement: (Double, Double)?) throws {
        if let (left, top) = placement, !left.isFinite || !top.isFinite {
            throw SessionError(description: "not a position on the page: (\(left), \(top))")
        }
        self.placement = placement
    }

    /// A negative moved from the centre, with room to move inside the margins.
    public var placed: Bool {
        guard placement != nil, let (width, height) = try? sizeInches() else { return false }
        let (roomWidth, roomHeight) = room
        return width <= roomWidth + 1e-6 && height <= roomHeight + 1e-6
    }

    /// How near the paper's edge the print may be put: the margin, less the marks' border when
    /// it lies outside the printable area (Keep marks inside the printable area off).
    var edge: Double { max(margin - (border - fitBorder), 0) }

    /// Where the print may be put, (width, height) in inches: the page inside its margins,
    /// widened by the marks' border when that lies outside the printable area.
    public var room: (Double, Double) {
        let (paperWidth, paperHeight) = page
        return (paperWidth - 2 * edge, paperHeight - 2 * edge)
    }

    /// Where the print's top-left corner lands: inches from the paper's left and top.
    public func pagePosition() throws -> (Double, Double) {
        let (width, height) = try sizeInches()
        let (paperWidth, paperHeight) = page
        guard placed, let (left, top) = placement else { return ((paperWidth - width) / 2, (paperHeight - height) / 2) }
        return (min(max(left, edge), paperWidth - edge - width), min(max(top, edge), paperHeight - edge - height))
    }

    /// The image on clear film filling the page inside its margins, at its position. That
    /// area prints centred on the page, so the negative lands where it was put.
    func onPage(_ image: RGBImage, ppi: Double) throws -> RGBImage {
        let (roomWidth, roomHeight) = room
        let pageWidth = max(pyRound(roomWidth * ppi), image.width), pageHeight = max(pyRound(roomHeight * ppi), image.height)
        let (left, top) = try pagePosition()
        let x = min(max(pyRound((left - edge) * ppi), 0), pageWidth - image.width)
        let y = min(max(pyRound((top - edge) * ppi), 0), pageHeight - image.height)
        var page = [UInt16](repeating: UInt16(maxValue), count: pageWidth * pageHeight * 3)
        let row = image.width * 3
        for r in 0..<image.height {
            let to = ((y + r) * pageWidth + x) * 3
            page.replaceSubrange(to..<to + row, with: image.pixels[r * row..<(r + 1) * row])
        }
        return RGBImage(width: pageWidth, height: pageHeight, pixels: page)
    }

    // MARK: rendering

    /// What is sent to the printer: a toned, calibrated print, or (in negative mode) the
    /// negative through the process curve, with its safe edge at `dpi`.
    /// `colour`: the pixels are 16-bit RGB, for a colour separation's negatives.
    public func render(_ pixels: [UInt16], width: Int, height: Int, dpi: Double? = nil, colour: Bool = false) throws -> RGBImage {
        if negative { return try renderLayer(pixels, width: width, height: height, layer: layer, dpi: dpi, colour: colour) }
        let dpi = try dpi ?? effectivePPI()
        let rgb = Composite.composite(mirrored(pixels, width: width, channels: 1), layers: Composite.presets[preset]!)
        let printed = Marks.addPrintMarks(RGBImage(width: width, height: height, pixels: calibration?.apply(rgb) ?? rgb),
                                          dpi: dpi, guide: guide, registration: registration)
        return withPrintWedges(printed, width: width, height: height, dpi: dpi, calibrated: true)
    }

    /// A print with its wedges: the grey wedge toned (and calibrated) like the photo, or left
    /// neutral on a colour print, and the colour wedge.
    func withPrintWedges(_ image: RGBImage, width: Int, height: Int, dpi: Double, calibrated: Bool = false,
                         colour: Bool = false) -> RGBImage {
        let horizontal = wedgeSide == "top" || wedgeSide == "bottom"
        let length = horizontal ? width : height
        let made = wedgeKinds.map { kind -> RGBImage in
            if kind == .colour {
                return Wedge.colour(length: length, row: max(1, pyRound(Wedge.colourRow * dpi)), horizontal: horizontal)
            }
            let (ramp, w, h) = greyWedge(length: length, dpi: dpi, side: wedgeSide)
            if colour { return RGBImage(width: w, height: h, pixels: ramp.flatMap { [$0, $0, $0] }) }
            let rgb = Composite.composite(ramp, layers: Composite.presets[preset]!)
            return RGBImage(width: w, height: h, pixels: calibrated ? calibration?.apply(rgb) ?? rgb : rgb)
        }
        return Wedge.attach(image, made, side: wedgeSide, gap: pyRound(wedgeGap * dpi), fill: wedgeFill)
    }

    /// Negative `layer` of the separation (any layer is the whole negative without one).
    /// `pixels` are greyscale, or 16-bit RGB (`colour`) for a colour separation.
    /// A grey wedge is made into a negative the same way, with its own safe edge. Joined, it
    /// runs the full width of the photo and its outline, and the gap between is opaque like
    /// the safe edge; made separately, the gap is clear film.
    public func renderLayer(_ pixels: [UInt16], width: Int, height: Int, layer: Int, dpi: Double? = nil,
                            colour: Bool = false) throws -> RGBImage {
        let dpi = try dpi ?? effectivePPI()
        let settings = negativeSettings(separated ? layer : nil)
        let image = try negativeLayer(pixels, width: width, height: height, layer: layer, dpi: dpi, colour: colour,
                                      settings: settings)
        guard wedge else { return image }
        let side = layoutWedgeSide, horizontal = side == "top" || side == "bottom"
        var length = horizontal ? width : height
        if !wedgeSeparate { length += 2 * pyRound(settings.outline * dpi) }  // as long as the photo and its outline
        var (ramp, w, h) = greyWedge(length: length, dpi: dpi, side: side)
        if colour { ramp = ramp.flatMap { [$0, $0, $0] } }
        let bare = NegativeSettings(colour: settings.colour, mirror: settings.mirror, safeEdge: settings.safeEdge, mark: false)
        let made = try negativeLayer(ramp, width: w, height: h, layer: layer, dpi: dpi, colour: colour, settings: bare)
        let gap = pyRound(wedgeGap * dpi), edge = pyRound(settings.safeEdge * dpi)
        if wedgeSeparate || edge == 0 { return Wedge.attach(image, [made], side: side, gap: gap, fill: wedgeFill) }
        if wedgeBackground != "colour" {  // joined, the space black or clear
            return Wedge.attach(image, [made.innerEdge(side: side, edge: edge, gap: 0)], side: side, gap: gap, fill: wedgeFill)
        }
        // Joined: the wedge's inner safe edge becomes the gap, opaque like the safe edge.
        return Wedge.attach(image, [made.innerEdge(side: side, edge: edge, gap: gap)], side: side, gap: 0)
    }

    func negativeLayer(_ pixels: [UInt16], width: Int, height: Int, layer: Int, dpi: Double, colour: Bool,
                       settings: NegativeSettings) throws -> RGBImage {
        var shaped = pixels
        var curve = process
        if let colourSeparation {
            shaped = colourSeparation.coatImage(pixels, colour: colour, coat: layer)
            curve = layerProcess(layer)
        } else if colour {
            throw SessionError(description: "a colour photo makes negatives only for a colour separation")
        } else if let separation {
            shaped = separation.coatImage(coatsCurve?.apply(pixels) ?? pixels, layer: layer)
            curve = layerProcess(layer)
        }
        shaped = curve?.apply(shaped) ?? shaped
        return Negative.make(shaped, width: width, height: height, settings: settings, dpi: dpi)
    }

    /// A colour print: the photo's own colour, untouched, with any darkroom marks.
    /// A print's photo flipped left to right when mirrored (for transfers); its marks and
    /// wedges stay where they were put.
    func mirrored(_ pixels: [UInt16], width: Int, channels: Int) -> [UInt16] {
        guard mirror, width > 0 else { return pixels }
        let row = width * channels
        var flipped = pixels
        for start in stride(from: 0, to: pixels.count, by: row) {
            for x in 0..<width {
                let from = start + x * channels, to = start + (width - 1 - x) * channels
                for c in 0..<channels { flipped[to + c] = pixels[from + c] }
            }
        }
        return flipped
    }

    public func renderColour(_ rgb: [UInt16], width: Int, height: Int, dpi: Double? = nil) throws -> RGBImage {
        let dpi = try dpi ?? effectivePPI()
        let printed = Marks.addPrintMarks(RGBImage(width: width, height: height, pixels: mirrored(rgb, width: width, channels: 3)),
                                          dpi: dpi, guide: guide, registration: registration)
        return withPrintWedges(printed, width: width, height: height, dpi: dpi, colour: true)
    }

    /// The full-resolution print: in colour, or rendered from the greyscale photo.
    public func renderPrint() throws -> RGBImage {
        let photo = try currentPhoto()
        let image: RGBImage
        if printsColour, let colour = photo.colour {
            image = try renderColour(colour, width: photo.width, height: photo.height)
        } else {
            let (pixels, colour) = negativeSource(photo)
            image = try render(pixels, width: photo.width, height: photo.height, colour: colour)
        }
        return placed ? try onPage(image, ppi: try effectivePPI()) : image
    }

    /// The pixels negatives are made from: the photo's colour for a colour separation (its
    /// greyscale if it has none), otherwise its greyscale; and whether they are colour.
    func negativeSource(_ photo: Photo) -> ([UInt16], Bool) {
        if negative, colourSeparation != nil, let colour = photo.colour { return (colour, true) }
        return (photo.pixels, false)
    }

    /// The ICC profile the print file carries: a colour print's own (sRGB if untagged).
    public func printProfile() -> Data? {
        if printsColour, let profile = photo?.iccProfile { return profile }
        return ImageFiles.srgbProfile()
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
        if printsColour, let colour = photo.colour {  // in its own colour, not proofed
            var rgb = colour
            if scale < 1.0 {
                let planes = (0..<3).map { c in
                    Self.resize(stride(from: c, to: colour.count, by: 3).map { colour[$0] }, from: (photo.width, photo.height),
                                to: (width, height))
                }
                rgb = (0..<width * height).flatMap { i in planes.map { $0[i] } }
            }
            return try renderColour(rgb, width: width, height: height, dpi: try effectivePPI() * scale)
        }
        if negative {
            var (shown, colour) = negativeSource(photo)
            if colour && scale < 1.0 {
                let planes = (0..<3).map { c in
                    Self.resize(stride(from: c, to: shown.count, by: 3).map { shown[$0] }, from: (photo.width, photo.height),
                                to: (width, height))
                }
                shown = (0..<width * height).flatMap { i in planes.map { $0[i] } }
            } else if !colour {
                shown = pixels
            }
            return try render(shown, width: width, height: height, dpi: try effectivePPI() * scale, colour: colour)
        }
        let dpi = try effectivePPI() * scale
        let toned = RGBImage(width: width, height: height, pixels: Composite.composite(mirrored(pixels, width: width, channels: 1),
                                                                                      layers: Composite.presets[preset]!))
        let shown = Marks.addPrintMarks(toned, dpi: dpi, guide: guide, registration: registration)
        return withPrintWedges(shown, width: width, height: height, dpi: dpi)
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
        let outside = marksInFit || border == 0 ? [] : ["Fit: the photo alone; its border lies outside the printable area"]
        return (marks.isEmpty ? [] : ["Darkroom marks: \(marks.joined(separator: " and "))"]) + outside
    }

    var separationLines: [String] {
        if let colourSeparation {
            return [
                "Colour separation: \(colourSeparation.describe())",
                "This negative: coat \(layer + 1) of \(colourSeparation.count) (\(colourSeparation.coats[layer].hex))",
                "Colour: \(negativeSettings(layer).colour)",
                "Process curve: \(layerProcessName(layer))",
            ]
        }
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
    func positionLine() throws -> [String] {
        guard placement != nil else { return [] }
        guard placed else { return ["Position: centred (no room to move it inside the margins)"] }
        let (left, top) = try pagePosition()
        return ["Position: \(units.length(left)) from the left, \(units.length(top)) from the top"]
    }

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
                "Paper: \(paperName)",
            ] + within + [
                "Size: \(size) with a \(units.length(safeEdge)) safe edge"
                    + (outline != 0 ? " and a \(units.length(outline)) black outline" : ""),
            ] + (try positionLine()) + separationLines + [
                "Mirrored: \(mirror ? "yes" : "no")",
            ] + marksLine + wedgeLines
        }
        let tones = printsColour
            ? ["Output: colour print (colour-managed by macOS)",
               "Colour profile: \(photo?.iccProfile != nil ? "embedded in the photo" : "none (read as sRGB)")"]
            : ["Toning: \(preset)", "Calibration: \(calibrationPath?.lastPathComponent ?? "none")"]
        return [
            "Photo: \(photoName)",
            "Printer: \(printer ?? "not chosen")",
            "Paper: \(paperName)",
        ] + within + [
            "Size: \(size) at \(String(format: "%.0f", try effectivePPI())) ppi",
        ] + (try positionLine()) + tones + (mirror ? ["Mirrored: yes"] : []) + marksLine + wedgeLines
    }

    var wedgeLines: [String] {
        let whereTo = ["top": "above", "bottom": "below", "left": "left of", "right": "right of"][wedgeSide]!
        let thing = negative ? "negative" : "print"
        let details = (wedgeStyle == "calibration" ? ["calibration style"] : wedgeStyle == "chartthrob" ? ["ChartThrob style, with gradient"] : []) + (wedgeLabels ? ["numbered"] : [])
        var away = wedgeGap != 0 ? "\(units.length(wedgeGap)) away" : "joined to it"
        if negative && wedgeSeparate { away += ", made separately" }
        if wedgeBackground != "colour" { away += ", on \(wedgeBackground)" }
        return wedgeKinds.map { kind in
            let name = kind == .grey
                ? "Step wedge: \(shownWedgeSteps) steps, \(units.length(wedgeWidth)) wide"
                    + (details.isEmpty ? "" : " (\(details.joined(separator: ", ")))")
                : "Colour wedge: \(Wedge.steps) hues"
            return "\(name), \(whereTo) the \(thing), \(away)"
        }
    }

    // MARK: output

    /// The full-resolution file to print, tagged with the print ppi: toned and calibrated
    /// (sRGB), or a colour print in the photo's own colour and profile.
    public func writePrintFile(_ url: URL) throws {
        let ppi = try effectivePPI()
        try ImageFiles.saveRGB(url, try renderPrint(), dpi: (ppi, ppi), iccProfile: printProfile())
    }

    /// Every negative of the separation as `<stem>-<k>of<n>.tif` in `folder`.
    @discardableResult
    public func writeSeparations(_ folder: URL, stem: String? = nil) throws -> [URL] {
        guard separated, negative else { throw SessionError(description: "set up a separation of the negative first") }
        let photo = try currentPhoto(), ppi = try effectivePPI(), count = negativeCount
        let stem = stem ?? source?.deletingPathExtension().lastPathComponent ?? "negative"
        let (pixels, colour) = negativeSource(photo)
        return try (0..<count).map { k in
            let url = folder.appendingPathComponent("\(stem)-\(k + 1)of\(count).tif")
            let image = try renderLayer(pixels, width: photo.width, height: photo.height, layer: k, dpi: ppi, colour: colour)
            try ImageFiles.saveRGB(url, image, dpi: (ppi, ppi), iccProfile: ImageFiles.srgbProfile())
            return url
        }
    }

    /// The print job's title, naming the negative of a separation.
    public var jobTitle: String {
        let title = source.map { "OpenQuad: \($0.lastPathComponent)" } ?? "OpenQuad"
        guard negative, separated else { return title }
        return title + " (negative \(layer + 1) of \(negativeCount))"
    }

    public func printJob(_ path: URL) throws -> PrintJob {
        guard let printer, !printer.isEmpty else { throw SessionError(description: "choose a printer first") }
        guard try fitsOnPaper() else { throw SessionError(description: "the photo is larger than the paper at this size") }
        return try PrintJob(path: path.path, printer: printer, paper: paper, ppi: try effectivePPI(), landscape: landscape, title: jobTitle,
                            options: printerOptions.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
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
    /// Each tab's page turned on its side (landscape).
    public var landscape = false
    public var negativeLandscape = false
    /// The test sheets' preferred size (the blocking test and process charts): fit within
    /// (width, height) inches; nil for their own size.
    public var chartSize: [Double]?
    /// The ICC profile colour prints are soft-proofed with (nil: no soft-proof).
    public var proofProfile: String?
    /// Driver options (media type, quality) chosen for each printer when printing straight to
    /// it, for prints and for negatives: [printer: [option: value]].
    public var printerOptions: [String: [String: String]] = [:]
    public var negativePrinterOptions: [String: [String: String]] = [:]
    /// The step wedges each tab prints beside the photo; nil for none chosen yet.
    public var printWedge: WedgeSettings?
    public var negativeWedge: WedgeSettings?
    /// Whether each tab fits the marks' border within the printable area with the photo.
    public var marksInFit = true
    public var negativeMarksInFit = true

    public init() {}

    /// Printer options as saved, keeping only [printer: [option: value]] strings.
    static func options(_ value: Any?) -> [String: [String: String]] {
        guard let object = value as? [String: Any] else { return [:] }
        return object.compactMapValues { chosen in (chosen as? [String: Any])?.compactMapValues { $0 as? String } }
    }

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
        settings.proofProfile = object["proof_profile"] as? String
        settings.printerOptions = options(object["printer_options"])
        settings.negativePrinterOptions = options(object["negative_printer_options"])
        settings.printWedge = WedgeSettings(object["print_wedge"])
        settings.negativeWedge = WedgeSettings(object["negative_wedge"])
        settings.marksInFit = object["marks_in_fit"] as? Bool != false
        settings.negativeMarksInFit = object["negative_marks_in_fit"] as? Bool != false
        settings.landscape = object["landscape"] as? Bool == true
        settings.negativeLandscape = object["negative_landscape"] as? Bool == true
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
            "chart_size": chartSize ?? NSNull(), "proof_profile": proofProfile ?? NSNull(),
            "printer_options": printerOptions, "negative_printer_options": negativePrinterOptions,
            "print_wedge": printWedge?.json ?? NSNull(), "negative_wedge": negativeWedge?.json ?? NSNull(),
            "marks_in_fit": marksInFit, "negative_marks_in_fit": negativeMarksInFit,
            "landscape": landscape, "negative_landscape": negativeLandscape,
        ]
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0a)
        try data.write(to: url, options: .atomic)
    }
}

/// A tab's step wedges, as remembered: the grey wedge, the colour wedge, the side, the gap,
/// whether they are made separately, and the grey wedge's steps, width, style and numbers.
public struct WedgeSettings: Sendable, Equatable {
    public var grey: Bool
    public var colour: Bool
    public var side: String
    public var gap: Double
    public var separate: Bool
    public var steps: Int
    public var width: Double
    public var style: String
    public var labels: Bool
    public var background: String

    public init(grey: Bool, colour: Bool, side: String, gap: Double, separate: Bool = false, steps: Int = Wedge.steps,
                width: Double = Wedge.width, style: String = "strip", labels: Bool = false, background: String = "colour") {
        self.grey = grey
        self.colour = colour
        self.side = side
        self.gap = gap
        self.separate = separate
        self.steps = steps
        self.width = width
        self.style = style
        self.labels = labels
        self.background = background
    }

    /// As saved, or nil if it isn't readable (as the Python app reads it).
    init?(_ value: Any?) {
        guard let object = value as? [String: Any], let side = object["side"] as? String, Wedge.sides.contains(side),
              let gap = object["gap"] as? NSNumber, CFGetTypeID(gap) != CFBooleanGetTypeID() else { return nil }
        let isTrue = { (key: String) in (object[key] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false }
        let number = { (value: Any?) -> NSNumber? in
            (value as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0 }
        }
        let steps = number(object["steps"]).flatMap { Wedge.stepChoices.contains($0.intValue) && Double($0.intValue) == $0.doubleValue
            ? $0.intValue : nil } ?? Wedge.steps
        let width = number(object["width"]).map { min(max($0.doubleValue, Wedge.minWidth), Wedge.maxWidth) } ?? Wedge.width
        let style = (object["style"] as? String).flatMap { Wedge.styles.contains($0) ? $0 : nil } ?? "strip"
        self.init(grey: isTrue("grey"), colour: isTrue("colour"), side: side, gap: min(max(gap.doubleValue, 0), Wedge.maxGap),
                  separate: isTrue("separate"), steps: steps, width: width, style: style, labels: isTrue("labels"),
                  background: (object["background"] as? String).flatMap { Wedge.backgrounds.contains($0) ? $0 : nil } ?? "colour")
    }

    var json: [String: Any] {
        ["grey": grey, "colour": colour, "side": side, "gap": gap, "separate": separate, "steps": steps, "width": width,
         "style": style, "labels": labels, "background": background]
    }
}
