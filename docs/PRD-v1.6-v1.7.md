# PRD — PurePlay v1.6 / v1.7

**版本目标**: 把 PurePlay 从「能播大多数格式的 Hi-Fi 播放器」推向「面向中文 HiFi 烧友的专业级 DSP/EQ 工具箱」。
**生成自**: 2026-06-29 grilling 会话（28 题决策）
**作者**: Qoder + 用户
**状态**: 草稿，待评审

---

## 1. 背景与定位

### 1.1 用户画像

中文圈 HiFi 烧友。特征：
- 外接独立 DAC（USB / I²S，常见 Topping / SMSL / RME / dCS / Mytek 等）
- 本地大体量音乐库（动辄数千张专辑，混合 FLAC / DSD / APE / 老 WMA 收藏）
- 关心比特完美、母带格式、采样率/位深一致性
- 愿意花时间调 EQ；多为头戴式监听耳机用户（HD600 / DT1990 / Sundara 等）

### 1.2 产品定位

**专业级 DSP/EQ 调音工具箱**（参考对标：HQPlayer Lite、Roon DSP、Audirvana 的 EQ 模块），**不是**「格式大全播放器」。

意味着：
- 格式覆盖以「覆盖常见 + 修可见 bug」为底线，不追求 codec 收集癖
- EQ 模块要做到「准、稳、可比较、能信任」——这是产品差异化的核心卖点
- 元数据、库视图、播放列表保留够用即可，不和 Roon 比库管理

### 1.3 EQ 使用场景

- **核心**: 耳机频响修正（AutoEQ 文件导入 → 一键应用） + 个性化微调
- **次要**: 高低频补偿、特定频段衰减/提升
- 不做：环境校正（房间声学）、多声道处理、动态压缩

### 1.4 工作流

「导入即用」为主：
1. 用户从 AutoEQ 项目下载耳机 ParamEQ 文件
2. 拖进 PurePlay → 自动应用到当前 EQ
3. 偶尔在「曲线编辑器」里微调

---

## 2. 范围

### 2.1 v1.6 范围（格式 + 基础设施）

| # | 工作项 | 文件影响范围（预估） |
|---|--------|---------------------|
| F1 | FFmpeg 重编：补 asf+matroska demuxer + wmalossless/pro/v2/v1/voice 解码器 | `scripts/build_ffmpeg.sh` |
| F2 | `.mka`/`.wma` 修复（依赖 F1 完成后自动启用） | `Sources/PurePlayCore/Decoder/FFmpegDecoder.swift` 注册表 |
| F3 | WMA Lossless 端到端解码（依赖 F1） | 同上 |
| F4 | DSD1024 支持（DSDRate enum、DSF/DFF allowlist、PCM 输出 384k/768k） | `Sources/PurePlayCore/DSD/DoPPacker.swift`、`Sources/PurePlayCore/Decoder/DSFDecoder.swift`、`Sources/PurePlayCore/Decoder/DFFDecoder.swift` |
| F5 | DACCapabilityProbe 处理 `.dsd1024`（永远 false，不加字段） | `Sources/PurePlayCore/DSD/DACCapabilityProbe.swift` |
| F6 | SpectrumAnalyzer 频率轴 bug 修复（前置 tech debt） | `Sources/PurePlayCore/Audio/SpectrumAnalyzer.swift:72-73` |
| F7 | 不支持 codec：失败标灰 + tooltip + 跳过 | `Sources/PurePlayApp/`（UI 层）+ FFmpegDecoder 错误码透传 |
| F8 | FFmpeg metadata 回退（asf/matroska tag + 内嵌封面） | `Sources/PurePlayCore/Metadata/MetadataReader.swift` |
| F9 | 轻量 audio thread CPU% + DSP 延迟显示（角落小角标，可隐藏） | `Sources/PurePlayApp/`（UI）+ CoreAudio 时间戳采集 |
| F10 | 样本文件端到端解码测试（APE/WMA/WMA-Lossless/MKA/DSD64/DSD1024） | `Tests/PurePlayCoreTests/`、新增 `Tests/Resources/` |
| F11 | DSD PCM 上限偏好（`dsdMaxPCMRate` key，默认 384k） | `Sources/PurePlayCore/Util/AudioPreferences.swift` |
| F12 | v1.5 → v1.6 EQ 迁移：旧 key → `eqSlotA`，双写保留兼容 | `Sources/PurePlayCore/Util/AudioPreferences.swift` |

### 2.2 v1.7 范围（EQ UI 专业化）

| # | 工作项 | 文件影响范围（预估） |
|---|--------|---------------------|
| E1 | SpectrumAnalyzer 非对称 attack/release 平滑 | `Sources/PurePlayCore/Audio/SpectrumAnalyzer.swift` |
| E2 | SpectrumAnalyzer 连到 EQ canvas（EQ-pre，半透明源频谱叠加） | `Sources/PurePlayApp/`（EQ 视图）+ SpectrumAnalyzer 引线 |
| E3 | 数字字段双击编辑 + 单位解析（`8.2k` → 8200，`+3dB` → 3.0） | EQ 编辑器组件 |
| E4 | Option-drag 改 Q + 保留滚轮 | ParametricEQEditor 鼠标处理 |
| E5 | LP/HP 滤波器（RBJ 12 dB/oct，UI 预留 slope 字段占位） | `Sources/PurePlayCore/DSP/DSPNodes.swift` + 滤波器 enum 扩展 |
| E6 | A/B 双槽 + B 键切换 + Copy A→B 按钮 | EQPanel + AudioPreferences `eqSlotA`/`eqSlotB` |
| E7 | 系数线性插值（块级 ≈93ms 过渡，消除参数跳变 click） | `Sources/PurePlayCore/DSP/ParametricEQNode.swift` |
| E8 | AutoEQ 文件名提取耳机型号 + 「当前耳机」状态栏标签 | `Sources/PurePlayCore/EQ/AutoEQParser.swift` + 状态栏 |

### 2.3 不在范围

- 多套命名 preset 库（多于 A/B 的方案）—— v1.8+
- macOS 原生 DSD 输出（厂商私有协议）—— 不计划
- AC-3 / DTS / TrueHD / MLP 解码—— 不计划（按 Q24 决策标灰处理）
- 房间声学校正（卷积、Audyssey 风格）—— 不计划
- 频响图上 LP/HP 陡降曲线可视化 —— v1.7 评审时定（默认按 Peak 钟形通用绘制）

---

## 3. 详细需求

### 3.1 格式覆盖（F1-F3）

**FFmpeg configure 增量**（`scripts/build_ffmpeg.sh:54-55`）:

```diff
- --enable-demuxer=ape,wv,tta,ogg,opus,flac,wav,aiff,dsf,mov,mp3,aac
+ --enable-demuxer=ape,wv,tta,ogg,opus,flac,wav,aiff,dsf,mov,mp3,aac,asf,matroska
- --enable-decoder=ape,wavpack,tta,opus,vorbis,flac,pcm_s16le,...,alac
+ --enable-decoder=ape,wavpack,tta,opus,vorbis,flac,pcm_s16le,...,alac,wmalossless,wmapro,wmav2,wmav1,wmavoice
```

**FFmpegDecoderFactory** 注册新扩展名：

```swift
public static let supportedExtensions: Set<String> = [
    "ape", "wv", "tta", "ogg", "opus",   // 已有
    "wma", "mka",                        // 新增
]
```

**验收**:
- 拖一个 WMA Lossless 文件能完整播完（帧数与 ffprobe 一致 ± 1）
- 拖一个 `.mka` (FLAC inside) 能完整播完
- 拖一个 `.mka` (AC-3 inside) 行为见 F7

### 3.2 DSD1024（F4 / F5）

**DSDRate** (`Sources/PurePlayCore/DSD/DoPPacker.swift:4-36`):

```swift
public enum DSDRate: Int, CaseIterable, Sendable {
    case dsd64   = 2_822_400
    case dsd128  = 5_644_800
    case dsd256  = 11_289_600
    case dsd512  = 22_579_200
    case dsd1024 = 45_158_400   // 新增

    public var recommendedPCMRate: Double {
        switch self {
        case .dsd64:   return 88_200
        case .dsd128:  return 176_400
        case .dsd256:  return 352_800
        case .dsd512:  return 352_800
        case .dsd1024: return 384_000   // 默认；可被 AudioPreferences.dsdMaxPCMRate 覆盖到 768_000
        }
    }

    public var displayName: String {
        switch self { /* 同上加 .dsd1024: "DSD1024" */ }
    }
}
```

**DSF/DFF allowlist** 扩到 5 项：

```swift
// DSFDecoder.swift:84 / DFFDecoder.swift:154
guard [2_822_400, 5_644_800, 11_289_600, 22_579_200, 45_158_400].contains(sampleFreq) else {
    throw ...
}
```

**DAC 能力探测** (`DACCapabilityProbe.swift`):

```swift
public func supports(_ rate: DSDRate) -> Bool {
    switch rate {
    case .dsd64:   return supportsDSD64
    case .dsd128:  return supportsDSD128
    case .dsd256:  return supportsDSD256
    case .dsd512:  return supportsDSD512
    case .dsd1024: return false   // PCM-only fallback (Q15/Q19)
    }
}
```

**SRC 路径**: 复用现有 `DSD2PCMConverter` + `SincResampler`（Q17）。DSD1024 输入 → `DSD2PCM (8× FIR)` → 5.6448 MHz float → `SincResampler` → 384k/768k。**架构零变更**。

**验收**:
- 一个 DSD1024 .dsf/.dff 文件能完整播完，输出 384k（默认）或 768k（用户切换后），无杂音
- DAC 报「不支持」时自动 fallback PCM，不弹错误

### 3.3 元数据回退（F8）

**MetadataReader** 现在走 AVAsset，AVFoundation 不支持 ASF / Matroska 元数据。

新逻辑（伪代码）:

```swift
func read(url: URL) -> Metadata {
    let asset = AVAsset(url: url)
    let primary = readFromAVAsset(asset)
    if primary.isEmpty && ["wma","mka"].contains(url.pathExtension.lowercased()) {
        return readFromFFmpeg(url)   // 新增
    }
    return primary
}

func readFromFFmpeg(url: URL) -> Metadata {
    // avformat_open_input → av_dict_get(metadata, "title"/"artist"/...)
    // 第一个 attached_pic AVStream → 封面 Data
}
```

**支持字段**: title, artist, album, albumArtist, genre, date, track, disc, artwork。**ReplayGain 标签** v1.6 不实现（评审时再定）。

**验收**:
- 一个带 tag 的 WMA 文件，库视图正确显示标题/艺术家/专辑
- 一个带封面的 .mka 文件，封面正确显示

### 3.4 SpectrumAnalyzer 频率轴 bug（F6）

**当前 bug** (`SpectrumAnalyzer.swift:72-73`):

```swift
let minLog: Float = log10(20.0)
let maxLog: Float = log10(Float(halfSize - 1))   // ⚠ halfSize 是 bin 数，不是 Hz
```

在 44.1 kHz / 1024-pt FFT 时，bin 索引范围 [0, 511]，对应频率 [0, 22050] Hz；但代码把 bin 索引当 Hz 使用，导致 bin → log 频率轴整体压缩到 0–2.7 Hz 这个错误区间，最终 frac=0 的低频 bin 全部映射到 lowIdx=1，丢失 ~860 Hz 以下信息。

**修复**:

```swift
let sampleRate: Float = ...   // 从外部传入或保存为属性
let nyquist = sampleRate / 2
let binHz = nyquist / Float(halfSize)
let minHz: Float = 20.0
let maxHz: Float = nyquist
for b in 0..<bandCount {
    let lowFrac = Float(b) / Float(bandCount)
    let highFrac = Float(b + 1) / Float(bandCount)
    let lowHz = pow(10, log10(minHz) + (log10(maxHz) - log10(minHz)) * lowFrac)
    let highHz = pow(10, log10(minHz) + (log10(maxHz) - log10(minHz)) * highFrac)
    let lowIdx = max(1, Int(lowHz / binHz))
    let highIdx = min(halfSize - 1, max(lowIdx + 1, Int(highHz / binHz)))
    // ...
}
```

**API 变化**: `init(bandCount:fftSize:smoothing:)` → `init(bandCount:fftSize:sampleRate:smoothing:)`。调用方需传当前播放采样率。

**验收**:
- 输入 20 Hz / 100 Hz / 1 kHz / 10 kHz 单频正弦，频谱在对应频段单独亮起
- 现有 spectrum 视图在不同采样率（44.1k / 96k / 192k / 384k）下表现一致

### 3.5 不支持 codec 的 UI 处理（F7）

**FFmpegDecoder 初始化失败** 返回带 codec 名的错误:

```swift
enum DecoderError: Error {
    case codecNotSupported(codecName: String)  // 新增
}
```

**UI 层**:
- 播放列表行：标灰文字 + 不允许双击播放
- Hover tooltip: `"Codec not supported: ac3"`
- 自动播放队列：跳过该曲到下一首，不弹对话框、不中断队列

**验收**:
- 一个 AC-3 内嵌的 `.mka` 文件加入库后显示为灰色 + tooltip 正确

### 3.6 性能监控小角标（F9）

**采集**: CoreAudio render callback 入口/出口时间戳 → 移动平均（100ms 窗）。

**显示**: 主窗口右下角小角标，两行：
```
CPU 4.2%   DSP 1.8ms / 5.8ms
```
- CPU% = render callback 总耗时 / 总实时时间
- DSP = render callback 平均耗时 / buffer 实时时长（< 80% 绿色，> 80% 黄色，> 95% 红色）

**偏好开关**: `AudioPreferences.showPerformanceHUD` 默认 `false`，用户在偏好里开启。

### 3.7 端到端解码测试（F10）

**新增** `Tests/Resources/`（git 直接提交，< 10MB 总量）:

```
Tests/Resources/
  sample.ape       (5s @ 44.1kHz int24)
  sample.wma       (5s @ 44.1kHz WMA v2)
  sample.wma_l     (5s @ 44.1kHz WMA Lossless, .wma 扩展名)
  sample.mka_flac  (5s @ 44.1kHz FLAC in MKA)
  sample.dsf64     (5s @ DSD64)
  sample.dsf1024   (2s @ DSD1024)
```

**测试断言**:
```swift
runTest("decodeAPESampleFullLength") {
    let decoder = try DecoderRegistry.shared.makeDecoder(for: sampleAPEURL)
    let expectedFrames = 5 * 44100
    var totalFrames = 0
    while !decoder.isAtEnd {
        totalFrames += try decoder.decode(buffer: buf, maxFrames: 4096)
    }
    try assertEqual(totalFrames, expectedFrames, tolerance: 1)
}
// ... 类似 6 个测试
```

不做 bit-exact PCM 比对（Q23），只校验帧数 + 无错误码。

### 3.8 EQ UI 专业化（E1-E8）

#### E1 非对称 attack/release

```swift
public init(bandCount: Int, fftSize: Int, sampleRate: Float,
            attackTime: Float = 0.05,    // 50ms
            releaseTime: Float = 0.3)    // 300ms
```

每帧：
```swift
let target = newBands[i]
let current = smoothedBands[i]
let coef = (target > current) ? attackCoef : releaseCoef
smoothedBands[i] = current + (target - current) * coef
```

`attackCoef = 1 - exp(-1 / (attackTime * frameRate))`。

#### E2 EQ canvas 频谱叠加

EQ 视图新增半透明源频谱图层（EQ-pre，在 EQ 处理之前采样）。颜色/透明度评审时定（默认建议：蓝绿色 alpha 0.3）。

#### E3 数字字段双击编辑

每个 freq/gain/Q 数字字段：
- 单击：保持滑动手势
- 双击：变成可编辑 TextField，光标定位
- 解析规则:
  - `8.2k` / `8200` → 8200 Hz
  - `+3dB` / `3` → +3.0 dB
  - `0.7` → Q = 0.7
- 失焦或 Enter 确认；Esc 取消

#### E4 Option-drag 改 Q

ParametricEQEditor 鼠标处理:
- 普通拖动：改 freq (X) + gain (Y)
- Option+拖动：垂直方向改 Q（向上窄、向下宽）
- 滚轮：维持现有 Q 调整行为

#### E5 LP/HP 滤波器

`FilterType` enum 新增:

```swift
public enum FilterType {
    case peak, lowShelf, highShelf  // 已有
    case lowPass12, highPass12      // 新增（RBJ 12 dB/oct）
    // UI 预留 slope 字段：v1.7 只支持 12 dB/oct，v1.8 可能加 24/48
}
```

系数计算参考 RBJ Audio EQ Cookbook LPF/HPF 公式。

#### E6 A/B 双槽

```swift
public extension AudioPreferences {
    var eqSlotA: Data? { /* JSON */ }
    var eqSlotB: Data? { /* JSON */ }
    var activeEQSlot: String { /* "A" or "B" */ }
}
```

UI:
- EQ Panel 顶部 [A] [B] 切换按钮，高亮当前活动
- B 键快捷键 → 切换 A↔B
- "Copy A→B" 按钮（B 槽为空时高亮提示）

#### E7 系数线性插值

`ParametricEQNode` 每个 process block 开头检测系数变化:

```swift
if pendingCoefs != currentCoefs {
    // 块内线性插值: c(t) = currentCoefs + (pendingCoefs - currentCoefs) * t/N
    // N = block size; ~93ms 过渡时间通过分多块完成
}
```

消除参数突变的 click。

#### E8 AutoEQ 耳机型号提取

`AutoEQParser`:

```swift
public struct AutoEQResult {
    public let bands: [EQBand]
    public let headphoneName: String?  // 新增
}

// 文件名格式：
// "Sennheiser HD 600 ParametricEQ.txt" → "Sennheiser HD 600"
// "Audeze LCD-X 2021 ParametricEQ.txt" → "Audeze LCD-X 2021"
```

EQ Panel 状态栏:
```
当前耳机: Sennheiser HD 600    A 槽: 10 bands    [A] [B]   Copy A→B
```

---

## 4. 验收标准（汇总）

### v1.6 验收

| 项 | 验收点 |
|----|--------|
| 格式 | 拖入 WMA Lossless / WMA v2 / `.mka`(FLAC) / `.mka`(Opus) 均能完整播完 |
| DSD1024 | 一个 DSD1024 文件完整播完，无杂音，无 underrun |
| 不支持 codec | `.mka`(AC-3) 显示灰色 + 正确 tooltip，自动跳过 |
| 元数据 | WMA / `.mka` 文件库视图正确显示 title/artist/album/封面 |
| 频谱 bug | 20 Hz / 1 kHz / 10 kHz 单频测试在对应频段亮起 |
| CPU 监控 | 偏好开关启用后，HUD 显示稳定数值 |
| 测试 | `swift test` 全绿，新增 6 个 sample decoder 测试通过 |
| 升级 | v1.5.11 用户升级后 EQ 配置自动出现在 A 槽 |

### v1.7 验收

| 项 | 验收点 |
|----|--------|
| 非对称平滑 | 频谱响应：beat drop 立刻顶起，长尾衰减自然 |
| 频谱叠加 | EQ canvas 上可见半透明源频谱，颜色对比舒适 |
| 双击编辑 | `8.2k` 输入正确解析为 8200，所有字段可编辑 |
| Option-Q | Option+拖动竖直方向 50px → Q 变化幅度可感知（建议 ±0.5） |
| LP/HP | LP @ 200Hz 截断高频可听见；HP @ 5kHz 截断低频可听见 |
| A/B | B 键 1 秒内 toggle 流畅，无 click 噪音 |
| 系数插值 | 大幅改 Q（0.3 → 5.0）瞬间不再有 click 噪音 |
| AutoEQ | 拖入 "Sennheiser HD 600 ParametricEQ.txt" 后状态栏正确显示 |

---

## 5. 风险与待定项

### 5.1 已知风险

| 风险 | 缓解 |
|------|------|
| FFmpeg 重编可能破坏现有 APE 解码（v1.5.11 刚修好） | F10 端到端测试覆盖；如出问题立即 rollback FFmpeg 二进制 |
| DSD1024 在 SincResampler 0.068× 比例下可能混叠 | v1.6 实测，必要时下次迭代加中间抽取级 |
| EQ A/B 双写 UserDefaults 在频繁切换时 IO 开销 | 节流写入（500ms debounce），避免每次 toggle 立即落盘 |
| 系数线性插值在小块（< 64 samples）时过渡不平滑 | 块大小由 CoreAudio 决定，最小 256 samples 起步，可接受 |
| 双击编辑与单击拖动手势冲突 | 250ms 双击窗口检测，500ms 内只有第二击且无拖动才进入编辑 |

### 5.2 评审时再定的细节

- v1.6 元数据回退是否包含 ReplayGain 标签
- v1.7 A/B 槽是否需要 A 键（除 B 键外）的快捷键
- v1.7 频响图上 LP/HP 是否绘制陡降曲线（vs 通用钟形）
- v1.7 频谱叠加默认颜色 / 透明度

### 5.3 性能预算目标

| 场景 | 目标 audio thread CPU（M1） |
|------|----------------------------|
| FLAC 44.1k + 6 段 EQ + 频谱 | < 5% |
| DSD64 + 6 段 EQ + 频谱 | < 10% |
| DSD1024 (768k) + 6 段 EQ + 频谱 | < 25% |
| 任何场景 | DSP buffer 利用率 < 80% (绿色 HUD) |

超过即在 HUD 上变黄，> 95% 变红。

---

## 6. 发布计划

### v1.6 (目标: 2-3 周开发周期)

第 1 周:
- F1 (FFmpeg 重编) → F2/F3 (.mka/.wma/WMA Lossless 验证) → F8 (metadata 回退)

第 2 周:
- F4/F5 (DSD1024) → F6 (频谱 bug) → F7 (codec UI) → F9 (CPU HUD)

第 3 周:
- F10 (端到端测试) → F11 (DSD 偏好) → F12 (EQ 迁移) → 集成测试 → 发布

### v1.7 (目标: 3-4 周开发周期)

第 1 周:
- E5 (LP/HP filter) → E7 (系数插值) — DSP 后端

第 2 周:
- E1/E2 (频谱非对称 + EQ canvas 叠加) — 视觉

第 3 周:
- E3/E4 (双击编辑 + Option-Q) → E6 (A/B 双槽)

第 4 周:
- E8 (AutoEQ 耳机名) → polish → 发布

---

## 7. 决策日志（grilling 28 题来源索引）

| Q | 决策 |
|---|------|
| Q1 | 目标用户: 中文 HiFi 烧友（外接 DAC + 大本地库） |
| Q2 | 定位: 专业级 DSP/EQ 工具箱 |
| Q3 | EQ 范围: 耳机修正 + 个性化微调 |
| Q4 | 工作流: 导入即用 + 偶尔微调 |
| Q5 | 视觉反馈: 源频谱 EQ-pre 半透明叠加 |
| Q6 | 频谱分辨率: 复用现有 48-band SpectrumAnalyzer |
| Q7 | 频谱时间响应: 非对称 attack/release |
| Q8 | 数字输入: 双击编辑 + 单位解析 |
| Q9 | Q 曲线交互: Option-drag + 保留滚轮 |
| Q10 | 滤波器: 加 LP/HP (RBJ 12 dB/oct) |
| Q11 | A/B 比较: 双槽 + B 键 toggle |
| Q12 | 系数过渡: 块级线性插值 ~93ms |
| Q13 | 耳机识别: AutoEQ 文件名提取 + 状态栏标签 |
| Q14 | 格式覆盖: 修 .mka/.wma + WMA Lossless + DSD1024 |
| Q15 | DSD1024 输出: 只走 PCM 下采样 |
| Q16 | DSD1024 PCM 上限: 默认 384k，可选 768k |
| Q17 | SRC 实现: 复用 DSD2PCM + SincResampler |
| Q18 | DSD 速率校验: 严格 allowlist 5 项 |
| Q19 | DAC 探测: `.dsd1024` 永远 false，不加字段 |
| Q20 | FFmpeg codec 范围: asf+matroska + 全套 WMA |
| Q21 | 元数据策略: FFmpeg 回退 + 封面 |
| Q22 | 版本切分: v1.6 格式 + v1.7 EQ |
| Q23 | 测试策略: 样本文件端到端 |
| Q24 | 不支持 codec: 标灰 + tooltip + 跳过 |
| Q25 | 性能监控: 轻量 HUD |
| Q26 | 持久化: 扩展 AudioPreferences |
| Q27 | 迁移策略: 旧 key → A 槽，双写保留 |
| Q28 | Grilling 收尾: 进入 PRD |
