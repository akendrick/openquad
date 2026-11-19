# JPEG 2000 test files

Files Pillow can't write, made with `scripts/jpeg2000_fixture.c` (OpenJPEG 2.5.4), 40 x 32
pixels, from `numpy.random.default_rng(23)` in this order:

- `rgb16.jp2`: 16-bit RGB, lossless; random, with the first row starting 65535, 65408,
  65407 and (65400, 30000, 100), the values Pillow's own reader turns black.
- `grey12.j2k`: a 12-bit grey ramp 0-4095 across, as a bare codestream.
- `rgba16-lossy.jp2`: 16-bit RGB and alpha, lossy (9/7 wavelet, rate 8); random colour, the
  top 5 rows transparent and rows 10-13, columns 6-11 at alpha 30000.
- `grey16-signed.j2k`: a 16-bit grey ramp 0-65535 stored as signed values.

Used by tests/test_jpeg2000.py and, through scripts/export_swift_vectors.py, by the Swift
parity tests.
