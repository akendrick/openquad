# Canon PIXMA MG3600, Letter plain paper

`canon-plain.oqcal` is the current grey-balance calibration (v3, 20 Oct 2026): worst cast 2.3,
mean 0.42, steps 1–18 within ±0.7. Valid only for the `Canon_MG3600_series` AirPrint queue at
default quality on Letter plain paper. Session details: `2026-10-20/README.md`.

```bash
openquad print photo.tif --printer Canon_MG3600_series --preset black-red \
    --calibration calibration-data/canon-mg3600-plain/canon-plain.oqcal
```
