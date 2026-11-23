# Plan: colour calibration

Status: phases 0 and 1 software built (Python), waiting for a real IT8.7/2 target and test prints. Written 2026-11-22.

## What this is for

OpenQuad already calibrates a printer for **black-and-white** prints. The Printer Calibration
wizard does this with grey balance (per-channel R, G, B curves) and tone linearization, measured
from scans of a framed step wedge. **Colour prints** ("Print in colour (colour-managed printer)")
don't use it. They go straight to macOS colour management with the photo's own ICC profile, so
their accuracy rests on the driver's generic profile for that paper.

Colour calibration closes that gap. It measures what the printer actually does with colour on a
given paper, through a given print path, using the same flatbed scanner. It then builds a
correction that the colour print path, the soft proof and other apps can use.

Out of scope for the first version: raw-ink (QuadToneRIP-style) printing, which isn't built for
grey either. Calibrating the coats of a colour-separation print is a different problem (the
"printer" is a darkroom process); it is a possible later phase (phase 7) that reuses parts of
this work.

## Decisions to make first

1. **Output: an ICC output profile (recommended), or OpenQuad's own 3D lookup table.**
   - *ICC profile:* plugs into what already exists. `SoftProof` lists printer ICC profiles, and
     `NativePrint` already prints images tagged with a profile. GIMP, Photoshop and Lightroom can
     use it too. It costs writing a small ICC writer (an `mft2`/LUT16 `A2B0`/`B2A0` profile) in
     both cores.
   - *3D LUT:* simpler, and stored like a grey calibration in the calibration library, but only
     OpenQuad can use it and the soft proof would need a second path.
   - Recommendation: build the profile maths once (a forward model and its inverse) and **save it
     as ICC**. OpenQuad does the conversion itself (photo profile → calibration) and then sends the
     result exactly the way the target was sent.
2. **How the scanner is trusted.** Grey calibration only needed near-neutral L\*a\*b\*, normalised
   to paper white, and a cast within 3 was good enough. Colour needs the scanner's chroma to be
   right, and a flatbed is not a colorimeter. Recommendation: characterise the scanner once with
   an **IT8.7/2 reflective target** (sold with a reference data file per batch), and keep the
   result per scanner. Without one, the correction can only be relative to the scanner's own
   view, which is fine for consistency between prints but not for accuracy.
3. **What counts as "the printer".** Grey calibration prints the target as sRGB-tagged RGB
   through the same path the photo will take (`lp` or the print panel), and the calibration is
   only valid for that path. Colour should do the same: treat "sRGB-tagged RGB → driver → paper" as
   the device. That avoids the hard question of switching off ColorSync, and matches how the
   library already records printer, paper, settings and print path.

## Phases

Each phase lands as its own PR, with Python as the reference and Swift kept in parity by shared
vectors (`scripts/export_swift_vectors.py`), as now.

### Phase 0: measure the scanner (go/no-go)

- Read the IT8.7/2 reference file (CGATS text: patch id, L\*a\*b\*) and locate the target in a
  Document-intent scan. The IT8 layout is fixed: the corners give the grid.
- Fit a scanner model: per-channel 1D curves plus a 3×3 matrix to XYZ, or a small polynomial if the
  matrix leaves errors over about 3 ΔE00. Report mean, 95th-percentile and worst ΔE00 against the
  reference.
- Repeat on three scans (another day, another spot on the glass) to measure repeatability.
- **Go** if the fitted scanner is within about 2 ΔE00 mean and repeatable within 1. Otherwise
  stop: colour calibration with this scanner would be guesswork, and the plan falls back to
  relative consistency only.
- New: `scanner_profile.py` (and the Swift port), a `scanner` entry in the calibration library,
  and `openquad scanner-profile` in the CLI.
- **Built (2026-11-23):** `openquad.scanner_profile` and `openquad scanner-profile`, Python only,
  tested on simulated scans. The target is located from five patch centres read off the scan
  (A1, A22, L1, GS0, GS23); finding them automatically can come later. The model is fitted to the
  average of the scans; repeatability is each patch's largest difference from that average. The
  Swift port and the library entry wait for a go verdict on a real target (they're only needed by
  the app, in phase 4). **Still to do:** buy an IT8.7/2 target, scan it on the MG3600 and the
  ET-2900, and record the verdicts in `docs/hardware-tests.md`.

### Phase 1: colour target and measuring it

- One Letter page of about 250 patches: a 6×6×6 RGB grid (216), 21 extra neutrals, and the
  primaries and secondaries at a few strengths. Patches go inside the black frame the grey target
  already uses, so `measure.find_frame` and the median sampling are reused. Rows are shuffled so a
  streaky print or uneven scan doesn't all land on one hue.
- A two-page, 9×9×9 option (729 patches) for glossy papers, where the gamut is bigger and the grid
  needs to be finer.
- `measure.py` generalises from wedge rows to a grid layout described by the target's JSON. Each
  patch gives scanner RGB → (scanner model) → L\*a\*b\*, normalised to the paper white.
- **Built (2026-11-23):** `openquad.colour_target`, `openquad target --kind colour [--fine]` and
  `openquad measure-colour`, Python only, tested on simulated prints and scans. Rather than
  generalising `measure.py`, the colour target has its own module that reuses `find_frame`,
  `count_marks` and median sampling. Patches run edge to edge inside the frame (0.43 in, 15 × 17 on
  one page; 0.32 in for the fine target, 21 columns over two pages), the whole set shuffled with a
  fixed seed. Page marks (one square for page 1, two for page 2) sit left of the frame, so scans
  can be given in any order and either way up. Paper white is sampled from the bare strips above
  and below the patches; a note is added if pages' paper white differs by more than 3%. With no
  scanner model the scan is taken as sRGB and adapted to D50 (Bradford), so both paths give D50
  XYZ. **Still to do:** print and scan the target on a real printer and check the measurements
  repeat between prints.

### Phase 2: build the profile

- **Forward model** (RGB sent → L\*a\*b\* measured): interpolate across the measured grid with a
  light smoothing fit, so one bad patch can't put a dent in the model; check it by leaving patches
  out.
- **Inverse** (L\*a\*b\* wanted → RGB to send): search the forward model on a 33³ L\*a\*b\* grid,
  as the colour separations already do for coat strengths (bounded least squares on a grid, then
  interpolate).
- **Out-of-gamut colours:** relative colorimetric with black-point compensation, which is what
  grey linearization already does for tone. Optionally, a gentle perceptual compression towards
  the gamut surface.
- Grey axis: neutrals must stay neutral. Pin the inverse along L\* to the existing grey
  calibration's behaviour, so a colour print of a grey photo matches a black-and-white print.
- Write an ICC v2 output profile (A2B0, B2A0/B2A1, gamut tag, description, media white point).
  Check that ColorSync loads it, and round-trip it against the model in tests.

### Phase 3: the verification loop

- Like the grey wizard's rounds: print a verification page through the new profile, scan it and
  report ΔE00. The page holds patches *not* in the training grid, the ColorChecker-like 24 colours
  and skin tones, and a neutral wedge.
- Goals, to set for real after phase 0: on plain paper, mean under 3 and 95th percentile under 6
  ΔE00; neutrals keep the grey goals (cast under 3, tone under 2 L\*).
- If the goals aren't met, refine: fold the measured residuals back into the forward model and
  rebuild, damped as grey balance is.
- Everything for a run (pages, scans, measurements, profile, `run.json`) is kept in the run folder,
  as `calibrate.py` does for grey.

### Phase 4: app

- **Printer Calibration wizard:** a "Black and white / Colour" choice at setup. Colour runs the same
  Print → Scan → Result card with its own rounds table (ΔE00 instead of cast and tone). It needs a
  scanner profile first; if there isn't one, the card says so and offers phase 0's "Measure the
  Scanner" step.
- **Calibration library:** colour profiles are listed per printer, paper and print path, next to the
  grey calibrations. Each one can be exported as an `.icc` to `~/Library/ColorSync/Profiles`.
- **Print tab:** under "Print in colour", a Profile picker: "macOS (driver's profile)" or one of
  this printer's OpenQuad profiles. The soft proof follows the choice automatically. The print
  path is matched as the grey calibration's is today.
- Busy and error text in the style that PR 75 introduces.

### Phase 5: Python parity and CLI

`openquad target --kind colour`, `openquad measure --kind colour`, `openquad profile build|verify`;
the PySide6 window gets the profile picker. Shared vectors cover the target layout, the forward
model, the inverse and the ICC bytes.

### Phase 6: hardware tests

On the Canon PIXMA MG3600 (Letter plain paper, `lp` path), then the Epson ET-2900. Record each
print in `docs/hardware-tests.md` and the raw scans and measurements in `calibration-data/`, as
for grey. Compare against the driver's own profile on the same verification page; that comparison
decides whether the feature is worth shipping.

### Phase 7 (later, optional): coat colours for colour separations

Print a coat chart as negatives, make the gum or cyanotype coats, scan, and measure each coat's real
colour at full strength and its tone response. These feed `ColourSeparation`'s coat colours and
per-coat curves, replacing the presets. This reuses phases 0–2 (scanner model, grid measuring,
forward model), not the ICC writer.

## Risks

- **Scanner accuracy** is the main risk, and phase 0 tests it before anything else is built.
- **Driver changes:** the profile is only valid for the driver, settings and paper it was made
  with. The library records them and the Print tab warns on a mismatch, as for grey.
- **Ink drift:** dye inks shift for about a day after printing. Scan targets after a fixed
  drying time (state it in the wizard; 1 hour minimum, 24 hours for the final round).
- **ICC writer correctness:** test against ColorSync (Swift) and, in CI, against LittleCMS through
  Pillow's `ImageCms` (Python), so neither core relies only on its own reader.

## Open questions for the owner

1. Is the ICC output (decision 1) right, or should the first version be OpenQuad-only?
2. Is buying an IT8.7/2 reflective target acceptable, or should phase 0 aim at a ColorChecker you
   already have?
3. Which papers matter after plain paper (a glossy or matte photo paper for the MG3600 or the
   ET-2900)?
4. Should phase 7 (coat colours for separations) come before printer colour, since it serves the
   alternative-process work more directly?
