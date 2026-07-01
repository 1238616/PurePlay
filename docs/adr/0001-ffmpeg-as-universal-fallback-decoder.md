# FFmpeg LGPL as universal fallback decoder

APE and WavPack are critical formats for Chinese audiophile collections, but PurePlay lacked support for them. We chose to integrate FFmpeg (LGPL, dynamically linked, embedded in the app bundle) as a single universal fallback decoder at priority 80, rather than integrating per-format libraries (libmac, libwavpack) individually.

## Considered Options

- **Per-format libraries** (libmac for APE, libwavpack for WavPack): more lightweight, but poorly maintained for Apple Silicon, doubles build infrastructure, and doesn't cover future formats.
- **FFmpeg as universal fallback**: one integration covers APE, WavPack, TTA, Opus, Vorbis, and anything else. Built with `--disable-everything` plus minimal `--enable-decoder/demuxer` flags. Ships libavcodec, libavformat, libavutil, libswresample in `Contents/Frameworks/`.

## Consequences

- App bundle grows ~15-20 MB from FFmpeg dylibs.
- Adding new format support in the future is a configure flag, not a new library integration.
- FFmpeg outputs are converted to native source bit depth (via libswresample) before entering the ring buffer, preserving bit-perfect semantics for integer sources.
- Priority 80 means dedicated decoders (LibFLAC at 100, ALAC at 95, CoreAudio at 90) take precedence for formats they handle natively.
