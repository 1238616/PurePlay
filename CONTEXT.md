# PurePlay

An open-source, macOS-native, bit-perfect Hi-Res local music player targeting Chinese audiophile users.

## Language

### Audio Path

**Bit-Perfect Path**:
The default signal path where decoded PCM/DSD passes through no software processing — integer PCM stays integer end-to-end from decoder to DAC.
_Avoid_: passthrough, direct mode, bypass mode

**Hog Mode**:
CoreAudio exclusive device access that prevents other apps from sharing the audio output, ensuring uncontaminated signal delivery to the DAC.
_Avoid_: exclusive mode, ASIO (Windows term)

**Signal Path**:
The complete chain from source through optional DSP to hardware output, displayed to the user in the SignalPathBar.
_Avoid_: audio chain, pipeline (internal implementation term)

**DoP (DSD over PCM)**:
A transport method that encodes DSD bitstream into 24-bit PCM frames with marker bytes, allowing DSD delivery over PCM-only interfaces.
_Avoid_: native DSD (ambiguous), DSD raw

### DSP

**Parametric Band**:
A single EQ filter with user-configurable frequency, Q (bandwidth), gain, and filter type (Peak, Low Shelf, High Shelf).
_Avoid_: EQ point, filter node, band pass

**Graphic EQ Mode**:
A UI presentation that exposes 10 fixed-frequency sliders mapped to parametric bands internally — not a separate engine.
_Avoid_: graphic EQ (as if it were a separate system)

**DSP Chain**:
An ordered sequence of bypassable processing nodes (EQ, crossfeed, gain, dither, resampler) inserted between decoder output and hardware output. Empty by default to preserve bit-perfect path.
_Avoid_: effects chain, processing pipeline

**EQ Panel Layout**:
The Equalizer window's content layout is a vertical stack: a toolbar row (title, on/off switch, preset menu, Import/Save/Reset, current-headphone chip floated right), the parametric curve editor that absorbs remaining height, and a fixed 180pt band region at the bottom (preamp toolbar row + band table). Window minSize is 700×520. The curve editor's height is derived (anchored to the band region's top), never set directly.
_Avoid_: EQ window layout, equalizer panel structure

### Library

**Track**:
A single playable audio item in the library, whether sourced from a local file or a cloud file.
_Avoid_: song (not all audio is songs), file (conflates storage with domain)

**Smart Playlist**:
A dynamic playlist whose membership is defined by JSON-encoded rules evaluated at query time.
_Avoid_: auto playlist, dynamic playlist

### Cloud

**Cloud Source**:
An `AudioSource` implementation that streams audio data via HTTP Range requests from Quark cloud drive, presenting the same interface as local files to the decoder layer.
_Avoid_: remote file, stream (overloaded)

### Decoder

**Decoder Registry**:
A priority-ordered list of decoder factories. When opening a track, the registry tries each factory by descending priority until one succeeds.
_Avoid_: codec registry, format handler

**FFmpeg Fallback**:
The universal decoder at priority 80 that handles formats not covered by dedicated decoders (APE, WavPack, TTA, Opus). Uses FFmpeg LGPL libraries.
_Avoid_: generic decoder, catch-all
