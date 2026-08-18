# PurePlay
<img width="840" height="1626" alt="image" src="https://github.com/user-attachments/assets/bce3fb85-f00e-4f76-a873-f3b826339e6c" />


> macOS-native, bit-perfect Hi-Res music player — DSD/DoP, Quark cloud streaming, full library tooling, visible signal path.

A SwiftPM package combining a Vox-inspired minimal dark UI with audiophile-grade audio plumbing and Strawberry-style library management.

```
┌──────────────────────────────────────────────────────────┐
│  PurePlay  v1.7.1                                        │
├──────────────────────────────────────────────────────────┤
│            ┌───────────────────────────────┐             │
│            │                               │             │
│            │        [ Album Cover ]        │             │
│            │                               │             │
│            └───────────────────────────────┘             │
│                                                          │
│   Track Title           [ DSD64 ]                        │
│   Artist · Album                                         │
│   📁 Local · Bit-Perfect                                 │
│                                                          │
│   ▰▰▰▰▰▰▰▰▱▱▱▱▱▱▱▱▱  01:24 / 04:18                      │
│                                                          │
│   ▁▂▃▅▆▇█▇▆▅▃▂▁▂▃▅▆     ← scrolling waveform (peak/rms) │
│   ║▌▌▍▎▎▍▌▌▍▎▏▍▌▎▏     ← FFT spectrum (vDSP)           │
│                                                          │
│   ◀◀  ▶  ▶▶  🔊─────  ☰  ≡  ☁  📚                       │
├──────────────────────────────────────────────────────────┤
│ 🟢 FLAC 24/96 → Bit-Perfect → ES9038 Hog 96kHz/24bit ✓  │
└──────────────────────────────────────────────────────────┘
```

The colored dot in the bottom signal-path bar reports the true playback state:
🟢 bit-perfect · 🟠 DSP active · 🔴 hardware rate mismatched · ⚪ idle.

---

## Table of Contents

1. [Highlights](#highlights)
2. [System Requirements](#system-requirements)
3. [Quick Start](#quick-start)
4. [Architecture](#architecture)
5. [Audio Engine Internals](#audio-engine-internals)
6. [Module Reference](#module-reference)
7. [Build & Release](#build--release)
8. [Usage Guide](#usage-guide)
9. [Quark Cloud Setup](#quark-cloud-setup)
10. [Optional Native Libraries](#optional-native-libraries)
11. [Keyboard & Hotkeys](#keyboard--hotkeys)
12. [Testing](#testing)
13. [Project Layout](#project-layout)
14. [Roadmap](#roadmap)
15. [License](#license)

---

## Highlights

### Audio Engine — true bit-perfect, made visible
- **Hog Mode + PhysicalFormat + mixable=0** — `CoreAudioHALOutput` takes exclusive control of the chosen DAC, writes the precise sample-rate and bit-depth via `kAudioStreamPropertyPhysicalFormat`, and restores the original `SupportsMixing` flag on release.
- **Four-class CoreAudio listener** (`AudioDeviceListener`) — wires `DeviceIsAlive`, `DefaultOutputDevice`, `PhysicalFormat`, and `Devices` events back to the controller; unplug triggers an immediate pause + UI refresh.
- **Per-track sample-rate switching** (`SampleRateManager`) with `switchAndWait` polling.
- **Bit-perfect by default** — `DSPChain.build` returns an empty chain unless the user explicitly opts into EQ / crossfeed / dither / ReplayGain. DSD sources always force an empty chain: any DSP would corrupt the DoP marker bytes, so the pipeline silently stays bit-perfect and the UI reports "EQ bypassed for DSD".
- **Integer PCM straight-through** — 16/24/32-bit signed packed ASBD when the source is integer; only float when DSP is engaged.
- **DSD via DoP v1.1** — `DSF` (LSB-first) and `DFF` (MSB-first) decoders both feed `DoPPacker` to emit byte-swapped 24-bit DoP markers that survive any little-endian CoreAudio path.
- **Gesemann 96-tap DSD→PCM** — `DSD2PCMConverter` with 256-entry lookup × 12-byte window for high-quality fallback when DoP is unavailable.
- **Kaiser-Sinc resampler** — `SincResampler` ships a 32-zero-crossing × 64-phase polyphase table with Kaiser β=9 (~-95 dB stopband); honest Swift code, no external dependency. `LibSoXR` slot ready when the user opts into the binary framework.
- **Lock-free ring buffer** — `PCMRingBuffer` single-producer/single-consumer with `swift-atomics`; 2-second default capacity.
- **Gapless playback** — `AudioPipeline.swapDecoder(_:)` exchanges decoders mid-flight when formats match; `PlayerController.tryGaplessAdvance()` automatically wires this for the queue.
- **DAC capability probe** — `DACCapabilityProbe` cross-references `AvailableNominalSampleRates` with the bundled 41-DAC whitelist (`Resources/KnownDSDDevices.json`).

### Decoders (8 formats + FFmpeg universal fallback)
| Decoder              | Library                | Notes                                                  |
| -------------------- | ---------------------- | ------------------------------------------------------ |
| `WAVDecoder`         | self-implemented       | PCM 16/24/32 + IEEE float; RF64 large-file support     |
| `AIFFDecoder`        | self-implemented       | AIFF/AIFC, big-endian → little-endian swap, IEEE-80 SR |
| `DSFDecoder`         | self-implemented       | DSD64..DSD1024, strict 5-rate allowlist, LSB-first → DoP |
| `DFFDecoder`         | self-implemented       | DSDIFF (FRM8), DSD64..DSD1024, MSB-first → DoP         |
| `ALACDecoderFactory` | CoreAudio              | dedicated `.alac/.m4a/.mp4` priority 95                |
| `CoreAudioDecoder`   | CoreAudio fallback     | `.flac/.mp3/.aac/.caf/.ogg`                            |
| `LibFLACDecoder`     | libFLAC (xcframework)  | activates when `CFLAC` is available, priority 100      |
| `FFmpegDecoder`      | FFmpeg (shipped dylib) | universal fallback (priority 80): APE, DTS (DCA), WMA incl. Lossless/Pro, Opus, Vorbis, WavPack, TTA, `.mka`/Matroska via custom AVIO; auto-detects container format (handles DTS-in-WAV) |
| `SineDecoder`        | self-implemented       | synthetic sine source for file-less E2E verification (`.sine`) |
| `CueSheet` parser    | self-implemented       | one-FILE multi-TRACK split via `TrimmingDecoder`       |
| FLAC MD5 verifier    | self-implemented       | parses STREAMINFO, validates the embedded MD5 hash     |

### DSP nodes (all bypassable)
- **ParametricEQNode** — the centrepiece (see [ADR-0002](docs/adr/0002-parametric-eq-replaces-graphic-eq.md)): up to 20 bands, each with type (Peak / Low Shelf / High Shelf / Low-Pass 12 dB / High-Pass 12 dB), frequency 20 Hz–20 kHz, gain ±24 dB, Q 0.1–30, plus a chain pre-amp. Block-level coefficient interpolation (~93 ms) makes live parameter changes click-free; bands hot-update from the UI thread without re-building the chain.
- **CrossfeedNode** — BS2B-style 700 Hz IIR LP + opposite-channel injection
- **GainNode** — pre-amp / ReplayGain in dB
- **DitherNode** — TPDF dither for bit-depth reduction
- **LinearResamplerNode** — the chain's current resampler slot; a Kaiser-windowed **SincResampler** (32 zero-crossings × 64 phases) is implemented and unit-tested, ready to be wired in

### Cloud (夸克网盘) — proper streaming, not buffering-then-playing
- **Sparse-chunk cache** — `CloudStreamSource` partitions the file into 1 MB blocks; fetches on demand via HTTP `Range`, max 3 concurrent requests. Memory cost stays bounded; seeks return instantly.
- **64 KB header probe** — `CloudHeaderProber` recognises WAV / FLAC / AIFF / AIFC / DSF / DFF / MP3 / M4A / Ogg / DTS from the first 64 KB and pre-computes `AudioFormat` so decoder selection no longer depends on file-name extensions.
- **Prefetch manager** — `CloudPrefetchManager` watches the play position and prefetches the next cloud track once the current one has ≤30 s remaining. De-duplicates per fid.
- **Cookie-based auth** with WKWebView panel + Keychain persistence (`com.pureplay.quark.cookie`).
- **Auto re-login** — `QuarkAPIClient` detects expired sessions (HTTP 401/403, business codes 32003/41001/41015, Chinese/English "登录失效" patterns) and fires `onAuthExpired`; the app surfaces a re-login dialog automatically.
- **2 GB LRU disk cache** (`CloudDownloadCache`).

### Library
- **GRDB SQLite** with three schema migrations:
  - `v1` — tracks / albums / artists / playlists / play history
  - `v2` — `source` / `cloudFileId` / `format` / `replayGainTrack/Album` columns to match the Design § 6.1 schema
  - `v3` — **FTS5 virtual table** (`track_fts`) + INSERT/UPDATE/DELETE triggers + bm25 ordering
- **FTS5 search** with phrase-quoted escaping; `SearchBar` falls back to LIKE when FTS returns zero hits.
- **AVAsset metadata reader** + cover-art extractor with SHA-256 cache.
- **FSEvents-based file watcher** + incremental scanner.
- **Smart playlists** with JSON-encoded rules (`contains`, `equals`, `greaterThan`, `lessThan`).

### UI (AppKit)
- **`SignalPathBar`** — driven by the structured `SignalPath` Core type; status dot + middle-truncated text label. Always reflects DSP bypass + hardware rate matching + Hog state.
- **`WaveformView`** — Core Graphics scrolling waveform fed by `WaveformBuffer` (peak + RMS bins). Green/amber/red colour temperature based on peak headroom.
- **`SpectrumView`** — CVDisplayLink-driven 48-band vDSP FFT visualizer. The analyzer is sample-rate aware (correct bin→Hz mapping at 44.1–384 kHz) and uses asymmetric attack/release smoothing (50 ms / 300 ms) so beats snap up instantly and decay naturally.
- **`EQPanel`** (780×520, min 700×520) — professional parametric EQ window laid out per [ADR-0003](docs/adr/0003-eq-panel-layout.md): toolbar row (title, on/off switch, preset menu, Import / Save / Reset, current-headphone chip floated right), a `ParametricEQEditor` curve that absorbs all remaining height, and a fixed 180 pt band region (pre-amp slider row + `EQBandTableView`).
- **`ParametricEQEditor`** — draggable band nodes on the frequency-response curve: drag = frequency + gain, scroll wheel over a node = Q, double-click a node = reset its gain, double-click empty space = add a band (max 20).
- **`EQBandTableView`** — exact-value band table (Type / Freq / Q / Gain / Enable) with per-row filter-type popup, pre-amp slider, and +/− band buttons.
- **AutoEQ import** — `AutoEQParser` reads AutoEQ ParametricEQ text files via the Import button, applies pre-amp + bands, and extracts the headphone model from the file name for the toolbar chip (5000+ correction profiles work out of the box).
- **`MiniPlayerWindow`** — floating 320×120 always-on-top mini player (⇧⌘M).
- **`DSDBadgeView`** — golden serif-italic `DSD64/128/256/512/1024` badge.
- **`NowPlayingViewModel`** — immutable value type, derived from `PlayerController`; the single-point `applyNowPlaying(_:)` update API on `VoxContentView` makes future SwiftUI migration painless.
- **`AlbumGridView` / `LibraryBrowser` / `QueueView` / `SmartPlaylistEditor` / `SearchBar`** — Vox-inspired dark theme throughout.

### System integration
- **GlobalHotKey** — Carbon `RegisterEventHotKey` wraps app-global shortcuts: `⌃⌥F8` play-pause, `⌃⌥→` next, `⌃⌥←` previous.
- **MediaKeyHandler** — `MPRemoteCommandCenter` + Now Playing publisher (title / artist / album / artwork / duration / elapsed).
- **Status bar item** with quick-access menu.

---

## System Requirements

| Item       | Minimum                          |
| ---------- | -------------------------------- |
| macOS      | 13.0 Ventura                     |
| CPU        | Apple Silicon (arm64) or Intel   |
| Swift      | 5.9 (Xcode 15+)                  |
| Disk       | ~50 MB for app + DB cache        |
| RAM        | <100 MB for 10k-track libraries  |

---

## Quick Start

### Install pre-built DMG
```sh
open dist/PurePlay-<version>-Installer.dmg

# Ad-hoc-signed builds need quarantine cleared on first launch:
xattr -dr com.apple.quarantine /Applications/PurePlay.app
```

### Build from source
```sh
git clone https://github.com/1238616/PurePlay.git
cd PurePlay
swift build -c release --product PurePlay
open .build/release/PurePlay.app
```

### Run tests
```sh
swift run PurePlayTests
# Tests: 272 total, 272 passed, 0 failed
# (275 when built with the vendored FFmpeg module flags)
```

---

## Architecture

PurePlay is a two-target SwiftPM package — pure-Swift Core, AppKit-only App.

```
┌───────────────────────────────────────────────────────────────────┐
│                       PurePlayApp (executable)                    │
│  AppDelegate · VoxContentView · NowPlayingViewModel               │
│  SignalPathBar · WaveformView · SpectrumView · DSDBadgeView       │
│  ParametricEQEditor · EQBandTableView · EQPanel · LibraryBrowser  │
│  AlbumGridView · QueueView · SmartPlaylistEditor · SearchBar      │
│  GlobalHotKey · MediaKeyHandler · QuarkLoginPanel · FileBrowser   │
└──────────────────────────────┬────────────────────────────────────┘
                               │ depends on
                               ▼
┌───────────────────────────────────────────────────────────────────┐
│                       PurePlayCore (library)                      │
│                                                                   │
│  ┌─Player ─────────────────┐   ┌─Audio ───────────────────────┐   │
│  │ PlayerController         │  │ AudioPipeline                 │  │
│  │ QueueManager             │  │ AudioFormat / PurePlayError   │  │
│  │ SignalPath (struct)      │  │ SpectrumAnalyzer (vDSP FFT)   │  │
│  └────────────┬─────────────┘  │ WaveformBuffer (peak/rms bins)│  │
│               │                └─────────────┬─────────────────┘  │
│               ▼                              ▼                    │
│  ┌─Decoder ──────────────┐  ┌─DSP ──────────┐  ┌─Buffer ──────┐   │
│  │ DecoderRegistry        │  │ DSPChain      │  │ PCMRingBuffer│   │
│  │ WAV / AIFF / DSF / DFF │  │ ParametricEQ  │  │ (lock-free)  │   │
│  │ ALAC / CoreAudio       │  │ Crossfeed     │  └──────────────┘   │
│  │ CueSheet + Trimming    │  │ Dither / Gain │                     │
│  │ LibFLAC (when CFLAC)   │  │ Resampler     │                     │
│  │ FLACMetadata + MD5     │  └───────────────┘                     │
│  │ Sine (test)            │                                       │
│  └────────┬───────────────┘                                       │
│           ▼                                                       │
│  ┌─DSD ──────────────────┐  ┌─Output ─────────────────────┐       │
│  │ DoPPacker             │  │ CoreAudioHALOutput          │       │
│  │ DSD2PCMConverter      │  │ AudioDeviceListener         │       │
│  │ DACCapabilityProbe    │  │ SampleRateManager           │       │
│  │ KnownDSDDevices(41)   │  └─────────────────────────────┘       │
│  └───────────────────────┘                                        │
│                                                                   │
│  ┌─Source ────────────┐  ┌─Library ─────────────┐                 │
│  │ LocalFileSource     │  │ FileWatcher / Scanner│                 │
│  │ CloudStreamSource   │  │ ScanService          │                 │
│  │   (sparse chunks)   │  │ SmartPlaylistEngine  │                 │
│  └─────────────────────┘  └──────────────────────┘                 │
│                                                                   │
│  ┌─Database ──────────────┐  ┌─Cloud ───────────────────────────┐ │
│  │ Schema v1/v2/v3 + FTS5 │  │ QuarkAPIClient (auth + rate ltd) │ │
│  │ DatabaseManager        │  │ CloudHeaderProber (64KB)         │ │
│  │ (GRDB.swift)           │  │ CloudPrefetchManager             │ │
│  └────────────────────────┘  │ CloudDownloadCache (LRU)         │ │
│                              │ KeychainStore                    │ │
│                              └──────────────────────────────────┘ │
└───────────────────────────────────────────────────────────────────┘
```

---

## Audio Engine Internals

### Bit-perfect path

```
Track → Source → Decoder → [DSPChain bypassed] → PCMRingBuffer → CoreAudioHALOutput
                                                                          │
                                                                          ├─▶ Hog Mode (exclusive)
                                                                          ├─▶ kAudioStreamPropertyPhysicalFormat
                                                                          ├─▶ SupportsMixing = 0
                                                                          └─▶ Integer PCM straight-through ASBD
```

When the source is FLAC 24/96 and the DAC accepts 96 kHz: the decoded `int32` block is written into the ring buffer with zero conversion, and CoreAudio renders it through the bit-perfect path. `didMatchHardwareRate` becomes `true` and the SignalPathBar dot turns 🟢.

### DSP path (only when user opts in)

```
Decoder → int→float → ReplayGain → Resampler → EQ → Crossfeed → Dither → ring buffer
```

DSPChain.build assembles only the enabled nodes; everything is skipped in bit-perfect mode. DSD sources override the preferences and always take the bypassed path, because DSP would corrupt DoP marker bytes.

### Gapless

```
Track A end of stream
        │
        ▼
endDetectionTimer ─▶ tryGaplessAdvance(B)
                         │
                         ▼  (formats match)
                    pipeline.swapDecoder(B)
                         │  decode loop continues with B
                         │  ring buffer never resets
                         ▼
                    seamless audio
```

The 250 ms grace window inside `AudioPipeline.decodeLoop` waits for `swapDecoder` to happen so the ring buffer keeps playing the previous track's tail.

### DSD pipeline

```
DSF / DFF  ──▶  DoPPacker  ──▶  24-bit DoP frame  ──▶  byte-swap  ──▶  DAC
                                (high byte = 0x05/0xFA marker)
```

`DoPPacker` alternates the marker byte every frame, packs 16 DSD bits per 24-bit sample, and respects the LSB-first / MSB-first convention of the source container.

For DACs that do not handle DoP, `DSD2PCMConverter` provides a 96-tap FIR Gesemann path that decimates the DSD bitstream to PCM at `dsd_rate / 8`.

### DSD1024

`DSDRate` covers the full ladder DSD64 / 128 / 256 / 512 / 1024 with a strict five-rate allowlist in the DSF/DFF parsers. `DSDStrategyChooser` decides DoP vs. PCM per (rate, DAC capability, user preference); because no DAC accepts a 45.1584 MHz PCM stream, `DACCapabilityProbe` always reports DSD1024 as DoP-incapable, so DSD1024 resolves to PCM output at the user's `dsdMaxPCMRate` preference (384 kHz default, 768 kHz opt-in), decimated through the `DSD2PCMConverter` FIR path. Lower DSD rates keep the DoP path on capable DACs.

---

## Module Reference

### `PurePlayCore`

| Path                                | Purpose                                                |
| ----------------------------------- | ------------------------------------------------------ |
| `Audio/AudioFormat.swift`           | Sample rate / bit depth / channels / DSD flag          |
| `Audio/AudioPipeline.swift`         | Decode-thread orchestrator + gapless swap              |
| `Audio/SpectrumAnalyzer.swift`      | vDSP FFT, log-spaced bands                             |
| `Audio/WaveformBuffer.swift`        | Peak / RMS bin ring buffer for UI                      |
| `Audio/PurePlayError.swift`         | Centralised error type                                 |
| `Buffer/PCMRingBuffer.swift`        | Lock-free SP/SC ring buffer                            |
| `Source/AudioSource.swift`          | Protocol + `LocalFileSource` + `MemorySource`          |
| `Decoder/AudioDecoder.swift`        | Protocol + `DecoderRegistry`                           |
| `Decoder/WAVDecoder.swift`          | RIFF/WAVE PCM/float parser                             |
| `Decoder/AIFFDecoder.swift`         | AIFF/AIFC + IEEE-80 sample-rate decoding               |
| `Decoder/DSFDecoder.swift`          | DSF container → DoP                                    |
| `Decoder/DFFDecoder.swift`          | DSDIFF container → DoP                                 |
| `Decoder/CueSheet.swift`            | CUE parser + `TrimmingDecoder` wrapper                 |
| `Decoder/CoreAudioDecoder.swift`    | ExtAudioFile path                                      |
| `Decoder/LibFLACDecoder.swift`      | libFLAC binding (`#if canImport(CFLAC)`)               |
| `Decoder/FLACMetadata.swift`        | STREAMINFO + Vorbis Comments + MD5 verifier            |
| `Decoder/SineDecoder.swift`         | Synthetic sine decoder for file-less E2E tests         |
| `Decoder/FFmpegDecoder.swift`       | FFmpeg universal decoder (shipped dylibs)              |
| `Decoder/FFmpegAVIOAdapter.swift`   | Custom AVIO context bridging Swift I/O to FFmpeg       |
| `Decoder/FFmpegSampleFormatSelector.swift` | Optimal sample format negotiation for FFmpeg   |
| `DSD/DoPPacker.swift`               | DSD-over-PCM marker injection                          |
| `DSD/DSD2PCMConverter.swift`        | Gesemann 96-tap FIR                                    |
| `DSD/DACCapabilityProbe.swift`      | Per-device DSD support detection                       |
| `DSP/DSPChain.swift`                | Auto-assembled node chain + `DSPPreferences`           |
| `DSP/DSPNodes.swift`                | ParametricEQ / Gain / Crossfeed / Dither / LinearResampler + `ParametricBand` model |
| `DSP/SincResampler.swift`           | Kaiser-windowed Sinc resampler                         |
| `DSP/EQPresetManager.swift`         | Factory JSON presets + user presets in `~/Library/Application Support/PurePlay/EQPresets/` |
| `DSP/AutoEQParser.swift`            | AutoEQ ParametricEQ text import + headphone-name extraction |
| `Output/AudioOutput.swift`          | `CoreAudioHALOutput` + protocol                        |
| `Output/AudioDeviceListener.swift`  | 4-class CoreAudio listener                             |
| `Output/SampleRateManager.swift`    | Switch + poll-confirm                                  |
| `Player/PlayerController.swift`     | State machine + queue + gapless                        |
| `Player/QueueManager.swift`         | Queue persistence                                      |
| `Player/SignalPath.swift`           | Structured signal-chain description                    |
| `Library/...`                       | FSEvents watcher + scanner + smart playlist engine     |
| `Library/LibraryModel.swift`        | `TrackInfo` + in-memory library model                  |
| `Database/Schema.swift`             | GRDB records (extended for source/cloud/format/RG)     |
| `Database/DatabaseManager.swift`    | Migrations v1/v2/v3 + FTS5 search                      |
| `Metadata/MetadataReader.swift`     | AVAsset tag extraction                                 |
| `Metadata/CoverArtManager.swift`    | Embedded + folder scan cache                           |
| `Metadata/ReplayGainReader.swift`   | ReplayGain tag extraction (track + album gain)         |
| `Cloud/QuarkAPIClient.swift`        | Authenticated REST + `onAuthExpired`                   |
| `Cloud/CloudStreamSource.swift`     | Sparse-chunk Range-fetch stream                        |
| `Cloud/CloudHeaderProber.swift`     | 64KB magic-byte format probe                           |
| `Cloud/CloudPrefetchManager.swift`  | Next-track prebuffer scheduler                         |
| `Cloud/CloudDownloadCache.swift`    | LRU disk cache                                         |
| `Cloud/KeychainStore.swift`         | Cookie persistence                                     |
| `Cloud/RateLimiter.swift`           | Token-bucket throttle (5 req/s)                        |
| `Util/AudioPreferences.swift`       | Persisted settings: device, Hog, EQ bands + A/B slots, pre-amp, `dsdMaxPCMRate`, v1.5→v1.6 EQ migration |
| `Util/WAVTestHelper.swift`          | WAV fixture generator for tests                        |

### `PurePlayApp`

| Path                          | Purpose                                                |
| ----------------------------- | ------------------------------------------------------ |
| `main.swift`                  | `AppDelegate` + `VoxContentView`                       |
| `NowPlayingViewModel.swift`   | Immutable value-type snapshot of the player state      |
| `SignalPathBar.swift`         | LED + text status bar                                  |
| `WaveformView.swift`          | Scrolling waveform (Core Graphics)                     |
| `SpectrumView.swift`          | CVDisplayLink FFT visualizer                           |
| `ParametricEQEditor.swift`    | Draggable parametric EQ curve (freq/gain drag, wheel Q, double-click add/reset) |
| `EQBandTableView.swift`       | Exact-value band table + pre-amp row                   |
| `EQPanel.swift`               | Parametric EQ window (toolbar / curve / band region)   |
| `MiniPlayerWindow.swift`      | Floating compact player                                |
| `DSDBadgeView.swift`          | Golden DSD badge                                       |
| `GlobalHotKey.swift`          | Carbon RegisterEventHotKey wrapper                     |
| `MediaKeyHandler.swift`       | `MPRemoteCommandCenter`                                |
| `LibraryBrowser.swift`        | Sidebar navigation                                     |
| `AlbumGridView.swift`         | NSCollectionView album grid                            |
| `QueueView.swift`             | Drag-and-drop queue                                    |
| `PlaylistPanel.swift`         | Flat playlist                                          |
| `SearchBar.swift`             | Debounced search field                                 |
| `SmartPlaylistEditor.swift`   | Rule-builder window                                    |
| `QuarkLoginPanel.swift`       | WKWebView login                                        |
| `QuarkFileBrowser.swift`      | Cloud folder navigator                                 |

---

## Build & Release

### Debug
```sh
swift build
swift run PurePlay
```

### Release + version bump + DMG
```sh
./scripts/build_release.sh                    # keep current version (default)
VERSION_PART=patch ./scripts/build_release.sh # patch +1
VERSION_PART=minor ./scripts/build_release.sh # minor +1, patch=0
VERSION_PART=major ./scripts/build_release.sh # major +1, minor=patch=0
./scripts/build_release.sh 2.0.0              # explicit version
```

Behaviour:
1. Reads `VERSION`; bumps only when `VERSION_PART` is set or an explicit version is passed (default keeps the current version).
2. Auto-builds FFmpeg via `scripts/build_ffmpeg.sh` if `Frameworks/FFmpeg` is missing, then `swift build -c release --product PurePlay` with the CFFmpeg module map + dylib link flags.
3. Assembles the `.app` bundle from `Resources/Info.plist.template`, syncs `Resources/` (icon, EQ presets, DAC whitelist) into it, and updates `CFBundleShortVersionString` / `CFBundleVersion`.
4. **Embeds the FFmpeg dylibs** into `Contents/Frameworks/`, rewrites them to `@rpath` form and drops stray Homebrew dependencies so the bundle runs on clean machines.
5. **Codesign** — if a `Developer ID Application` identity is in the login keychain (or `DEVELOPER_ID_APP` env is set), uses hardened runtime + secure timestamp + `Resources/PurePlay.entitlements`; otherwise falls back to ad-hoc.
6. **dSYM** — emits `dist/PurePlay-<version>.dSYM.zip` for crash symbolication.
7. **DMG** — `hdiutil create` with drag-to-install layout (incl. `Applications` symlink), `UDZO zlib-level=9`. Signed too when a Developer ID is available.

### Notarization (when Developer ID is set up)
```sh
# One-time keychain credential:
xcrun notarytool store-credentials AC_PROFILE \
  --apple-id you@example.com --team-id ABCDE12345 \
  --password "app-specific-password"

# Sign + submit + staple in one command:
./scripts/notarize.sh dist/PurePlay-<version>-Installer.dmg
```

### Performance baseline
```sh
./scripts/perf_bench.sh dist/PurePlay.app path/to/sample.flac
# Reports 10-trial median launch, idle RSS, 30s playback peak RSS & avg CPU.
```

### First-launch quarantine bypass (ad-hoc builds)
```sh
xattr -dr com.apple.quarantine /Applications/PurePlay.app
```

---

## Usage Guide

### Open files / folders
- **⌘O** → file picker (multi-select queues every selected file).
- Drop folders onto the dock icon to enqueue every supported audio file recursively.

### Library
- 📚 sidebar → Albums (grid) / Artists / Genres / Favourites / Recently Played / Playlists.
- Search bar runs **FTS5 first**, falls back to LIKE for partial matches.
- Smart playlists re-evaluate every time they are opened.

### Queue
- Drag rows to reorder; current row highlighted in amber.
- **Save** persists the queue as a regular playlist.
- Double-click a row to jump to it.

### Audio device control
- **Audio menu** lists every output device with check-mark for the active one.
- **Exclusive Mode (Hog)** toggle is persisted across launches.
- The bottom **SignalPathBar** reports live state: source format → DSP → device + actual hardware sample-rate.
- DAC unplug pauses playback automatically; replug + select device to resume.

### Equalizer
- **View → Equalizer (⌘E)** opens the parametric EQ panel: toolbar (on/off, preset menu, Import / Save / Reset, current-headphone chip), the response-curve editor, and the band table with a pre-amp slider.
- **Curve editing**: drag a node to move it in frequency (X) and gain (Y, ±24 dB); scroll the wheel over a node to change Q; double-click a node to reset its gain to 0 dB; double-click empty curve space to add a new Peak band (up to 20 bands).
- **Band table**: exact values per band — filter type (Peak / Low Shelf / High Shelf / Low Pass 12 dB / High Pass 12 dB), frequency, Q (0.1–30), gain, enable checkbox — plus +/− buttons to add and remove bands.
- **Presets**: factory presets load from `Resources/EQPresets.json` (Flat / Bass Boost / Treble Boost / Vocal Forward / Classical / Jazz / Electronic / Rock / Pop / Hi-Fi Loudness); Save writes user presets to `~/Library/Application Support/PurePlay/EQPresets/`.
- **AutoEQ**: Import an AutoEQ `* ParametricEQ.txt` file to apply a headphone correction profile (pre-amp + bands); the headphone model is extracted from the file name and shown in the toolbar chip.
- Parameter changes apply live and click-free (block-level coefficient interpolation). EQ settings persist across launches (A/B slot storage with automatic migration from v1.5).
- DSD tracks always play bit-perfect: the EQ is bypassed automatically while a DSD stream is active.

### Mini Player
- **View → Mini Player (⇧⌘M)** opens a floating 320×120 always-on-top window.
- Shows title + active device + progress + prev/play/next.

### Format indicators
- **Right of song title**: golden `DSD64/128/256/512/1024` badge for native DSD streams.
- **Bottom SignalPathBar**: `🟢 FLAC 24/96 → Bit-Perfect → ES9038 Hog 96kHz/24bit ✓`
  - 🟢 = bit-perfect verified
  - 🟠 = DSP active (EQ / Crossfeed / Dither / Resample)
  - 🔴 = hardware sample-rate mismatched (system would resample)
  - ⚪ = idle

---

## Quark Cloud Setup

1. **File → Cloud (⌘K)** opens a WKWebView pointed at `pan.quark.cn`.
2. Sign in normally. PurePlay extracts the session cookie and stores it in Keychain.
3. The cloud browser appears; double-click a file to stream.
4. Streaming uses HTTP `Range` per 1 MB chunk + 5 MB pre-buffer, so seeking is essentially instant.
5. 2 GB of recently played cloud files are kept in `~/Library/Caches/PurePlay/CloudCache` (LRU).
6. Once the current track has ≤30 s remaining, the next cloud track is prefetched automatically — no audible gap.
7. **Session expired?** The next API call detects HTTP 401/403 or business-code 32003/41001/41015 and pops a "登录已失效" dialog. Clicking *Re-login* reopens the WKWebView panel.

---

## Optional Native Libraries

PurePlay uses CoreAudio's FLAC path by default and ships a competent Kaiser-Sinc resampler. For audiophiles who want the reference implementations:

```sh
# 1. Build the xcframeworks (one-time, ~3-5 min each)
./scripts/build_libflac.sh   # → Frameworks/libFLAC.xcframework
./scripts/build_soxr.sh      # → Frameworks/libsoxr.xcframework

# 2. Append the binary targets to Package.swift:
#    .binaryTarget(name: "CFLAC", path: "Frameworks/libFLAC.xcframework"),
#    .binaryTarget(name: "CSOXR", path: "Frameworks/libsoxr.xcframework"),
#    Add them to PurePlayCore.dependencies.

# 3. swift build —— LibFLACDecoderFactory auto-registers at priority 100,
#    superseding the CoreAudio FLAC path. The SincResampler can be swapped
#    for a SoXR-backed implementation in a follow-up commit.
```

The xcframework builds use only macOS public toolchain (autoconf + CMake + xcodebuild) — no licensed software required. libFLAC is BSD; SoXR is LGPL (statically linked builds re-distribute under LGPL terms).

---

## Keyboard & Hotkeys

| Action                | Shortcut                            |
| --------------------- | ----------------------------------- |
| Open file             | ⌘O                                  |
| Cloud login           | ⌘K                                  |
| New smart playlist    | ⌘N                                  |
| Equalizer             | ⌘E                                  |
| Mini Player           | ⇧⌘M                                 |
| Quit                  | ⌘Q                                  |
| **Global hotkeys** (work even when PurePlay is not focused) |   |
| Play / Pause          | ⌃⌥ F8                               |
| Next track            | ⌃⌥ →                                |
| Previous track        | ⌃⌥ ←                                |
| **Media keys (AirPods / Bluetooth / Touch Bar)** |               |
| Play / Pause / Next / Prev / Stop | via `MPRemoteCommandCenter` |

Now Playing info (title / artist / album / artwork / duration / elapsed) is published via `MPNowPlayingInfoCenter`, so it appears in the Now Playing widget, AirPods controls, and Control Center.

---

## Testing

```sh
swift run PurePlayTests
# Tests: 272 total, 272 passed, 0 failed
# (275 when built with the vendored FFmpeg module flags: adds 3 CFFmpeg-gated registry tests)
```

The custom harness (no XCTest dependency) covers:

- **Audio core** — `AudioFormat`, `PCMRingBuffer` concurrency, `MemorySource`, `WaveformBuffer` ring + peak/rms math, `SpectrumAnalyzer` (single-tone band mapping at multiple sample rates, asymmetric attack/release)
- **Decoders** — WAV (incl. RF64 + float32), AIFF (BE→LE swap, IEEE-80), DSF/DFF DoP markers + seek reset, CUE parser + `TrimmingDecoder`, FLAC MD5 verifier, ALAC factory priority, CoreAudio registry, `SineDecoder`, FFmpeg sample-format selection (3 CFFmpeg-gated registry tests when FFmpeg is linked)
- **DSP** — `ParametricEQNode` (incl. legacy graphic-preset compatibility), `Crossfeed` full-signal, `Gain`, `DitherNode`, `SincResampler` (1:1 identity, 2:1 decimation, stereo interleave, reset), `DSD2PCMConverter` (rate math, DC-balanced input, capacity limit), DSP-chain assembly
- **DSD strategy** — DoP packing, marker alternation, `DSDStrategyChooser` decisions incl. DSD1024 (PCM-only, 384k default / 768k opt-in), pipeline forces DSP bypass for DSD
- **DAC probe** — whitelist match (case-insensitive substring), per-rate capability inference
- **SignalPath** — bit-perfect detection, DSD source, display text format
- **Gapless** — `canSwapDecoder` precondition, `swapDecoder` accepts/rejects, `tryGaplessAdvance` end-to-end
- **Cloud** — `CloudHeaderProber` for 8 formats incl. garbage rejection, `CloudStreamSource` chunk injection / boundary crossing / seek / EOF, `CloudPrefetchManager` threshold + dedupe + consume, timer-scheduling regression
- **Database & Library** — Schema v2 fields, FTS5 empty / quote injection robustness, GRDB CRUD, smart-playlist engine, scanner + file watcher, metadata reader
- **Preferences** — `dsdMaxPCMRate` default/clamp/opt-in, EQ A/B slot storage, v1.5→v1.6 EQ migration idempotency
- **E2E & stress** — full pipeline playback loops, bit-perfect acceptance suite (WAV byte-perfect round-trip, DSD→DoP round-trip, Hog exclusivity, auto sample-rate switch, PhysicalFormat preference, device lifecycle hooks)

---

## Project Layout

```
localplayer/
├── AGENT.md               # Product design document (Strawberry-inspired architecture)
├── CONTEXT.md             # Ubiquitous-language glossary for contributors
├── Design.md              # Long-form product/design document
├── FixPlan.md             # Open fix plan
├── Test_plan.md           # Test strategy
├── README.md              # this file
├── Package.swift          # SwiftPM manifest
├── Package.resolved
├── LICENSE                # GPL 3.0
├── VERSION                # SemVer source of truth
│
├── Sources/
│   ├── PurePlayCore/      # Audio engine, library, cloud (no AppKit)
│   │   ├── Audio/  Buffer/  Cloud/  Database/  Decoder/
│   │   ├── DSD/    DSP/     Library/  Metadata/  Output/
│   │   ├── Player/  Source/   Util/
│   └── PurePlayApp/       # AppKit UI executable
│
├── Tests/
│   └── PurePlayCoreTests/
│       └── TestRunner.swift
│
├── Resources/
│   ├── AppIcon.png
│   ├── AppIcon.icns             # generated from PNG (all iconset sizes)
│   ├── Info.plist.template      # app bundle Info.plist (icon + version metadata)
│   ├── EQPresets.json           # built-in EQ presets (v2: parametric bands + legacy gains)
│   └── KnownDSDDevices.json     # 41-DAC DSD whitelist
│
├── scripts/
│   ├── build_release.sh        # version bump + sign + DMG + dSYM
│   ├── build_ffmpeg.sh         # build FFmpeg dylibs from source
│   ├── notarize.sh             # Apple notarization + stapling
│   ├── perf_bench.sh           # launch / RSS / CPU baseline
│   ├── build_libflac.sh        # optional libFLAC xcframework
│   ├── build_soxr.sh           # optional libsoxr xcframework
│   └── pureplay.rb             # Homebrew Cask formula template
│
├── Frameworks/
│   └── FFmpeg/                 # shipped FFmpeg headers + dylibs (arm64)
│
├── Modules/
│   └── CFFmpeg/                # Swift module map for FFmpeg C interop
│
├── docs/                       # PRD, ADRs, issue tracking
│
└── dist/                       # (gitignored) generated DMG + app + dSYM
```

---

## Roadmap

| Phase | Status | Highlights                                                  |
| ----- | ------ | ----------------------------------------------------------- |
| M1    | ✅      | Hog + PhysicalFormat + 4-class device listener + acceptance |
| M2    | ✅      | AIFF / DFF / CUE decoders + ALAC factory                    |
| M3    | ✅      | Kaiser-Sinc + DSD2PCM + DACCapabilityProbe + SignalPath     |
| M4    | ✅      | Schema v2/v3 + FTS5 + gapless `swapDecoder` + GlobalHotKey  |
| M5    | ✅      | Sparse cloud chunks + Range Seek + header probe + prefetch  |
| P6    | ✅      | DMG + dSYM + Notarize script + Cask + perf bench + xcfw scripts |
| UI    | ✅      | SignalPathBar + WaveformView + MiniPlayer + EQ panel (now parametric) |
| G     | ✅      | EQPanel + Cookie auto re-login + NowPlayingViewModel        |
| S1-S3 | ✅      | 18 bug fixes: volume, stop race, chunk eviction, retry backoff, thread safety, EQ persistence, stress tests (210 total) |
| M6    | ✅      | FFmpeg dylib + custom AVIO (APE / Opus / Vorbis / WavPack / TTA / WMA / Matroska) |
| v1.6  | ✅      | Parametric EQ engine (20 bands, LP/HP, click-free coefficient interpolation) · DSD1024 + `dsdMaxPCMRate` · EQ A/B slot persistence + v1.5 migration · AutoEQ import + headphone chip · spectrum axis fix + asymmetric smoothing · WMA/MKA via FFmpeg |
| v1.7  | ✅      | DTS (DCA) playback via FFmpeg, local + cloud file picker DTS support, LocalizedError, proper app bundle Info.plist + app icon, extension-based audio file filters, version-stable builds |
| v1.7.1| ✅      | Fix cloud track next/previous switching error (I/O error: Cloud tracks require async playback) in main window + mini player |
| Next  | ⏳      | EQ polish: spectrum overlay on the EQ canvas, double-click numeric entry with unit parsing, Option-drag Q, A/B slot switch UI |
| Next  | ⏳      | Unsupported-codec grayout (tooltip + auto-skip) · FFmpeg metadata fallback for WMA/MKA tags + covers · audio-thread performance HUD |
| Next  | ⏳      | taglib integration replacing AVAsset metadata reader        |
| Next  | ⏳      | TechBadgeView (generic sample-rate / bit-depth / format badge) |
| Next  | ⏳      | MenuBarPopover replacing NSMenu status item                 |
| Next  | ⏳      | Developer ID real signing + Notarize + Homebrew Cask publish |

---

## License

PurePlay is free software: you can redistribute it and/or modify it under the terms of the [GNU General Public License v3.0](LICENSE) as published by the Free Software Foundation.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the [LICENSE](LICENSE) file for details.

Third-party software:
- [GRDB.swift](https://github.com/groue/GRDB.swift) — MIT
- [swift-atomics](https://github.com/apple/swift-atomics) — Apache-2.0
- [FFmpeg](https://ffmpeg.org/) (shipped dylibs) — LGPL 2.1
- Optional: [libFLAC](https://xiph.org/flac/) — BSD; [SoXR](https://sourceforge.net/projects/soxr/) — LGPL
