# Digital negatives for carbon transfer: coated office transparency film

Canon PIXMA MG3600 printing on inkjet-coated office overhead film (no surfactant yet: Tween 20 not
arrived, so ink beads/reticulates), carbon tissue at the usual exposure. Printed from GIMP as is.
Print dialog settings (both prints, printed from GIMP):

| Setting | Value |
| --- | --- |
| Paper / media type | Fine glossy paper |
| Quality | Extra detail |
| Print pattern | Diffusion (error diffusion, not a halftone pattern) |
| Resolution | 600 × 600 |

Keep these identical for every negative and calibration on this film: a different media type
changes how much ink goes down, which changes how much UV the negative blocks.

| Date | File | What |
| --- | --- | --- |
| 2026-10-22 | `2026-10-22/blocking-negative-film-scan.jpg` | The printed blocking-test negative itself (not a carbon print) |
| 2026-10-23 | `2026-10-23/blocking-carbon-print-scan.jpg`, `blocking-report.txt` | Carbon print 1, laid sideways, 0.8° tilt |
| 2026-10-24 | `2026-10-24/blocking-carbon-print-2-scan.jpg`, `blocking-report.txt` | Carbon print 2 (repeat): negative mirrored, laid sideways, 3.3° tilt; more reticulation; tissue fade towards one side |

## Results: two prints of the same test negative

Full-patch L\* (higher = blocked more UV), usable wedge steps out of 11, and whether it blocks fully
(within 3 L\* of the best blocker):

| Colour | Print 1 L\* | Print 2 L\* | Blocks 1 / 2 | Steps 1 / 2 |
| --- | --- | --- | --- | --- |
| black | 82.5 | 80.5 | no / no | 8 / 9 |
| green | 92.5 | 91.3 | yes / yes | 9 / 8 |
| orange | **93.8** | **92.7** | yes / yes | 9 / 8 |
| yellow | 93.3 | 85.9 | yes / no | 8 / 6 |
| red | 90.0 | 67.7 | no / no | 9 / 8 |
| olive | 91.9 | 90.5 | yes / yes | 7 / 7 |

Process white (best blocker) to bare paper: 4.9 and 4.8 L\*, so both exposures were fine.

**Confirmed by both prints:**
- **Black blocks the least UV** on this film (L\* 82.5 and 80.5): don't use black negatives or
  black safe edges here.
- **Green and orange are the dependable blockers**: both block fully on both prints, within
  about 1 L\* of each other; orange is the strongest blocker each time, green gives slightly more
  usable steps. Olive also blocks on both but with fewer steps.
- **Yellow and red are inconsistent**: fine on print 1, much weaker on print 2 (red 90.0 → 67.7).
  Print 2 had more ink reticulation and a tissue fade, so these are the colours most sensitive to
  how the ink lies on the film. Retest after Tween 20 arrives.

Print 2's tonal ranges are shorter (about 55 vs 65 L\*): consistent with the tissue fade the
printer noted, not a negative problem.

**Recommendation for step 3 (process calibration):** green negatives (orange as the alternative),
with safe edges in the same colour.

## What the analysis learned from these prints

The analysis was hardened on these real prints: the sheet is found inside a larger exposed tissue
field (tape, ink drips), its edges pinned where clear film meets the safe edge (works with a leaky,
grey safe edge), any of 8 orientations (sideways, mirrored), tilt up to 6° squared up, and the
marker allowed to sit slightly off (tissue stretch). Regression tests pin both prints' results.
