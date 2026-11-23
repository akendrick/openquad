// The walkthroughs: for each tab, what it's for and step-by-step walkthroughs of the things you
// do there, shown beside the tab (TabWalkthroughs.swift). Also "How to Use OpenQuad", the intro
// (Start Here only), shown on first launch (and when it changes) and from the Help menu.

import SwiftUI

public struct GuideView: View {
    /// Raise when the guide changes enough to show it again on launch.
    public static let version = 32
    public static let showNotification = Notification.Name("OpenQuadShowGuide")
    /// Shows the walkthroughs beside the tab in front.
    public static let showWalkthroughsNotification = Notification.Name("OpenQuadShowWalkthroughs")

    /// One thing you do, from start to finish.
    struct Walkthrough {
        let title: String
        let summary: String
        /// Each step: what to do, then why or what happens.
        let steps: [(action: String, detail: String)]
    }

    /// A tab (or Start Here): what it's for and its walkthroughs.
    struct Page {
        let tab: AppTab?
        let symbol: String
        let title: String
        let purpose: String
        let walkthroughs: [Walkthrough]

        var name: String { tab?.title ?? "Start Here" }
    }

    static let pages: [Page] = [startHerePage, printPage, negativePage, contactSheetPage, printerCalibrationPage,
                                processCalibrationPage]

    /// The page for a tab; Start Here for none.
    static func pageIndex(for tab: AppTab?) -> Int {
        pages.firstIndex { $0.tab == tab } ?? 0
    }

    /// A tab's walkthroughs.
    static func page(for tab: AppTab) -> Page { pages[pageIndex(for: tab)] }

    // MARK: Start Here

    static let startHerePage = Page(
        tab: nil, symbol: "sparkles", title: "Welcome to OpenQuad",
        purpose: "OpenQuad prints black-and-white photos with accurate, neutral tones on an ordinary inkjet printer, "
            + "and makes digital negatives for contact printing (carbon, cyanotype, gum and other UV processes). "
            + "Each tab at the top does one job, and has its own walkthroughs: choose Walkthroughs in the "
            + "toolbar and they open beside the tab, so you can follow the steps as you go.",
        walkthroughs: [
            Walkthrough(
                title: "Find your way round",
                summary: "Five tabs, each keeping its own work while you use the others.",
                steps: [
                    ("Print (⌘1)", "Prints a photo on paper, toned and calibrated for your printer."),
                    ("Negative (⌘2)", "Makes a digital negative on film for a contact-printing process."),
                    ("Contact Sheet (⌘3)", "Puts up to 16 photos on one sheet, as a print or a negative."),
                    ("Printer Calibration (⌘4)", "Measures your printer through your scanner and corrects its "
                        + "greys, so prints come out neutral and evenly toned."),
                    ("Process Calibration (⌘5)", "Finds the negative colour that blocks UV best for your process, "
                        + "then the curve that makes the print's tones land where they should."),
                    ("Switch freely", "Calibrate one printer, print on another and refine a process at the same "
                        + "time; each tab keeps its photo and settings."),
                    ("Walkthroughs", "The Walkthroughs button in the toolbar opens step-by-step help for the "
                        + "tab you're on, beside your work. It stays open as you switch tabs, showing each tab's own."),
                ]),
            Walkthrough(
                title: "Your first black-and-white print",
                summary: "The shortest way from a photo to a good print on paper.",
                steps: [
                    ("Calibrate the printer once", "In Printer Calibration, choose the printer, paper and scanner and "
                        + "work through the rounds until both goals are met (see that tab's page). Skip this to print "
                        + "uncorrected; you can calibrate later."),
                    ("Open the photo", "In Print, Open… (⌘O). Colour photos are converted to grey unless you "
                        + "choose to print in colour."),
                    ("Choose printer and paper", "Under Printer and size. Choosing a printer picks its newest "
                        + "calibration for that paper."),
                    ("Print", "Print… (⌘P). OpenQuad always asks before anything is printed."),
                ]),
            Walkthrough(
                title: "Your first digital negative",
                summary: "From a photo to a negative you can contact print.",
                steps: [
                    ("Find your blocking colour", "In Process Calibration, print the test sheet on film, expose and "
                        + "develop it as usual, and scan the print. OpenQuad says which colour blocks UV best."),
                    ("Calibrate the process", "In the same tab, print the chart page in that colour, contact print it, "
                        + "scan it and refine until the tones are on target. Use the curve when it's done."),
                    ("Make the negative", "In Negative, open the photo; the colour and curve are already set. Check "
                        + "the safe edge and mirror, then print on transparency film at 100%."),
                    ("Keep the recipe", "Save Setup… keeps the colour, curve and settings under a name, ready next time."),
                ]),
            Walkthrough(
                title: "Good to know",
                summary: "Things that make results repeatable, and where your work is kept.",
                steps: [
                    ("Print the same way every time", "A calibration only fits the printer, paper, driver settings and "
                        + "way of printing it was made with (the print panel or straight to the printer)."),
                    ("Scan in Document mode", "OpenQuad scans with fixed settings so days compare; a scanner's Photo "
                        + "mode alters colour and crops."),
                    ("Nothing happens behind your back", "Nothing is printed or scanned without you confirming it first."),
                    ("Your files", "Calibration runs, scans, setups and contact sheets are kept in ~/Library/"
                        + "Application Support/OpenQuad, shared with the OpenQuad command-line tools."),
                    ("Millimetres", "OpenQuad > Settings… (⌘,) switches every length in the app to mm."),
                    ("When you quit", "OpenQuad asks whether to keep your open photos for next time."),
                    ("It's a beta", "Please report anything that goes wrong, or reads unclearly, at "
                        + "github.com/akendrick/openquad/issues."),
                ]),
        ])

    // MARK: Print

    static let printPage = Page(
        tab: .print, symbol: "printer", title: "Print",
        purpose: "Prints a photo on paper through your printer's normal driver. Black-and-white photos are toned "
            + "(or kept neutral) and corrected by your printer's calibration; colour photos can print in colour "
            + "through macOS colour management. The settings are on the left, in sections you can fold away (a "
            + "folded section shows what's set in it); the preview on the right shows how the print should look.",
        walkthroughs: [
            Walkthrough(
                title: "Print a black-and-white photo",
                summary: "Open, check the tone, size it and print.",
                steps: [
                    ("Open the photo", "Open… (⌘O), or drop a file on the preview. TIFF, PNG, JPEG and JPEG 2000 (read "
                        + "at full 16-bit depth) open directly; a GIMP .xcf opens through GIMP 3, if it's installed."),
                    ("Choose toning", "Under Toning and calibration: Neutral, or a duotone such as black and red. "
                        + "Toning isn't remembered, so every photo starts neutral."),
                    ("Check the calibration", "Calibration lists your saved calibrations; Import… adds a file and "
                        + "Calibrate This Printer… opens Printer Calibration. None (uncorrected) prints as the driver does."),
                    ("Choose printer and paper", "Under Printer and size. Picking a printer picks its newest "
                        + "calibration for that paper."),
                    ("Check the size", "With Scale to fill the page on, the photo fills the page inside its margins; "
                        + "Print size shows the result and its resolution."),
                    ("Print", "Print… (⌘P). If Print… is dimmed, the line above it says why (for example, the photo "
                        + "doesn't fit the page at this size)."),
                ]),
            Walkthrough(
                title: "Print a colour photo",
                summary: "Keep a photo's colours and let macOS match them to the printer.",
                steps: [
                    ("Open a colour photo", "It opens as grey, with a note that it's a colour image."),
                    ("Turn on Print in colour", "Under Toning and calibration. The photo keeps its colours and "
                        + "colour profile (sRGB if it has none); toning and calibration are skipped."),
                    ("Soft-proof it", "Soft-proof with a paper's profile shows on screen what the paper can't "
                        + "hold. It changes only the preview."),
                    ("Set the paper in the print panel", "macOS colour-manages the print: choose the paper type or "
                        + "profile under Media & Quality, the same every time."),
                    ("Add a colour wedge", "Under Registration and step wedges, a colour gamut wedge (31 hues as a "
                        + "tint, full colour and shade) shows how much of each colour the printer reaches."),
                ]),
            Walkthrough(
                title: "Add darkroom marks and a step wedge",
                summary: "Marks for lining prints up, and a wedge to check the tones.",
                steps: [
                    ("Open Registration and step wedges", "The darkroom marks come first, then the step wedge."),
                    ("Add marks", "Guide line in black draws a line round the image; Registration marks adds targets "
                        + "on each side and crop marks at the corners, in a thin white border round the print."),
                    ("Choose where the marks go", "Keep marks inside the printable area fits them with the photo "
                        + "(the photo shrinks a little); turn it off and the photo keeps its size, with the marks out "
                        + "in the margins."),
                    ("Add a grey step wedge", "It's toned and calibrated like the photo, so the print shows what "
                        + "the setup does to every tone."),
                    ("Choose its look", "11, 21, 31 or 51 steps; a plain strip, the calibration target's style "
                        + "(two rows in a black frame) or ChartThrob's (21 steps and a gradient); its width, numbered "
                        + "steps, the side, the space from the photo and the background round it. They're remembered."),
                ]),
            Walkthrough(
                title: "Size and place the print",
                summary: "Exact sizes, turned pages and placing the print by hand.",
                steps: [
                    ("Set the resolution yourself", "Turn off Scale to fill the page and type a resolution under the "
                        + "photo; Photo's Own goes back to the photo's own ppi."),
                    ("Fit within a set size", "Fit within: A set size (e.g. 8 × 10 in) limits the print to that box "
                        + "instead of the page."),
                    ("Turn the page", "Orientation: Landscape turns the page on its side for a wide photo; the print "
                        + "is sent turned to match. Each tab remembers its own."),
                    ("Mirror it", "Mirror flips the photo left to right, for transfers."),
                    ("Place it on the page", "Position on the page: Preview on the page shows the whole sheet. Drag "
                        + "the print anywhere inside the margins, or type From the left and From the top; Centre "
                        + "puts it back."),
                ]),
            Walkthrough(
                title: "Print straight to the printer, or save a file",
                summary: "Three ways to get the print out.",
                steps: [
                    ("Ask each time (print panel)", "The usual macOS print panel opens: pick the printer and the "
                        + "same Media & Quality settings every time."),
                    ("Or pick a printer", "Under Printer and size, choose a printer to print straight to it, with "
                        + "no panel. Its own Media type and Quality appear there, remembered for that printer."),
                    ("Match the calibration", "A calibration made through the print panel should be used through "
                        + "the panel, and one made printing straight should be used that way; the app matches them."),
                    ("Save Print File…", "Writes the finished 16-bit file (toned, calibrated, with marks and "
                        + "wedges) to print from another app at 100%."),
                ]),
        ])

    // MARK: Negative

    static let negativePage = Page(
        tab: .negative, symbol: "film", title: "Negative",
        purpose: "Makes a digital negative on transparency film for contact printing, in black or a colour that "
            + "blocks UV, through the process curve that makes your process print the photo's tones correctly. "
            + "It can also split a photo into several negatives for multi-coat or colour processes. It has its "
            + "own photo, printer and paper, separate from Print.",
        walkthroughs: [
            Walkthrough(
                title: "Make a digital negative",
                summary: "From an open photo to a negative on film.",
                steps: [
                    ("Open the photo", "Open… (⌘O) or drop it on the preview."),
                    ("Choose a setup or set it up", "Setup switches between saved recipes in one step. Otherwise set "
                        + "Ink colour and Process curve, which come from Process Calibration (Calibrate a Process… is "
                        + "in the curve's Choose menu)."),
                    ("Check the edge", "Under Registration and step wedges: Safe edge is the opaque border that "
                        + "keeps light off the tissue round the photo; Outline in black adds a black border between it "
                        + "and the photo."),
                    ("Mirror if needed", "Mirror (under Printer and size) if the film's printed side must face the "
                        + "tissue. The F cut into the safe edge reads correctly in the print when the mirror setting "
                        + "was right."),
                    ("Print on film", "Print… on transparency film at 100%, with your usual film settings."),
                ]),
            Walkthrough(
                title: "Fit the negative to your tissue",
                summary: "Sizes and placing for paper or tissue smaller than the page.",
                steps: [
                    ("Set a size", "Under Printer and size, Fit within: A set size (e.g. 8 × 10 in). That becomes the "
                        + "negative's outer edge, safe edge included, and the photo shrinks to fit."),
                    ("Turn the page if it helps", "Orientation: Landscape for a wide negative."),
                    ("Place it on the film", "Position on the page: Preview on the page shows the sheet with its "
                        + "margins dashed. Drag the negative, or step it with From the left and From the top."),
                    ("Separations stay together", "Every negative of a separation prints in the same place, so they "
                        + "line up."),
                ]),
            Walkthrough(
                title: "Add marks and a step wedge",
                summary: "Find the negative under a safelight, and check the process in every print.",
                steps: [
                    ("Darkroom marks", "Under Registration and step wedges: a black guide line round the image and "
                        + "registration marks in the safe edge. Red and orange negatives all but vanish under a red "
                        + "safelight; black marks show. They block UV like the safe edge, so they don't print."),
                    ("A step wedge beside the negative", "Made with the same process curve, so the contact print "
                        + "shows how the process holds every tone. Same choices as in Print."),
                    ("Background round the wedge", "Colour keeps the space opaque like the safe edge; Black or White "
                        + "instead. Create wedge separately gives the wedge its own safe edge, with clear film between."),
                ]),
            Walkthrough(
                title: "Save and reuse a setup",
                summary: "Keep a whole recipe under a name, such as \"Cyanotype on Pictorico\".",
                steps: [
                    ("Get it right once", "Ink colour, process curve, mirror, edges, printer, paper and any separation."),
                    ("Save Setup…", "In the ⋯ menu beside Setup. Give it a name you'll recognise."),
                    ("Use it next time", "Pick it from Setup: everything comes back in one step. Changing anything "
                        + "shows Custom until you save again."),
                    ("Tidy up", "The same ⋯ menu deletes a setup you no longer use."),
                ]),
            Walkthrough(
                title: "Split by tone: multi-coat negatives",
                summary: "For gum or multi-coat cyanotype: 2 to 6 negatives, one per coat, printed over each other.",
                steps: [
                    ("Open Separations", "Choose Split by: Tones and the number of negatives."),
                    ("Set the bands", "Set where the bands meet on the step scale, and an overlap so the seams "
                        + "don't show. Each negative prints nothing lighter than its band and full strength darker, "
                        + "so the coats add up."),
                    ("Turn on registration marks", "Every negative's targets are cut clear and it's numbered, so the "
                        + "first coat records them. Print the lightest first and line the others up on them."),
                    ("Test the split", "Use Step Test as Photo and print every negative of it: numbered steps over a "
                        + "gradient show where each band falls and whether the seams show."),
                    ("Curves per coat", "Each negative can use its own curve. Preview all coats together shows each "
                        + "coat in its own colour on the photo."),
                    ("Calibrate the coats together", "Use Chart as Photo, print every negative onto one sheet, scan "
                        + "the print and Read Chart Scan…; the coats curve evens out how the coats add up."),
                ]),
            Walkthrough(
                title: "Split by colour: tricolour negatives",
                summary: "For tricolour gum or cyanotype under gum: 2 to 4 negatives, one per pigment.",
                steps: [
                    ("Open Separations", "Choose Split by: Colours."),
                    ("Set each coat's colour", "In the order you print them: a pigment preset (Cyanotype blue, "
                        + "Quinacridone magenta, Hansa yellow, ...) or your own coat's colour from the colour well. "
                        + "Add Coat for up to four, e.g. a lamp black key."),
                    ("Set the saturation", "Above 1 strengthens the photo's colours before the split: cyanotype and "
                        + "gum print duller than a screen, so 1.3 to 1.6 often looks closer."),
                    ("Preview the print", "Shows the coats stacked as they'll print; colours your pigments can't make "
                        + "come out as near as they can."),
                    ("Print and save", "Give each coat its own curve, print them in order on the registration marks, "
                        + "and Save Setup… to keep the coats, saturation and curves."),
                ]),
        ])

    // MARK: Contact Sheet

    static let contactSheetPage = Page(
        tab: .contactSheet, symbol: "square.grid.3x3", title: "Contact Sheet",
        purpose: "Puts up to 16 photos on one sheet (⇧⌘N), to proof them on paper or to make one negative of "
            + "them all. The sheet is made here, then sent to Print or Negative to print.",
        walkthroughs: [
            Walkthrough(
                title: "Proof a set of photos",
                summary: "One sheet of thumbnails on paper.",
                steps: [
                    ("Add the photos", "Add Photos…, or drop them on the window. A bar shows each opening and the "
                        + "time left."),
                    ("Put them in order", "Drag the list to change the order."),
                    ("Choose the look", "Portrait or landscape, a black or white background, whole photos or "
                        + "cropped to fill, file names, and a grey step wedge to check the print's tones."),
                    ("Send to Print Tab", "Makes the sheet for the Print tab's page and opens it there, with that "
                        + "tab's toning and calibration. Print it from there."),
                ]),
            Walkthrough(
                title: "Make one negative of many photos",
                summary: "Contact print a whole set at once.",
                steps: [
                    ("Set up the Negative tab first", "Its colour, curve, safe edge and page decide how the sheet "
                        + "is made."),
                    ("Add and arrange the photos", "As for a proof sheet."),
                    ("Send to Negative Tab", "Makes the sheet to fit the Negative tab's page, inside its safe edge "
                        + "and outline, and opens it there."),
                    ("Print on film", "From the Negative tab, as for any negative."),
                ]),
        ])

    // MARK: Printer Calibration

    static let printerCalibrationPage = Page(
        tab: .printerCalibration, symbol: "slider.horizontal.3", title: "Printer Calibration",
        purpose: "Makes your printer print greys neutral and evenly spaced. It prints a test page, scans it with "
            + "your scanner, measures every grey and corrects what it finds, in rounds, until the colour cast and "
            + "tone are within their goals. The result is a calibration for that printer, paper and way of printing.",
        walkthroughs: [
            Walkthrough(
                title: "Before you start",
                summary: "What you need, and the one rule.",
                steps: [
                    ("A printer and the paper you'll print photos on", "The calibration is only valid for that paper."),
                    ("A scanner", "A network (eSCL/AirScan) scanner, found with Find. Any other scanner works by "
                        + "scanning yourself and reading the file. The first time, macOS asks to let OpenQuad find "
                        + "devices on your network: choose Allow."),
                    ("Print the same way every time", "Choose Print with: the print panel or straight to the printer, "
                        + "with the same settings for the calibration and for every print afterwards."),
                ]),
            Walkthrough(
                title: "Calibrate a printer, round by round",
                summary: "Each round is Print, Scan, Result; the blue card always says which step you're on.",
                steps: [
                    ("Set up and Start", "Choose the printer, paper (and its type), how you'll print and the scanner."),
                    ("Print", "The comparison page has two wedges: the top one uncorrected (one square), the bottom "
                        + "one through the calibration being tested (two squares)."),
                    ("Scan", "When it's dry, put it face down on the glass and choose Scan and Measure."),
                    ("Read the result", "The charts show the colour cast and tone at each grey step against their "
                        + "goals (cast under 3, tone within 2 L*)."),
                    ("Improve", "The card says what to do next: usually Improve Grey Balance first (colour casts), "
                        + "then Even Out Tone (lightness), printing and scanning again after each to check."),
                ]),
            Walkthrough(
                title: "Finish, and use it",
                summary: "Saving the calibration and coming back later.",
                steps: [
                    ("Use This Calibration", "When both goals are met. It's saved, and the Print tab uses it when it "
                        + "prints on that printer and paper."),
                    ("Stopped halfway?", "Continue a Previous Run picks up exactly where you left off."),
                    ("Start again", "New Calibration in the toolbar, e.g. after changing ink or paper."),
                    ("Bring one in", "In Print, Import… adds a calibration file made elsewhere."),
                ]),
        ])

    // MARK: Process Calibration

    static let processCalibrationPage = Page(
        tab: .processCalibration, symbol: "chart.line.uptrend.xyaxis", title: "Process Calibration",
        purpose: "Calibrates a contact-printing process (carbon, cyanotype, gum...) in two steps: first which "
            + "negative colour blocks UV best on your film, then the process curve that makes every tone of a "
            + "photo print where it should. You print on film, make a real print in the darkroom, and scan it.",
        walkthroughs: [
            Walkthrough(
                title: "Wizard or Advanced",
                summary: "Two views of the same work.",
                steps: [
                    ("Calibration Wizard", "Takes you through both steps one at a time, with one button for the "
                        + "next thing to do and the alternatives beside it."),
                    ("Advanced", "Shows every setting at once, with the step picker (blocking colour or curve) at "
                        + "the top."),
                    ("Switch any time", "Both keep the same work. New Process in the toolbar starts over."),
                ]),
            Walkthrough(
                title: "Step 1: find the best blocking colour",
                summary: "A sheet of every negative colour, to find the one that blocks UV best.",
                steps: [
                    ("Choose the chart", "Standard (six colours) or Ink mixtures (ten colours your printer makes from "
                        + "single inks and simple mixes)."),
                    ("Size and marks", "Standard size, or Fit within a set size (e.g. your tissue). Darkroom marks "
                        + "help you place it under a red safelight."),
                    ("Print the test sheet", "On film, then expose it on your tissue at your usual time and develop it."),
                    ("Scan the print", "When it's dry, Scan the Print (or Read a Scan File…); OpenQuad reads it any way "
                        + "up, tilted or mirrored."),
                    ("Pick the colour", "The report says which colours block fully and how many distinct steps each "
                        + "gives. Use the best one; Skip: I Know My Colour if you already know it."),
                ]),
            Walkthrough(
                title: "Step 2: calibrate the process curve",
                summary: "A chart of 101 tones per colour, printed and read until the tones are on target.",
                steps: [
                    ("Start and print the chart page", "On film, in your blocking colour (or several colours to "
                        + "compare). Printed it from another app at 100%? Say so with I Printed It Elsewhere."),
                    ("Contact print it", "At your usual exposure; develop and dry it."),
                    ("Scan and read it", "Each colour's measured tones are drawn against the target."),
                    ("Refine the Curves", "Then print, contact print and read again, until every patch is within 3 L*. "
                        + "Smoothing evens out noise from the print and the scan."),
                    ("Watch for lost tones", "If highlights print as paper white or shadows as full black, OpenQuad "
                        + "says so and what to change (exposure or colour): the curve can only squeeze what's left."),
                ]),
            Walkthrough(
                title: "Use and export the curve",
                summary: "Put the finished curve to work.",
                steps: [
                    ("Use This Colour's Curve", "The Negative tab uses it straight away and offers to save it as a "
                        + "setup."),
                    ("Export Curve…", "Saves it for Photoshop (.acv, .amp), as a LUT (.cube) or as CSV, to use "
                        + "elsewhere."),
                    ("Another run", "New Run… puts this run away and starts a fresh one; runs are kept in your "
                        + "OpenQuad folder."),
                ]),
        ])

    // MARK: View (the intro)

    let done: () -> Void
    @State private var walkthrough: Int
    @Environment(\.dismiss) private var dismiss

    private static var intro: Page { startHerePage }

    /// Opens at the intro's `walkthrough`.
    public init(walkthrough: Int = 0, done: @escaping () -> Void = {}) {
        self.done = done
        _walkthrough = State(initialValue: min(max(walkthrough, 0), Self.intro.walkthroughs.count - 1))
    }

    public var body: some View {
        let intro = Self.intro
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: intro.symbol)
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                    .frame(width: 40)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(intro.title).font(.title.bold())
                    Text(intro.purpose).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(alignment: .top, spacing: 16) {
                WalkthroughList(walkthroughs: intro.walkthroughs, selection: $walkthrough)
                    .frame(width: 220)
                ScrollView {  // a long walkthrough scrolls instead of being clipped
                    WalkthroughSteps(walkthrough: intro.walkthroughs[walkthrough])
                        .padding(.trailing, 6)
                }
                .id(walkthrough)  // each walkthrough starts at its top
            }
            HStack {
                Text("\(walkthrough + 1) of \(intro.walkthroughs.count)").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { finish() }.keyboardShortcut(.cancelAction)
                Button("Back") { walkthrough -= 1 }.disabled(walkthrough == 0)
                if walkthrough < intro.walkthroughs.count - 1 {
                    Button("Next") { walkthrough += 1 }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Start Using OpenQuad") { finish() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 760, height: 560)
    }

    private func finish() {
        done()
        dismiss()
    }
}

/// The walkthroughs' titles, to pick one.
struct WalkthroughList: View {
    let walkthroughs: [GuideView.Walkthrough]
    @Binding var selection: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(walkthroughs.indices, id: \.self) { i in
                Button { selection = i } label: {
                    Text(walkthroughs[i].title)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(i == selection ? Color.accentColor.opacity(0.15) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(i == selection ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
    }
}

/// One walkthrough: its title, what it's for and its numbered steps.
struct WalkthroughSteps: View {
    let walkthrough: GuideView.Walkthrough

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(walkthrough.title).font(.title3.bold())
            Text(walkthrough.summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(walkthrough.steps.enumerated()), id: \.offset) { n, step in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(n + 1)")
                        .font(.callout.bold().monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.accentColor))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.action).bold()
                        Text(step.detail).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Step \(n + 1): \(step.action). \(step.detail)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
