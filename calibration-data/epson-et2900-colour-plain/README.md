# Epson ET-2900, Letter plain paper: colour calibration (phase 6)

Printer queue `EPSON_ET_2900_Series` (AirPrint), straight to the printer (`lp`), options
`MediaType=stationery`, `cupsPrintQuality=Normal`, `PageSize=Letter`, sent as sRGB.
Scanned on the Epson's own flatbed over eSCL, Document intent.

**No scanner model yet** (no IT8.7/2 target): scans are read as sRGB, adapted to D50. ΔE figures
here measure consistency between what the model predicts and what the same scanner sees, not
absolute colour accuracy.

## Log

- 2026-11-25 08:45: colour target (`target.tif`, 255 patches) printed, job 3178. CUPS
  couldn't reach the printer for about 7 minutes after it woke, then printed. Drying 1 hour
  minimum before scanning.
- 2026-11-25 09:13: early scan (`target-scan-early.jpg`, about 27 minutes after printing,
  before the hour's drying) measured into `measured-early.json`: deepest black L\* 20.8, grey
  cast mean 2.57 (worst 5.3); full cyan pale (L\* 90.4, chroma 22.6) and greens weak. Ink
  levels 72/89/89/90 % (K/Y/M/C); nozzle check clean.
- 2026-11-25 09:18: the owner ran the Epson's own calibration program. The 08:45 target
  predates it, so it is kept only as a "before" reference; the target is to be printed again.
- 2026-11-25 09:48: colour target printed again after the Epson's calibration, job 3179.
- 2026-11-25 09:50: plain paper set aside for glossy (`../epson-et2900-colour-glossy/`); job 3179 not scanned.
