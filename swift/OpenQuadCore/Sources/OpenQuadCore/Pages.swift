// What the calibration wizards print: the framed grey-balance target and comparison
// page (openquad/targets.py, greybalance.py) and the process chart (openquad/chart.py).

import Foundation

extension Targets {
    /// The grey-balance target as neutral 16-bit RGB (R = G = B) on white paper.
    public static func framedTarget(layout: FramedLayout = FramedLayout(), dpi: Double = 300) -> RGBImage {
        func px(_ inches: Double) -> Int { pyRound(inches * dpi) }
        let levels = wedgeLevels(layout.steps)
        let height = px(layout.height), width = px(layout.width)
        var grey = [UInt16](repeating: UInt16(maxValue), count: width * height)
        let f = px(layout.frame)
        for y in 0..<height {
            for x in 0..<width where y < f || y >= height - f || x < f || x >= width - f { grey[y * width + x] = 0 }
        }
        for box in layout.patchBoxes() {
            fill(&grey, width: width, height: height, rows: px(box.top)..<px(box.bottom),
                 columns: px(box.left)..<px(box.right), value: levels[box.level])
        }
        return RGBImage(width: width, height: height, pixels: grey.flatMap { [$0, $0, $0] })
    }

    /// Set a block (clamped to the image, as numpy slicing is) to one value.
    static func fill(_ pixels: inout [UInt16], width: Int, height: Int, rows: Range<Int>, columns: Range<Int>, value: UInt16) {
        for y in pySlice(rows.lowerBound, rows.upperBound, height) {
            for x in pySlice(columns.lowerBound, columns.upperBound, width) { pixels[y * width + x] = value }
        }
    }
}

extension Calibration {
    /// No correction: each channel sends every level unchanged.
    public static func identity(steps: Int = 21) -> Calibration {
        let levels = Array(Targets.wedgeLevels(steps).reversed())
        return try! Calibration(levels: levels, curves: [levels, levels, levels])
    }
}

extension GreyBalance {
    /// One page: the uncorrected target above, the corrected one below; scanned together,
    /// both get identical scanner processing. One black square marks the uncorrected
    /// target, two the corrected.
    public static func comparisonPage(_ calibration: Calibration, dpi: Double = 300) -> RGBImage {
        let plain = Targets.framedTarget(dpi: dpi)
        let corrected = calibration.apply(plain.pixels)
        let h = plain.height, w = plain.width
        let gap = pyRound(1.0 * dpi), mark = pyRound(0.15 * dpi), lead = pyRound(0.4 * dpi), pad = pyRound(0.07 * dpi)
        let width = w + lead, height = 2 * h + gap
        var page = [UInt16](repeating: UInt16(maxValue), count: width * height * 3)
        for y in 0..<h {
            let row = y * w * 3
            page.replaceSubrange(((y * width + lead) * 3)..<((y * width + lead + w) * 3), with: plain.pixels[row..<(row + w * 3)])
            let target = ((y + h + gap) * width + lead) * 3
            page.replaceSubrange(target..<(target + w * 3), with: corrected[row..<(row + w * 3)])
        }
        for (count, top) in [(1, 0), (2, h + gap)] {
            for i in 0..<count {
                let y0 = top + pad + i * (mark + pad)
                for y in pySlice(y0, y0 + mark, height) {
                    for x in pySlice(pad, pad + mark, width) {
                        for c in 0..<3 { page[(y * width + x) * 3 + c] = 0 }
                    }
                }
            }
        }
        return RGBImage(width: width, height: height, pixels: page)
    }
}

extension Chart {
    /// Inches of clear film between stacked charts.
    public static let pageGap = 0.3

    /// The chart as the photo it stands for (before inversion): black background, the 101
    /// patches, the strip, the gradient, a white marker and `index` identification squares.
    public static func photo(layout: ChartLayout = ChartLayout(), dpi: Double = 300, index: Int = 0) -> (pixels: [UInt16], width: Int, height: Int) {
        precondition((0...ChartLayout.maxID).contains(index), "chart index must be 0-\(ChartLayout.maxID)")
        let height = pyRound(layout.height * dpi), width = pyRound(layout.width * dpi)
        var photo = [UInt16](repeating: 0, count: width * height)
        func fill(_ box: (Double, Double, Double, Double), _ value: UInt16) {
            Targets.fill(&photo, width: width, height: height, rows: pyRound(box.1 * dpi)..<max(pyRound(box.1 * dpi), pyRound(box.3 * dpi)),
                         columns: pyRound(box.0 * dpi)..<max(pyRound(box.0 * dpi), pyRound(box.2 * dpi)), value: value)
        }
        fill(layout.markerBox(), UInt16(maxValue))  // prints white: full ink on the film
        for k in 0..<index { fill(layout.idBox(k), UInt16(maxValue)) }
        for n in 0..<ChartLayout.patches { fill(layout.patchBox(n), patchLevel(n)) }
        for step in 0..<ChartLayout.strip {
            fill(layout.stripBox(step), UInt16(pyRound(Double(maxValue) * (1 - Double(step) / Double(ChartLayout.strip - 1)))))
        }
        let g = (layout.gradientLeft, layout.gridTop, layout.gradientLeft + layout.gradientWidth, layout.gridTop + layout.gridHeight)
        let top = pyRound(g.1 * dpi), bottom = pyRound(g.3 * dpi)
        let ramp = linspace(Double(maxValue), 0, bottom - top).map { UInt16(rint($0)) }
        for (i, y) in (top..<bottom).enumerated() {
            Targets.fill(&photo, width: width, height: height, rows: y..<(y + 1),
                         columns: pyRound(g.0 * dpi)..<pyRound(g.2 * dpi), value: ramp[i])
        }
        return (photo, width, height)
    }

    /// The chart printed as a negative, through `process` if given.
    public static func negative(colour: String = "green", process: ProcessCurve? = nil, mirror: Bool = false, dpi: Double = 300,
                                layout: ChartLayout = ChartLayout(), index: Int = 0) -> RGBImage {
        let chart = photo(layout: layout, dpi: dpi, index: index)
        let shaped = process?.apply(chart.pixels) ?? chart.pixels
        return Negative.make(shaped, width: chart.width, height: chart.height,
                             settings: NegativeSettings(colour: colour, mirror: mirror), dpi: dpi)
    }

    /// Several compact charts stacked on one page, one per colour; chart k carries k
    /// identification squares, so a scan of the page says which is which.
    public static func page(colours: [String], processes: [ProcessCurve?]? = nil, mirror: Bool = false, dpi: Double = 300) -> RGBImage {
        precondition((1...(ChartLayout.maxID + 1)).contains(colours.count), "a page holds 1-\(ChartLayout.maxID + 1) charts")
        let processes = processes ?? Array(repeating: nil, count: colours.count)
        precondition(processes.count == colours.count, "give one process curve (or none) per colour")
        let charts = zip(colours, processes).enumerated().map { k, pair in
            negative(colour: pair.0, process: pair.1, mirror: mirror, dpi: dpi, layout: .compact(), index: k)
        }
        let gap = pyRound(pageGap * dpi), width = charts[0].width
        let height = charts.map(\.height).reduce(0, +) + gap * (charts.count - 1)
        var page = [UInt16](repeating: UInt16(maxValue), count: width * height * 3)  // clear film
        var top = 0
        for chart in charts {
            page.replaceSubrange((top * width * 3)..<((top + chart.height) * width * 3), with: chart.pixels)
            top += chart.height + gap
        }
        return RGBImage(width: width, height: height, pixels: page)
    }
}

// MARK: files the runs keep

/// numpy round(x, decimals): multiply, round half to even, divide.
func npRound(_ x: Double, _ decimals: Int) -> Double {
    let scale = pow(10.0, Double(decimals))
    return rint(x * scale) / scale
}

func jsonText(_ object: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
}

extension Measurement {
    /// The `openquad-measurement` JSON, rounded as Python writes it.
    public func json() throws -> String {
        try jsonText([
            "format": "openquad-measurement", "version": 1,
            "levels": levels.map(Int.init), "sent": sent.map { $0.map(Int.init) },
            "rgb": rgb.map { $0.map { npRound($0, 6) } }, "lab": lab.map { $0.map { npRound($0, 3) } },
        ] as [String: Any])
    }

    /// The largest |a*| or |b*| of any patch.
    public func worstCast() -> Double { lab.flatMap { [abs($0[1]), abs($0[2])] }.max() ?? 0 }
}

extension ChartReading {
    /// The `openquad-chart-reading` JSON, rounded as Python writes it.
    public func json() throws -> String {
        try jsonText([
            "format": "openquad-chart-reading", "version": 1, "levels": levels.map(Int.init),
            "lightness": lightness.map { npRound($0, 3) }, "strip": strip.map { npRound($0, 3) },
            "orientation": orientation, "paper": pyRound(paper, 3),
        ] as [String: Any])
    }

    struct File: Codable {
        var format: String
        var levels: [Int]
        var lightness: [Double]
        var strip: [Double]?
        var orientation: String?
        var paper: Double?
    }

    public static func decode(_ data: Data) throws -> ChartReading {
        guard let file = try? JSONDecoder().decode(File.self, from: data), file.format == "openquad-chart-reading",
              file.levels.count == file.lightness.count else {
            throw FileFormatError(description: "not an OpenQuad chart reading")
        }
        return ChartReading(levels: file.levels.map { UInt16(clamping: $0) }, lightness: file.lightness, strip: file.strip ?? [],
                            orientation: file.orientation ?? "", paper: file.paper ?? 100)
    }
}
