// Curves already in OpenQuad, and calibrating the coats together.

import CoreGraphics
import Foundation
import OpenQuadCore

extension AppModel {
    // MARK: curves already in OpenQuad

    /// A process curve OpenQuad already has, to choose from a menu instead of a file panel.
    public struct KnownCurve: Hashable, Sendable {
        /// Where it came from: "Setups", "Process calibrations" or "Coats curves".
        public let group: String
        public let label: String
        public let url: URL
    }

    /// Where the Process Calibration tab keeps its runs.
    var processFolder: URL { settingsURL.deletingLastPathComponent().appendingPathComponent("processes") }


    /// Every saved setup's curve, each process calibration's latest curve per colour (newest
    /// run first) and the coats curves, e.g. "Cyanotype, blue: round 2". Read again every few
    /// seconds, not on every redraw.
    public var knownCurves: [KnownCurve] { knownCurvesCache.get(readKnownCurves) }

    /// Read the curves again next time (after saving one).
    func forgetKnownCurves() { knownCurvesCache.clear() }

    func readKnownCurves() -> [KnownCurve] {
        let fm = FileManager.default
        var curves = setups.compactMap { setup in
            setupLibrary.processURL(setup).map { KnownCurve(group: "Setups", label: setup.name, url: $0) }
        }
        let folders = (try? fm.contentsOfDirectory(at: processFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let runs = folders.compactMap { url -> (ProcessRun, Date)? in
            guard let run = try? ProcessRun.resume(url) else { return nil }
            let modified = (try? url.appendingPathComponent("run.json").resourceValues(
                forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return (run, modified)
        }
        for (run, _) in runs.sorted(by: { $0.1 > $1.1 }) {
            for colour in run.colours where run.current.curves[colour] != nil {
                let url = run.curvePath(colour)
                guard fm.fileExists(atPath: url.path) else { continue }
                curves.append(KnownCurve(group: "Process calibrations",
                                         label: "\(run.name), \(colour): round \(run.current.version)", url: url))
            }
        }
        let coats = ((try? fm.contentsOfDirectory(at: separationFolder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "oqproc" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        curves += coats.map { KnownCurve(group: "Coats curves", label: $0.deletingPathExtension().lastPathComponent, url: $0) }
        return curves
    }

    // MARK: calibrating the coats together

    /// Where the step test, the coats chart and the coats curves are kept.
    var separationFolder: URL { settingsURL.deletingLastPathComponent().appendingPathComponent("separations") }

    /// Use the process chart as the photo, to print through every negative of the separation
    /// onto one sheet; a scan of that print calibrates the coats together (`readCoatsScan`).
    public func openCoatsChart() {
        attempt {
            try FileManager.default.createDirectory(at: separationFolder, withIntermediateDirectories: true)
            let url = separationFolder.appendingPathComponent("coats-chart.tif")
            let chart = Chart.photo()
            try ImageFiles.saveGrey(url, GreyImage(width: chart.width, height: chart.height, pixels: chart.pixels,
                                                   dpi: (300, 300)))
            try session.open(url)
        }
        refreshPreview()
    }

    /// Calibrate the stacked coats with this curve (nil: none).
    public func setCoatsCurve(_ url: URL?) {
        attempt { try session.setCoatsCurve(url) }
        refreshPreview()
    }

    /// Read a scan of the coats chart printed through every negative: build the next coats
    /// curve from it (through the current one), save it beside the chart and use it.
    public func readCoatsScan(_ scan: URL) async {
        busy = true
        defer { busy = false }
        let previous = session.coatsCurve, folder = separationFolder
        do {
            let (curve, reading) = try await Task.detached(priority: .userInitiated) {
                let reading = try Chart.read(try Scan.load(scan))
                return (try ProcessCurve.build(reading, previous: previous), reading)
            }.value
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let round = (1...).first { !FileManager.default.fileExists(atPath: folder.appendingPathComponent("coats-\($0).oqproc").path) }!
            let url = folder.appendingPathComponent("coats-\(round).oqproc")
            try curve.encode().write(to: url)
            forgetKnownCurves()
            try session.setCoatsCurve(url)
            let errors = reading.toneErrors().map(abs)
            let (highlights, shadows) = Clipping.lost(reading)
            status = String(format: "Read the chart: %.1f L* off on average, %.1f at worst. ", errors.reduce(0, +) / Double(errors.count),
                            errors.max() ?? 0)
                + "Saved \(url.lastPathComponent) and using it; print the chart again to check."
                + (Clipping.advice(highlights: highlights, shadows: shadows).map { " " + $0 } ?? "")
            error = nil
        } catch {
            self.error = String(describing: error)
        }
        refreshPreview()
    }

    /// Every negative of the separation as TIFFs in `folder`.
    public func saveSeparations(to folder: URL) async {
        busy = true
        defer { busy = false }
        let snapshot = session
        do {
            let written = try await Task.detached(priority: .userInitiated) { try snapshot.writeSeparations(folder) }.value
            status = "Saved \(written.map(\.lastPathComponent).joined(separator: ", "))."
            error = nil
        } catch {
            self.error = String(describing: error)
        }
    }
}
