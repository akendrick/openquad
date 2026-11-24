# Changelog

All notable changes are recorded here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Colour calibration, phase 5: Python parity. The PySide6 window gets **Print in colour** and a
  **Colour profile** picker (macOS's driver profile, or this printer's OpenQuad profiles from
  the runs in its calibrations folder, matched to the printer and paper and remembered); through
  one, the photo is converted with LittleCMS (perceptual, from its own profile) and sent
  sRGB-tagged, and the preview soft-proofs through it. `openquad print --colour-profile ICC`
  does the same from the command line, `openquad profile list [FOLDER]` lists the profiles, and
  `profile start` takes `--printer`, `--paper` and `--settings` so a run's profiles can be
  matched. The Swift vectors check compares least-squares fits by shape only, since their last
  digits depend on the BLAS numpy is built with.
- Colour calibration, phase 4: the Mac app. Printer Calibration has a Black and white / Colour
  choice at setup. Colour prints the colour target (one page, or two for photo papers), scans
  it (each page, in any order, either way up), builds profile v0, then checks it in rounds of
  verification pages, with a rounds table of ΔE00 mean, 95th percentile and the greys' cast and
  tone, the worst colours shown wanted beside printed, and Refine Profile until the goals are
  met. Scans are read through a scanner model kept in the library (added from the file
  `openquad scanner-profile` wrote), or as sRGB without one. The Print tab's colour prints get
  a Profile picker: macOS (the driver's profile) or one of the printer's OpenQuad profiles,
  matched to the printer and paper as grey calibrations are; through one, the photo is
  converted (perceptual) and sent sRGB-tagged as the target was, and the preview soft-proofs
  through it. Export to ColorSync copies a profile to `~/Library/ColorSync/Profiles`. The Swift
  core gains the colour target, measuring, the profile (fitted with LAPACK), the ICC writer, the
  verification page and colour runs, checked against the Python reference with shared vectors;
  numpy's random generator is reproduced exactly so targets shuffle the same way. Runs are
  shared with the CLI: Python's `profile` commands keep the app's extra `run.json` fields (the
  printer, paper, target stage and scanner model) and read scans through the run's scanner
  model.
- Colour calibration, phase 3: checking a profile on real prints and refining it, in rounds kept
  in a run folder with a `run.json` log (as grey calibration runs are). `openquad profile start
  FOLDER MEASUREMENT... --name NAME` builds the first profile; `profile page FOLDER` writes a
  verification page of 144 colours the profile wasn't built from (a colour checker's 24, 8 skin
  tones, a 12-step grey wedge and 100 random photo colours), each sent through the profile's
  relative colourimetric inverse; `profile verify FOLDER SCAN...` measures it and judges it
  against the goals (ΔE00 mean under 3 and 95% under 6 for printable colours; greys' cast under
  3 and tone within 2 L\*), with the worst patches named; `profile refine FOLDER [--damping D]`
  fits a smooth correction to what was measured, folds half of it (by default) into the forward
  model and builds the next profile. Python only, tested on a simulated printer that drifted:
  two rounds bring it from a mean of 3.8 to 1.2. Core: `openquad.colour_verify`;
  `colour_target.layout_target` and `colour_profile.fit_lattice`.
- Colour calibration, phase 2: building the printer's colour profile. `openquad profile build
  MEASUREMENT... -o PROFILE.icc [--description NAME] [--smoothing S]` fits a forward model (RGB sent
  to L\*a\*b\* measured: a 9×9×9 lattice fitted with a smoothing term, the amount chosen by leaving
  patches out), inverts it on a 33³ L\*a\*b\* grid (nearest printable colour; the perceptual table
  adds black-point compensation), and writes an ICC v2 output profile (A2B0-2, B2A0-2, gamut,
  media white and black points). Several prints' measurements are averaged, and how far they
  differ is reported. The forward model is saved beside the profile as JSON. Checked with
  LittleCMS in the tests, and ColorSync loads and verifies the profiles. Python only. Core:
  `openquad.colour_profile`.
- Colour calibration, phase 1: the colour target and measuring it. `openquad target --kind colour`
  writes a one-page target of 255 patches (a 6-level RGB grid, 21 greys, and the primaries and
  secondaries as tints at three strengths), shuffled the same way every time, inside the black
  frame the grey target uses, with its layout saved beside it as JSON; `--fine` makes a 9-level,
  768-patch target over two pages, numbered with page marks. `openquad measure-colour SCAN...
  --target LAYOUT [--scanner-model MODEL] -o OUT` finds each page's frame, reads which page it is
  from its marks (turning a scan that came back upside down), samples every patch and the paper,
  and saves each patch's RGB sent with its XYZ (D50, through the scanner model; or the scan taken
  as sRGB) and L\*a\*b\* relative to the paper. Python only, tested on simulated prints. Core:
  `openquad.colour_target`; `colour.linear_rgb_to_xyz` and `d65_to_d50` (Bradford).
- Colour calibration, phase 0: measuring how well the scanner sees colour, from an IT8.7/2
  reflective target and its reference file. `openquad scanner-profile SCAN... --reference REF
  --corners "x,y x,y x,y x,y x,y"` (the centres of A1, A22, L1, GS0 and GS23) samples every patch,
  fits a scanner model (per-channel curves from the grey row, then a matrix or a second-order
  polynomial to XYZ under D50), and reports CIEDE2000 against the reference: on the fitted
  patches, on patches held out column by column, and between scans for repeatability. It ends
  with a go/no-go verdict for the rest of colour calibration (held-out mean 2 or less, repeatable
  within 1) and writes the model and report as JSON; `--check-image` outlines the sampled boxes.
  Python only for now; the Swift port follows if the verdict is go. Core: `openquad.scanner_profile`;
  `colour.xyz_to_lab` and `lab_to_xyz` with a white point, `D50_WHITE` and `delta_e_2000`
  (checked against Sharma, Wu and Dalal's test pairs).
- Orientation under Printer and size: Portrait or Landscape (the page turned on its side, for a
  wide photo), remembered for each tab. Fitting, placing and the page preview use the turned
  page; the print panel is set to match and a direct print is sent with `-o landscape`. Core:
  `PrintSession.landscape`, `page_size` and `PrintJob.landscape` in Python and Swift alike
  (shared vectors).

- Background for the step wedges, under Step wedges (Print and Negative tabs, remembered for
  each): what fills the space between the photo and its wedges. Colour, the default, keeps it as
  before (on a negative its own opaque colour, or clear film if the wedge is made separately; on
  a print, white paper); Black or White set it outright. Core: `PrintSession.wedge_background`
  in Python and Swift alike (shared vectors).

- Fit within printable area, under Registration (Print and Negative tabs, remembered for each).
  On, as before, the photo shrinks so its marks' border (a print's white border, a negative's
  safe edge and outline) fits within the margins too; off, the photo fits on its own and the
  border lies outside it, in the margins. Core: `PrintSession.marks_in_fit` in Python and Swift
  alike (shared vectors). Mirror moves to Printer and size.

- Step wedge options: 11, 21, 31 or 51 steps; a plain strip or the printer calibration target's
  style (two rows, white to black and back, in a thin black frame); a width of 0.2 to 1 in; and
  the steps numbered in a band beside the wedge. The space from the photo can always be set (0 to
  2 in, none by default): on a negative it is opaque like the safe edge, unless the wedge is made
  separately, when it is clear film. Each tab remembers its choices. Core: `wedge_steps`,
  `wedge_width`, `wedge_style` and `wedge_labels` in Python and Swift alike (shared vectors).
- A print can be placed on its page too: Position on the page, under Printer and size in the
  Print tab, previews the whole sheet and the print can be dragged anywhere inside the margins.

- Mirror in the Print tab too (for transfers): the photo flips left to right; its marks and
  wedges stay where they were put. The summary says so. Core: in Python and Swift alike.
- Create wedge separately. A step wedge now joins the print by default: on a negative it sits at
  the edge of the safe edge with no clear film between, running the full width of the photo and
  its outline. Create wedge separately makes it a piece of its own, the gap away (as before).
  Core: `PrintSession.wedge_separate`, remembered as `separate` in each tab's wedge settings.
- Step wedges beside the print or negative. The Step wedges section (Print and Negative tabs) adds
  an optional 31-step wedge, paper white to full black, on the top, bottom, left or right with a
  gap of 0 to 2 in. On a print it is toned and calibrated like the photo; on a negative it goes
  through the same process curve and safe edge, so the contact print shows every tone. A colour
  print can add a colour gamut wedge: 31 hues as a tint, the full colour and a shade. The print
  size and page fit allow for them, the summary lists them, and each tab remembers its own. Core:
  `openquad.wedge` and `PrintSession.wedge`, `colour_wedge`, `set_wedge_side` and `set_wedge_gap`
  in Python and Swift alike (shared vectors).
- A printer's own media type and quality. Printing straight to a printer, the app's Printer and
  paper section offers that printer's Media type and Quality (Matte Photo Paper, Super Fine and so
  on, or the printer's default), read from its CUPS driver (PPD); AirPrint media get plain names.
  They are sent to `lp`, remembered for each printer in each tab, kept in negative setups, and
  listed in the summary before printing. Core: `printer_options`, `parse_ppd` and
  `media_and_quality` in Python and Swift alike (shared vectors), and `PrintSession.printer_options`.
  With the print panel, its own Media & Quality is used as before.
- Size and resolution shows the photo's own resolution as soon as it is open ("Photo's own: 300 ppi
  (4.00 x 2.66 in)"), or that it has none and 300 ppi is used, so an empty Resolution field is no
  longer a guess.

- A negative can go anywhere on the page. App: "Preview on the page" under Position on the page in the Negative
  tab shows the whole sheet with its margins dashed; drag the negative to move it, or step it with
  From the left and From the top, and Centre puts it back. It is kept inside the margins, and the
  summary gives its position. When moved, the print is the page inside its margins with the
  negative in place on clear film, so it lands where it was put through the print panel or `lp`.
  Core: `PrintSession.set_placement` and `page_position` in Python and Swift alike (shared
  vectors).
- JPEG 2000 and GIMP photos. `.jp2`, `.j2k` and `.jpx` files open at their full bit depth through
  OpenJPEG 2.5.4: Pillow's copy in Python, built into the Mac app (COpenJPEG, BSD 2-clause) since
  macOS's ImageIO reads 16-bit JPEG 2000 as 8-bit. Grey, grey and alpha, RGB and RGB and alpha
  are read, with the file's ICC profile and capture resolution; subsampled, YCC and CMYK files are
  refused (save those as TIFF). GIMP's `.xcf` files open through GIMP 3 (`gimp-console`, found in
  /Applications, ~/Applications, on the PATH or through `OPENQUAD_GIMP`): it merges the visible
  layers, keeping transparency, into a 16-bit TIFF that loads as usual; the app does this off
  the main thread, saying "Opening … in GIMP". The Open dialogs offer both.
- Colour separations: a colour photo split by colour into 2-4 negatives, one per coat of a
  coloured pigment (tricolour gum, cyanotype under gum). Each coat is the colour it prints at full
  strength (pigment presets or any colour); each pixel gets the coat strengths whose stacked
  densities come closest to its colour (bounded least squares, worked out on a 33³ grid and
  interpolated). A saturation setting (0-2, in OKLab) strengthens the photo's colours first, for
  processes that print duller than the photo. App: Options ▸ Separations, Split by Tones or
  Colours, a row per coat, Add Coat, the saturation slider and "Preview the print" (the coats
  stacked in their colours); setups keep the coats, saturation and each coat's curve. Core:
  `ColourSeparation` and `PrintSession.set_colour_separation` in Python and Swift alike (shared
  vectors).
- Colour prints: a colour photo can be printed in colour on a colour-managed printer instead of
  being converted to greyscale. App: "Print in colour (colour-managed printer)" in the Print tab,
  off for every new photo. The print keeps the photo's colours and embedded RGB ICC profile
  (sRGB if it has none), skips toning and calibration, and goes to macOS colour management (the
  print panel's paper type or profile, or `lp`); the summary says so. "Soft-proof with" shows the
  preview through a printer and paper ICC profile found on the Mac, or one you choose; it is
  remembered and changes only the preview. Core: `Photo.colour` and `Photo.icc_profile`,
  `PrintSession.set_colour_print` / `render_print`, in Python and Swift alike (shared vectors).
- Separations for multi-coat processes: split a photo by tone into 2-6 negatives, printed one
  after another in register on one sheet. Choose where the bands meet on a step scale (default
  30) and an overlap that blends the seams; the coats add up to the photo exactly. Each negative
  can have its own process curve. With registration marks, the targets are cut clear and each
  negative is numbered in its own place, so the first coat records them on the paper. App:
  the Negative tab's Separations section, closed until wanted (band diagram, which negative to show and print, Save
  All Negatives…). Command line: `openquad negative --separations N --splits ... --overlap ...
  --layer-process K=CURVE`.
- A step test for separations, laid out like a contact-printed step tablet: the step scale's
  steps, each numbered sideways inside it, over a continuous gradient lined up with them, to print through every negative and see where each band falls and whether the
  seams show. App: "Use Step Test as Photo"; command line: `openquad target --kind steps`.
- Calibrating a separation's coats together: print the process chart through every negative onto
  one sheet, scan it and read it; the coats curve it gives (applied before the photo is split)
  evens out how the coats add up. In a simulated three-coat gum print with uneven coats, one round
  brings every patch within 1 L* of target (from 8 off). App: "Use Chart as Photo", "Read Chart
  Scan…" and the coats curve in Separations; command line: `openquad target --kind chart-photo`,
  `openquad chart`, `openquad negative --coats-curve`.
- Export process curves for other software, as with ChartThrob: Photoshop Curves (.acv, up to 16
  spline points placed where they matter), Photoshop arbitrary map (.amp, exact), a 3D LUT (.cube)
  and CSV. In the app: "Export Curve…" in Process Calibration. Command line: `openquad curve
  CURVE OUTPUT`, and `--image PHOTO` with a .tif output for the photo with the curve applied.
- Process curves are smoothed (a local straight-line fit over neighbouring patches), so noise in
  the print or the scan no longer kinks the curve; None, Light, Medium (default) or Strong, kept
  with the run (`openquad chart --smoothing`).
- Lost tones are reported: when more patches than should print as paper white or full black,
  the reading says how many and what to change (exposure or blocking colour).

- Process calibration shows a preview of the chart page it will print (before Start, from the
  settings; after, this round's page through its curves) with its size on film.
- Process calibration can continue a kept run ("Continue a Previous Run"), start a new run from
  an earlier run's latest curves or from .oqproc files ("Start from"), and go back to the settings
  with "New Run…" to adjust a finished calibration further.
- The process run's print-settings note can be edited after Start; it is saved with the run and
  recorded in later curves.
- Darkroom marks: a black guide line round the image and registration marks (a crosshair target
  on each side, crop marks at the corners), each a checkbox. On negatives they go in the safe edge
  in black ink, which shows under a red safelight (red and orange negatives all but vanish there)
  and blocks UV like the safe edge, so nothing prints; saved setups remember them. Prints get them
  in a 0.25 in white border. The blocking test and process charts offer them too. Command line:
  `--guide` and `--registration` on `negative` and `target --kind blocking|chart`.
- Test sheets take a preferred size: the blocking test and process chart page can be enlarged or
  shrunk to fit within W x H (turned to match, safe edge included, never past the page's margins);
  the patches keep their shape, so scans read as before. Remembered between sessions. Command
  line: `openquad target --kind blocking --size 8x10`.
- Tabs: the Mac app is one window with five tabs along the toolbar (⌘1–⌘5): Print, Negative,
  Contact Sheet, Printer Calibration and Process Calibration (blocking colour, then process curve).
  Each tab keeps its own work, so one printer can be calibrating while another prints; the Print
  and Negative tabs each remember their own photo, printer and paper. A finished calibration,
  blocking colour or process curve offers to go straight to the tab that uses it, and a contact
  sheet goes to Print It or Make a Negative. On quitting, OpenQuad asks whether to keep the open
  photos and contact sheet for next time; it reopens on the last tab used.
- Contact sheets show a progress bar while photos open, with each photo's name and an estimate of
  the time left.
- Contact sheets: the Contact Sheet tab (⇧⌘N) arranges up
  to 16 photos as thumbnails on one sheet the size of the page (inside its margins, safe edge and
  outline), portrait or landscape, on black or white, each whole or cropped to fill its cell, with
  optional file names and a 21-step greyscale wedge. Print It or Make a Negative sends it to that
  tab. Command line: `openquad contact-sheet PHOTOS... -o sheet.tif`.
- Saved negative setups: Save Setup… in negative mode remembers the process curve (a copy is kept
  with the setup), ink colour, mirror, safe edge, black outline, printer and paper under a name
  such as "Cyanotype on Pictorico"; the Setup menu switches all of them at once, and shows which
  setup the current settings match. Kept as .oqsetup files in OpenQuad's setups folder.
- Millimetres: OpenQuad > Settings… (⌘,) shows and takes every length in the app (safe edge, black
  outline, set sizes, print sizes, the summary) in inches or millimetres, remembered between
  sessions. Files, settings and the command line stay in inches.
- Ink-mixture chart for the blocking test: ten printable colours made from single inks and
  simple two-ink mixes (yellow, orange, red, magenta, blue, cyan, green, yellow-green, olive,
  black), each as a full patch and an 11-step wedge. Chosen in the app's blocking window (the
  usual six-colour sheet stays the default); `openquad target --kind blocking --mixtures` and
  `openquad blocking SCAN --mixtures`. Magenta, blue, cyan and yellow-green are new negative
  colours. The app shows results as a heat map (how light each patch printed) or as lines.
- Max image size: with Fit to page, "Fit within: A set size" keeps the image within W x H
  inches (turned to match the photo, never past the page's margins). For a negative it is the
  outer edge, safe edge included, e.g. the carbon tissue's size; the photo shrinks to fit inside.
  Remembered between sessions. Command line: `openquad negative --fit Letter --max-size 8x10`.
- Outline in black for digital negatives: an optional black border of a set width (0.01-1 in)
  between the safe edge and the photo, so photos with white or light, high-contrast edges still
  print with a clean frame. It is clear film on the negative (no ink), so it prints as the
  process's deepest black. Part of the negative's size, so Fit to page and Fit within allow for
  it. App: "Outline in black" with its width under the safe edge; command line:
  `openquad negative --outline 0.1`.

- Process Calibration has two modes: **Calibration Wizard**, one step at a time from the blocking
  test to a finished curve with the button for the next thing to do (or skip the blocking test),
  and **Advanced**, every setting at once as before. The choice is remembered.
- Negative setups keep a separation: its bands, overlap, each negative's own curve and the coats
  curve (copied beside the setup like its process curve).
- "Preview all coats together" in Separations: the photo with every coat in its own colour, as
  strong as it prints, to check the bands and seams before printing film.

### Changed

- Walkthroughs on every tab: Walkthroughs in the toolbar (or Help ▸ Walkthroughs for This Tab)
  opens a panel beside the tab saying what the tab is for, with step-by-step walkthroughs of the
  things you do there (20 across the five tabs, from printing a colour photo to splitting a photo
  into tricolour negatives), to follow while you work. The panel shows whichever tab is in front,
  remembers the walkthrough chosen on each, and stays open or closed as you left it. How to Use
  OpenQuad, the intro on first launch, is now Start Here alone (four walkthroughs); guide version
  32, so it shows again once.
- Registration and Step wedges are one section, Registration and step wedges; the wedges fold
  away inside it.

- The sidebar is regrouped. Darkroom marks is now Registration, and holds Mirror, Safe edge and
  Outline in black (the Negative tab's Options section is gone). Printer and paper, Size and
  resolution and Position on the page are one Printer and size section, with Position on the
  page folded inside it. Resolution moves to the top, under the photo, and shows the ppi the
  print is made at (not "photo's own"), with the photo's own beside it. Every length (safe edge,
  wedge gap, outline, position) can be typed as well as stepped.

- A tidier sidebar in the Print and Negative tabs. Every section folds away (click its title) and,
  folded, shows what's set in it, e.g. "Darkroom marks: guide line" or "Separations: 3 negatives";
  which are open is remembered. The photo is one row with Open… beside it. The Negative section
  is three rows: Save and Delete setup moved to a ⋯ menu by Setup, Calibrate a Process… and Clear
  to the process curve's Choose menu. Separations has its own section (it was inside Options), Page
  is split into Printer and paper, Size and resolution, and Position on the page.

- The blocking test and process charts print on the Negative tab's paper instead of always Letter.
- The wizards and curve menus no longer re-read every kept run (or redraw the chart preview) on each
  redraw; they read again every few seconds, or as soon as they change something.

- Negative tab: Mirror, Safe edge, Outline in black and Separations are now in one collapsible
  Options section; its header says what's set (e.g. "Options: mirrored, 3 negatives").
- Curve choosers (Process curve, a negative's own curve, the coats curve) are menus of the curves
  OpenQuad already has: saved setups, the latest round of each process calibration (e.g.
  "Cyanotype, blue: round 2") and coats curves, plus Other File….
- The guide's pages scroll instead of clipping long text, and separations have a page of their own.

- Process curves are fitted with the least-squares never-falling fit (pooling adjacent
  patches) instead of a running maximum, which leaned towards the lightest noisy patch.

- The process print-settings note no longer defaults to "600 x 600"; it starts empty, since the
  quality and resolution are chosen in the print panel.
- Stacked process charts sit closer together: 0.1 in of film between them instead of 0.3 in.

### Fixed

- With Fit within printable area off, a print or negative moved on the page kept its marks'
  border inside the margins, pushing the photo in from the margin. Now the photo goes to the
  margin and the border lies in it, as when centred.

- A 16-bit colour JPEG 2000 read through Pillow came out 8-bit with its brightest values (65408
  and up) turned black; JPEG 2000 is now decoded straight through OpenJPEG instead.
- The app no longer crashes when a blocking colour is chosen while a process run in other
  colours is under way and that run's curve is then used or exported; the run keeps its colours.
- The Negative tab no longer switches printer calibrations (or says a negative "will print
  uncorrected") when its printer or paper changes: negatives are shaped by their process curve.
- Printing straight to a printer no longer leaves a full-size print file in the temporary folder.
- The Printer Calibration tab gets the printer list when the app opens on it (it showed a text
  field to type the CUPS queue into).
- The contact sheet's "No room" message goes once there is room again.
- A test sheet's set size ignores a width or height of 0.
- App tests wait up to 30 s for background work instead of 2-3 s, so they don't fail on a busy
  machine.

## [0.1.0-beta.3] - 2026-10-27

### Fixed
- Mac app: scanning failed with "The Internet connection appears to be offline" (or timed out)
  because macOS blocked the app from the local network: the app now declares its local network use
  (NSLocalNetworkUsageDescription, the eSCL / IPP Bonjour services, plain http to local devices
  only), so macOS asks once. If access is still blocked, the error says where to turn it on.
- Mac app: `--scan-test HOST RESULT` checks that the app itself can reach a scanner.

## [0.1.0-beta.2] - 2026-10-27

### Fixed
- Scanning with Epson printers (found on an ET-2900): Epson answers a scan job created over http
  with an https:// job address on a self-signed certificate, so the download failed, the job was
  never closed and every later scan got "HTTP 503". OpenQuad now keeps to the scanner address it
  connected to (only the job's path is taken from the reply), in both the Python and Swift clients.
- A scanner that stays busy now says so plainly ("a scan job is still open on it…") instead of
  "scanner refused the job (HTTP 503): b''".

## [0.1.0-beta.1] - 2026-10-25

First beta for testers: a native Mac app alongside the Python tools.

### Added (Mac app, Phase 8)
- **OpenQuad.app** (SwiftUI, macOS 14+, universal): print window (open a photo, neutral or toned,
  calibration, page and size, live preview, 16-bit print file), printing through the macOS print panel
  at exact size or straight to a CUPS printer (`lp`), and digital negatives.
- Printer calibration wizard (comparison page, eSCL scan, grey balance, tone), blocking test, and
  process calibration wizard, sharing run files with the Python version.
- Calibration library: saved calibrations per printer and paper in a dropdown; choosing a printer
  picks its calibration.
- How to Use OpenQuad guide (first launch, Help menu), app icon, signing and notarization script.
- The Swift core (`swift/OpenQuadCore`) reproduces the Python core exactly, checked against
  exported test vectors (real Canon scans and carbon prints) in CI.

### Changed
- Version 0.1.0b1 (beta).

### Added (Phase 7: digital negatives for carbon printing, Python)
- `openquad negative`: a photo as a digital negative: inverted, black or a UV-blocking colour
  (green, orange, yellow, red, olive), optional mirror, opaque safe edge (0.25 in) with an orientation
  F that flips with the image; `--fit` sizes photo plus safe edge to the page.
- Blocking-colour test: `openquad target --kind blocking` prints a sheet of candidate colours (full
  patch + 11-step wedge each) to print on film and expose; `openquad blocking SCAN` reads the scanned
  carbon print (any way up or mirrored) and reports which colours block fully, their tonal range and
  usable steps, and the best one. Finds the sheet inside a larger exposed tissue field (tape and
  ink drips allowed), any way up including sideways, and judges against the best-blocking area
  (the process's white), flagging a leaking safe edge or over-exposure.
- Safe edges are printed in the negative's colour (black leaked more UV than colours on film).
- Process calibration (Phase 7, step 3): `openquad target --kind chart` prints a ChartThrob-style chart
  (101 patches in 1% steps, 21-step strip, gradient; after Kevin Bjorke's ChartThrob, chart design by
  Thomas Howard) as a negative in the chosen colour; `openquad chart SCAN -o curve.oqproc` reads the
  scanned contact print (any orientation, tilt, tissue field) and builds a process curve that puts
  each tone at its target lightness; `--process` on `target --kind chart` (to check or refine) and on
  `openquad negative` applies it.
- App (Phase 7, step 4): a **Digital negative** output mode in the print window (ink colour, process
  curve, mirror, safe edge; the preview shows the negative as on film; **Save negative** for printing
  from GIMP), and a **process calibration wizard** (chart page per colour, print here or from GIMP,
  scan here or read a scan file, measured-vs-target chart, refine, use a colour's curve). Runs are kept
  with every file and a `run.json` log (`process_run.ProcessRun`, Qt-free).
- App stability: background work runs on Python's thread pool and Python's garbage collector runs
  only on the main thread (automatic collection on a worker thread freed Qt objects there and crashed
  the app intermittently); window signal hubs are owned by their windows.
- Several colours on one page: `--colour green,orange` stacks compact charts (identification squares
  tell them apart); `openquad chart SCAN --colours green,orange -o x.oqproc` reads both and writes
  one curve per colour.

### Added (Phase 5: desktop app)
- Calibration wizard ("Calibrate…" in the print window): print a comparison page, scan it over eSCL,
  measure, see colour cast and tone per step on a chart, and improve grey balance or even out tone
  until both goals are met; then use the result for printing. Every print and scan asks first. Runs
  are kept with all files and a `run.json` log (`calibrate.CalibrationRun`, Qt-free).
- Scanner discovery on the network (`escl.discover`, via dns-sd or avahi); the scanner is remembered.
- `openquad-app` (install with the `ui` extra): print window to open a photo, choose toning (neutral by
  default), calibration, printer, paper and fit-to-page, with a live preview rendered off the UI thread,
  a confirmation before printing, and saving the print file. Remembers printer, paper and calibration,
  never the toning.
- `photo.load_photo`: any greyscale photo (8/16-bit, grey stored as RGB/RGBA, transparency placed on
  paper white, transparent edges cropped; colour converted by luminance with a note).
- `paper`: paper sizes and fit-to-page; `openquad print --fit`.
- `session.PrintSession`: the app's Qt-free model; `settings`: remembered settings.

### Changed
- Colour toning is opt-in: `composite` now defaults to the `neutral` preset (was `black-red`);
  `print` tones only with `--preset`.

### Added
- Project foundation: package layout, CLI stub, smoke tests, ruff, mypy, pre-commit, CI on macOS and Ubuntu.
- `quadfile`: read and write `.quad` curve files, round-trip safe, with line-numbered errors.
- `curves`: 256 → 65,536-entry lookup tables, ink limits, parametric multi-ink curve generation.
- `separate`: 16-bit greyscale → per-ink channels in row bands, with a total-ink warning.
- `imageio`: 8/16-bit greyscale TIFF load/save keeping DPI and ICC profile; per-ink previews.
- `targets`: step-wedge generation.
- Golden-file test of a known image + curve (`scripts/update_golden.py` regenerates fixtures).
- `composite`: multi-layer colour toning (subtractive, linear-light mixing) with presets `neutral`, `black-red`, `red-only`, `warm-split`; `imageio.save_rgb` for 16-bit RGB TIFFs.
- `scripts/make_composite_test.py`: composite-path test sheet (neutral and black + red wedges).
- Smooth ramp shape (`InkSpec(shape="smooth")`); colour presets use it, removing the visible line where a layer peaks.
- CLI: `openquad target`, `composite`, `presets`, `print` (with `--preset`, `--dry-run`, `--option`) and `printers`.
- `printing`: CUPS `lp` wrapper that prints at real size and returns the job id.
- Grey balance (Phase 3, composite path): framed grey-balance target (`target --kind grey-balance`),
  eSCL/AirScan scanning (`scan`), scan measurement to L\*a\*b\* (`measure`), per-channel RGB
  correction (`greybalance`, `.oqcal` files) and `--calibration` on `target`, `composite` and `print`.
- `colour`: sRGB transfer functions, luminance and CIE L\*a\*b\* (D65).
- Pillow dependency for reading JPEG scans.
- `target --kind comparison`: uncorrected and corrected targets on one page (marked with one and two
  squares) so one scan compares them under identical scanner processing.
- `measure --pair`: measures both targets of a comparison page, either way up.
- `greybalance --damping` / `--shadow-damping`: apply only part of each correction (steps 17–21 for
  the shadow option) so passes don't overshoot where the printer switches to pigment black.
- Scanning: eSCL jobs are closed after download; Document is the default intent (Photo auto-crops).
- Regression tests on real Canon MG3600 scans in `calibration-data/`.
- Tone linearization (`linearize` module, `openquad linearize`): measured vs target L\* report and a
  tone curve folded into the calibration, targeting sRGB lightness scaled between paper black and
  paper white (black-point compensation).
