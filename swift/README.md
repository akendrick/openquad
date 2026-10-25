# OpenQuad for macOS (Swift)

The native Mac app is being built here, module by module, against the Python
implementation in `src/openquad`, which stays the reference.

- `OpenQuadCore/`: Swift package with the core (colour maths, `.quad` files, curves,
  separation, colour layers, digital negatives, paper fitting, `.oqcal` calibrations and
  `.oqproc` process curves, building grey balance, linearization and process curves
  from measurements, reading scans (grey-balance wedges, the blocking test and
  process charts), eSCL scanning and scanner discovery, CUPS `lp` printing, and
  16-bit TIFFs with resolution and ICC profile). The whole Python core is now ported;
  next is the SwiftUI app with the native print dialog.
  Open `OpenQuadCore/Package.swift` in Xcode, or run
  `swift test --package-path swift/OpenQuadCore`.
- **Parity:** `scripts/export_swift_vectors.py` writes test vectors (inputs and the
  Python outputs) to `OpenQuadCore/Tests/OpenQuadCoreTests/Vectors/`. Each Swift module
  must reproduce them before it is accepted. A Python test fails if the committed vectors
  no longer match what the Python code produces, so the two can't silently drift.

Scans used as vectors are real Canon and carbon prints (and simulated charts), reduced
and stored as lossless PNGs, so Swift decodes exactly the pixels Python measured. JPEG
decoders differ slightly between Pillow and ImageIO, so a JPEG scan reads within about
a level of the Python result rather than bit for bit.

Regenerate the vectors after an intended change in the Python core:

```bash
uv run python scripts/export_swift_vectors.py
```
