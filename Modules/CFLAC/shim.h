#ifndef CFLAC_SHIM_H
#define CFLAC_SHIM_H

#if __has_include(<FLAC/all.h>)

#include <FLAC/all.h>

#define CFLAC_AVAILABLE 1
#else
#define CFLAC_AVAILABLE 0
#endif

#endif /* CFLAC_SHIM_H */
