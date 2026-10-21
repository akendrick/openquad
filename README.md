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
