# OpenQuad

> [!WARNING]
> **Beta: work in progress.** OpenQuad 0.1.0 beta 1 is an early test release. It works on the
> hardware it was developed with (a Canon PIXMA MG3600 and its built-in scanner), but it hasn't been
> tried widely yet. Expect rough edges, and please
> [report what you find](https://github.com/akendrick/openquad/issues/new/choose).

Open-source black-and-white and toned inkjet printing, and digital negatives for carbon transfer, in
the spirit of QuadToneRIP. OpenQuad calibrates an ordinary inkjet printer with its own scanner so
greys print neutral and evenly spaced, adds optional duotone toning, and makes UV-blocking digital
negatives with process calibration (ChartThrob-style charts) for contact printing.

It comes as a **Mac app** (beta) and as a **Python command-line tool and desktop app**, which share
calibration files and settings.

## Download the beta (Mac app)

1. Download **OpenQuad-0.1.0b1.zip** from the
   [latest pre-release](https://github.com/akendrick/openquad/releases) and unzip it.
2. Move **OpenQuad.app** to your Applications folder.
3. The beta isn't notarized by Apple yet, so the first time you open it macOS will refuse. Open it
   anyway: double-click it once, then go to **System Settings ▸ Privacy & Security** and click
   **Open Anyway** next to OpenQuad. Or, in Terminal:
   `xattr -dr com.apple.quarantine /Applications/OpenQuad.app`

Needs macOS 14 (Sonoma) or later, on Apple silicon or Intel. A short **How to Use OpenQuad** guide
opens on first launch (and later from **Help** or the **?** button).

### What to try

- **Print a photo:** open a photo, leave toning neutral or choose a duotone, and print through the
  macOS print panel or straight to a printer. Does the print match the preview, and come out at the
  size it says?
- **Calibrate your printer**, if it has a network (AirScan / eSCL) scanner: Calibrate This Printer…
  prints a test page, scans it and corrects colour casts and tone. How many rounds did it take, and
  did the goals get met?
- **Digital negatives:** make a negative and try the blocking test and process calibration, if you
  contact print (carbon, or another UV process).
- **The guide:** is anything unclear or missing?

### Reporting problems

Use the [beta feedback form](https://github.com/akendrick/openquad/issues/new?template=beta-feedback.yml).
Say which Mac, macOS version, printer and paper you used, and attach a screenshot or scan if it helps.
The app keeps its calibration runs, scans and measurements in
`~/Library/Application Support/OpenQuad`, which you can zip up and attach as well.

### Known limitations

- **Not notarized:** see the install steps above.
- **Tested hardware:** only a Canon PIXMA MG3600 (Letter, plain paper) and its scanner so far. Other
  printers should work through the macOS print panel or CUPS. Scanning needs an eSCL scanner on the
  network; any scanner works through "Read a Scan File".
- **Print panel vs `lp`:** the Canon calibration was made printing straight to the printer (`lp`). A
  calibration made through the macOS print panel should be used through the panel (the wizard records
  which, and the app matches it).
- **Carbon:** the process calibration has been checked on simulated prints and the blocking test on
  real carbon prints, but not a full process calibration on real tissue yet.
- **QuadToneRIP-style raw-ink printing** (per-ink channels through Gutenprint) isn't built yet. The
  beta prints through the normal printer driver.

## Status

| Part | State |
| --- | --- |
| Mac app (SwiftUI): print window, toning, digital negatives, print panel or direct printing | beta |
| Printer calibration wizard (grey balance, tone), calibration library per printer | beta, tested on Canon MG3600 |
| Blocking test and process calibration wizards (carbon) | beta, partly tested |
| Python CLI and desktop app (PySide6) | working; the reference implementation |
| Raw-ink QuadToneRIP-style path | not built |

Hardware results: [docs/hardware-tests.md](docs/hardware-tests.md). Calibration data from real prints
and scans: [calibration-data/](calibration-data/). Mac app details: [swift/README.md](swift/README.md).
Screenshots: [docs/screenshots/](docs/screenshots/).

## Python tools (command line and desktop app)

```bash
uv sync --extra ui
uv run openquad-app          # the PySide6 desktop app
uv run openquad --help       # the command line
```

### Usage

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

### Digital negatives (carbon printing)

Print negatives on **inkjet-coated** transparency film (plain or laser film won't hold the ink):

```bash
openquad target --kind blocking -o blocking.tif      # 1. which ink colour blocks the UV?
openquad print blocking.tif --printer Canon_MG3600_series
#    expose it on carbon tissue at your usual time, make the print, scan it:
openquad scan --host 876298000000.local -o carbon.jpg
openquad blocking carbon.jpg                          #    -> which colours block, and their range
openquad negative photo.tif -o neg.tif --colour green --fit Letter   # 2. a negative in that colour
```

The orientation **F** in the safe edge prints in the carbon print: if it reads backwards, flip
`--mirror`.

Then calibrate the process from a ChartThrob-style chart (after Kevin Bjorke's ChartThrob):

```bash
openquad target --kind chart --colour green -o chart.tif     # print on film, contact print, scan
openquad chart carbon-chart.jpg -o carbon.oqproc               # build the process curve
openquad target --kind chart --process carbon.oqproc -o chart2.tif   # check: print, scan, read
openquad chart carbon-chart2.jpg --process carbon.oqproc -o carbon-v2.oqproc
openquad negative photo.tif -o neg.tif --process carbon-v2.oqproc --fit Letter
```

## Development

```bash
uv sync
uv run pytest
uv run ruff check . && uv run mypy
uv run pre-commit install --hook-type pre-commit --hook-type pre-push
swift test --package-path swift/OpenQuadCore     # the Swift core, checked against Python
swift test --package-path swift/OpenQuadApp      # the Mac app
swift/sign-app.sh                                # build swift/build/OpenQuad.app
```

The Swift core is matched against the Python reference with test vectors
(`scripts/export_swift_vectors.py`); CI runs both on every push.

## Licence

GPL-2.0-or-later. See [LICENSE](LICENSE). OpenQuad is not affiliated with QuadToneRIP.
