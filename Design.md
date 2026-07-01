# PurePlay — 产品与技术设计方案

> 项目代号：**PurePlay**
> 定位：macOS 原生、bit-perfect、本地 + 夸克网盘的 Hi-Res 音乐播放器
> 设计基线：[AGENT.md](./AGENT.md) 的产品需求 + [VLC](https://github.com/videolan/vlc) 架构借鉴
> 文档版本：v1.0（基于 VLC master 分支与 AGENT.md 调研）

---

## 0. 文档导读

本文档分两条主线：

1. **产品设计**（第 1–4 章）— PurePlay 要做什么、为谁做、长什么样
2. **技术实现**（第 5–11 章）— 借鉴 VLC 的工程经验，落地一个 macOS 原生 Hi-Fi 播放器

VLC 是世界上最成熟的开源媒体播放器，但**它不是发烧友播放器**：没有 DSD、没有 PCM 自动切换采样率、没有"独占 PCM"模式。本设计的核心策略是：

> **借鉴 VLC 的"模块化解码 + 过滤图 + 输出抽象"工程范式，但抛弃其 macOS CoreAudio 后端，自建 bit-perfect 输出层；并补齐 DSD/DoP、自动采样率切换、夸克网盘流式播放三大空白。**

---

## 1. 产品愿景

### 1.1 目标用户

| 群体 | 场景 | 核心诉求 |
|------|------|---------|
| **Hi-Fi 发烧友** | 暗室聆听、外接 USB DAC | bit-perfect、DSD 原生、信号路径透明 |
| **本地音乐收藏者** | 本地大型 FLAC/APE/DSD 收藏 | 多格式、元数据完整、扫描快 |
| **云盘音乐用户** | 夸克网盘存储 TB 级音乐 | 流式播放、断点续播、离线缓存 |

### 1.2 一句话定位

> "**Vox 的极简 UI，Audirvana 的音质底座，Roon 的元数据洞察，加上夸克网盘云端音乐库。**"

### 1.3 产品差异化（vs 现有方案）

| 维度 | Vox | Audirvana | VLC | PurePlay |
|------|:---:|:---------:|:---:|:--------:|
| 原生 macOS 体验 | ✅ | ✅ | ⚠️ | ✅ |
| Bit-Perfect / Hog Mode | ✅ | ✅ | ❌ | ✅ |
| DSD 原生（DoP） | ⚠️ | ✅ | ❌ | ✅ |
| 自动采样率切换 | ❌ | ✅ | ❌ | ✅ |
| 信号路径可见 | ❌ | ⚠️ | ❌ | ✅ |
| 夸克网盘流式 | ❌ | ❌ | ❌ | ✅ |
| 开源 | ❌ | ❌ | ✅ | ✅ |
| 体积 | <20MB | ~80MB | ~50MB | <30MB |

---

## 2. VLC 架构分析与可借鉴点

### 2.1 VLC 架构概览

```
┌─────────────────────────────────────────────────────────┐
│ Input (file://, http://, stream://, ...)                │
└────────────────┬────────────────────────────────────────┘
                 ▼
┌─────────────────────────────────────────────────────────┐
│ Demux Plugin (modules/demux/*.c)                        │
│  flac.c, wav.c, caf.c, aiff.c, mod.c, ...              │
└────────────────┬────────────────────────────────────────┘
                 ▼
┌─────────────────────────────────────────────────────────┐
│ Packetizer + Decoder Plugin (modules/codec/*.c)         │
│  flac, faad, fdkaac, mpg123, opus, vorbis,              │
│  + libavcodec wrappers (ALAC/APE/WMA/...)               │
└────────────────┬────────────────────────────────────────┘
                 ▼  audio_sample_format_t (FL32)
┌─────────────────────────────────────────────────────────┐
│ aout Core (src/audio_output/output.c, filters.c)        │
│  ┌─────────────────────────────────────────────────┐    │
│  │ Filter Chain (modules/audio_filter/*)           │    │
│  │  format converter → channel mixer → resampler   │    │
│  │   → equalizer → gain → final converter          │    │
│  └─────────────────────────────────────────────────┘    │
└────────────────┬────────────────────────────────────────┘
                 ▼
┌─────────────────────────────────────────────────────────┐
│ Output Plugin (modules/audio_output/*)                  │
│  apple/auhal.c (macOS CoreAudio HAL)                    │
│  apple/coreaudio_common.c                                │
└─────────────────────────────────────────────────────────┘
```

### 2.2 关键工程经验（VLC 已经踩过的坑）

| VLC 设计 | 工程价值 | PurePlay 借鉴策略 |
|---------|---------|------------------|
| **统一插件契约**（`Open`/`Close` + 回调表） | 解码器/滤波器/输出可热插拔，扩展性强 | ✅ 借鉴 — Swift `protocol` 模拟 `vlc_module_t` |
| **格式协商**（`audio_sample_format_t`） | 解码与输出之间用单一描述结构通信 | ✅ 借鉴 — `AudioFormat` 结构贯穿管线 |
| **Filter Chain 自动组装** | `filters.c` 根据输入/输出格式自动插入转换器 | ✅ 借鉴 — DSP Chain 自动适配 |
| **Bitexact 标志位**（`audio-bitexact`） | 给用户"尽量不动信号"的开关 | ✅ 借鉴并强化 — 真正 bypass DSP |
| **格式网关**（`AOUT_FMT_LINEAR`/`SPDIF`/`HDMI`） | 区分 PCM、压缩透传、HDMI 比特流 | ✅ 借鉴 — 增加 `AOUT_FMT_DOP` |
| **`libvlc_audio_set_callbacks`** | 第三方 App 可让 VLC 解码、自己接管输出 | ✅ 备选方案 — 紧急兜底，但不依赖 |
| **CoreAudio Hog Mode 监听器** | `auhal.c` 设备热插拔/默认设备变更监听 | ✅ 借鉴 — 完全照搬监听模式 |

### 2.3 VLC 不能直接用的原因

| 缺陷 | 影响 | PurePlay 的对策 |
|------|------|----------------|
| **无 DSD/DoP 支持** | 无 `dsf`/`dff` demuxer，无 dsd 滤波器 | 自建 DSDDecoder + DoP 打包器 |
| **PCM 不自动切设备采样率** | auhal 只在 SPDIF 路径切 physical format | 自建 `SampleRateManager` |
| **`bitexact` 名不副实** | 仍会插入 FL32 converter + resampler | 真 bypass：解码器直出原生整数 PCM |
| **Hog Mode 仅 SPDIF 用** | PCM 始终走系统混音器 | PCM + Hog Mode 联动，发烧友默认开启 |
| **GPL/LGPLv2.1+ 许可** | 部分模块 GPL，影响闭源/商用 | 我们自身计划开源，但避开 GPL 模块；libavcodec 用 LGPL 编译 |
| **C 语言为主，Swift 互操作复杂** | 难以与 SwiftUI 自然集成 | Swift 6 主导，C/C++ 仅用于解码/重采样核 |

### 2.4 直接复用 vs 重写的取舍

```
┌───────────────────────────────────────────────────────────────┐
│              VLC / 第三方库使用策略                              │
├───────────────────────────────────────────────────────────────┤
│                                                               │
│  ✅ 直接借用                                                   │
│  ─────────                                                    │
│  • 模块注册/动态选择思想 → Swift protocol + DecoderRegistry   │
│  • Filter Chain 自动组装 → DSPChain 类似 src/audio_output/   │
│  •                          filters.c 的 aout_FiltersNew     │
│  • auhal.c 的 CoreAudio 设备监听 → 改写为 Swift Combine       │
│  • libavcodec（LGPL 编译）→ 兜底解码（FFmpegDecoder）          │
│                                                               │
│  ⚠️ 部分借用                                                   │
│  ────────                                                     │
│  • 解码器接口（vlc_codec.h）→ 设计参考，但用 Swift 重写        │
│  • 元数据读取 → 用 SFBAudioEngine + taglib，不直接用 VLC       │
│                                                               │
│  ❌ 不借用                                                     │
│  ─────                                                        │
│  • VLC 的 auhal.c CoreAudio 后端（不支持发烧友需求）           │
│  • VLC 的 demux 框架（用 SFBAudioEngine 或自建更轻量）         │
│  • VLC 的 GUI（VLC 用 Qt/Cocoa 不纯 SwiftUI）                 │
│  • libVLC 整体嵌入（体积大，license 复杂）                     │
│                                                               │
└───────────────────────────────────────────────────────────────┘
```

---

## 3. 系统架构

### 3.1 四层分层架构

```
┌──────────────────────────────────────────────────────────────────┐
│ Layer 4 — Presentation (SwiftUI + AppKit)                        │
│  ContentView · NowPlayingView · LibraryView · SettingsView       │
│  WaveformView · SpectrumView · SignalPathBar · MenuBarPopover    │
├──────────────────────────────────────────────────────────────────┤
│ Layer 3 — Application (Player Controller)                        │
│  PlayerController · PlaybackQueue · PlaylistManager              │
│  CloudSession · LibraryService · PreferencesService              │
├──────────────────────────────────────────────────────────────────┤
│ Layer 2 — Audio Engine (Pure-Audio Core)                         │
│  ┌────────────┐  ┌────────────┐  ┌──────────┐  ┌────────────┐    │
│  │  Source    │─▶│  Decoder   │─▶│ DSPChain │─▶│   Output   │    │
│  │  (Local /  │  │ (FLAC/DSD/ │  │ (bypass  │  │ (CoreAudio │    │
│  │   Cloud)   │  │  APE/...)  │  │  by def) │  │  HogMode)  │    │
│  └────────────┘  └────────────┘  └──────────┘  └────────────┘    │
│         ▼              ▼              ▼              ▼           │
│   PCMRingBuffer · DACCapabilityProbe · SampleRateManager         │
├──────────────────────────────────────────────────────────────────┤
│ Layer 1 — Data & Infrastructure                                  │
│  LibraryDB(GRDB) · MetadataReader · FileScanner(FSEvents)        │
│  QuarkAPIClient · CloudDownloadCache · KeychainStore             │
└──────────────────────────────────────────────────────────────────┘
```

### 3.2 模块职责矩阵

| 模块 | 职责 | 关键依赖 | VLC 类比 |
|------|------|---------|---------|
| **Source** | 本地文件 / 云盘字节流统一抽象 | URLSession, mmap | `input/access_*` |
| **Decoder** | 字节流 → PCM/DSD bitstream | libFLAC, SFB, dr_libs, FFmpeg | `modules/codec` |
| **DSPChain** | 重采样、EQ、Crossfeed、ReplayGain、Dither | SoXR, vDSP | `modules/audio_filter` |
| **Output** | PCM/DoP → CoreAudio Hog Mode → DAC | CoreAudio HAL | `modules/audio_output/auhal.c` |
| **PCMRingBuffer** | 解码线程↔音频线程 无锁通信 | atomics | `coreaudio_common.c` ringbuf |
| **PlayerController** | 播放控制、队列、状态机 | Combine | `src/audio_output/dec.c` |
| **LibraryDB** | 曲目/专辑/播放列表索引 | GRDB.swift, SQLite | — |
| **QuarkAPIClient** | 夸克网盘 API 客户端 | URLSession, WKWebView | — |

---

## 4. UI 与交互设计

### 4.1 设计原则（沿用 AGENT.md 第 6 章）

```
"播放器是家具，不是广告牌" — Vox 哲学
"信号路径可见，技术信息可读"  — PurePlay 改进
```

### 4.2 主窗口结构

```
┌──────────────────────────────────────────────────────────────────┐
│ ● ● ●  PurePlay                                       [⌃] [⎚]   │
├───────────┬──────────────────────────────────────────────────────┤
│ LIBRARY   │                                                      │
│  All      │            ┌──────────────────────┐                  │
│  Albums   │            │                      │                  │
│  Artists  │            │     ALBUM ART        │  ┌────────┐     │
│  Genres   │            │   (60% 主视觉区)      │  │ 96kHz  │     │
│           │            │                      │  │ 24bit  │     │
│ CLOUD     │            └──────────────────────┘  │ FLAC   │     │
│  ☁ 夸克   │                                      │ Bit-P. │     │
│   📁 FLAC │       Track Title                    └────────┘     │
│   📁 DSD  │       Artist · Album                                 │
│           │                                                      │
│ PLAYLISTS │       ──●──────────────────────────────              │
│           │       02:34                          05:12           │
│ SETTINGS  │       🔀  ◄◄  ▶ ⏸  ►►  🔁                           │
│  ⚙ Audio  │                                                      │
│  📁 Lib   │       ┌── 滚动波形 ──────────────────────┐           │
│  ☁ Cloud  │       │ ▁▂▃▅▆▇█▇▆▅▃▂▁▂▃▅▆▇█▇▆▅▃▂▁▁▂▃▅▆ │           │
│           │       └────────────────────────────────────┘           │
├───────────┴──────────────────────────────────────────────────────┤
│ 🔊 USB DAC ES9038 · Hog · 96k/24b · Bit-Perfect · ☁ 5.0/5.0MB   │
└──────────────────────────────────────────────────────────────────┘
```

### 4.3 关键 UI 组件清单

| 组件 | 路径 | 说明 |
|------|------|------|
| `NowPlayingView` | `UI/Player/` | 封面英雄 + 技术 Badge |
| `WaveformView` | `UI/Components/` | Vox 风格滚动波形（Metal 渲染） |
| `SpectrumView` | `UI/Components/` | FFT 频谱（vDSP） |
| `SignalPathBar` | `UI/Player/` | 底部信号路径栏（PurePlay 独创） |
| `EQCurveEditor` | `UI/Settings/` | 拖拽式 EQ 曲线编辑 |
| `TechBadgeView` | `UI/Components/` | 采样率/位深/格式标签 |
| `MenuBarPopover` | `UI/Player/` | 菜单栏弹出面板 |
| `QuarkLoginView` | `UI/Cloud/` | WKWebView 登录 |
| `CloudBrowserView` | `UI/Cloud/` | 云盘文件浏览 |

详细 UI 视觉规范见 [AGENT.md §6](./AGENT.md)。

---

## 5. 音频引擎技术实现

### 5.1 解码器层（Decoder Layer）

#### 5.1.1 解码器接口（借鉴 VLC `decoder_t`）

```swift
/// 借鉴 VLC modules/codec/* 的统一接口契约
/// 与 VLC 的差异：返回原生 PCM 整数（默认），仅在需要 DSP 时才转 FL32
protocol AudioDecoder: AnyObject, Sendable {
    /// 解码后的原生格式
    var format: AudioFormat { get }

    /// 总帧数（-1 表示流式不可知）
    var totalFrames: Int64 { get }

    /// 当前帧
    var currentFrame: Int64 { get }

    /// 解码 maxFrames 帧到 buffer，返回实际解码帧数
    /// buffer 字节布局必须匹配 self.format（int32 packed / float32 planar 等）
    func decode(into buffer: UnsafeMutableRawPointer, maxFrames: Int) -> Int

    /// Seek 到指定帧
    func seek(to frame: Int64) -> Bool

    /// 关闭解码器
    func close()
}

/// 解码器工厂 — 借鉴 VLC module_need
protocol DecoderFactory {
    static var supportedExtensions: Set<String> { get }
    static var priority: Int { get }   // 高优先级先尝试
    static func canDecode(source: AudioSource) -> Bool
    static func makeDecoder(source: AudioSource) throws -> AudioDecoder
}
```

#### 5.1.2 解码器选择（DecoderRegistry）

```swift
final class DecoderRegistry {
    /// 注册顺序 = 优先级（与 VLC 的 module_need 类似）
    /// 专用解码器 > FFmpeg 兜底
    private static let factories: [DecoderFactory.Type] = [
        FLACDecoderFactory.self,        // libFLAC（参考实现 + MD5 校验）
        DSDDecoderFactory.self,         // SFBAudioEngine 内置 DSF/DFF
        APEDecoderFactory.self,         // CXXMonkeysAudio
        WAVDecoderFactory.self,         // dr_wav（含 RF64 64GB+）
        AIFFDecoderFactory.self,        // dr_wav AIFF 模式
        ALACDecoderFactory.self,        // CoreAudio AudioConverter
        OpusDecoderFactory.self,        // libopus
        VorbisDecoderFactory.self,      // libvorbis
        WavPackDecoderFactory.self,     // libwavpack
        FFmpegDecoderFactory.self       // 万能兜底（LGPL 编译）
    ]

    static func makeDecoder(for source: AudioSource) throws -> AudioDecoder {
        for factory in factories where factory.canDecode(source: source) {
            return try factory.makeDecoder(source: source)
        }
        throw DecoderError.unsupportedFormat
    }
}
```

#### 5.1.3 各解码器实现要点

| 解码器 | 库 | 关键实现 |
|--------|-----|---------|
| **FLACDecoder** | libFLAC | 启用 MD5 校验（`FLAC__stream_decoder_set_md5_checking`），解码完成后对比头部 MD5 验证 bit-perfect |
| **DSDDecoder** | SFBAudioEngine | 同时输出原始 DSD bitstream（用于 DoP）+ 提供 PCM 转换路径（DSD2PCM） |
| **APEDecoder** | CXXMonkeysAudio | 后台预解码大缓冲（≥2s），高压缩级别下避免实时性问题 |
| **WAVDecoder** | dr_wav | 直接 mmap 大文件，避免内存拷贝 |
| **FFmpegDecoder** | libavcodec (LGPL) | 仅编译需要的解码器，剥离视频相关，体积控制在 ~8MB |

#### 5.1.4 FFmpeg LGPL 编译策略（避开 VLC 的 GPL 困境）

```bash
./configure --disable-everything \
  --enable-decoder=flac,alac,ape,wavpack,tta,mlp,truehd \
  --enable-decoder=mp3,aac,vorbis,opus,wmav1,wmav2 \
  --enable-demuxer=flac,wav,aiff,caf,m4a,mp3,ogg,ape \
  --enable-protocol=file --enable-shared \
  --disable-gpl --disable-nonfree \
  --enable-pic
```

输出 `libavcodec.dylib` ~8MB，仅 LGPL 兼容，可放心闭源分发或开源 MIT。

### 5.2 PCM Ring Buffer（无锁缓冲）

借鉴 VLC `coreaudio_common.c` 中的 ringbuffer 设计，单生产单消费，使用 C11 原子：

```swift
final class PCMRingBuffer {
    private let buffer: UnsafeMutableRawPointer
    private let capacity: Int
    private let writeIndex: UnsafeMutablePointer<Atomic<Int>>  // 解码线程
    private let readIndex: UnsafeMutablePointer<Atomic<Int>>   // 音频回调线程

    init(capacityBytes: Int) { /* posix_memalign 64-byte 对齐 */ }

    /// 解码线程调用，返回实际写入字节数
    func write(_ data: UnsafeRawPointer, length: Int) -> Int

    /// 音频回调线程调用，必须 lock-free
    /// 不足时填充静音，避免 underrun glitch
    func read(into dst: UnsafeMutableRawPointer, length: Int) -> Int

    /// 容量配置：默认 2 秒缓冲
    /// DSD256 立体声: 2.82 MB/s × 2s × 2ch = ~11 MB
    /// 192kHz/24bit 立体声: 1.15 MB/s × 2s = ~2.3 MB
}
```

### 5.3 DSP Chain（借鉴 VLC `aout_FiltersPipelineNew`）

#### 5.3.1 DSP 节点接口

```swift
protocol DSPNode: AnyObject, Sendable {
    var isEnabled: Bool { get set }
    var name: String { get }

    /// 当采样率/声道变化时重新配置
    func configure(inputFormat: AudioFormat) -> AudioFormat

    /// 处理 PCM（in-place 或写入 outBuffer）
    func process(input: UnsafePointer<Float>,
                 output: UnsafeMutablePointer<Float>,
                 frameCount: Int)
}
```

#### 5.3.2 DSP Chain 自动组装（VLC `filters.c` 风格）

```swift
final class DSPChain {
    /// 节点顺序固定（借鉴 VLC filter_chain 的组装规则）
    /// PCM int → FL32 → ReplayGain → Resampler → EQ → Crossfeed →
    ///   Dither → FL32 → 输出格式
    private(set) var nodes: [DSPNode] = []

    /// 给定输入与目标输出格式，自动构建管线
    /// 借鉴 VLC aout_FiltersPipelineCreate
    static func build(inputFormat: AudioFormat,
                      outputFormat: AudioFormat,
                      preferences: DSPPreferences) -> DSPChain {
        var chain: [DSPNode] = []

        // Bit-Perfect 模式：所有节点 bypass
        if preferences.bitPerfect {
            return DSPChain(nodes: [])
        }

        if preferences.replayGain != .off { chain.append(ReplayGainNode(...)) }
        if inputFormat.sampleRate != outputFormat.sampleRate {
            chain.append(SoXRResamplerNode(target: outputFormat.sampleRate))
        }
        if preferences.eqEnabled { chain.append(EQNode(bands: preferences.eqBands)) }
        if preferences.crossfeed { chain.append(CrossfeedNode(.medium)) }
        if outputFormat.bitDepth < inputFormat.bitDepth {
            chain.append(DitherNode(.tpdf))
        }
        return DSPChain(nodes: chain)
    }
}
```

#### 5.3.3 关键 DSP 节点

| 节点 | 库/算法 | 说明 |
|------|--------|------|
| **SoXRResamplerNode** | SoXR VHQ | C 桥接，构建为 xcframework |
| **EQNode** | 自实现 IIR Biquad 级联 | 10 段图形 + 参量；Accelerate `vDSP_biquad` 加速 |
| **CrossfeedNode** | BS2B 算法 | 参考 [bs2b](http://bs2b.sourceforge.net/) |
| **ReplayGainNode** | 整数增益（避免精度损失） | 读取 ID3/Vorbis Comment 中的 `REPLAYGAIN_*` 标签 |
| **DitherNode** | TPDF + Noise Shape | 仅在位深降级时启用 |

### 5.4 CoreAudio 输出层（核心差异化）

#### 5.4.1 与 VLC `auhal.c` 的对比

| 特性 | VLC auhal.c | PurePlay CoreAudioOutput |
|------|:-----------:|:------------------------:|
| Hog Mode（PCM） | ❌ | ✅ 默认开启 |
| Hog Mode（SPDIF） | ✅ | ✅ |
| 自动设备采样率切换（PCM） | ❌ | ✅ |
| 自动设备采样率切换（SPDIF） | ✅ | ✅ |
| 设备热插拔监听 | ✅ | ✅ |
| 默认设备变更监听 | ✅ | ✅ |
| 整数 PCM 直通（避开 FL32） | ❌ | ✅（可选） |
| DoP 输出 | ❌ | ✅ |

#### 5.4.2 实现要点

```swift
final class CoreAudioOutput {

    // MARK: 1. 设备枚举（借鉴 auhal.c DevicesListener）
    func enumerateDevices() -> [AudioDevice] {
        // kAudioHardwarePropertyDevices → AudioObjectID 数组
        // 过滤出输出设备（kAudioDevicePropertyScopeOutput）
    }

    // MARK: 2. Hog Mode 独占（关键差异化点）
    func acquireHogMode(device: AudioDevice) throws {
        var pid: pid_t = getpid()
        let status = AudioObjectSetPropertyData(
            device.id,
            &kAudioDevicePropertyHogMode,
            0, nil,
            UInt32(MemoryLayout<pid_t>.size),
            &pid
        )
        guard status == noErr else { throw OutputError.hogModeDenied }

        // 同时禁用混音（macOS 对 Hog Mode 的隐含要求）
        var mixable: UInt32 = 0
        AudioObjectSetPropertyData(device.id, &kAudioDevicePropertySupportsMixing, ...)
    }

    // MARK: 3. 自动采样率切换（VLC 不做这件事）
    func switchSampleRate(to rate: Double, on device: AudioDevice) throws {
        // 优先尝试 kAudioStreamPropertyPhysicalFormat（精确控制位深）
        // 回退到 kAudioDevicePropertyNominalSampleRate
        // 等待 device.isReady（监听 kAudioDevicePropertyDeviceIsRunning）
    }

    // MARK: 4. 设置位深匹配（FLAC 24bit → DAC 24bit；不强制 FL32）
    func setOutputFormat(_ fmt: AudioFormat) throws {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: fmt.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: fmt.isInteger
                ? kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
                : kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(fmt.bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(fmt.bytesPerFrame),
            mChannelsPerFrame: UInt32(fmt.channels),
            mBitsPerChannel: UInt32(fmt.bitDepth),
            mReserved: 0
        )
        // kAudioStreamPropertyPhysicalFormat
    }

    // MARK: 5. 渲染回调（借鉴 coreaudio_common.c 的 RenderCallback）
    private let renderCallback: AURenderCallback = { (inRefCon, ioActionFlags,
                                                      inTimeStamp, inBusNumber,
                                                      inNumberFrames, ioData) in
        let output = Unmanaged<CoreAudioOutput>.fromOpaque(inRefCon).takeUnretainedValue()
        return output.handleRender(ioData: ioData!, frames: Int(inNumberFrames))
    }

    private func handleRender(ioData: UnsafeMutablePointer<AudioBufferList>,
                              frames: Int) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        let bytesNeeded = frames * currentFormat.bytesPerFrame
        let actuallyRead = ringBuffer.read(into: buffers[0].mData!, length: bytesNeeded)
        if actuallyRead < bytesNeeded {
            // Underrun: 填充静音 + 记录 metric
            memset(buffers[0].mData! + actuallyRead, 0, bytesNeeded - actuallyRead)
        }
        return noErr
    }

    // MARK: 6. 监听器（完全照搬 auhal.c 模式）
    private var listeners: [AudioDeviceListener] = [
        DeviceAliveListener(),
        DefaultDeviceChangedListener(),
        StreamFormatChangedListener(),
        DevicesChangedListener()
    ]

    // MARK: 7. 释放（必须恢复设备原状态）
    func release() {
        // 释放 Hog Mode（pid = -1）
        // 恢复 mixable = 1
        // 取消监听器
        // 这是发烧友 App 的礼貌：不影响其他 App 后续使用
    }
}
```

### 5.5 DSD 输出（DoP）— VLC 完全没有

#### 5.5.1 DoP 打包器

```swift
/// DSD bitstream → DoP PCM frames (24-bit)
/// 协议参考 AGENT.md §12.3
final class DoPPacker {
    private var markerToggle: UInt8 = 0x05  // 与 0xFA 交替

    /// 输入：DSD bitstream（每字节 8 个 1-bit DSD samples）
    /// 输出：24-bit PCM 立体声帧（高字节为 marker，低 16 位为 16 个 DSD bits）
    func pack(dsdBytes: UnsafePointer<UInt8>,
              dsdLength: Int,
              channels: Int,
              outPCM: UnsafeMutablePointer<UInt8>) -> Int {
        // 每 16 个 DSD bits（2 字节）打包成一个 24-bit PCM sample
        // 注意 DSF (LSB first) vs DFF (MSB first) 的位序差异
        // 标记字节 0x05 / 0xFA 必须每帧切换
    }
}

/// DSD 速率 → DoP PCM 载波速率映射
/// DSD64  → 176.4 kHz / 24-bit
/// DSD128 → 352.8 kHz / 24-bit
/// DSD256 → 705.6 kHz / 24-bit（macOS 上限，需 DAC 支持 705.6kHz PCM）
```

#### 5.5.2 DAC 能力探测

```swift
final class DACCapabilityProbe {

    struct Capabilities {
        let maxPCMRate: Double      // 通过 kAudioDevicePropertyAvailableNominalSampleRates 枚举
        let supportsDSD64ViaDoP: Bool
        let supportsDSD128ViaDoP: Bool
        let supportsDSD256ViaDoP: Bool
        let isWhitelisted: Bool     // 名称匹配已知 DSD-capable DAC
    }

    func probe(_ device: AudioDevice) -> Capabilities {
        let rates = device.availableSampleRates
        let maxRate = rates.max() ?? 44100
        return Capabilities(
            maxPCMRate: maxRate,
            supportsDSD64ViaDoP:  maxRate >= 176_400,
            supportsDSD128ViaDoP: maxRate >= 352_800,
            supportsDSD256ViaDoP: maxRate >= 705_600,
            isWhitelisted: KnownDSDDevices.matches(name: device.name)
        )
    }
}
```

#### 5.5.3 DSD 决策流程（实现 AGENT.md §12.10）

```swift
enum DSDOutputStrategy {
    case dop(carrierRate: Double)
    case pcm(targetRate: Double, quality: DSD2PCMQuality)
}

func chooseDSDStrategy(file: DSDFileInfo,
                       dac: DACCapabilities,
                       userPref: DSDPreference) -> DSDOutputStrategy {
    let dopRequiredRate = file.dsdRate.dopCarrierRate
    let dacSupportsDoP = dac.maxPCMRate >= dopRequiredRate

    switch userPref {
    case .preferDoP where dacSupportsDoP:
        return .dop(carrierRate: dopRequiredRate)
    case .alwaysPCM, .preferDoP:  // DAC 不支持 DoP，回退
        let pcmRate = file.dsdRate.recommendedPCMRate  // DSD64 → 88.2k, DSD128 → 176.4k...
        return .pcm(targetRate: pcmRate, quality: .gesemann96TapFIR)
    case .auto:
        return dacSupportsDoP
            ? .dop(carrierRate: dopRequiredRate)
            : .pcm(targetRate: file.dsdRate.recommendedPCMRate, quality: .high)
    }
}
```

---

## 6. 音乐库与元数据

### 6.1 数据模型（沿用 AGENT.md §5.1）

```swift
// SQLite Schema (via GRDB.swift)
CREATE TABLE tracks (
    id            BLOB PRIMARY KEY,           -- UUID
    file_path     TEXT NOT NULL UNIQUE,
    source        TEXT NOT NULL,              -- 'local' | 'quark'
    cloud_file_id TEXT,                       -- 云盘 fid
    title         TEXT,
    artist        TEXT,
    album         TEXT,
    album_artist  TEXT,
    track_number  INTEGER,
    disc_number   INTEGER,
    year          INTEGER,
    genre         TEXT,
    duration      REAL,
    sample_rate   REAL,
    bit_depth     INTEGER,
    channels      INTEGER,
    format        TEXT,                       -- 'flac', 'dsd', 'ape', ...
    file_size     INTEGER,
    date_added    REAL,
    replay_gain_track REAL,
    replay_gain_album REAL
);

CREATE INDEX idx_tracks_album ON tracks(album_artist, album, disc_number, track_number);
CREATE INDEX idx_tracks_artist ON tracks(artist);
CREATE INDEX idx_tracks_format ON tracks(format);

CREATE VIRTUAL TABLE tracks_fts USING fts5(
    title, artist, album, content='tracks', content_rowid='rowid'
);
```

### 6.2 扫描器（FSEvents 监听）

```swift
final class LibraryScanner {
    let supportedExtensions: Set<String> = [
        "flac", "ape", "wav", "aiff", "aif",
        "dsf", "dff",
        "alac", "m4a", "mp4",
        "mp3", "ogg", "opus", "oga",
        "wv", "mpc", "tta",
        "iso",      // SACD ISO（Phase 5+）
        "cue"       // 整轨分轨
    ]

    /// 1. 全量扫描：递归遍历 + 并发解析元数据
    func fullScan(directories: [URL]) async throws

    /// 2. 增量监听：FSEvents
    /// 监听变化事件：created / modified / removed / renamed
    func startWatching(directories: [URL])

    /// 3. 元数据读取（taglib + SFB 兜底）
    private func readMetadata(_ url: URL) throws -> Track
}
```

---

## 7. 夸克网盘集成

### 7.1 架构（沿用 AGENT.md §13）

```
┌──────────────┐    ┌──────────────────┐    ┌─────────────────┐
│ WKWebView    │    │ QuarkAPIClient   │    │ CloudAudio      │
│ (登录)       │───▶│ (URLSession)     │───▶│ StreamDecoder   │
│              │    │ - Cookie 管理    │    │                 │
│ pan.quark.cn │    │ - Auto Refresh   │    │ + 普通 Decoder  │
└──────────────┘    │ - 请求限速 5/s   │    └────────┬────────┘
                    └──────────────────┘             │
                              │                      ▼
                              ▼            ┌──────────────────┐
                    ┌──────────────────┐   │  PCMRingBuffer   │
                    │CloudDownloadCache│──▶│  (与本地一致)    │
                    │ LRU 2GB / 可配   │   └──────────────────┘
                    └──────────────────┘
```

### 7.2 关键实现要点

| 模块 | 关键决策 |
|------|---------|
| **认证** | WKWebView 内嵌登录，Cookie 提取后存 macOS Keychain |
| **Cookie 刷新** | 每次响应解析 `Set-Cookie`，更新 `__puus`/`__pus` |
| **请求限速** | Token Bucket，≤5 req/s |
| **流式播放** | HTTP Range 请求 + 5MB 预缓冲启动阈值 |
| **Seek** | 取消当前下载 → 新 Range 请求 → 等待头部就绪 |
| **格式探测** | 先下载 64KB 头部 → 解析 WAV/FLAC/DSF magic 与 metadata → 推断准确 `AudioFormat` |
| **本地缓存** | 完整下载后落盘，LRU 淘汰，下次秒开 |

### 7.3 法律与合规（沿用 AGENT.md §13.8）

- ✅ 用户主动 WKWebView 登录，不自动化凭证获取
- ✅ Cookie 仅本地 Keychain 加密存储
- ✅ 不上传/共享凭证到任何第三方
- ✅ UI 明确告知"使用非官方 API，账户风险用户自负"
- ⚠️ 首版仅支持读取（列表 + 下载 + 播放），不支持上传/删除，降低风控触发面

---

## 8. 项目结构

```
PurePlay/
├── Package.swift
├── PurePlay.xcodeproj
├── Sources/
│   ├── App/
│   │   ├── PurePlayApp.swift
│   │   └── AppDelegate.swift
│   │
│   ├── UI/                              # SwiftUI 视图层
│   │   ├── Sidebar/
│   │   ├── Library/
│   │   ├── Player/
│   │   │   ├── NowPlayingView.swift
│   │   │   ├── SignalPathBar.swift     ★ PurePlay 独创
│   │   │   └── MenuBarPopover.swift
│   │   ├── Cloud/
│   │   │   ├── QuarkLoginView.swift
│   │   │   └── CloudBrowserView.swift
│   │   ├── Settings/
│   │   └── Components/
│   │       ├── WaveformView.swift
│   │       ├── SpectrumView.swift
│   │       ├── EQCurveEditor.swift
│   │       └── TechBadgeView.swift
│   │
│   ├── AudioEngine/                     # 音频引擎（核心差异化）
│   │   ├── AudioPipeline.swift          # 借鉴 src/audio_output/output.c
│   │   ├── Source/
│   │   │   ├── AudioSource.swift        # 本地 / 云盘统一抽象
│   │   │   ├── LocalFileSource.swift
│   │   │   └── CloudStreamSource.swift
│   │   ├── Decoder/                     # 借鉴 modules/codec
│   │   │   ├── AudioDecoder.swift
│   │   │   ├── DecoderRegistry.swift
│   │   │   ├── FLACDecoder.swift
│   │   │   ├── DSDDecoder.swift
│   │   │   ├── APEDecoder.swift
│   │   │   ├── WAVDecoder.swift
│   │   │   ├── ALACDecoder.swift
│   │   │   └── FFmpegDecoder.swift
│   │   ├── DSP/                         # 借鉴 modules/audio_filter
│   │   │   ├── DSPNode.swift
│   │   │   ├── DSPChain.swift
│   │   │   ├── SoXRResamplerNode.swift
│   │   │   ├── EQNode.swift
│   │   │   ├── CrossfeedNode.swift
│   │   │   ├── ReplayGainNode.swift
│   │   │   └── DitherNode.swift
│   │   ├── DSD/                         # ★ VLC 完全没有
│   │   │   ├── DoPPacker.swift
│   │   │   ├── DSD2PCMConverter.swift   # Gesemann 96-tap FIR
│   │   │   └── DSDStrategy.swift
│   │   ├── Output/                      # 替代 VLC auhal.c
│   │   │   ├── CoreAudioOutput.swift
│   │   │   ├── AudioDeviceManager.swift
│   │   │   ├── SampleRateManager.swift  # ★ VLC PCM 不做这件事
│   │   │   └── DACCapabilityProbe.swift
│   │   └── Buffer/
│   │       └── PCMRingBuffer.swift
│   │
│   ├── Player/
│   │   ├── PlayerController.swift
│   │   ├── PlaybackQueue.swift
│   │   └── PlaybackState.swift
│   │
│   ├── Library/
│   │   ├── LibraryDatabase.swift        # GRDB
│   │   ├── LibraryScanner.swift         # FSEvents
│   │   └── MetadataReader.swift
│   │
│   ├── Cloud/
│   │   ├── QuarkAPIClient.swift
│   │   ├── QuarkCookieStore.swift       # Keychain
│   │   ├── CloudDownloadCache.swift     # LRU
│   │   └── RateLimiter.swift            # Token Bucket
│   │
│   ├── Utilities/
│   │   ├── AudioFormat.swift
│   │   ├── FFTAnalyzer.swift            # vDSP
│   │   ├── KnownDSDDevices.swift
│   │   └── Logger.swift
│   │
│   └── CInterop/
│       ├── soxr-bridge/
│       ├── dr_libs/
│       └── include/PurePlay-Bridging-Header.h
│
├── Tests/
│   ├── AudioEngineTests/
│   │   ├── BitPerfectTests.swift        # 关键发烧友验证
│   │   ├── DSDDoPIntegrityTests.swift
│   │   ├── DecoderTests.swift
│   │   └── DSPChainTests.swift
│   ├── LibraryTests/
│   └── CloudTests/
│
└── Resources/
    ├── Assets.xcassets
    ├── EQPresets.json
    └── KnownDSDDevices.json
```

---

## 9. 实施路线图

### Phase 1 — 核心引擎 MVP（4 周）

**目标**：FLAC/WAV → CoreAudio Hog Mode → bit-perfect 输出

| # | 任务 | 验收 |
|---|------|------|
| 1.1 | `CoreAudioOutput` Hog Mode + 设备枚举 | 独占 USB DAC，外部混音器无声 |
| 1.2 | `SampleRateManager` 自动切换 | 44.1k 与 96k 文件依次播放，DAC LED 切换 |
| 1.3 | FLAC 解码器（libFLAC + MD5 校验） | `BitPerfectTests.testFLACBitPerfect` 通过 |
| 1.4 | WAV 解码器（dr_wav） | RF64 4GB+ 文件可播 |
| 1.5 | `PCMRingBuffer` 无锁 | 24h 长时压测 0 underrun |
| 1.6 | `AudioPipeline` 串联 | 命令行可播放 FLAC |
| 1.7 | 基础 `PlayerController` | Play/Pause/Stop/Seek 可用 |

### Phase 2 — 格式扩展 + 基础 UI（4 周）

| # | 任务 |
|---|------|
| 2.1 | DSD 解码（SFB DSF/DFF） |
| 2.2 | `DoPPacker` + DAC 能力探测 |
| 2.3 | `DSD2PCMConverter` Gesemann 96-tap FIR |
| 2.4 | APE / ALAC / FFmpeg 兜底解码 |
| 2.5 | CUE 整轨分轨 |
| 2.6 | SwiftUI 主界面（Vox 风格） |
| 2.7 | `TechBadgeView` + `SignalPathBar` |
| 2.8 | 元数据读取（taglib） |
| 2.9 | 菜单栏弹出面板 |

### Phase 3 — 音质控制 + DSP（3 周）

| # | 任务 |
|---|------|
| 3.1 | SoXR VHQ C 桥接 |
| 3.2 | 10 段图形 EQ + 10 段参量 EQ |
| 3.3 | `EQCurveEditor` 交互 |
| 3.4 | ReplayGain（Track/Album） |
| 3.5 | Crossfeed (BS2B) |
| 3.6 | Dither (TPDF) |
| 3.7 | `WaveformView` Metal 渲染 |
| 3.8 | `SpectrumView` vDSP FFT |
| 3.9 | `BitPerfectIndicator` 实时检测 |

### Phase 4 — 音乐库（3 周）

| # | 任务 |
|---|------|
| 4.1 | GRDB SQLite Schema + 迁移 |
| 4.2 | 全量扫描 + FSEvents 增量 |
| 4.3 | 专辑网格视图 |
| 4.4 | 艺术家/流派/年代视图 |
| 4.5 | 播放列表 CRUD + 智能播放列表 |
| 4.6 | FTS5 全文搜索 |
| 4.7 | 双缓冲无缝播放 |
| 4.8 | 悬浮迷你模式 |
| 4.9 | 全局热键 + 媒体键 |

### Phase 5 — 夸克网盘（4 周）

| # | 任务 |
|---|------|
| 5.1 | `QuarkAPIClient` 完整 API 封装 |
| 5.2 | WKWebView 登录 + Keychain 存储 |
| 5.3 | Cookie 自动刷新 + 失效检测 |
| 5.4 | 文件列表浏览 + 格式过滤 |
| 5.5 | 64KB 头部探测 |
| 5.6 | `CloudAudioStreamDecoder` 流式解码 |
| 5.7 | HTTP Range Seek |
| 5.8 | LRU 磁盘缓存 + 预下载下一曲 |
| 5.9 | 混合播放队列（本地 + 云盘） |
| 5.10 | 请求限速 + 风控规避 |

### Phase 6 — 打磨 + 发布（3 周）

| # | 任务 |
|---|------|
| 6.1 | 性能优化（启动 <1s，内存峰值 <300MB） |
| 6.2 | 多 DAC 偏好记忆 |
| 6.3 | M3U/PLS 导入导出 |
| 6.4 | 代码签名 + Notarize |
| 6.5 | DMG 打包 + Homebrew Cask |
| 6.6 | 用户文档 + 已知 DSD DAC 数据库 |

**总周期：~21 周（5 个月）**

---

## 10. 关键设计决策记录（汇总）

| # | 决策点 | 选择 | 主要备选 | 决策依据 |
|---|--------|------|---------|---------|
| 1 | 整体架构思路 | 借鉴 VLC 模块化 + 自建 macOS 后端 | 直接 fork VLC / 完全自建 | VLC 后端不满足需求，但工程经验值得借鉴 |
| 2 | 编程语言 | Swift 6 + C/C++（解码核心） | Rust + Tauri | 最佳 macOS 原生体验 |
| 3 | UI 框架 | SwiftUI + AppKit | Tauri / Qt | 体积小、原生感强、CoreAudio 直连 |
| 4 | 音频引擎 | 自建 + SFBAudioEngine 复用 DSD | 嵌 libVLC | libVLC 不支持 DSD/Hog Mode，体积过大 |
| 5 | 解码器分发 | DecoderRegistry 优先级表 | 单一 FFmpeg | 借鉴 VLC `module_need`，专用解码器更稳更准 |
| 6 | FFmpeg 编译 | LGPL 配置、剥视频、~8MB | 完整 FFmpeg | 避免 GPL 污染 |
| 7 | DSP Chain | 自动组装（VLC `filters.c` 思路） | 静态固定链 | 适配可变采样率/位深 |
| 8 | CoreAudio 后端 | 自建 + Hog Mode for PCM | 沿用 auhal.c 风格 | VLC 仅 SPDIF 用 Hog，发烧友需要 PCM 也用 |
| 9 | 自动采样率 | PCM + SPDIF 都自动切 | 仅 SPDIF（VLC 风格） | 这是 vs Vox/VLC 的关键差异化 |
| 10 | DSD 输出 | DoP 优先 + Gesemann FIR 兜底 | 仅 PCM 转换 | macOS 无 Native DSD，DoP 是 bit-perfect 唯一路径 |
| 11 | DSP 默认状态 | 全部 bypass（真 bit-perfect） | 默认开启 EQ | Vox/VLC 都未做到真 bypass |
| 12 | 信号路径可见 | 底部状态栏实时显示 | 隐藏 | 发烧友核心需求 |
| 13 | 数据库 | SQLite via GRDB.swift | Core Data | 更轻量，可控 |
| 14 | 云盘接入 | URLSession 直连 HTTP API | AList 中间件 | 零外部依赖，体积最小 |
| 15 | 云盘认证 | WKWebView 登录 + Keychain | 手动粘 Cookie | UX 好且安全 |
| 16 | 云盘播放 | 流式 + LRU 磁盘缓存 | 仅完整下载 | Hi-Res 文件大，流式启动快 |
| 17 | 最低系统 | macOS 14 (Sonoma) | macOS 13 | 获得 Observable / SwiftData |

---

## 11. 风险与缓解

| 风险 | 概率 | 影响 | 缓解策略 |
|------|:----:|:----:|---------|
| **SFBAudioEngine 维护停滞** | 中 | 中 | 解耦：仅依赖其 DSD 解码，FLAC 直接用 libFLAC |
| **SoXR Swift Package 集成困难** | 低 | 低 | 预构建 xcframework，源码方式作为 PR 提交至社区 |
| **Hog Mode 与某些 USB DAC 兼容性差** | 中 | 中 | 设备白名单 + 用户可关闭 Hog Mode 回退 |
| **CoreAudio 705.6kHz PCM 部分 DAC 不支持** | 中 | 低 | DSD256 自动降级为 DSD128 DoP 或 DSD→PCM |
| **VLC GPL 模块意外引入** | 低 | 高 | 严格只用 libavcodec（LGPL）；不嵌入 libVLC |
| **夸克 API 变更** | 高 | 中 | 监控 AList/quarkpan-rs 社区；远程下发 endpoint 配置 |
| **夸克 Cookie 频繁失效** | 中 | 中 | 静默自动刷新 + 失效后 WebView 重登录 |
| **夸克账号被风控/封禁** | 中 | 中 | 请求限速 ≤5/s，模拟正常用户行为，明确告知用户风险 |
| **APE Extra High 解码 CPU 高** | 中 | 低 | 后台预解码 + 大缓冲；显示警告 |
| **Apple App Store 审核拒绝**（云盘逆向） | 高 | 中 | 首发走 Homebrew/官网 DMG，不走 MAS |

---

## 12. 验收标准（Bit-Perfect 验证）

发烧友播放器的核心承诺必须可量化验证：

```swift
final class BitPerfectAcceptanceTests {

    /// FLAC 全文件解码 → 对比内嵌 MD5 → 必须一致
    func testFLAC_MD5Verification()

    /// WAV 解码字节流 → 对比原始数据区 → 必须一致
    func testWAV_RawByteCompare()

    /// DSD → DoP → 解包 → 对比原始 DSD bitstream → 必须一致
    func testDSD_DoP_RoundTrip()

    /// Hog Mode 期间，启动其他 App 播音乐 → 必须无声（独占成功）
    func testHogMode_Exclusivity()

    /// 切换 44.1k/48k/96k/192k 文件 → DAC 显示采样率必须每次切换正确
    func testAutoSampleRateSwitch()

    /// 所有 DSP bypass + 整数 PCM 模式 → 输出 byte-equal 解码原始字节
    func testTrueBitPerfectMode()

    /// 24h 长时播放 0 underrun，0 内存泄漏
    func test24hStress()
}
```

通过全部以上测试，才能宣称 PurePlay 是真正的 bit-perfect 播放器。

---

## 附录 A — 与 AGENT.md 章节对应表

| AGENT.md 章节 | 本文档章节 | 增补内容 |
|--------------|----------|---------|
| §1 调研 | §2 VLC 分析 | 增加 VLC 借鉴/不借鉴的具体取舍 |
| §2 架构 | §3 系统架构 | 重组为 4 层 + 模块职责矩阵 |
| §3 技术栈 | §5 技术实现 | 落实到具体接口签名 |
| §4 音质 | §5.3 DSP Chain | 增加 VLC `filters.c` 风格自动组装 |
| §5 音乐库 | §6 库与元数据 | 增加 SQLite Schema 与索引 |
| §6 UI | §4 UI 设计 | 简化引用，避免重复 |
| §7 项目结构 | §8 项目结构 | 标注 ★ VLC 没有的差异化模块 |
| §8 路线图 | §9 路线图 | 重排 Phase 顺序，云盘前置 |
| §9 决策 | §10 决策记录 | 增加 VLC 借鉴相关条目 |
| §10 风险 | §11 风险 | 增加 GPL/AppStore 风险 |
| §11 解码深度 | §5.1 解码器层 | 浓缩为接口定义 + 工厂表 |
| §12 DSD 深度 | §5.5 DSD 输出 | 浓缩为决策流程 |
| §13 云盘 | §7 云盘集成 | 浓缩为关键决策 |

---

## 附录 B — 参考资料

- [VLC 源码](https://github.com/videolan/vlc) — Apache/GPL 媒体播放器（架构参考）
- [SFBAudioEngine](https://github.com/sbooth/SFBAudioEngine) — Swift CoreAudio 引擎
- [SoXR](https://github.com/chirlu/soxr) — 高品质重采样
- [dsd2pcm (Gesemann)](https://github.com/dsd-pcm/dsd2pcm) — 参考级 DSD→PCM
- [GRDB.swift](https://github.com/groue/GRDB.swift) — SQLite ORM
- [DoP Standard v1.1](https://dsd-guide.com/dop-open-standard) — DoP 协议
- [AList](https://github.com/AlistGo/alist) — 多云盘网关（夸克 API 参考）
- [Apple CoreAudio HAL Reference](https://developer.apple.com/documentation/coreaudio/core_audio_hal)
- AGENT.md — PurePlay 产品需求基线

---

**文档结束。**
准备进入 Phase 1 实施。
