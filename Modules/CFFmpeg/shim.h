#ifndef CFFMPEG_SHIM_H
#define CFFMPEG_SHIM_H

#if __has_include(<libavcodec/avcodec.h>)

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/opt.h>
#include <libavutil/channel_layout.h>
#include <libavutil/samplefmt.h>
#include <libavutil/mathematics.h>
#include <libswresample/swresample.h>

#define CFFMPEG_AVAILABLE 1
#else
#define CFFMPEG_AVAILABLE 0
#endif

#endif /* CFFMPEG_SHIM_H */
