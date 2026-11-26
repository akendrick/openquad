# Epson ET-2900, Letter glossy photo paper: colour calibration (phase 6)

Printer queue `EPSON_ET_2900_Series` (AirPrint), straight to the printer (`lp`), options
`MediaType=photographic-high-gloss`, `cupsPrintQuality=High`, `PageSize=Letter`, sent as sRGB.
The fine target (`--fine`: 768 patches, two pages). Scanned on the Epson's own flatbed over
eSCL (https), Photo intent (Document intent clips; see the log).

**No scanner model yet** (no IT8.7/2 target): scans are read as sRGB, adapted to D50. ΔE figures
here measure consistency between what the model predicts and what the same scanner sees, not
absolute colour accuracy.

Plain paper was tried first (`../epson-et2900-colour-plain/`) and set aside for glossy: its
cyan and greens printed weak, with a clean nozzle check.

## Log

- 2026-11-25 09:51: fine target printed, page 1 job 3180, page 2 job 3181, after the Epson's
  own calibration program. Drying before scanning: 1 hour minimum, longer is better on glossy.
- 2026-11-25 10:49–10:52: Document-intent scans (`target-1of2-scan-1.jpg`,
  `target-2of2-scan-1.jpg`); page 1 again placed against the glass's guide edge
  (`target-1of2-scan-2.jpg`). All three read 0.8° tilted: the scanner's guide edge is out
  by that much. OpenQuad now straightens scans tilted up to 3°. Rescan repeatability on
  page 1: 0.18 ΔE00 mean, 1.04 worst.
- Document intent clips on this scanner: 24 patches read L\* 0 (sRGB values up to about 95
  in one channel) and the paper reads pure white. Photo intent (`target-1of2-scan-photo.jpg`)
  keeps the shadows apart (darkest patches 19–57 of 255) and the paper below white, and
  scans the whole page (the Canon's Photo intent cropped). **The Epson is scanned with
  Photo intent from here on.**
- 2026-11-25: Photo-intent scans of both pages (`target-*-scan-photo.jpg`) measured into
  `measured-photo-1.json`: darkest patch L\* 6.7, paper white L\* 98.7, nothing clipped.
  Profile v0 built (`run/`): fit 0.47 ΔE00 mean, held-out patches 1.04 mean (95% 2.23,
  worst 6.57); black L\* 6.6; greys neutral through the profile.
- 2026-11-25 17:46: v0 verification page (job 3182) and the driver comparison (job 3183, the
  same 144 colours sent as plain sRGB) printed on high-gloss, High quality.
- 2026-11-25 17:48: jobs 3182–3183 came out wrong (a print error); both sent again with the same settings, jobs 3184 (verification) and 3185 (driver).
- 2026-11-25 19:17: the first scan of the v0 page timed out mid-download and the printer's
  `.local` name stopped resolving; the stuck scan job was closed and the page scanned by IP
  (`https://192.168.2.236`), Photo intent (`v0-verify-scan.jpg`).
- v0 verification: **goals not met**. 73 of 144 colours printable; ΔE00 mean 5.11 (95%
  8.56); greys: worst cast 4.4, worst tone 3.0 L\*. A steady shift rather than scatter:
  printable patches measure ΔL\* −2.5, Δa\* −2.2, Δb\* −1.7 on average, light greys bluest
  (b\* about −4). Paper white reads the same as on the target's scans.
- 2026-11-25 19:25: driver comparison scanned (`driver-scan.jpg`): **mean 1.19 ΔE00** (95%
  2.47), colour checker 1.29, skin 1.03; greys worst cast 2.1, worst tone 3.0 L\*. Read
  through a scanner taken as sRGB, so this is the Epson's print-and-scan loop agreeing with
  itself, not an absolute measure.
- v0's model fits the target's own patches (0.47) but mispredicts both evening pages by
  about 6 ΔE00, in opposite directions (verify page darker, driver page lighter than
  predicted). The scanner isn't adapting to content: the driver sheet scanned full-page and
  cropped to its patches differs by 0.4 of 255 on average.
- 2026-11-25 19:35: the v0 sheet scanned again by mistake for target page 1 (`v0-verify-scan-2.jpg`): it matches the first v0 scan within 0.4 of 255, so the scanner repeats.
- 2026-11-25: a driver-comparison sheet scanned again in place of target page 1 (`driver-scan-2.jpg`): within 0.8 of 255 of the first driver scan.
- 2026-11-25 evening: target page 1 scanned again in Photo intent
  (`target-1of2-scan-photo-evening.jpg`): within **0.59 ΔE00** mean (95% 1.46) of its
  morning scan, so neither the target nor the scanner has moved. The evening sheets
  printed about 6 ΔE00 from what the morning target predicts: the printer printed them
  differently. Next: reprint the target (`reprint/`, same patches, now labelled) and compare
  it patch for patch with the morning print.
- From here every sheet carries a printed label saying what it is (kind, run, version,
  page, file, date).
