# Canon PIXMA MG3600 — Letter plain paper — 22 Oct 2026

Linearization check. Same printer queue and settings as `../2026-10-20/`.

| File | What it is |
| --- | --- |
| `scan7-v4.jpg`, `m7-*.json` | Comparison page with `canon-plain-v4-linear.oqcal` (job 3151), Document intent |
| `canon-plain-v5-linear.oqcal` | Second linearization pass, built from `m7-corrected.json`; not yet printed |

## Result

| | v3 (grey balance only) | v4 (linearized) |
| --- | --- | --- |
| Worst tone error | 6.6 L\* | 3.6 L\* |
| Steps 1–14 | −5.8 to +3.8 | within 1.7 |
| L\* of steps 18–21 | 33.0, 27.4, 27.5, 27.0 | 39.1, 33.7, 27.7, 23.7 |
| Worst / mean cast | 2.3 / 0.42 | 2.4 / 0.43 |

Highlights and mid-tones are on target and the shadows now separate. Steps 15–19 overshoot
light by 2.5–3.6 L\*, partly because this sheet's deepest black measured L\* 23.7 (27.0 on
20 Oct), which lowers the shadow targets: print-to-print variation in the deep black is a few L\*.
The uncorrected target read worst cast 5.5 (5.1–5.4 before), so measurements stay consistent.
