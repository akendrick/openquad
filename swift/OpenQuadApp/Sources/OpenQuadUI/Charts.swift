// Charts for the wizards: a measured wedge (colour cast and tone error per step) and
// read process charts (measured L* against the target for every patch).

import Charts
import OpenQuadCore
import SwiftUI

/// Top: a* and b* per step (corrected solid, uncorrected faint) with the ±3 goal band.
/// Bottom: tone error per step (L*) with the ±2 goal band.
public struct WedgeChartView: View {
    let uncorrected: Measurement?
    let corrected: Measurement?
    let round: Int

    public init(uncorrected: Measurement?, corrected: Measurement?, round: Int = 1) {
        self.uncorrected = uncorrected
        self.corrected = corrected
        self.round = round
    }

    struct Point: Identifiable {
        let id = UUID()
        let step: Int, value: Double, series: String, faint: Bool
    }

    static let thisRound = ["a* this round (green–red)", "b* this round (blue–yellow)"]
    static let before = ["a* uncorrected", "b* uncorrected"]

    static func casts(_ m: Measurement, faint: Bool) -> [Point] {
        let names = faint ? before : thisRound
        return m.byLevelDescending.enumerated().flatMap { step, i in
            [Point(step: step, value: m.lab[i][1], series: names[0], faint: faint),
             Point(step: step, value: m.lab[i][2], series: names[1], faint: faint)]
        }
    }

    public var body: some View {
        if let corrected {
            VStack(alignment: .leading, spacing: 6) {
                Text("Colour cast at each grey step").font(.headline)
                Text("How far each step is from neutral grey: 0 is neutral, positive a* is reddish, negative is greenish, "
                     + "positive b* is yellowish, negative is bluish. The goal is to stay inside the green band (±3). "
                     + "Solid lines are this round's corrected wedge; faint lines are the uncorrected wedge on the same page "
                     + "(the printer's own cast, for comparison).")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Chart {
                    RectangleMark(yStart: .value("goal", -Assessment.castGoal), yEnd: .value("goal", Assessment.castGoal))
                        .foregroundStyle(.green.opacity(0.12))
                    ForEach(Self.casts(corrected, faint: false) + (uncorrected.map { Self.casts($0, faint: true) } ?? [])) { p in
                        LineMark(x: .value("Step", p.step), y: .value("Cast", p.value))
                            .foregroundStyle(by: .value("Series", p.series))
                            .lineStyle(StrokeStyle(lineWidth: p.faint ? 1 : 2.5, dash: p.faint ? [4, 3] : []))
                            .opacity(p.faint ? 0.45 : 1)
                    }
                }
                .chartForegroundStyleScale(domain: Self.thisRound + Self.before, range: [Color.pink, Color.blue, Color.pink, Color.blue])
                .chartXAxisLabel("step: white (0) to black (20)")
                .frame(minHeight: 170)

                Text("Tone at each grey step").font(.headline).padding(.top, 8)
                Text("How much lighter (+) or darker (−) each step printed than it should, in L* units. The goal is "
                     + "within ±2 (the green band). Even Out Tone fixes this once the colour cast is under control.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Chart {
                    RectangleMark(yStart: .value("goal", -Assessment.toneGoal), yEnd: .value("goal", Assessment.toneGoal))
                        .foregroundStyle(.green.opacity(0.12))
                    ForEach(Array(Linearize.toneErrors(corrected).reversed().enumerated()), id: \.offset) { step, error in
                        LineMark(x: .value("Step", step), y: .value("Tone error", error)).foregroundStyle(.gray)
                        PointMark(x: .value("Step", step), y: .value("Tone error", error)).foregroundStyle(.gray)
                    }
                }
                .chartXAxisLabel("step: white (0) to black (20)")
                .chartYAxisLabel("L* off target")
                .frame(minHeight: 150)
            }
        } else {
            ContentUnavailableView("Round \(round): nothing measured yet", systemImage: "chart.xyaxis.line",
                                   description: Text("The charts appear after the printed page is scanned."))
        }
    }
}

/// Measured L* per patch for each colour, with each colour's target dashed.
public struct ToneChartView: View {
    let readings: [(String, ChartReading)]

    public init(readings: [(String, ChartReading)]) { self.readings = readings }

    struct Point: Identifiable {
        let id = UUID()
        let patch: Int, value: Double, series: String, target: Bool
    }

    public var body: some View {
        if readings.isEmpty {
            ContentUnavailableView("No chart read yet", systemImage: "chart.xyaxis.line")
        } else {
            let points = readings.flatMap { colour, r -> [Point] in
                r.lightness.indices.flatMap { n -> [Point] in
                    let target = Linearize.targetLightness(Double(r.levels[n]), paper: r.white, black: r.black)
                    return [Point(patch: n, value: r.lightness[n], series: colour, target: false),
                            Point(patch: n, value: target, series: "\(colour) target", target: true)]
                }
            }
            Chart(points) { p in
                LineMark(x: .value("Patch", p.patch), y: .value("L*", p.value))
                    .foregroundStyle(by: .value("Series", p.series))
                    .lineStyle(StrokeStyle(lineWidth: p.target ? 1 : 2, dash: p.target ? [4, 3] : []))
            }
            .chartForegroundStyleScale(domain: readings.flatMap { [$0.0, "\($0.0) target"] },
                                       range: readings.flatMap { colour, _ in [Self.swatch(colour), Self.swatch(colour).opacity(0.6)] })
            .chartYScale(domain: 0...100)
            .chartXAxisLabel("patch (0% to 100% ink in the print)")
            .chartYAxisLabel("L*")
        }
    }
}

extension ToneChartView {
    /// The negative's own ink colour (darkened a little where it would be too pale to see).
    static func swatch(_ colour: String) -> Color {
        let (r, g, b) = Negative.colours[colour] ?? (0.3, 0.3, 0.3)
        let scale = colour == "yellow" ? 0.8 : 1.0
        return Color(.sRGB, red: r * scale, green: g * scale, blue: b * scale)
    }
}

extension Measurement {
    /// Indices from white to black (the order the target prints the steps in).
    var byLevelDescending: [Int] { levels.indices.sorted { levels[$0] > levels[$1] } }
}
