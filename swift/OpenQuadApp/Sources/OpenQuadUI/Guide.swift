// "How to Use OpenQuad": a short walk through the app, shown on first launch and from
// the Help menu or the toolbar.

import SwiftUI

public struct GuideView: View {
    /// Raise when the guide changes enough to show it again on launch.
    public static let version = 4
    public static let showNotification = Notification.Name("OpenQuadShowGuide")

    struct Page {
        let symbol: String
        let title: String
        let text: String
        let steps: [String]
    }

    static let pages: [Page] = [
        Page(symbol: "printer.fill", title: "Welcome to OpenQuad",
             text: "OpenQuad prints black-and-white photos with accurate, neutral tones on an ordinary inkjet printer, "
                + "and makes digital negatives for contact printing (carbon transfer).",
             steps: ["Open a photo, choose how it should print, and print.",
                     "Calibrate your printer once, with its scanner, so greys print neutral and evenly spaced.",
                     "For carbon: find the best negative colour, then calibrate the process.",
                     "This is a beta. Please report anything that goes wrong, or reads unclearly, at "
                        + "github.com/akendrick/openquad/issues."]),
        Page(symbol: "photo", title: "Print a photo",
             text: "Everything is on the left; the preview on the right shows how the print should look.",
             steps: ["Open Photo… (⌘O): greyscale or colour, any size. Colour photos are converted to grey.",
                     "Output: Print. Toning stays Neutral unless you choose a duotone; it's never remembered.",
                     "Calibration: pick one of your saved calibrations (Import… adds a file). Choosing a printer "
                        + "under Page picks its newest calibration for that paper.",
                     "Page: paper, Fit to page, or turn Fit off and give a resolution. Print size shows the result.",
                     "Print… (⌘P). With \"Choose in the print panel\" the macOS panel opens: pick the printer and the "
                        + "same quality settings every time. Or pick a printer to print straight to it.",
                     "Save Print File… writes the finished 16-bit file to print from another app at 100%."]),
        Page(symbol: "slider.horizontal.3", title: "Calibrate your printer",
             text: "Calibrate This Printer… (under Calibration) prints a test page with two step wedges, scans it and "
                + "measures every step.",
             steps: ["Choose the printer, paper, paper type and how you'll print (straight to the printer or "
                        + "through the print panel), then Start and 1. Print Comparison Page….",
                     "When it's dry, put it face down on the scanner glass and choose 2. Scan and Measure "
                        + "(Find looks for the scanner on the network). The first time, macOS asks to let OpenQuad "
                        + "find devices on your local network: choose Allow.",
                     "Follow the advice: Improve Grey Balance while there is a colour cast, then Even Out Tone.",
                     "Repeat until both goals are met (cast under 3, tone within 2 L*), then Use This Calibration: "
                        + "it joins your saved calibrations under the printer's name.",
                     "Print the same way every time (same printer, paper and settings) or the calibration won't fit."]),
        Page(symbol: "film", title: "Digital negatives",
             text: "Output: Digital negative turns the photo into a negative for contact printing, in black or a "
                + "colour that blocks UV.",
             steps: ["Ink colour: the colour to print the negative in (the blocking test finds the best one).",
                     "Process curve: shapes the tones for your process (made by Calibrate a Process…).",
                     "Mirror if the film's printed side must face the tissue.",
                     "The safe edge frames the photo; the F cut into it reads correctly in the print when the "
                        + "mirror setting was right.",
                     "Print on transparency film at 100% with your usual film settings."]),
        Page(symbol: "square.grid.3x3.square", title: "Find the best blocking colour",
             text: "Find the Best Blocking Colour… (in negative mode) prints a sheet of every negative colour.",
             steps: ["Print the test sheet on film and expose it on your tissue at your usual time.",
                     "Develop it, let it dry, and scan the print (or read a scan file).",
                     "OpenQuad reads the print any way up, tilted or mirrored, and reports which colours block "
                        + "fully and how many distinct steps each gives.",
                     "Use the best colour for your negatives."]),
        Page(symbol: "chart.line.uptrend.xyaxis", title: "Calibrate the process",
             text: "Calibrate a Process… prints process charts (101 tones each) on one page, one chart per colour.",
             steps: ["Start, then print the chart page on film (or print it from another app at 100% and say so).",
                     "Contact print it at your usual exposure, develop, dry, and scan the print.",
                     "Each colour's measured tones are drawn against the target; Refine the Curves and repeat "
                        + "until every patch is within 3 L*.",
                     "Use This Colour's Curve: your negatives then print with tones on target."]),
        Page(symbol: "lightbulb", title: "Good to know",
             text: "A few things that make results repeatable.",
             steps: ["Scans are made in Document mode with fixed settings so days compare; Photo mode alters colour.",
                     "Calibration runs, scans and measurements are kept in ~/Library/Application Support/OpenQuad, "
                        + "shared with the OpenQuad command-line tools.",
                     "Nothing is printed or scanned without you confirming it first.",
                     "Open this guide again any time from Help ▸ How to Use OpenQuad or the ? button."]),
    ]

    let done: () -> Void
    @State private var page = 0
    @Environment(\.dismiss) private var dismiss

    public init(done: @escaping () -> Void = {}) { self.done = done }

    public var body: some View {
        let current = Self.pages[page]
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: current.symbol)
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                    .frame(width: 48)
                Text(current.title).font(.title.bold())
            }
            Text(current.text).font(.title3).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(current.steps.enumerated()), id: \.offset) { n, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(n + 1)").font(.callout.bold().monospacedDigit()).foregroundStyle(.secondary).frame(width: 18)
                        Text(step).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 0)
            HStack {
                HStack(spacing: 6) {
                    ForEach(Self.pages.indices, id: \.self) { i in
                        Circle().fill(i == page ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                    }
                }
                Spacer()
                Button("Skip") { finish() }.opacity(page == Self.pages.count - 1 ? 0 : 1)
                Button("Back") { page -= 1 }.disabled(page == 0)
                if page < Self.pages.count - 1 {
                    Button("Next") { page += 1 }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Start Using OpenQuad") { finish() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(28)
        .frame(width: 620, height: 520)
    }

    private func finish() {
        done()
        dismiss()
    }
}
