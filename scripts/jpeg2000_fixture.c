// Writes the JPEG 2000 test files that Pillow can't (16-bit colour, 12-bit, signed, lossy
// 16-bit), in fixtures/jpeg2000. Build it against the OpenJPEG copy in the Swift package:
//
//   S=swift/OpenQuadCore/Sources/COpenJPEG
//   clang -O2 -w -I$S -I$S/include scripts/jpeg2000_fixture.c $S/*.c -o /tmp/jpeg2000_fixture
//
// Usage: jpeg2000_fixture out.jp2|out.j2k width height components precision signed(0/1)
//        lossless(0/1) < pixels (little-endian uint16, interleaved)
// (fixtures/jpeg2000/README.md has the pixels each file was made from.)
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "openjpeg.h"
int main(int argc, char **argv) {
  const char *out = argv[1]; int w = atoi(argv[2]), h = atoi(argv[3]), nc = atoi(argv[4]), prec = atoi(argv[5]);
  int sgnd = atoi(argv[6]), lossless = atoi(argv[7]);
  opj_image_cmptparm_t p[4]; memset(p, 0, sizeof p);
  for (int c = 0; c < nc; c++) { p[c].dx = p[c].dy = 1; p[c].w = w; p[c].h = h; p[c].prec = prec; p[c].sgnd = sgnd; }
  opj_image_t *img = opj_image_create(nc, p, nc >= 3 ? OPJ_CLRSPC_SRGB : OPJ_CLRSPC_GRAY);
  img->x1 = w; img->y1 = h;
  if (nc == 2 || nc == 4) img->comps[nc-1].alpha = 1;
  unsigned short *buf = malloc(2 * w * h * nc); fread(buf, 2, w * h * nc, stdin);
  for (int i = 0; i < w * h; i++) for (int c = 0; c < nc; c++) img->comps[c].data[i] = sgnd ? (int)buf[i*nc+c] - (1 << (prec-1)) : buf[i*nc+c];
  opj_cparameters_t params; opj_set_default_encoder_parameters(&params);
  if (!lossless) { params.irreversible = 1; params.tcp_numlayers = 1; params.tcp_rates[0] = 8; params.cp_disto_alloc = 1; }
  params.tcp_mct = nc >= 3 ? 1 : 0;
  int j2k = strstr(out, ".j2k") != NULL;
  opj_codec_t *codec = opj_create_compress(j2k ? OPJ_CODEC_J2K : OPJ_CODEC_JP2);
  opj_setup_encoder(codec, &params, img);
  opj_stream_t *s = opj_stream_create_default_file_stream(out, OPJ_FALSE);
  if (!opj_start_compress(codec, img, s) || !opj_encode(codec, s) || !opj_end_compress(codec, s)) { fprintf(stderr, "failed\n"); return 1; }
  opj_stream_destroy(s); opj_destroy_codec(codec); opj_image_destroy(img); return 0;
}
