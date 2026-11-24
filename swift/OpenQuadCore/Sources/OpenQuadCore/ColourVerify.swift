// Checking a colour profile by printing through it, and improving it (phase 3), and a
// colour calibration run from the target onwards. Mirrors openquad/colour_verify.py; the
// run keeps the same run.json (kind "openquad colour run"), with the target's stage and
// the printer's details added, so either version can continue a run.

import Foundation

public enum ColourVerification {
    public static let meanGoal = 3.0  // ΔE00, printable colours
    public static let p95Goal = 6.0
    public static let castGoal = 3.0  // largest C* of a neutral, as for grey
    public static let toneGoal = 2.0  // largest L* error of a neutral
    public static let damping = 0.5
    public static let correctionSmoothing = 0.03
    public static let randomColours = 100
    static let shuffleSeed: UInt32 = 17
    static let colourSeed: UInt32 = 13

    /// A colour-checker chart's 24 colours, as commonly published (L*a*b*, D50).
    public static let checker: [(String, Double, Double, Double)] = [
        ("dark skin", 37.54, 14.37, 14.92), ("light skin", 64.66, 19.27, 17.50), ("blue sky", 49.32, -3.82, -22.54),
        ("foliage", 43.46, -12.74, 22.72), ("blue flower", 54.94, 9.61, -24.79), ("bluish green", 70.48, -32.26, -0.37),
        ("orange", 62.73, 35.83, 56.50), ("purplish blue", 39.43, 10.75, -45.17), ("moderate red", 50.57, 48.64, 16.67),
        ("purple", 30.10, 22.54, -20.87), ("yellow green", 71.77, -24.13, 58.19), ("orange yellow", 71.51, 18.24, 67.37),
        ("blue", 28.37, 15.42, -49.80), ("green", 54.38, -39.72, 32.27), ("red", 42.43, 51.05, 28.62),
        ("yellow", 81.80, 2.67, 80.41), ("magenta", 50.63, 51.28, -14.12), ("cyan", 49.57, -29.71, -28.32),
        ("white", 95.19, -1.03, 2.93), ("neutral 8", 81.29, -0.57, 0.44), ("neutral 6.5", 66.89, -0.75, -0.06),
        ("neutral 5", 50.76, -0.13, 0.14), ("neutral 3.5", 35.63, -0.46, -0.48), ("black", 20.64, 0.07, -0.46),
    ]
    /// Skin tones from deep to fair (L*a*b*, D50).
    public static let skin: [(String, Double, Double, Double)] = [
        ("skin 1", 30.0, 12.0, 14.0), ("skin 2", 38.0, 14.0, 17.0), ("skin 3", 46.0, 15.0, 19.0), ("skin 4", 54.0, 15.0, 20.0),
        ("skin 5", 62.0, 14.0, 19.0), ("skin 6", 69.0, 12.0, 17.0), ("skin 7", 75.0, 10.0, 15.0), ("skin 8", 81.0, 8.0, 13.0),
    ]
    public static let neutrals = linspace(15, 95, 12)

    /// (names, groups, wanted L*a*b*) of the verification page, unshuffled.
    public static func colours(_ count: Int = randomColours) -> ([String], [String], [[Double]]) {
        var names = checker.map(\.0) + skin.map(\.0)
        var groups = [String](repeating: "checker", count: checker.count) + [String](repeating: "skin", count: skin.count)
        var wanted = (checker + skin).map { [$0.1, $0.2, $0.3] }
        for l in neutrals {
            names.append("grey L* \(String(format: "%.0f", l))")
            groups.append("neutral")
            wanted.append([l, 0, 0])
        }
        var rng = NumpyRandom(seed: colourSeed)
        let values = rng.uniform(0.03, 0.97, count: count * 3)
        for i in 0..<count {
            let rgb = Array(values[(3 * i)..<(3 * i + 3)])
            names.append("photo \(i + 1) (sRGB \(rgb.map { String(pyRound(255 * $0)) }.joined(separator: " ")))")
            groups.append("photo")
            wanted.append(Colour.xyzToLab(Colour.srgbToD50(rgb), white: Colour.d50White))
        }
        return (names, groups, wanted)
    }

    /// The verification page for a profile's model: each colour sent as its inverse, shuffled.
    public static func make(_ model: ForwardModel, count: Int = randomColours) throws -> VerificationTarget {
        let (names, groups, wanted) = colours(count)
        let rgb = ColourProfiles.invert(model, wanted)
        let printable = zip(rgb, wanted).map { Colour.deltaE76(model.lab($0), $1) <= ColourProfiles.gamutLimit }
        var rng = NumpyRandom(seed: shuffleSeed)
        let order = rng.permutation(wanted.count)
        let sent = rgb.map { $0.map { UInt16(rint($0 * Double(maxValue))) } }
        return VerificationTarget(target: try ColourTargets.layout(order.map { sent[$0] }), names: order.map { names[$0] },
                                  groups: order.map { groups[$0] }, wanted: order.map { wanted[$0] }, printable: order.map { printable[$0] })
    }

    public static func verify(_ measurement: ColourMeasurement, _ verification: VerificationTarget) throws -> VerificationReport {
        guard measurement.sent == verification.target.sent else {
            throw ProfileError(description: "the measurement isn't of this verification page")
        }
        return VerificationReport(verification: verification, measured: measurement.lab,
                                  deltaE: zip(measurement.lab, verification.wanted).map { Colour.deltaE2000($0, $1) })
    }

    /// The model, corrected towards what a verification page measured: the measured minus
    /// predicted difference at each RGB sent, fitted with a smooth lattice of its own, and
    /// `damping` of it added.
    public static func refine(_ model: ForwardModel, _ measurement: ColourMeasurement, damping: Double = damping,
                              smoothing: Double = correctionSmoothing) throws -> ForwardModel {
        guard damping > 0, damping <= 1 else { throw ProfileError(description: "damping must be over 0 and at most 1, got \(String(format: "%g", damping))") }
        let rgb = measurement.sent.map { $0.map { Double($0) / Double(maxValue) } }
        let residual = zip(measurement.lab, rgb).map { lab, rgb in zip(lab, model.lab(rgb)).map { $0 - $1 } }
        let correction = try ColourProfiles.fitLattice(rgb, residual, smoothing: smoothing, n: model.size)
        return ForwardModel(nodes: zip(model.nodes, correction).map { $0 + damping * $1 }, smoothing: model.smoothing,
                            paperXYZ: model.paperXYZ)
    }
}

/// The verification page: what each patch sent, and what it should measure.
public struct VerificationTarget: Sendable, Equatable {
    public let target: ColourTarget
    public let names: [String]
    public let groups: [String]
    public let wanted: [[Double]]
    public let printable: [Bool]  // the model expects the printer can make it

    public func json() throws -> String {
        let target = try JSONSerialization.jsonObject(with: Data(try self.target.json().utf8))
        return try jsonCompact([
            "kind": "openquad colour verification", "version": 1, "target": target, "names": names, "groups": groups,
            "wanted": wanted.map { $0.map { npRound($0, 4) } }, "printable": printable,
        ] as [String: Any])
    }

    public static func decode(_ data: Data) throws -> VerificationTarget {
        guard let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              d["kind"] as? String == "openquad colour verification", let target = d["target"],
              let names = d["names"] as? [String], let groups = d["groups"] as? [String],
              let wanted = d["wanted"] as? [[NSNumber]], let printable = d["printable"] as? [Bool] else {
            throw ProfileError(description: "not an OpenQuad colour verification layout")
        }
        return VerificationTarget(target: try ColourTarget.decode(try JSONSerialization.data(withJSONObject: target)), names: names,
                                  groups: groups, wanted: wanted.map { $0.map(\.doubleValue) }, printable: printable)
    }
}

/// How close each verification colour printed to what was wanted.
public struct VerificationReport: Sendable, Equatable {
    public let verification: VerificationTarget
    public let measured: [[Double]]
    public let deltaE: [Double]

    var printable: [Bool] { verification.printable }
    func chosen(_ group: String?) -> [Int] {
        deltaE.indices.filter { printable[$0] && (group == nil || verification.groups[$0] == group) }
    }

    public var mean: Double { npMean(chosen(nil).map { deltaE[$0] }) }
    public var p95: Double { percentile(chosen(nil).map { deltaE[$0] }, [95])[0] }

    public func groupMean(_ group: String) -> Double {
        let picked = chosen(group)
        return picked.isEmpty ? .nan : npMean(picked.map { deltaE[$0] })
    }

    public var worstCast: Double { chosen("neutral").map { hypot(measured[$0][1], measured[$0][2]) }.max() ?? 0 }
    public var worstTone: Double { chosen("neutral").map { abs(measured[$0][0] - verification.wanted[$0][0]) }.max() ?? 0 }

    public var passed: Bool {
        mean < ColourVerification.meanGoal && p95 < ColourVerification.p95Goal && worstCast < ColourVerification.castGoal
            && worstTone < ColourVerification.toneGoal
    }

    public var assessment: [String: Double] {
        ["mean": npRound(mean, 3), "p95": npRound(p95, 3), "checker": npRound(groupMean("checker"), 3),
         "skin": npRound(groupMean("skin"), 3), "photo": npRound(groupMean("photo"), 3), "worst_cast": npRound(worstCast, 3),
         "worst_tone": npRound(worstTone, 3), "printable": Double(printable.filter { $0 }.count), "patches": Double(deltaE.count)]
    }

    /// The printable patches furthest off, worst first.
    public var furthest: [(String, Double)] {
        chosen(nil).sorted { deltaE[$0] > deltaE[$1] }.prefix(3).map { (verification.names[$0], deltaE[$0]) }
    }

    public func summary() -> String {
        func mark(_ ok: Bool) -> String { ok ? "ok" : "not yet" }
        let a = assessment, outside = Int(a["patches"]! - a["printable"]!)
        typealias V = ColourVerification
        return [
            "\(Int(a["printable"]!)) of \(Int(a["patches"]!)) colours printable"
                + (outside > 0 ? " (\(outside) outside the gamut, left out of the averages)." : "."),
            String(format: "ΔE00: mean %.2f (goal under %g, %@), 95%% %.2f (goal under %g, %@).", a["mean"]!, V.meanGoal,
                   mark(mean < V.meanGoal), a["p95"]!, V.p95Goal, mark(p95 < V.p95Goal)),
            String(format: "Colour checker %.2f, skin %.2f, photo colours %.2f (means).", a["checker"]!, a["skin"]!, a["photo"]!),
            String(format: "Greys: worst cast %.1f (goal under %g, %@), worst tone %.1f L* (goal under %g, %@).", a["worst_cast"]!,
                   V.castGoal, mark(worstCast < V.castGoal), a["worst_tone"]!, V.toneGoal, mark(worstTone < V.toneGoal)),
            "Furthest off: " + furthest.map { "\($0.0) \(String(format: "%.1f", $0.1))" }.joined(separator: "; ") + ".",
            passed ? "Goals met: done." : "Goals not met: refine the profile.",
        ].joined(separator: "\n")
    }

    public func json() throws -> String {
        try jsonText([
            "kind": "openquad colour verification report", "version": 1, "assessment": assessment, "passed": passed,
            "patches": deltaE.indices.map { i -> [String: Any] in
                ["name": verification.names[i], "group": verification.groups[i], "printable": printable[i],
                 "wanted": verification.wanted[i].map { npRound($0, 2) }, "measured": measured[i].map { npRound($0, 2) },
                 "delta_e": npRound(deltaE[i], 3)]
            },
        ] as [String: Any])
    }
}

// MARK: - a run, from the target onwards

/// The colour target's part of a run: printed and scanned once, to build the first profile.
public struct ColourTargetStage: Sendable, Equatable {
    public var grid: Int
    public var layout: String
    public var pages: [String] = []
    public var job: String?
    public var scans: [String] = []
    public var measurement: String?
    public var summary: String?

    var dictionary: [String: Any] {
        ["grid": grid, "layout": layout, "pages": pages, "job": job ?? NSNull(), "scans": scans,
         "measurement": measurement ?? NSNull(), "summary": summary ?? NSNull()]
    }

    init(grid: Int, layout: String) {
        self.grid = grid
        self.layout = layout
    }

    init(_ d: [String: Any]) {
        grid = d["grid"] as? Int ?? 6
        layout = d["layout"] as? String ?? ""
        pages = d["pages"] as? [String] ?? []
        job = d["job"] as? String
        scans = d["scans"] as? [String] ?? []
        measurement = d["measurement"] as? String
        summary = d["summary"] as? String
    }
}

public struct ColourRound: Sendable, Equatable {
    public var version: Int
    public var profile: String
    public var model: String
    public var pages: [String] = []
    public var layout: String?
    public var job: String?
    public var scans: [String] = []
    public var measurement: String?
    public var report: String?
    public var assessment: [String: Double]?
    public var action: String?  // "done" or "refine"

    var dictionary: [String: Any] {
        ["version": version, "profile": profile, "model": model, "pages": pages, "layout": layout ?? NSNull(), "job": job ?? NSNull(),
         "scans": scans, "measurement": measurement ?? NSNull(), "report": report ?? NSNull(),
         "assessment": assessment ?? NSNull(), "action": action ?? NSNull()]
    }

    init(version: Int, profile: String, model: String) {
        self.version = version
        self.profile = profile
        self.model = model
    }

    init(_ d: [String: Any]) throws {
        guard let version = d["version"] as? Int, let profile = d["profile"] as? String, let model = d["model"] as? String else {
            throw RunError(description: "run.json: a round has no version, profile or model")
        }
        self.version = version
        self.profile = profile
        self.model = model
        pages = d["pages"] as? [String] ?? []
        layout = d["layout"] as? String
        job = d["job"] as? String
        scans = d["scans"] as? [String] ?? []
        measurement = d["measurement"] as? String
        report = d["report"] as? String
        assessment = (d["assessment"] as? [String: NSNumber])?.mapValues(\.doubleValue)
        action = d["action"] as? String
    }
}

/// A colour calibration run: the target, then rounds of verification pages. One step at
/// a time, like the grey CalibrationRun.
public final class ColourRun: @unchecked Sendable {
    public static let pagePPI = 300.0
    public static let modelFile = "scanner-model.json"

    public let folder: URL
    public let name: String
    public let description: String
    public let printer: String
    public let paper: String
    /// The paper's name in the profile's label ("Letter plain"); `paper` is the page size.
    public let paperLabel: String
    public let settings: String
    public var scannerHost: String
    /// The pages' resolution (300 ppi; tests use less).
    public let ppi: Double
    /// The scanner model's file in the run's folder, if the scans are read through one.
    public let scannerModel: String?
    public private(set) var target: ColourTargetStage?
    public private(set) var rounds: [ColourRound]

    init(folder: URL, name: String, description: String, printer: String, paper: String, paperLabel: String = "", settings: String,
         scannerHost: String, scannerModel: String?, target: ColourTargetStage?, rounds: [ColourRound], ppi: Double = pagePPI) {
        self.folder = folder
        self.ppi = ppi
        self.name = name
        self.description = description
        self.printer = printer
        self.paper = paper
        self.paperLabel = paperLabel.isEmpty ? paper : paperLabel
        self.settings = settings
        self.scannerHost = scannerHost
        self.scannerModel = scannerModel
        self.target = target
        self.rounds = rounds
    }

    /// A new run in `folder`: the colour target's pages are written, ready to print.
    public static func start(folder: URL, name: String, description: String = "", printer: String, paper: String = "Letter",
                             paperLabel: String = "", settings: String = "", scannerHost: String = "", scannerModel: URL? = nil,
                             grid: Int = 6, ppi: Double = pagePPI) throws -> ColourRun {
        guard validRunName(name) else { throw RunError(description: "invalid profile name \(pyRepr(name))") }
        if let scannerModel { _ = try ScannerModel.decode(Data(contentsOf: scannerModel)) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let scannerModel {
            try Data(contentsOf: scannerModel).write(to: folder.appendingPathComponent(modelFile))
        }
        let typed = description.trimmingCharacters(in: .whitespaces)
        let run = ColourRun(folder: folder, name: trimmed, description: typed.isEmpty ? trimmed : typed, printer: printer, paper: paper,
                            paperLabel: paperLabel, settings: settings, scannerHost: scannerHost, scannerModel: scannerModel == nil ? nil : modelFile,
                            target: ColourTargetStage(grid: grid, layout: "\(trimmed)-target.json"), rounds: [], ppi: ppi)
        let layout = try ColourTargets.make(grid: grid)
        try writeText(try layout.json(), to: folder.appendingPathComponent(run.target!.layout))
        run.target!.pages = try run.writePages(layout, stem: "\(trimmed)-target")
        try run.saveLog()
        return run
    }

    public static func resume(_ folder: URL) throws -> ColourRun {
        let data = try Data(contentsOf: folder.appendingPathComponent("run.json"))
        guard let d = try JSONSerialization.jsonObject(with: data) as? [String: Any], d["kind"] as? String == "openquad colour run",
              let name = d["name"] as? String, let rounds = d["rounds"] as? [[String: Any]] else {
            throw RunError(description: "\(folder.lastPathComponent) isn't a colour calibration run")
        }
        return ColourRun(folder: folder, name: name, description: d["description"] as? String ?? name,
                         printer: d["printer"] as? String ?? "", paper: d["paper"] as? String ?? "Letter",
                         paperLabel: d["paper_label"] as? String ?? "", settings: d["settings"] as? String ?? "", scannerHost: d["scanner_host"] as? String ?? "",
                         scannerModel: d["scanner_model"] as? String, target: (d["target"] as? [String: Any]).map(ColourTargetStage.init),
                         rounds: try rounds.map(ColourRound.init), ppi: exactDouble(d["page_ppi"]) ?? pagePPI)
    }

    func saveLog() throws {
        try writeText(try jsonText([
            "kind": "openquad colour run", "name": name, "description": description, "printer": printer, "paper": paper,
            "paper_label": paperLabel,
            "settings": settings, "scanner_host": scannerHost, "scanner_model": scannerModel ?? NSNull(), "page_ppi": ppi,
            "target": target?.dictionary ?? NSNull(), "rounds": rounds.map(\.dictionary),
        ] as [String: Any]), to: folder.appendingPathComponent("run.json"))
    }

    func url(_ name: String) -> URL { folder.appendingPathComponent(name) }

    func writePages(_ layout: ColourTarget, stem: String) throws -> [String] {
        let count = layout.pages.count
        return try (0..<count).map { page in
            let file = "\(stem)\(count == 1 ? "" : "-\(page + 1)of\(count)").tif"
            try ImageFiles.saveRGB(url(file), layout.page(page, dpi: ppi), dpi: (ppi, ppi),
                                   iccProfile: ImageFiles.srgbProfile())
            return file
        }
    }

    public func loadScannerModel() throws -> ScannerModel? {
        try scannerModel.map { try ScannerModel.decode(Data(contentsOf: url($0))) }
    }

    // MARK: where the run is

    /// The target still needs printing, scanning or measuring.
    public var onTarget: Bool { rounds.isEmpty }
    public var current: ColourRound? { rounds.last }

    /// The pages to print now: the target's, or this round's verification page.
    public var pagesToPrint: [URL] { (onTarget ? target?.pages ?? [] : current?.pages ?? []).map(url) }
    public var printed: Bool { onTarget ? target?.job != nil : current?.job != nil }
    public var pagesNeeded: Int { (onTarget ? target?.pages.count : current?.pages.count) ?? 1 }
    public var scansSoFar: [String] { onTarget ? target?.scans ?? [] : current?.scans ?? [] }
    public var measured: Bool { onTarget ? false : current?.measurement != nil }

    // MARK: the steps

    /// Make this round's verification page (the target's are made at the start).
    @discardableResult
    public func makePages() throws -> [URL] {
        guard let round = current else { return pagesToPrint }
        if !round.pages.isEmpty { return pagesToPrint }
        let verification = try ColourVerification.make(try model())
        let stem = "\(name)-v\(round.version)-verify"
        try writeText(try verification.json(), to: url("\(stem).json"))
        rounds[rounds.count - 1].layout = "\(stem).json"
        rounds[rounds.count - 1].pages = try writePages(verification.target, stem: stem)
        try saveLog()
        return pagesToPrint
    }

    func title(_ page: Int) -> String {
        let what = onTarget ? "colour target" : "colour check v\(current!.version)"
        return "OpenQuad \(what): \(name)\(pagesNeeded > 1 ? " page \(page + 1) of \(pagesNeeded)" : "")"
    }

    /// Print the pages through lp; returns the CUPS job ids.
    public func printPages(runner: Printing.Runner = Printing.runCommand) throws -> [String] {
        let pages = try makePages()
        let ids = try pages.enumerated().map { i, page in
            try Printing.send(try PrintJob(path: page.path, printer: printer, paper: paper, ppi: ppi, title: title(i)), runner: runner)
        }
        try markPrinted(ids.joined(separator: ", "))
        return ids
    }

    /// Record that the pages were printed (by lp, the print panel or another app).
    public func markPrinted(_ note: String) throws {
        try makePages()
        if onTarget { target?.job = note } else { rounds[rounds.count - 1].job = note }
        try saveLog()
    }

    func scanFile(_ index: Int, _ suffix: String) -> String {
        onTarget ? "\(name)-target-scan\(index)\(suffix)" : "\(name)-v\(current!.version)-scan\(index)\(suffix)"
    }

    func addScan(_ file: String) throws {
        if onTarget { target?.scans.append(file) } else {
            rounds[rounds.count - 1].scans.append(file)
            rounds[rounds.count - 1].measurement = nil
        }
        try saveLog()
    }

    /// Scan one page on the eSCL scanner (Document intent, as the target was).
    @discardableResult
    public func scanPage(fetch: ESCL.Fetch = ESCL.httpFetch) throws -> URL {
        guard !scannerHost.isEmpty else { throw RunError(description: "no scanner chosen") }
        let file = scanFile(scansSoFar.count + 1, ".jpg")
        try ESCL.scan(host: scannerHost, settings: try ScanSettings(), fetch: fetch).write(to: url(file))
        try addScan(file)
        return url(file)
    }

    /// Use a scan made some other way (copied into the run's folder).
    public func useScan(_ source: URL) throws {
        let file = scanFile(scansSoFar.count + 1, source.pathExtension.isEmpty ? ".jpg" : "." + source.pathExtension)
        try Data(contentsOf: source).write(to: url(file))
        try addScan(file)
    }

    /// Start this page's scans again (a scan of the wrong page, or a poor one).
    public func clearScans() throws {
        if onTarget { target?.scans = [] } else {
            rounds[rounds.count - 1].scans = []
            rounds[rounds.count - 1].measurement = nil
        }
        try saveLog()
    }

    /// Whether every page has been scanned.
    public var scannedAll: Bool { scansSoFar.count >= pagesNeeded }

    func measureScans(_ layout: ColourTarget) throws -> ColourMeasurement {
        let model = try loadScannerModel()
        let scans = try scansSoFar.suffix(pagesNeeded).map { try Scan.load(url($0)) }
        return try ColourMeasure.measure(scans, target: layout, model: model)
    }

    /// Measure the target's scans and build the first profile from them; returns its report.
    public func measureTarget() throws -> ProfileReport {
        guard var stage = target, onTarget else { throw RunError(description: "the target is already measured") }
        guard scannedAll else { throw RunError(description: "scan every page of the target first") }
        let layout = try ColourTarget.decode(Data(contentsOf: url(stage.layout)))
        let measurement = try measureScans(layout)
        stage.measurement = "\(name)-target-measured.json"
        try writeText(try measurement.json(), to: url(stage.measurement!))
        let report = try ProfileReport.build([measurement])
        stage.summary = measurement.summary() + "\n" + report.summary()
        target = stage
        try newRound(report.model, tables: report.tables)
        return report
    }

    func newRound(_ model: ForwardModel, tables: ProfileTables? = nil) throws {
        let version = rounds.count
        let stem = "\(name)-v\(version)"
        try writeText(try model.json(), to: url("\(stem).json"))
        try ColourProfiles.iccProfile(model, description: "\(description) (OpenQuad v\(version))", tables: tables)
            .write(to: url("\(stem).icc"))
        rounds.append(ColourRound(version: version, profile: "\(stem).icc", model: "\(stem).json"))
        try saveLog()
    }

    public func model() throws -> ForwardModel {
        guard let round = current else { throw RunError(description: "measure the colour target first") }
        return try ForwardModel.decode(Data(contentsOf: url(round.model)))
    }

    public var profileURL: URL? { current.map { url($0.profile) } }

    public func verification() throws -> VerificationTarget {
        guard let layout = current?.layout else { throw RunError(description: "make this round's verification page first") }
        return try VerificationTarget.decode(Data(contentsOf: url(layout)))
    }

    /// Measure the verification page's scan against the goals, and record the result.
    public func measure() throws -> VerificationReport {
        if onTarget { throw RunError(description: "measure the colour target first") }
        guard scannedAll else { throw RunError(description: "scan the verification page first") }
        let verification = try verification()
        let measurement = try measureScans(verification.target)
        let stem = "\(name)-v\(current!.version)"
        try writeText(try measurement.json(), to: url("\(stem)-measured.json"))
        let report = try ColourVerification.verify(measurement, verification)
        try writeText(try report.json(), to: url("\(stem)-report.json"))
        rounds[rounds.count - 1].measurement = "\(stem)-measured.json"
        rounds[rounds.count - 1].report = "\(stem)-report.json"
        rounds[rounds.count - 1].assessment = report.assessment
        rounds[rounds.count - 1].action = report.passed ? "done" : "refine"
        try saveLog()
        return report
    }

    /// This round's report, if it was measured.
    public func report() throws -> VerificationReport? {
        guard let measured = current?.measurement else { return nil }
        let measurement = try ColourMeasurement.decode(Data(contentsOf: url(measured)))
        return try ColourVerification.verify(measurement, try verification())
    }

    /// Build the next round's profile from this round's measurements.
    @discardableResult
    public func refine(damping: Double = ColourVerification.damping) throws -> ColourRound {
        guard let measured = current?.measurement else { throw RunError(description: "measure this round's verification page first") }
        let measurement = try ColourMeasurement.decode(Data(contentsOf: url(measured)))
        let next = try ColourVerification.refine(try model(), measurement, damping: damping)
        try newRound(next)
        return current!
    }
}
