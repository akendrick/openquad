# Canon PIXMA MG3600, Letter plain paper

`canon-plain.oqcal` is the current calibration (v5, 22 Oct 2026): grey balance plus tone
linearization. Worst tone error 1.4 L\* (mean 0.48); worst colour cast 2.0 (mean 0.62); deepest
black L\* 23.5. Valid only for the `Canon_MG3600_series` AirPrint queue at default quality on
Letter plain paper. Sessions: `2026-10-20/` (grey balance), `2026-10-22/` (linearization).

```bash
openquad print photo.tif --printer Canon_MG3600_series --preset black-red \
    --calibration calibration-data/canon-mg3600-plain/canon-plain.oqcal
```
