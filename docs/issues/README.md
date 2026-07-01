# Issues — PRD v1.6 / v1.7

每个 issue 是一个**可独立领取的任务**。`/implement` 时把 PRD（`../PRD-v1.6-v1.7.md`）+ 单个 issue 文件传给一个全新的会话。

## v1.6 — 格式 + 基础设施

| # | 标题 | 估时 | 依赖 |
|---|------|------|------|
| [F1](F1-ffmpeg-rebuild-asf-matroska-wma.md) | FFmpeg 重编：补 asf+matroska demuxer + WMA 解码器家族 | 0.5d | — |
| [F2](F2-mka-wma-extension-registration.md) | `.mka`/`.wma` 扩展名注册与端到端验证 | 1h | F1 |
| [F3](F3-wma-lossless-decode-verification.md) | WMA Lossless 解码验证（位深/采样率回归） | 2h | F1, F2 |
| [F4](F4-dsd1024-enum-allowlist.md) | DSD1024 enum / allowlist / PCM 输出路径 | 0.5d | — |
| [F5](F5-dac-probe-dsd1024-false.md) | DACCapabilityProbe 处理 DSD1024（false） | 30m | F4 |
| [F6](F6-spectrum-frequency-axis-bug.md) | SpectrumAnalyzer 频率轴 bug 修复 | 0.5d | — |
| [F7](F7-unsupported-codec-grayout.md) | 不支持 codec：标灰 + tooltip + 跳过 | 1d | F1 |
| [F8](F8-ffmpeg-metadata-fallback.md) | FFmpeg metadata 回退（asf/matroska + 封面） | 1.5d | F1 |
| [F9](F9-performance-hud.md) | 轻量 audio thread CPU% + DSP 延迟 HUD | 1d | — |
| [F10](F10-sample-decode-tests.md) | 样本文件端到端解码测试 | 1.5d | F1-F4 |
| [F11](F11-dsd-pcm-max-preference.md) | DSD PCM 上限偏好（dsdMaxPCMRate） | 0.5d | F4 |
| [F12](F12-eq-migration-v15-to-v16.md) | v1.5 → v1.6 EQ 迁移（单槽 → A 槽 + 双写） | 0.5d | — |

## v1.7 — EQ UI 专业化

| # | 标题 | 估时 | 依赖 |
|---|------|------|------|
| [E1](E1-spectrum-asymmetric-smoothing.md) | SpectrumAnalyzer 非对称 attack/release 平滑 | 0.5d | F6 |
| [E2](E2-spectrum-eq-canvas-overlay.md) | SpectrumAnalyzer 接到 EQ canvas（频谱叠加） | 2d | F6, E1 |
| [E3](E3-double-click-numeric-edit.md) | 数字字段双击编辑 + 单位解析 | 1d | — |
| [E4](E4-option-drag-q.md) | Option-drag 改 Q + 保留滚轮 | 0.5d | — |
| [E5](E5-lowpass-highpass-filters.md) | LP/HP 滤波器（RBJ 12 dB/oct） | 1d | — |
| [E6](E6-eq-ab-slots.md) | A/B EQ 双槽 + B 键切换 + Copy A→B | 2d | F12 |
| [E7](E7-coefficient-interpolation.md) | ParametricEQNode 系数线性插值（~93ms） | 1.5d | — |
| [E8](E8-autoeq-headphone-name.md) | AutoEQ 文件名提取耳机型号 + 状态栏 | 0.5d | — |

## 推荐领取顺序

**v1.6**:
1. 第一波（并行）：F1（FFmpeg 重编，半天阻塞链）、F4（DSD1024 enum）、F6（频谱 bug）、F9（性能 HUD）、F12（EQ 迁移）
2. F1 完成后：F2 → F3、F7、F8
3. F4 完成后：F5、F11
4. 最后：F10（端到端测试，等所有解码路径就绪）

**v1.7**:
1. 并行：E3、E4、E5、E7、E8（互不依赖）
2. F6/E1 完成后：E2
3. F12/E7 完成后：E6
