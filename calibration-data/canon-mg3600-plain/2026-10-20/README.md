# Canon PIXMA MG3600 — Letter plain paper — 20 Oct 2026

First real grey-balance session (composite path). Printer queue `Canon_MG3600_series`
(AirPrint, default quality); scanner: the MG3600's own flatbed over eSCL at 300 dpi.

| File | What it is |
| --- | --- |
| `scan1.jpg`, `m1.json` | Pass 1 target (uncorrected), job 3146. Scanner cropped tight to the frame (2128 × 656). Worst cast 6.7 (blue-violet mid-tones, b\* to −6.7, a\* to +3.4); deepest black L\* 19.4 |
| `canon-plain.oqcal` | Calibration built from `m1.json` |
| `scan2*.jpg`, `m2*.json` | Pass 2 target (corrected with `canon-plain.oqcal`), job 3147. Three scans of the same sheet agree within ~0.3. Worst cast 2.5; deepest black L\* 26.0 |
| `scan1b.jpg`, `scan1c.jpg`, `m1b.json`, `m1c.json` | Rescans of what was meant to be the pass 1 sheet, full-page crop. They read almost the same as pass 2 |

## Open question

The full-page scans read both sheets as nearly neutral and lift the deepest black from
L\* 19 to about 26. That suggests the scanner auto-corrects colour and levels when it
scans a full page (but not when it crops tight), which would make the pass 2 result
unreliable. Test: one page with both targets (`scripts/make_comparison_page.py`, job 3148)
scanned once, so both get the same scanner processing.

The texture-correlation check used during the session is not reliable for identifying
sheets: printer banding repeats across pages, and the tight-cropped scan misaligns.
