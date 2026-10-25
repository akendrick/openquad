# OpenQuad for macOS (Swift)

The native Mac app is being built here, module by module, against the Python
implementation in `src/openquad`, which stays the reference.

- `OpenQuadCore/`: Swift package with the core (colour maths, `.quad` files, curves,
  separation, colour layers, digital negatives, paper fitting, `.oqcal` calibrations and
  `.oqproc` process curves, building grey balance, linearization and process curves
  from measurements, reading scans (grey-balance wedges, the blocking test and
  process charts), eSCL scanning and scanner discovery, CUPS `lp` printing, and
  16-bit TIFFs with resolution and ICC profile, photo loading, the print session and
  settings). Open `OpenQuadCore/Package.swift` in Xcode, or run
  `swift test --package-path swift/OpenQuadCore`.
- `OpenQuadApp/`: the Mac app (SwiftUI). Open `OpenQuadApp/Package.swift` in Xcode and
  run the OpenQuad scheme, or build an app bundle with `swift/build-app.sh`
  (`swift/build/OpenQuad.app`, unsigned for now). The print window opens a photo, tones
  it or makes a digital negative, sets the page, previews, saves the 16-bit print file,
  and prints through the standard macOS print panel at the exact print size. Settings
  are shared with the Python app (`~/Library/Application Support/OpenQuad/settings.json`);
  toning is never remembered.
  Two calibration wizards open from the print window:
  - **Calibrate This Printer…** prints a comparison page, scans it (eSCL), measures it,
    then improves grey balance or evens out tone until both goals are met.
  - **Calibrate a Process…** prints a page of process charts on film (or you print it
    elsewhere), scans the contact print, reads every chart and refines the curves.

  Runs are kept in `~/Library/Application Support/OpenQuad/calibrations` and
  `processes`, with the same `run.json` as the Python app, so either app can continue a
  run.
- **Parity:** `scripts/export_swift_vectors.py` writes test vectors (inputs and the
  Python outputs) to `OpenQuadCore/Tests/OpenQuadCoreTests/Vectors/`. Each Swift module
  must reproduce them before it is accepted. A Python test fails if the committed vectors
  no longer match what the Python code produces, so the two can't silently drift.

Scans used as vectors are real Canon and carbon prints (and simulated charts), reduced
and stored as lossless PNGs, so Swift decodes exactly the pixels Python measured. JPEG
decoders differ slightly between Pillow and ImageIO, so a JPEG scan reads within about
a level of the Python result rather than bit for bit.

## Signing and notarization

`swift/sign-app.sh` builds `OpenQuad.app` and signs it with the hardened runtime. With no
settings it signs ad hoc, which runs on the Mac that built it (CI does this on every
push). To give the app to other people it must be signed with a **Developer ID
Application** certificate (Apple Developer Program) and notarized by Apple:

1. Install the Developer ID Application certificate in your login keychain.
2. Store notary credentials once (asks for an app-specific password):
   `xcrun notarytool store-credentials openquad-notary --apple-id APPLE_ID --team-id TEAMID`
3. Run
   `OPENQUAD_SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" OPENQUAD_NOTARY_PROFILE=openquad-notary swift/sign-app.sh`

The script signs, notarizes and staples the app, then makes, signs, notarizes and
staples `swift/build/OpenQuad-VERSION.dmg`. The identity and credentials stay in your
keychain and environment; nothing secret goes in the repository. The app is not
sandboxed: it runs `lp`, `lpstat` and `dns-sd` and talks to the scanner over the network.

**Calibrations and the print panel:** the Canon calibration was made by printing through
`lp`. The macOS print panel may colour-manage differently, so check a print made through
the panel against the calibration before relying on it (`Printing.send` keeps the `lp`
path available).

Regenerate the vectors after an intended change in the Python core:

```bash
uv run python scripts/export_swift_vectors.py
```
