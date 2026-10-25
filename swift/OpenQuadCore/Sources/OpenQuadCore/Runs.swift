// Calibration runs: the print, scan, measure, improve loop for a printer
// (openquad/calibrate.py) and for a negative process (openquad/process_run.py). Every
// file and a run.json log are kept in the run's folder, in the same format as the
// Python version, so either can inspect or continue a run.

import Foundation

public struct RunError: Error, Equatable, CustomStringConvertible {
    public let description: String
}

func validRunName(_ name: String) -> Bool {
    !name.trimmingCharacters(in: .whitespaces).isEmpty && !name.contains("/") && !name.contains("\\")
}

func writeText(_ text: String, to url: URL) throws {
    try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
}

// MARK: - printer calibration

/// How a corrected print measured against the goals.
public struct Assessment: Sendable, Equatable {
    public static let castGoal = 3.0  // largest |a*| or |b*|
    public static let meanCastGoal = 1.0
    public static let toneGoal = 2.0  // largest L* error

    public var worstCast, meanCast, worstTone, meanTone, uncorrectedCast: Double

    /// "grey balance", "linearize" or "done".
    public var nextStep: String {
        if worstCast >= Self.castGoal || meanCast > Self.meanCastGoal { return "grey balance" }
        if worstTone >= Self.toneGoal { return "linearize" }
        return "done"
    }

    public func summary() -> String {
        String(format: "Colour cast: worst %.1f, mean %.2f (goal under %g). Tone: worst %.1f L*, mean %.2f (goal under %g). "
               + "Uncorrected cast on the same page: %.1f.",
               worstCast, meanCast, Self.castGoal, worstTone, meanTone, Self.toneGoal, uncorrectedCast)
    }

    var dictionary: [String: Double] {
        ["worst_cast": worstCast, "mean_cast": meanCast, "worst_tone": worstTone, "mean_tone": meanTone,
         "uncorrected_cast": uncorrectedCast]
    }

    public static func assess(uncorrected: Measurement, corrected: Measurement) -> Assessment {
        let casts = corrected.lab.flatMap { [abs($0[1]), abs($0[2])] }
        let errors = Linearize.toneErrors(corrected).map(abs)
        return Assessment(worstCast: casts.max() ?? 0, meanCast: npMean(casts), worstTone: errors.max() ?? 0,
                          meanTone: npMean(errors), uncorrectedCast: uncorrected.worstCast())
    }
}

extension Linearize {
    /// Measured minus target L* for each step, in level order (openquad tone_report).
    public static func toneErrors(_ measurement: Measurement) -> [Double] {
        let order = measurement.byLevel
        let measured = order.map { measurement.lab[$0][0] }
        let paper = measured.max() ?? 100, black = measured.min() ?? 0
        return zip(order, measured).map { i, l in l - targetLightness(Double(measurement.levels[i]), paper: paper, black: black) }
    }
}

public struct CalibrationRound: Sendable, Equatable {
    public var version: Int
    public var calibration: String
    public var page: String?
    public var job: String?
    public var scan: String?
    public var measurements: [String] = []
    public var assessment: [String: Double]?
    public var action: String?

    var dictionary: [String: Any] {
        ["version": version, "calibration": calibration, "page": page ?? NSNull(), "job": job ?? NSNull(),
         "scan": scan ?? NSNull(), "measurements": measurements, "assessment": assessment ?? NSNull(),
         "action": action ?? NSNull()]
    }

    init(version: Int, calibration: String) {
        self.version = version
        self.calibration = calibration
    }

    init(_ d: [String: Any]) throws {
        guard let version = d["version"] as? Int, let calibration = d["calibration"] as? String else {
            throw RunError(description: "run.json: a round has no version or calibration")
        }
        self.version = version
        self.calibration = calibration
        page = d["page"] as? String
        job = d["job"] as? String
        scan = d["scan"] as? String
        measurements = d["measurements"] as? [String] ?? []
        assessment = (d["assessment"] as? [String: NSNumber])?.mapValues(\.doubleValue)
        action = d["action"] as? String
    }
}

/// One step at a time: the wizard runs each step off the main thread and waits for it.
public final class CalibrationRun: @unchecked Sendable {
    public static let pagePPI = 300.0
    public static let defaultSettings = "default quality; eSCL Document intent"

    public let folder: URL
    public let name: String
    public let printer: String
    public let paper: String
    public var scannerHost: String
    public private(set) var rounds: [CalibrationRound]

    init(folder: URL, name: String, printer: String, paper: String, scannerHost: String, rounds: [CalibrationRound]) {
        self.folder = folder
        self.name = name
        self.printer = printer
        self.paper = paper
        self.scannerHost = scannerHost
        self.rounds = rounds
    }

    /// A new run in `folder`, starting from `starting` (default: no correction).
    /// `paperLabel` (e.g. "Letter plain") names the paper in the calibration files; the
    /// run itself keeps `paper` as the page size it prints on.
    public static func start(folder: URL, name: String, printer: String, paper: String = "Letter", scannerHost: String = "",
                             starting: Calibration? = nil, settings: String = defaultSettings,
                             paperLabel: String? = nil) throws -> CalibrationRun {
        guard validRunName(name) else { throw RunError(description: "invalid calibration name \(pyRepr(name))") }
        let run = CalibrationRun(folder: folder, name: name.trimmingCharacters(in: .whitespaces), printer: printer,
                                 paper: paper, scannerHost: scannerHost, rounds: [])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = starting ?? .identity()
        let calibration = try Calibration(levels: base.levels, curves: base.curves, printer: printer,
                                          paper: paperLabel ?? paper, settings: base.settings.isEmpty ? settings : base.settings,
                                          created: ISO8601DateFormatter().string(from: Date()))
        try run.newRound(calibration)
        return run
    }

    public static func resume(_ folder: URL) throws -> CalibrationRun {
        let data = try Data(contentsOf: folder.appendingPathComponent("run.json"))
        guard let d = try JSONSerialization.jsonObject(with: data) as? [String: Any], let name = d["name"] as? String,
              let printer = d["printer"] as? String, let rounds = d["rounds"] as? [[String: Any]] else {
            throw RunError(description: "not an OpenQuad calibration run")
        }
        return CalibrationRun(folder: folder, name: name, printer: printer, paper: d["paper"] as? String ?? "Letter",
                              scannerHost: d["scanner_host"] as? String ?? "", rounds: try rounds.map(CalibrationRound.init))
    }

    func saveLog() throws {
        try writeText(try jsonText(["name": name, "printer": printer, "paper": paper, "scanner_host": scannerHost,
                                    "rounds": rounds.map(\.dictionary)] as [String: Any]),
                      to: folder.appendingPathComponent("run.json"))
    }

    func newRound(_ calibration: Calibration) throws {
        let version = rounds.count
        let file = "\(name)-v\(version).oqcal"
        try calibration.encode().write(to: folder.appendingPathComponent(file))
        rounds.append(CalibrationRound(version: version, calibration: file))
        try saveLog()
    }

    public var current: CalibrationRound { rounds[rounds.count - 1] }
    public var calibrationPath: URL { folder.appendingPathComponent(current.calibration) }
    public func calibration() throws -> Calibration { try Calibration.decode(Data(contentsOf: calibrationPath)) }

    func file(_ kind: String, _ suffix: String) -> URL {
        folder.appendingPathComponent("\(name)-v\(current.version)-\(kind)\(suffix)")
    }

    /// The comparison page for this round: uncorrected above, current calibration below.
    @discardableResult
    public func makePage() throws -> URL {
        let url = file("page", ".tif")
        try ImageFiles.saveRGB(url, GreyBalance.comparisonPage(try calibration(), dpi: Self.pagePPI),
                               dpi: (Self.pagePPI, Self.pagePPI), iccProfile: ImageFiles.srgbProfile())
        rounds[rounds.count - 1].page = url.lastPathComponent
        try saveLog()
        return url
    }

    public var pageURL: URL? { current.page.map { folder.appendingPathComponent($0) } }

    /// Print the page through lp; returns the CUPS job id.
    public func printPage(runner: Printing.Runner = Printing.runCommand) throws -> String {
        let page = try pageURL ?? makePage()
        let job = try PrintJob(path: page.path, printer: printer, paper: paper, ppi: Self.pagePPI,
                               title: "OpenQuad calibration: \(name) v\(current.version)")
        let id = try Printing.send(job, runner: runner)
        rounds[rounds.count - 1].job = id
        try saveLog()
        return id
    }

    /// Record that the page was printed another way (the print panel, another app).
    public func markPrinted(_ note: String) throws {
        if current.page == nil { try makePage() }
        rounds[rounds.count - 1].job = note
        try saveLog()
    }

    @discardableResult
    public func scanPage(fetch: ESCL.Fetch = ESCL.httpFetch) throws -> URL {
        guard !scannerHost.isEmpty else { throw RunError(description: "no scanner chosen") }
        let url = file("scan", ".jpg")
        try ESCL.scan(host: scannerHost, settings: try ScanSettings(), fetch: fetch).write(to: url)
        rounds[rounds.count - 1].scan = url.lastPathComponent
        try saveLog()
        return url
    }

    /// Use a scan made some other way (copied into the run's folder).
    public func useScan(_ source: URL) throws {
        let suffix = source.pathExtension.isEmpty ? ".jpg" : "." + source.pathExtension
        let target = file("scan", suffix)
        try Data(contentsOf: source).write(to: target)
        rounds[rounds.count - 1].scan = target.lastPathComponent
        try saveLog()
    }

    public func measure() throws -> (Measurement, Measurement, Assessment) {
        guard let scan = current.scan else { throw RunError(description: "scan the printed page first") }
        let sent = try calibration().sentFor(Targets.wedgeLevels(21))
        let rows = stride(from: 0, to: sent.count, by: 3).map { Array(sent[$0..<($0 + 3)]) }
        let (plain, corrected) = try Measure.measurePair(try Scan.load(folder.appendingPathComponent(scan)), sent: rows)
        var names: [String] = []
        for (kind, measurement) in [("uncorrected", plain), ("corrected", corrected)] {
            let url = file(kind, ".json")
            try writeText(try measurement.json(), to: url)
            names.append(url.lastPathComponent)
        }
        let result = Assessment.assess(uncorrected: plain, corrected: corrected)
        rounds[rounds.count - 1].measurements = names
        rounds[rounds.count - 1].assessment = result.dictionary
        try saveLog()
        return (plain, corrected, result)
    }

    public func measurements() throws -> (Measurement, Measurement) {
        guard current.measurements.count == 2 else { throw RunError(description: "measure the scan first") }
        let read = { try Measurement.decode(Data(contentsOf: self.folder.appendingPathComponent($0))) }
        return (try read(current.measurements[0]), try read(current.measurements[1]))
    }

    /// Build the next calibration ("grey balance" or "linearize"); returns its file.
    @discardableResult
    public func improve(_ action: String, damping: Double = 1.0, shadowDamping: Double? = 0.5) throws -> URL {
        let (_, measurement) = try measurements()
        let current = try calibration()
        let next: Calibration
        switch action {
        case "grey balance":
            next = try GreyBalance.build(measurement, damping: damping, shadowDamping: shadowDamping, printer: printer,
                                         paper: current.paper.isEmpty ? paper : current.paper, settings: current.settings)
        case "linearize":
            next = try Linearize.linearize(current, measurement)
        default:
            throw RunError(description: "unknown action \(pyRepr(action))")
        }
        rounds[rounds.count - 1].action = action
        try newRound(next)
        return calibrationPath
    }
}

// MARK: - negative process calibration

public struct ProcessResult: Sendable, Equatable {
    public static let toneGoal = 3.0  // every patch within this many L* of its target
    public var worst, mean, white, black: Double
    public var done: Bool { worst < Self.toneGoal }

    public init(_ reading: ChartReading) {
        let errors = reading.toneErrors().map(abs)
        worst = errors.max() ?? 0
        mean = npMean(errors)
        white = reading.white
        black = reading.black
    }

    init(worst: Double, mean: Double, white: Double, black: Double) {
        (self.worst, self.mean, self.white, self.black) = (worst, mean, white, black)
    }

    var dictionary: [String: Double] { ["worst": worst, "mean": mean, "white": white, "black": black] }
}

public struct ProcessRound: Sendable, Equatable {
    public var version: Int
    public var curves: [String: String]
    public var page: String?
    public var job: String?
    public var scan: String?
    public var readings: [String: String] = [:]
    public var results: [String: [String: Double]] = [:]
    public var refined = false

    init(version: Int, curves: [String: String]) {
        self.version = version
        self.curves = curves
    }

    init(_ d: [String: Any]) throws {
        guard let version = d["version"] as? Int, let curves = d["curves"] as? [String: String] else {
            throw RunError(description: "run.json: a round has no version or curves")
        }
        self.version = version
        self.curves = curves
        page = d["page"] as? String
        job = d["job"] as? String
        scan = d["scan"] as? String
        readings = d["readings"] as? [String: String] ?? [:]
        results = (d["results"] as? [String: [String: NSNumber]])?.mapValues { $0.mapValues(\.doubleValue) } ?? [:]
        refined = d["refined"] as? Bool ?? false
    }

    var dictionary: [String: Any] {
        ["version": version, "curves": curves, "page": page ?? NSNull(), "job": job ?? NSNull(), "scan": scan ?? NSNull(),
         "readings": readings, "results": results, "refined": refined]
    }
}

/// One step at a time: the wizard runs each step off the main thread and waits for it.
public final class ProcessRun: @unchecked Sendable {
    public static let pagePPI = 300.0

    public let folder: URL
    public let name: String
    public let colours: [String]
    public var printer: String
    public let paper: String
    public var scannerHost: String
    public let mirror: Bool
    public let film: String
    public let printing: String
    public private(set) var rounds: [ProcessRound]

    init(folder: URL, name: String, colours: [String], printer: String, paper: String, scannerHost: String,
         mirror: Bool, film: String, printing: String, rounds: [ProcessRound]) {
        self.folder = folder
        self.name = name
        self.colours = colours
        self.printer = printer
        self.paper = paper
        self.scannerHost = scannerHost
        self.mirror = mirror
        self.film = film
        self.printing = printing
        self.rounds = rounds
    }

    public static func start(folder: URL, name: String, colours: [String], printer: String = "", paper: String = "Letter",
                             scannerHost: String = "", mirror: Bool = false, film: String = "", printing: String = "",
                             starting: [String: ProcessCurve] = [:]) throws -> ProcessRun {
        guard validRunName(name) else { throw RunError(description: "invalid name \(pyRepr(name))") }
        guard (1...5).contains(colours.count), colours.allSatisfy({ Negative.colours[$0] != nil }) else {
            throw RunError(description: "choose 1-5 colours from \(Negative.colourOrder.joined(separator: ", "))")
        }
        let run = ProcessRun(folder: folder, name: name.trimmingCharacters(in: .whitespaces), colours: colours, printer: printer,
                             paper: paper, scannerHost: scannerHost, mirror: mirror, film: film, printing: printing, rounds: [])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try run.newRound(Dictionary(uniqueKeysWithValues: colours.map { ($0, starting[$0] ?? .identity(colour: $0)) }))
        return run
    }

    public static func resume(_ folder: URL) throws -> ProcessRun {
        let data = try Data(contentsOf: folder.appendingPathComponent("run.json"))
        guard let d = try JSONSerialization.jsonObject(with: data) as? [String: Any], let name = d["name"] as? String,
              let colours = d["colours"] as? [String], let rounds = d["rounds"] as? [[String: Any]] else {
            throw RunError(description: "not an OpenQuad process run")
        }
        return ProcessRun(folder: folder, name: name, colours: colours, printer: d["printer"] as? String ?? "",
                          paper: d["paper"] as? String ?? "Letter", scannerHost: d["scanner_host"] as? String ?? "",
                          mirror: d["mirror"] as? Bool ?? false, film: d["film"] as? String ?? "",
                          printing: d["printing"] as? String ?? "", rounds: try rounds.map(ProcessRound.init))
    }

    func saveLog() throws {
        try writeText(try jsonText(["name": name, "colours": colours, "printer": printer, "paper": paper,
                                    "scanner_host": scannerHost, "mirror": mirror, "film": film, "printing": printing,
                                    "rounds": rounds.map(\.dictionary)] as [String: Any]),
                      to: folder.appendingPathComponent("run.json"))
    }

    func newRound(_ curves: [String: ProcessCurve]) throws {
        let version = rounds.count
        var names: [String: String] = [:]
        for colour in colours {
            let file = "\(name)-\(colour)-v\(version).oqproc"
            try curves[colour]!.encode().write(to: folder.appendingPathComponent(file))
            names[colour] = file
        }
        rounds.append(ProcessRound(version: version, curves: names))
        try saveLog()
    }

    public var current: ProcessRound { rounds[rounds.count - 1] }
    public func curvePath(_ colour: String) -> URL { folder.appendingPathComponent(current.curves[colour]!) }
    public func curve(_ colour: String) throws -> ProcessCurve { try ProcessCurve.decode(Data(contentsOf: curvePath(colour))) }

    func file(_ kind: String, _ suffix: String) -> URL {
        folder.appendingPathComponent("\(name)-v\(current.version)-\(kind)\(suffix)")
    }

    /// This round's page of charts (to print here or from another app at 300 ppi).
    @discardableResult
    public func makePage() throws -> URL {
        let url = file("page", ".tif")
        let page = Chart.page(colours: colours, processes: try colours.map { try curve($0) }, mirror: mirror, dpi: Self.pagePPI)
        try ImageFiles.saveRGB(url, page, dpi: (Self.pagePPI, Self.pagePPI), iccProfile: ImageFiles.srgbProfile())
        rounds[rounds.count - 1].page = url.lastPathComponent
        try saveLog()
        return url
    }

    public var pageURL: URL? { current.page.map { folder.appendingPathComponent($0) } }

    public func printPage(runner: Printing.Runner = Printing.runCommand) throws -> String {
        guard !printer.isEmpty else { throw RunError(description: "no printer chosen") }
        let page = try pageURL ?? makePage()
        let job = try PrintJob(path: page.path, printer: printer, paper: paper, ppi: Self.pagePPI,
                               title: "OpenQuad process chart: \(name) v\(current.version)")
        let id = try Printing.send(job, runner: runner)
        rounds[rounds.count - 1].job = id
        try saveLog()
        return id
    }

    /// Record that the page was printed outside this run (the print panel, GIMP).
    public func markPrinted(_ note: String = "printed elsewhere") throws {
        if current.page == nil { try makePage() }
        rounds[rounds.count - 1].job = note
        try saveLog()
    }

    @discardableResult
    public func scanPage(fetch: ESCL.Fetch = ESCL.httpFetch) throws -> URL {
        guard !scannerHost.isEmpty else { throw RunError(description: "no scanner chosen") }
        let url = file("scan", ".jpg")
        try ESCL.scan(host: scannerHost, settings: try ScanSettings(), fetch: fetch).write(to: url)
        rounds[rounds.count - 1].scan = url.lastPathComponent
        try saveLog()
        return url
    }

    /// Use a scan made some other way (copied into the run's folder).
    public func useScan(_ source: URL) throws {
        let suffix = source.pathExtension.isEmpty ? ".jpg" : "." + source.pathExtension
        let target = file("scan", suffix)
        try Data(contentsOf: source).write(to: target)
        rounds[rounds.count - 1].scan = target.lastPathComponent
        try saveLog()
    }

    public func measure() throws -> [String: ProcessResult] {
        guard let scan = current.scan else { throw RunError(description: "scan the contact print first") }
        let readings = try Chart.readPage(try Scan.load(folder.appendingPathComponent(scan)), count: colours.count)
        var results: [String: ProcessResult] = [:]
        for (colour, reading) in zip(colours, readings) {
            let url = file("\(colour)-reading", ".json")
            try writeText(try reading.json(), to: url)
            rounds[rounds.count - 1].readings[colour] = url.lastPathComponent
            let result = ProcessResult(reading)
            rounds[rounds.count - 1].results[colour] = result.dictionary
            results[colour] = result
        }
        try saveLog()
        return results
    }

    public func readings() throws -> [String: ChartReading] {
        try current.readings.mapValues { try ChartReading.decode(Data(contentsOf: folder.appendingPathComponent($0))) }
    }

    public func results() -> [String: ProcessResult] {
        current.results.compactMapValues { r in
            guard let worst = r["worst"], let mean = r["mean"], let white = r["white"], let black = r["black"] else { return nil }
            return ProcessResult(worst: worst, mean: mean, white: white, black: black)
        }
    }

    /// The colour closest to target (smallest worst error) in this round.
    public func bestColour() -> String? {
        let results = results()
        return colours.filter { results[$0] != nil }.min { results[$0]!.worst < results[$1]!.worst }
    }

    /// Build the next curve for every colour from this round's readings.
    @discardableResult
    public func refine() throws -> [String: URL] {
        guard current.readings.count == colours.count else { throw RunError(description: "measure the scan first") }
        let readings = try readings()
        var curves: [String: ProcessCurve] = [:]
        for colour in colours {
            curves[colour] = try ProcessCurve.build(readings[colour]!, previous: try curve(colour), film: film, printing: printing)
        }
        rounds[rounds.count - 1].refined = true
        try newRound(curves)
        return Dictionary(uniqueKeysWithValues: colours.map { ($0, curvePath($0)) })
    }
}
