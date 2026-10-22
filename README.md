# OpenQuad

Open-source monochrome and multi-layer colour inkjet printing, in the spirit of QuadToneRIP.

OpenQuad splits a 16-bit greyscale image into per-ink channels using `.quad`-compatible curves
and prints through libgutenprint's raw ink mode. It can also layer colour tones (for example a
black + red duotone) to emulate printing from several stacked negatives on an ordinary colour
inkjet.

**Status:** Phase 0 (project foundation). Not usable yet.

## Desktop app

```bash
uv sync --extra ui
uv run openquad-app
```

Open a photo, pick toning (neutral unless you choose otherwise), calibration, printer and paper; the
preview shows the toned result; Print asks for confirmation first.

## Usage

```bash
openquad target -o wedge.tif                       # 21-step greyscale wedge, 300 dpi
openquad presets                                   # list colour-layer presets
openquad composite photo.tif -o toned.tif --preset black-red
openquad printers                                  # CUPS printer names
openquad print toned.tif --printer Canon_MG3600_series --dry-run
openquad print photo.tif --printer Canon_MG3600_series --preset black-red
```

Grey balance for a colour inkjet (example: Canon MG3600 on plain paper):

```bash
openquad target --kind grey-balance -o gb.tif
openquad print gb.tif --printer Canon_MG3600_series
openquad scan --host 876298000000.local -o scan.jpg       # face down; Document mode by default
openquad measure scan.jpg -o m1.json
openquad greybalance m1.json -o canon-plain.oqcal --printer Canon_MG3600_series --paper "Letter plain"
openquad print photo.tif --printer Canon_MG3600_series --preset black-red --calibration canon-plain.oqcal
```

To check and refine, print a comparison page (uncorrected and corrected targets on one sheet), scan it
once, and measure both:

```bash
openquad target --kind comparison --calibration canon-plain.oqcal -o compare.tif
openquad measure scan2.jpg --pair --calibration canon-plain.oqcal -o m2.json
openquad greybalance m2-corrected.json -o canon-plain-v2.oqcal --shadow-damping 0.5
```

Once grey balance is good, even out the tone from the same kind of measurement:

```bash
openquad linearize m3-corrected.json --calibration canon-plain-v3.oqcal          # report only
openquad linearize m3-corrected.json --calibration canon-plain-v3.oqcal -o canon-plain-v4.oqcal
```
A calibration is only valid for the printer, paper and driver settings it was made with.

`print` prints at the file's real size (its DPI) on Letter paper by default; use `--paper`,
`--ppi`, `--copies` and `--option NAME=VALUE` (driver options) to change that.

## Development

```bash
uv sync
uv run pytest
uv run ruff check . && uv run mypy
uv run pre-commit install --hook-type pre-commit --hook-type pre-push
```

## Licence

GPL-2.0-or-later. See [LICENSE](LICENSE). OpenQuad is not affiliated with QuadToneRIP.
