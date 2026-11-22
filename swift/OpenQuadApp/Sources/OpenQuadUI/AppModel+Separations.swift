// Separating a negative into coats: by tone, or by colour.

import CoreGraphics
import Foundation
import OpenQuadCore

extension AppModel {
    // MARK: separations


    /// Split the negative into `count` negatives with even bands (1: no separation).
    public func setNegativeCount(_ count: Int) {
        let count = min(max(count, 1), SeparationPlan.maxNegatives)
        separationSplits = (1..<count).map { Int((Double($0 * separationSteps) / Double(count)).rounded()) }
        applySeparation()
    }

    /// Count the split points on a scale of `steps` steps, keeping them where they were.
    public func setSeparationSteps(_ steps: Int) {
        let steps = min(max(steps, separationSplits.count + 1, 2), 101)
        let scale = Double(steps) / Double(separationSteps)
        separationSplits = Self.spread(separationSplits.map { Int((Double($0) * scale).rounded()) }, steps: steps)
        separationOverlap = (separationOverlap * scale * 2).rounded() / 2
        separationSteps = steps
        applySeparation()
    }

    /// Move split point `index` (0 = between the first two negatives), within its neighbours.
    public func setSplit(_ index: Int, step: Int) {
        guard separationSplits.indices.contains(index) else { return }
        let low = index == 0 ? 1 : separationSplits[index - 1] + 1
        let high = index == separationSplits.count - 1 ? separationSteps - 1 : separationSplits[index + 1] - 1
        separationSplits[index] = min(max(step, low), high)
        applySeparation()
    }

    /// How many steps neighbouring bands blend over (up to the narrowest band).
    public func setSeparationOverlap(_ steps: Double) {
        separationOverlap = min(max(steps, 0), Double(narrowestBand))
        applySeparation()
    }

    /// The narrowest band, in steps.
    public var narrowestBand: Int {
        let edges = [0] + separationSplits + [separationSteps]
        return zip(edges, edges.dropFirst()).map { $1 - $0 }.min() ?? separationSteps
    }

    /// Split points made distinct and in order within 1..<steps (after rescaling).
    static func spread(_ splits: [Int], steps: Int) -> [Int] {
        var result: [Int] = []
        for (k, split) in splits.enumerated() {
            let low = (result.last ?? 0) + 1, high = steps - (splits.count - k)
            result.append(min(max(split, low), high))
        }
        return result
    }

    func applySeparation() {
        separationOverlap = min(separationOverlap, Double(narrowestBand))
        guard separationKind == .tones else { return applyColourSeparation() }
        attempt {
            let plan = separationSplits.isEmpty ? nil
                : try SeparationPlan.fromSteps(separationSplits.map(Double.init), steps: separationSteps,
                                               overlap: separationOverlap)
            session.setColourSeparation(nil)
            session.setSeparation(plan)
        }
        refreshPreview()
    }

    // MARK: colour separations

    public enum SeparationKind: String, CaseIterable, Sendable {
        case tones = "Tones", colours = "Colours"
    }


    public func setSeparationKind(_ kind: SeparationKind) {
        separationKind = kind
        applySeparation()
    }

    /// Change coat `index`'s pigment colour.
    public func setCoat(_ index: Int, _ colour: ColourSeparation.RGB8) {
        guard colourCoats.indices.contains(index) else { return }
        colourCoats[index] = colour
        applyColourSeparation()
    }

    /// Add a coat (up to four), of a pigment not used yet.
    public func addCoat() {
        guard colourCoats.count < ColourSeparation.maxCoats else { return }
        let unused = ColourSeparation.pigments.first { !colourCoats.contains($0.colour) }
        colourCoats.append(unused?.colour ?? ColourSeparation.pigment("Lamp black")!)
        applyColourSeparation()
    }

    /// Remove coat `index` (keeping at least two).
    public func removeCoat(_ index: Int) {
        guard colourCoats.count > ColourSeparation.minCoats, colourCoats.indices.contains(index) else { return }
        colourCoats.remove(at: index)
        attempt { try session.setLayer(min(session.layer, colourCoats.count - 1)) }
        // The negatives' own curves move with their coats.
        let curves = session.layerProcessPaths
        attempt {
            for k in index..<colourCoats.count { try session.setLayerProcess(k, curves[k + 1]) }
        }
        applyColourSeparation()
    }

    /// How much the photo's colour is strengthened (above 1) or muted before it is split, 0-2.
    public func setColourSaturation(_ saturation: Double) {
        colourSaturation = min(max((saturation * 20).rounded() / 20, 0), ColourSeparation.maxSaturation)
        applyColourSeparation()
    }

    /// The pigment a colour is, by name, if it is one of the presets.
    public func pigmentName(_ colour: ColourSeparation.RGB8) -> String? {
        ColourSeparation.pigments.first { $0.colour == colour }?.name
    }

    /// Work the colour separation out off the main thread (it takes a moment), then use it.
    func applyColourSeparation() {
        let coats = colourCoats, saturation = colourSaturation
        do {
            try ColourSeparation.validate(coats: coats, saturation: saturation)
        } catch {
            self.error = String(describing: error)
            return
        }
        error = nil
        if let current = session.colourSeparation, current.coats == coats, current.saturation == saturation {
            return refreshPreview()
        }
        colourToken += 1
        let token = colourToken
        separatingColours = true
        Task.detached(priority: .userInitiated) {
            // Wait a moment: while a colour or the saturation is being dragged, only the last counts.
            try? await Task.sleep(for: .milliseconds(120))
            guard await MainActor.run(body: { token == self.colourToken }) else { return }
            let separation = try? ColourSeparation(coats: coats, saturation: saturation)
            await MainActor.run {
                guard token == self.colourToken else { return }  // a newer change wins
                self.separatingColours = false
                guard self.separationKind == .colours, let separation else { return }
                self.session.setColourSeparation(separation)
                if let layer = self.pendingLayer, layer < separation.count { try? self.session.setLayer(layer) }
                self.pendingLayer = nil
                self.refreshPreview()
            }
        }
    }


    public func setShowCoats(_ on: Bool) {
        showCoats = on
        if on { showOnPage = false }
        refreshPreview()
    }

    /// The preview is the coats map rather than a negative.
    public var showingCoats: Bool { showCoats && session.negative && session.separated }


    public func setShowOnPage(_ on: Bool) {
        showOnPage = on
        if on { showCoats = false }
        refreshPreview()
    }

    /// The preview is the whole page with the negative on it.
    public var showingPage: Bool { showOnPage && session.photo != nil && !showingCoats }

    /// Move the negative's top-left corner to (left, top) inches on the page, kept inside the
    /// margins; nil centres it. Every negative of a separation prints in the same place.
    public func setPlacement(_ placement: (Double, Double)?) {
        do {
            try session.setPlacement(placement)
            if session.placed { try session.setPlacement(try session.pagePosition()) }  // as kept inside the margins
            error = nil
        } catch {
            self.error = String(describing: error)
        }
    }

    /// The page, the room inside its margins and the negative on it, all in inches.
    public var pageLayout: (paper: (Double, Double), margin: Double, negative: CGRect)? {
        guard let size = try? session.sizeInches(), let position = try? session.pagePosition() else { return nil }
        return (session.page, session.margin, CGRect(x: position.0, y: position.1, width: size.0, height: size.1))
    }

    /// Where the negative is, for the Page section: "Centred" or its distance from two edges.
    public var positionDescription: String {
        guard session.placement != nil else { return "Centred" }
        guard session.placed, let (left, top) = try? session.pagePosition() else { return "Centred (no room to move it)" }
        let short = { (inches: Double) in self.units.length((inches * 100).rounded() / 100) }
        return "\(short(left)) from the left, \(short(top)) from the top"
    }

    /// Show (and print) negative `layer` of the separation.
    public func setLayer(_ layer: Int) {
        if separationKind == .colours, separatingColours, colourCoats.indices.contains(layer) {
            pendingLayer = layer  // its coat's negative is still being worked out
            return
        }
        attempt { try session.setLayer(layer) }
        refreshPreview()
    }

    /// Give negative `layer` its own process curve (nil: the shared one).
    public func setLayerProcess(_ layer: Int, _ url: URL?) {
        attempt { try session.setLayerProcess(layer, url) }
        refreshPreview()
    }

    /// Use the step test as the photo: the step scale's numbered steps over a continuous
    /// gradient, to print through the separation and see where each coat's band falls. It is
    /// kept in the app's separations folder; the last photo folder is left as it was.
    public func openStepTest() {
        attempt {
            try FileManager.default.createDirectory(at: separationFolder, withIntermediateDirectories: true)
            let url = separationFolder.appendingPathComponent("step-test-\(separationSteps).tif")
            try ImageFiles.saveGrey(url, try SeparationPlan.stepTest(steps: separationSteps))
            try session.open(url)
        }
        refreshPreview()
    }
}
