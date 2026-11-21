import OpenQuadCore

// The step wedges beside the print or negative: chosen in the sidebar, remembered for each tab.
extension AppModel {
    /// Change the wedges: checked (an error is shown, not thrown), remembered for this tab, redrawn.
    func changeWedge(_ change: () throws -> Void) {
        attempt(change)
        rememberWedge()
        refreshPreview()
    }

    /// The 31-step grey wedge beside the print (toned and calibrated, or through the process curve).
    public func setWedge(_ on: Bool) {
        changeWedge { session.wedge = on }
    }

    /// The colour gamut wedge, for a colour print.
    public func setColourWedge(_ on: Bool) {
        changeWedge { session.colourWedge = on }
    }

    public func setWedgeSide(_ side: String) {
        changeWedge { try session.setWedgeSide(side) }
    }

    public func setWedgeGap(_ gap: Double) {
        changeWedge { try session.setWedgeGap(min(max(gap, 0), Wedge.maxGap)) }
    }

    /// Joined to the print (the default; on a negative, inside its safe edge) or made separately, the gap away.
    public func setWedgeSeparate(_ on: Bool) {
        changeWedge { session.wedgeSeparate = on }
    }

    /// 11, 21, 31 or 51 steps.
    public func setWedgeSteps(_ steps: Int) {
        changeWedge { try session.setWedgeSteps(steps) }
    }

    /// Inches across the grey wedge (0.2 to 1).
    public func setWedgeWidth(_ width: Double) {
        changeWedge { try session.setWedgeWidth(min(max(width, Wedge.minWidth), Wedge.maxWidth)) }
    }

    /// A plain strip, or the calibration target's style (two rows in a black frame).
    public func setWedgeStyle(_ style: String) {
        changeWedge { try session.setWedgeStyle(style) }
    }

    /// What fills the space between the photo and its wedges: colour (the negative's own; white
    /// paper on a print), black or white.
    public func setWedgeBackground(_ background: String) {
        changeWedge { try session.setWedgeBackground(background) }
    }

    /// The step numbers in a band beside the wedge.
    public func setWedgeLabels(_ on: Bool) {
        changeWedge { session.wedgeLabels = on }
    }

    /// The wedges are remembered for each tab.
    func rememberWedge() {
        let chosen = WedgeSettings(grey: session.wedge, colour: session.colourWedge, side: session.wedgeSide, gap: session.wedgeGap,
                                   separate: session.wedgeSeparate, steps: session.wedgeSteps, width: session.wedgeWidth,
                                   style: session.wedgeStyle, labels: session.wedgeLabels,
                                   background: session.wedgeBackground)
        let negative = role == .negative
        saveSettings { if negative { $0.negativeWedge = chosen } else { $0.printWedge = chosen } }
    }

    /// "31 steps, below", "21 steps and colour, on the right", or "none".
    public var wedgeDescription: String {
        let kinds = session.wedgeKinds
        guard !kinds.isEmpty else { return "none" }
        let steps = "\(session.wedgeSteps) steps"
        let what = kinds == [.colour] ? "colour" : kinds.count == 2 ? "\(steps) and colour" : steps
        let whereTo = ["top": "above", "bottom": "below", "left": "on the left", "right": "on the right"][session.wedgeSide] ?? ""
        return "\(what), \(whereTo)"
    }
}
