# OpenQuad for macOS (Swift)

The native Mac app is being built here, module by module, against the Python
implementation in `src/openquad`, which stays the reference.

- `OpenQuadCore/`: Swift package with the core (colour maths, `.quad` files, curves,
  separation, colour layers, digital negatives, paper fitting, `.oqcal` calibrations and
  `.oqproc` process curves; still to port: building calibrations from scans, chart
  reading, eSCL scanning and printing).
  Open `OpenQuadCore/Package.swift` in Xcode, or run
  `swift test --package-path swift/OpenQuadCore`.
- **Parity:** `scripts/export_swift_vectors.py` writes test vectors (inputs and the
  Python outputs) to `OpenQuadCore/Tests/OpenQuadCoreTests/Vectors/`. Each Swift module
  must reproduce them before it is accepted. A Python test fails if the committed vectors
  no longer match what the Python code produces, so the two can't silently drift.

Regenerate the vectors after an intended change in the Python core:

```bash
uv run python scripts/export_swift_vectors.py
```
