# Changelog

All notable changes are recorded here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
