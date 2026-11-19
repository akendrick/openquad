/* Written by hand for OpenQuad (CMake generates this upstream): macOS, no threads. */

#define OPJ_PACKAGE_VERSION "2.5.4"

#define OPJ_HAVE_FSEEKO 1
#define OPJ_HAVE_POSIX_MEMALIGN

#if !defined(_POSIX_C_SOURCE)
#if defined(OPJ_HAVE_FSEEKO) || defined(OPJ_HAVE_POSIX_MEMALIGN)
/* Get declarations of fseeko, ftello, posix_memalign. */
#define _POSIX_C_SOURCE 200112L
#endif
#endif

/* Byte order: Mac compilers define __BIG_ENDIAN__ or __LITTLE_ENDIAN__. */
#if defined(__BIG_ENDIAN__)
# define OPJ_BIG_ENDIAN
#endif
