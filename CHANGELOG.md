# Changelog

All notable changes are recorded here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

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

### Changed

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
