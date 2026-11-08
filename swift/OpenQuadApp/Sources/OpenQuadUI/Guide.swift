// "How to Use OpenQuad": a short walk through the app's tabs, shown on first launch
// (and when it changes) and from the Help menu or the toolbar.

import SwiftUI

public struct GuideView: View {
    /// Raise when the guide changes enough to show it again on launch.
    public static let version = 17
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
                + "and makes digital negatives for contact printing (carbon, cyanotype and other UV processes).",
             steps: ["The tabs at the top (⌘1 to ⌘5) are the five parts of the app: Print, Negative, Contact Sheet, "
                        + "Printer Calibration and Process Calibration.",
                     "Each tab keeps its own work while you use the others: calibrate one printer, print on another "
                        + "and refine a process at the same time.",
                     "When you quit, OpenQuad asks whether to keep your open photos for next time.",
                     "This is a beta. Please report anything that goes wrong, or reads unclearly, at "
                        + "github.com/akendrick/openquad/issues."]),
        Page(symbol: "printer", title: "Print a photo",
             text: "The Print tab: everything is on the left; the preview on the right shows how the print should look.",
             steps: ["Open Photo… (⌘O): greyscale or colour, any size. Colour photos are converted to grey, "
                        + "unless you turn on Print in colour.",
                     "Print in colour (colour-managed printer), for a colour photo: it keeps its colours and colour "
                        + "profile, skips toning and calibration, and macOS matches it to the printer: choose the "
                        + "paper type or profile in the print panel. Soft-proof with a paper's profile to see it in "
                        + "the preview.",
                     "Toning stays Neutral unless you choose a duotone; it's never remembered.",
                     "Calibration: pick one of your saved calibrations (Import… adds a file). Choosing a printer "
                        + "under Page picks its newest calibration for that paper.",
                     "Page: paper, Fit to page, or turn Fit off and give a resolution. Print size shows the result.",
                     "Print… (⌘P). With \"Choose in the print panel\" the macOS panel opens: pick the printer and the "
                        + "same quality settings every time. Or pick a printer to print straight to it.",
                     "Save Print File… writes the finished 16-bit file to print from another app at 100%."]),
        Page(symbol: "slider.horizontal.3", title: "Calibrate your printer",
             text: "The Printer Calibration tab (or Calibrate This Printer… in Print). Calibration goes in rounds; each "
                + "round is Print, Scan, Result, and the blue card always says which step you're on.",
             steps: ["Choose the printer, paper (and type), how you'll print and the scanner, then Start. Print the same "
                        + "way every time, or the calibration won't fit.",
                     "Print: the comparison page has two wedges, the top one uncorrected (one square), the bottom one "
                        + "through the calibration being tested (two squares).",
                     "Scan: when it's dry, put it face down on the glass and choose Scan and Measure. The first time, "
                        + "macOS asks to let OpenQuad find devices on your network: choose Allow.",
                     "Result: the card says what to do. Usually Improve Grey Balance first (colour casts), then Even "
                        + "Out Tone (lightness), printing and scanning again after each to check it.",
                     "When both goals are met, Use This Calibration saves it and the Print tab uses it (if it prints "
                        + "on that printer). New Calibration in the toolbar starts again.",
                     "Stopped halfway? Continue a Previous Run picks up exactly where you left off."]),
        Page(symbol: "film", title: "Digital negatives",
             text: "The Negative tab turns a photo into a negative for contact printing, in black or a colour that "
                + "blocks UV. It has its own photo, printer and paper.",
             steps: ["Setup: switch between saved setups (curve, colour, mirror, edges, printer and paper) in one step. "
                        + "Once a process is calibrated, Save Setup… keeps it under a name, e.g. Cyanotype on Pictorico.",
                     "Ink colour and Process curve: both come from the Process Calibration tab.",
                     "Mirror if the film's printed side must face the tissue. The F cut into the safe edge reads "
                        + "correctly in the print when the mirror setting was right.",
                     "Outline in black adds a black border of the width you set between the safe edge and the "
                        + "photo: a natural frame for photos with white or light edges.",
                     "Darkroom marks: a black guide line round the image and registration marks (targets on each "
                        + "side, crop marks at the corners), in the safe edge. Red and orange negatives all but vanish "
                        + "under a red safelight; black shows. The marks block UV like the safe edge, so they don't print. "
                        + "The Print tab offers them too, in a thin white border round the print.",
                     "Separations: for processes that build their tones up in several coats (gum, multi-coat "
                        + "cyanotype), split the photo into 2-6 negatives by tone. Set where the bands meet on a step "
                        + "scale and an overlap so the seams don't show; each negative can have its own process curve. "
                        + "Each prints nothing lighter than its band and full strength darker, so the coats add up. "
                        + "With registration marks on, the targets are cut clear and every negative is numbered, so the "
                        + "first coat records them on the paper to line the others up on. Print the lightest first. "
                        + "Use Step Test as Photo first: numbered steps over a matching gradient show where each band "
                        + "falls on your paper and whether the seams show. Then calibrate the coats together: Use Chart as "
                        + "Photo, print every negative of it onto one sheet, scan the print and Read Chart Scan…; the coats "
                        + "curve it makes evens out how the coats add up. Read a second print to check.",
                     "Prefer millimetres? OpenQuad > Settings… (⌘,) switches every length in the app to mm.",
                     "Tissue smaller than the page? Under Page, set Fit within to A set size (e.g. 8 × 10 in): "
                        + "that becomes the negative's outer edge, safe edge included, and the photo shrinks to fit.",
                     "Print on transparency film at 100% with your usual film settings."]),
        Page(symbol: "square.grid.3x3", title: "Contact sheets",
             text: "The Contact Sheet tab (⇧⌘N) puts up to 16 photos on one sheet, to proof them or to make one "
                + "negative of them all.",
             steps: ["Add Photos… (or drop them on the sheet); a bar shows each photo opening and the time left. Drag "
                        + "the list to change the order.",
                     "Choose portrait or landscape, a black or white background, whole photos or cropped to fill, "
                        + "file names, and a greyscale step wedge to check the print's tones.",
                     "Print It makes the sheet for the Print tab's page and opens it there; Make a Negative makes it "
                        + "for the Negative tab's page (inside its safe edge and outline)."]),
        Page(symbol: "square.grid.3x3.square", title: "Find the best blocking colour",
             text: "Process Calibration, step 1: a sheet of every negative colour, to find the one that blocks UV best.",
             steps: ["Choose the chart: Standard (six colours) or Ink mixtures (ten colours your printer makes "
                        + "from single inks and simple mixes). Print it on film and expose it at your usual time.",
                     "Size: Standard, or Fit within a set size (e.g. your tissue) to enlarge or shrink the sheet; it "
                        + "never goes past the page's margins. Darkroom marks help you place it under a red safelight.",
                     "Develop it, let it dry, and scan the print (or read a scan file).",
                     "OpenQuad reads the print any way up, tilted or mirrored, and reports which colours block "
                        + "fully and how many distinct steps each gives.",
                     "Use the best colour: the Negative tab prints in it, and step 2 calibrates in it."]),
        Page(symbol: "chart.line.uptrend.xyaxis", title: "Calibrate the process",
             text: "Process Calibration, step 2: process charts (101 tones each) on one page, one chart per colour.",
             steps: ["Set the page's size and darkroom marks if you like (as in step 1), Start, then print the chart "
                        + "page on film (or print it from another app at 100% and say so).",
                     "Contact print it at your usual exposure, develop, dry, and scan the print.",
                     "Each colour's measured tones are drawn against the target; Refine the Curves and repeat "
                        + "until every patch is within 3 L*. Smoothing evens out noise from the print and the scan.",
                     "If highlights print as paper white or shadows as full black, OpenQuad says so and what to "
                        + "change: those tones are lost, and the curve can only squeeze the rest.",
                     "Use This Colour's Curve: the Negative tab uses it and offers to save it as a setup. Export Curve "
                        + "saves it for Photoshop (.acv, .amp), as a LUT (.cube) or CSV."]),
        Page(symbol: "lightbulb", title: "Good to know",
             text: "A few things that make results repeatable.",
             steps: ["Scans are made in Document mode with fixed settings so days compare; Photo mode alters colour.",
                     "Calibration runs, scans, setups and contact sheets are kept in ~/Library/Application Support/"
                        + "OpenQuad, shared with the OpenQuad command-line tools.",
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
