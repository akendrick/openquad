# OpenQuad

Open-source monochrome and multi-layer colour inkjet printing, in the spirit of QuadToneRIP.

OpenQuad splits a 16-bit greyscale image into per-ink channels using `.quad`-compatible curves
and prints through libgutenprint's raw ink mode. It can also layer colour tones (for example a
black + red duotone) to emulate printing from several stacked negatives on an ordinary colour
inkjet.

**Status:** Phase 0 (project foundation). Not usable yet.

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

Repeat with `target --calibration canon-plain.oqcal` and `measure --calibration ...` to refine.
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
