# Changelog

All notable changes are recorded here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Project foundation: package layout, CLI stub, smoke tests, ruff, mypy, pre-commit, CI on macOS and Ubuntu.
- `quadfile`: read and write `.quad` curve files, round-trip safe, with line-numbered errors.
- `curves`: 256 → 65,536-entry lookup tables, ink limits, parametric multi-ink curve generation.
- `separate`: 16-bit greyscale → per-ink channels in row bands, with a total-ink warning.
- `imageio`: 8/16-bit greyscale TIFF load/save keeping DPI and ICC profile; per-ink previews.
- `targets`: step-wedge generation.
- Golden-file test of a known image + curve (`scripts/update_golden.py` regenerates fixtures).
- `composite`: multi-layer colour toning (subtractive, linear-light mixing) with presets `neutral`, `black-red`, `red-only`, `warm-split`; `imageio.save_rgb` for 16-bit RGB TIFFs.
- `scripts/make_composite_test.py`: composite-path test sheet (neutral and black + red wedges).
