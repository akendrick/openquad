# COpenJPEG

The JPEG 2000 decoder from [OpenJPEG](https://github.com/uclouvain/openjpeg) 2.5.4 (tag
`v2.5.4`), the same library and version Pillow uses, so the Mac app reads `.jp2`, `.j2k` and
`.jpx` photos at their full bit depth (macOS's own ImageIO cuts 16-bit JPEG 2000 to 8-bit).

Copied unchanged from `src/lib/openjp2`, leaving out the benchmark, test and table-generator
programs and the JPIP index writers. `include/opj_config.h` and `opj_config_private.h` are
written by hand in place of CMake's. OpenJPEG is under the BSD 2-clause licence in `LICENSE`.
