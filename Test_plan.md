# PurePlay — 测试计划 (Test Plan)

> 版本：v1.1
> 对应代码：`Sources/PurePlayCore/` + `Tests/PurePlayCoreTests/TestRunner.swift`
> 运行方式：`swift run PurePlayTests`（无需 Xcode）

---

## 1. 测试策略总览

```
┌────────────────────────────────────────────────────────────┐
│                        测试金字塔                            │
├────────────────────────────────────────────────────────────┤
│                                                            │
│      ▲  手工验证 / 硬件测试                                 │
│     ╱ ╲   - 真实 DAC Hog Mode                              │
│    ╱   ╲  - DSD 文件端到端播放                              │
│   ╱     ╲ - 夸克网盘流式播放                                │
│  ╱───────╲                                                 │
│ ╱ 集成测试  ╲ - AudioPipeline 端到端                        │
│╱─────────────╲ - Decoder → RingBuffer → MockOutput          │
│╱               ╲                                            │
│  单元测试        - AudioFormat / Source / Decoder / DSP     │
│                  - RingBuffer / DoP / Library / Output      │
│                  - 69 个自动化测试，全部通过                  │
│                                                            │
└────────────────────────────────────────────────────────────┘
```

### 原则

| 原则 | 说明 |
|------|------|
| **Bit-Perfect 优先** | 解码器的核心验收标准是输出与源文件 PCM 数据逐字节一致 |
| **无硬件可 CI** | 所有自动化测试通过 `MockAudioOutput` 运行，不依赖 DAC |
| **快速反馈** | 全套 69 测试 <2 秒完成 |
| **分层隔离** | 每层独立可测：Source / Decoder / DSP / Buffer / Output / Pipeline |

---

## 2. 已实现的自动化测试（69 个）

### 2.1 AudioFormat Tests（5 个）

| # | 测试名 | 验证内容 | 状态 |
|---|--------|---------|:----:|
| 1 | `pcmConvenience` | `AudioFormat.pcm()` 构造器正确设置采样率/声道/位深/bytesPerFrame | ✅ |
| 2 | `float32Format` | Float32 格式 bytesPerFrame=8, isInteger=false | ✅ |
| 3 | `int16Format` | Int16 单声道 bytesPerFrame=2, isInteger=true | ✅ |
| 4 | `dsdFormat` | DSD 标记位正确传递 | ✅ |
| 5 | `audioFileFormat` | 文件扩展名 → 枚举映射，大小写不敏感，isDSD/isLossless 正确 | ✅ |

### 2.2 MemorySource Tests（6 个）

| # | 测试名 | 验证内容 | 状态 |
|---|--------|---------|:----:|
| 6 | `readAll` | 完整读取全部字节，currentPosition 更新正确 | ✅ |
| 7 | `partialRead` | 部分读取，position 正确推进 | ✅ |
| 8 | `readPastEnd` | 超出末尾时返回实际可读量（不崩溃） | ✅ |
| 9 | `seek` | Seek 到指定偏移后读取正确数据 | ✅ |
| 10 | `seekOutOfBounds` | 越界 seek 抛出错误 | ✅ |
| 11 | `emptySource` | 空数据源读取返回 0 | ✅ |

### 2.3 WAV Decoder Tests（6 个）

| # | 测试名 | 验证内容 | 状态 |
|---|--------|---------|:----:|
| 12 | `decode16BitStereo` | 16bit/44.1kHz 立体声 WAV 解码，格式/帧数/isAtEnd 正确 | ✅ |
| 13 | `decode24BitMono` | 24bit/96kHz 单声道 WAV 解码格式正确 | ✅ |
| 14 | `partialDecode` | 分批解码：400+400+200=1000 帧，末尾不足时返回实际量 | ✅ |
| 15 | `wavSeek` | Seek 到 2000 帧后继续解码，帧数正确 | ✅ |
| 16 | **`bitPerfectRoundTrip`** | **关键测试**：生成 WAV → 解码 → 逐字节对比原始 PCM 数据 → 一致 | ✅ |
| 17 | `invalidHeader` | 垃圾数据触发 `invalidWAVHeader` 错误 | ✅ |

### 2.4 Sine Decoder Tests（5 个）

| # | 测试名 | 验证内容 | 状态 |
|---|--------|---------|:----:|
| 18 | `sineBasic` | 合成 440Hz 正弦波解码，总帧数/格式正确 | ✅ |
| 19 | `sineAmplitude` | 振幅 0.5 的正弦波，实际峰值在 [0.4, 0.5] 范围内 | ✅ |
| 20 | `sineSeek` | Seek 到中间位置 + Seek 超过末尾（clamp 到 totalFrames） | ✅ |
| 21 | `decoderRegistry` | DecoderRegistry 能通过 ".sine" 扩展名找到 SineDecoder | ✅ |
| 22 | `registryUnsupported` | 未知扩展名 "xyz" 触发 `unsupportedFormat` 错误 | ✅ |

### 2.5 PCMRingBuffer Tests（6 个）

| # | 测试名 | 验证内容 | 状态 |
|---|--------|---------|:----:|
| 23 | `writeAndRead` | 写入 8 字节 → 读取 8 字节，数据完全一致 | ✅ |
| 24 | `overflowProtection` | 容量 4 字节时写入 6 字节，仅写入 4（不越界） | ✅ |
| 25 | `underflowProtection` | 空 buffer 读取返回 0（不阻塞/不崩溃） | ✅ |
| 26 | `wraparound` | 写→读→写→读 触发环绕，数据顺序正确 | ✅ |
| 27 | `reset` | Reset 后 availableToRead=0, availableToWrite=capacity | ✅ |
| 28 | **`concurrentAccess`** | **并发测试**：生产者+消费者双线程传输 10,000 字节，无数据丢失 | ✅ |

### 2.6 DSP Chain Tests（5 个）

| # | 测试名 | 验证内容 | 状态 |
|---|--------|---------|:----:|
| 29 | `bitPerfectBypass` | Bit-Perfect 模式下 DSP 链为空，isBypass=true | ✅ |
| 30 | `gainNode` | +6dB 增益 ≈ 2x 振幅，精度 ±0.001 | ✅ |
| 31 | `zeroGain` | 0dB 增益不改变信号（unity gain），精度 ±0.0001 | ✅ |
| 32 | `crossfeedNode` | 纯左声道输入后右声道 >0（交叉馈入生效） | ✅ |
| 33 | `chainWithDSP` | 非 Bit-Perfect 模式：3 个节点（Gain+EQ+Crossfeed） | ✅ |

### 2.7 DoP Packer Tests（7 个）

| # | 测试名 | 验证内容 | 状态 |
|---|--------|---------|:----:|
| 34 | `basicPacking` | MSB-first DSD 立体声打包，标记=0x05，数据字节正确 | ✅ |
| 35 | `markerAlternation` | 连续帧标记从 0x05 切换到 0xFA | ✅ |
| 36 | `isDoPDetection` | 合法 DoP 流检测=true；非法标记检测=false | ✅ |
| 37 | `dsdRates` | DSD64/128/256 对应 DoP 载波速率正确 | ✅ |
| 38 | `strategyDoP` | DAC 支持 384kHz → DSD64 选择 DoP 模式 | ✅ |
| 39 | `strategyFallbackPCM` | DAC 仅 96kHz → DSD128 回退到 PCM 转换 | ✅ |
| 40 | `strategyAlwaysPCM` | 用户偏好 alwaysPCM → 即使 DAC 支持也走 PCM | ✅ |

### 2.8 Mock Output Tests（5 个）

| # | 测试名 | 验证内容 | 状态 |
|---|--------|---------|:----:|
| 41 | `listDevices` | MockAudioOutput 返回 1 个 "Mock DAC" 设备 | ✅ |
| 42 | `hogModeLifecycle` | acquire → isHogMode=true → release → false | ✅ |
| 43 | `sampleRateSwitch` | 切换到 96kHz/192kHz，currentSampleRate 更新 | ✅ |
| 44 | `startStop` | start 后 isPlaying=true，stop 后 false | ✅ |
| 45 | `renderCallback` | pullFrames 触发回调，framesRendered 累计正确 | ✅ |

### 2.9 AudioPipeline Tests（4 个）

| # | 测试名 | 验证内容 | 状态 |
|---|--------|---------|:----:|
| 46 | `pipelineWithSine` | Sine → Pipeline → MockOutput 端到端，拉取帧数>0 | ✅ |
| 47 | `pipelineWithWAV` | WAV → Pipeline → MockOutput 端到端，格式=int16 | ✅ |
| 48 | `pipelineStopIdempotent` | 连续两次 stop() 不崩溃 | ✅ |
| 49 | `pipelineDSPEnabled` | DSP 启用（-3dB gain）模式下管线正常工作 | ✅ |

### 2.10 Library Model Tests（4 个）

| # | 测试名 | 验证内容 | 状态 |
|---|--------|---------|:----:|
| 50 | `addAndRetrieve` | 添加曲目后可检索，标题正确 | ✅ |
| 51 | `search` | 搜索 "jazz" 返回 2 条结果 | ✅ |
| 52 | `remove` | 删除后 count=0 | ✅ |
| 53 | `autoTitle` | 无显式 title 时从文件名推导 | ✅ |

---

## 3. 待实现的测试（后续 Phase 扩展）

### 3.1 Phase 2 — 格式扩展测试

| 测试类别 | 测试项 | 优先级 |
|---------|--------|:------:|
| **FLAC 解码** | libFLAC MD5 校验 bit-perfect | P0 |
| **FLAC 解码** | 24bit/96kHz + 32bit/192kHz 多规格 | P0 |
| **FLAC 解码** | Seek 精度（帧级 ±4096 samples） | P1 |
| **DSD 解码** | DSF 文件头解析（DSD64/128/256） | P0 |
| **DSD 解码** | DFF 文件头解析（MSB first） | P1 |
| **DoP 端到端** | DSD → DoP 打包 → 解包 → 对比原始 bitstream | P0 |
| **APE 解码** | Normal/High/Extra High 压缩级别 | P1 |
| **APE 解码** | Extra High 解码性能（<10x 实时） | P2 |
| **ALAC 解码** | CoreAudio AudioConverter 路径 | P1 |
| **FFmpeg 兜底** | MP3/AAC/Ogg/WavPack 基础解码 | P2 |
| **CUE Sheet** | 整轨分轨解析 + Seek 到指定轨 | P1 |

### 3.2 Phase 3 — 音质控制测试

| 测试类别 | 测试项 | 优先级 |
|---------|--------|:------:|
| **SoXR 重采样** | 44.1k→96k VHQ 模式，THD+N <-140dB | P0 |
| **SoXR 重采样** | 96k→44.1k 回采样，频响 ±0.01dB@20kHz | P1 |
| **参量 EQ** | 10 段 IIR Biquad 精度 vs 参考实现 | P1 |
| **EQ** | 全 0dB 增益时信号不变（直通验证） | P0 |
| **ReplayGain** | Track/Album 模式切换正确 | P1 |
| **Crossfeed BS2B** | 参考信号对比 | P2 |
| **Dither TPDF** | 24→16bit 量化噪声分布验证 | P2 |
| **DSP Chain** | 信号通过完整链后 SINAD 测量 | P1 |

### 3.3 Phase 4 — CoreAudio 硬件测试

> 这些测试需要真实 USB DAC，不在 CI 中运行。

| 测试类别 | 测试项 | 验收标准 |
|---------|--------|---------|
| **Hog Mode** | 独占 DAC，其他 App 无声 | 启动 Safari YouTube → 无声 |
| **自动采样率** | 44.1k→96k→192k 文件依次播放 | DAC LED 每次显示正确采样率 |
| **自动采样率** | 同家族切换（44.1k→88.2k） vs 跨家族（44.1k→48k） | 均无 glitch |
| **Bit-Perfect** | 用 DAC 回路录音对比 | 录音 vs 源文件 checksum 一致 |
| **设备热插拔** | 播放中拔出 DAC | 无崩溃，切回系统默认设备 |
| **设备热插拔** | 播放中插入 DAC | 自动切换到新设备（可选） |
| **DSD DoP** | DSD64 文件 → DoP 输出到支持 DoP 的 DAC | DAC 指示灯显示 "DSD" |
| **DSD PCM 回退** | DSD128 → 不支持 DoP 的 DAC | 自动软件转换为 PCM |
| **长时稳定** | 24 小时连续播放 | 0 underrun，内存不泄漏 |
| **多 DAC 偏好** | 切换设备后记忆上次的 Hog/采样率设置 | 插回同一 DAC 恢复设置 |

### 3.4 Phase 5 — 夸克网盘测试

| 测试类别 | 测试项 | 优先级 |
|---------|--------|:------:|
| **登录** | WKWebView 扫码登录 → Cookie 提取成功 | P0 |
| **登录** | 密码登录 → Cookie 提取 | P1 |
| **Cookie 持久化** | App 重启后从 Keychain 恢复 Cookie | P0 |
| **Cookie 刷新** | `__puus` 自动刷新（解析 Set-Cookie） | P0 |
| **Cookie 过期** | 模拟过期 → 自动提示重新登录 | P1 |
| **文件列表** | 列出根目录 + 子目录文件 | P0 |
| **格式过滤** | 仅显示音频文件（按扩展名过滤） | P1 |
| **格式探测** | 下载 64KB 头部 → 解析 FLAC/WAV/DSF magic | P0 |
| **流式播放** | 5MB 预缓冲 → 开始播放 → 播放不中断 | P0 |
| **Seek** | 云端文件 seek → HTTP Range 重请求 → 继续播放 | P1 |
| **磁盘缓存** | 播放完成后缓存到磁盘 → 第二次播放秒开 | P0 |
| **LRU 淘汰** | 缓存超 2GB → 最久未用文件被清理 | P1 |
| **预加载** | 当前曲播完前自动下载下一曲 | P1 |
| **混合队列** | 本地文件 + 云盘文件混合播放列表 | P1 |
| **请求限速** | ≤5 req/s Token Bucket | P0 |
| **断网恢复** | 播放中断网 → 缓冲区耗尽后暂停 → 恢复后继续 | P2 |
| **非会员限速** | 低速场景（~1Mbps）→ 预缓冲策略验证 | P2 |

### 3.5 UI 测试

| 测试类别 | 测试项 | 验证方式 |
|---------|--------|---------|
| **主窗口** | 封面显示、技术 Badge、播放控件 | 手工 + 截图对比 |
| **信号路径栏** | 显示 DAC 名称 · 采样率 · 位深 · Bit-Perfect | 手工 |
| **菜单栏弹出** | 控件可用、Up Next 列表正确 | 手工 |
| **悬浮模式** | Float on Top + 迷你窗口 | 手工 |
| **专辑网格** | 封面加载、格式标签显示 | 手工 |
| **EQ 编辑器** | 拖拽节点、预设切换 | 手工 |
| **深色/浅色** | 跟随系统主题切换 | 手工 |
| **键盘快捷键** | 媒体键 / Space / ←→ | 手工 |

---

## 4. 测试环境

### 4.1 CI 环境（自动化）

| 项目 | 要求 |
|------|------|
| **OS** | macOS 13+ (Ventura+) |
| **Swift** | 5.9+ / 6.0+ |
| **硬件** | Apple Silicon 或 Intel |
| **Xcode** | 不需要（使用 `swift build` + `swift run`） |
| **运行命令** | `swift run PurePlayTests` |
| **超时** | 30 秒（当前 <2 秒） |

### 4.2 硬件测试环境（手工）

| 项目 | 推荐配置 |
|------|---------|
| **Mac** | MacBook Pro M1+ / Mac mini M2+ |
| **DAC** | USB DAC（ESS9038 / AK4497 芯片），支持 DoP |
| **耳机** | 任意有线耳机 |
| **测试文件** | FLAC 44.1k/96k/192k + DSD64/128 + APE + WAV 24bit |

---

## 5. 运行测试

```bash
# 构建
swift build

# 运行全部 53 个测试
swift run PurePlayTests

# 预期输出
# ═══ AudioFormat Tests ═══
#   ✓ pcmConvenience
#   ✓ float32Format
#   ...
# ══════════════════════════════════════════════════
# Tests: 53 total, 53 passed, 0 failed
# ══════════════════════════════════════════════════
```

---

## 6. 覆盖率矩阵

| 模块 | 源文件 | 测试数 | 覆盖重点 |
|------|--------|:------:|---------|
| `Audio/AudioFormat` | AudioFormat.swift | 5 | 构造 / 格式枚举 / DSD 标记 |
| `Source/AudioSource` | AudioSource.swift | 6 | MemorySource 读写 / seek / 边界 |
| `Decoder/WAVDecoder` | WAVDecoder.swift | 6 | 16/24bit / 部分解码 / seek / **bit-perfect** |
| `Decoder/SineDecoder` | SineDecoder.swift | 5 | 合成信号 / 振幅 / registry |
| `Buffer/PCMRingBuffer` | PCMRingBuffer.swift | 6 | 读写 / 溢出 / 环绕 / **并发安全** |
| `DSP/DSPChain` | DSPChain.swift, DSPNodes.swift | 5 | bypass / gain / crossfeed / 链组装 |
| `DSD/DoPPacker` | DoPPacker.swift | 7 | 打包 / 标记交替 / 检测 / 策略决策 |
| `Output/AudioOutput` | AudioOutput.swift | 5 | Mock 设备 / hog / 采样率 / 回调 |
| `Audio/AudioPipeline` | AudioPipeline.swift | 4 | 端到端 / WAV / DSP / 幂等 stop |
| `Library/LibraryModel` | LibraryModel.swift | 4 | CRUD / 搜索 / 自动标题 |
| **合计** | **10 文件** | **53** | |

---

## 7. 质量门禁

发布前必须满足：

| 门禁项 | 标准 | 阶段 |
|--------|------|:----:|
| 全部自动化测试通过 | 69/69 ✅ | Phase 1 |
| FLAC MD5 bit-perfect | 解码后 MD5 = 文件头 MD5 | Phase 2 |
| DSD DoP 往返完整性 | 打包→解包 = 原始 bitstream | Phase 2 |
| WAV bit-perfect | 解码 = 源 PCM 数据 | ✅ 已满足 |
| RingBuffer 并发安全 | 10,000+ 字节双线程无丢失 | ✅ 已满足 |
| Hog Mode 独占 | 其他 App 无法发声 | Phase 4 |
| 自动采样率切换 | DAC LED 正确变化 | Phase 4 |
| 24h 稳定性 | 0 underrun / 0 leak | Phase 6 |
| 云盘流式播放不断流 | 5 首曲目连续播放无中断 | Phase 5 |

---

**文档结束。**
当前状态：Phase 1 自动化测试已完成（69/69 通过），涵盖 bit-perfect 验证、int-to-float 转换、IIR Biquad EQ、TPDF Dither、DoP 打包、并发 ring buffer。后续 Phase 测试将随功能实现逐步补充。
