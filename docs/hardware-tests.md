# Hardware tests

Every real print and scan made while developing OpenQuad, newest first. Raw data for the
calibration sessions is in `calibration-data/`. All on a Canon PIXMA MG3600 (`Canon_MG3600_series`
AirPrint queue, default quality, Letter plain paper) and its flatbed over eSCL.

| Date | Job | What | Result |
| --- | --- | --- | --- |
| 2026-10-23 | (GIMP) | Carbon print of the blocking-test negative on coated office film | Black blocks least (L\* 82.8); green best (9 steps, 65 L\*), orange strongest blocker (L\* 94.0); black safe edge leaked. See `calibration-data/carbon-ohp/` |
| 2026-10-22 | 3153 | Portrait, black + red preset, v5 calibration, 7.4 × 10 in | Print matches the on-screen preview (by eye) |
| 2026-10-22 | 3152 | Comparison page, v5 (second linearization) | Tone within 1.4 L\* (mean 0.48); worst cast 2.0. Phase 3 goals met |
| 2026-10-22 | 3151 | Comparison page, v4 (first linearization) | Tone error 6.6 → 3.6 L\*; shadows separate |
| 2026-10-20 | 3150 | Comparison page, v3 (shadow damping 0.5) | Worst cast 2.3, mean 0.42 |
| 2026-10-20 | 3149 | Comparison page, v2 | Worst cast 2.9; near-black overshoots warm |
| 2026-10-20 | 3148 | Comparison page, v1 | Correction confirmed: 5.4 → 2.5. Found: Photo scan mode auto-crops and alters colour |
| 2026-10-20 | 3147 | Grey-balance target, v1 | Measured 2.5, but scanner processing differed between scans |
| 2026-10-20 | 3146 | Grey-balance target, uncorrected | Blue-violet cast, worst 6.7 (Photo mode) |
| 2026-10-20 | 3145 | Composite test sheet, smooth ramps | No visible line in the gradient |
| 2026-10-20 | 3144 | Composite test sheet, first print | Neutral wedge grey on screen but blue-violet on paper; duotone pink → red → black |

Scanner findings: use Document intent (Photo auto-crops to one region and changes colour and levels);
close each eSCL job after download or the next scan is refused; Document scans come back rotated 180°.
