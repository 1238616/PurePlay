# F3 — WMA Lossless 解码验证（位深/采样率回归）

**Milestone**: v1.6
**Depends on**: F1, F2
**Blocks**: F10
**估时**: 2 小时

## 上下文

WMA Lossless 解码器（wmalossless）的输出 sample format 可能是 S16/S24/S32（packed 或 planar），需要确保现有 FFmpegDecoder 的 `processFrame` 路径正确处理。v1.5.11 修复 APE 的相关 bug 后，FFmpegDecoder 已对位深做了正确判定（codec.sample_fmt + bits_per_coded_sample 回退），但 WMA Lossless 与 APE 的元数据字段填充习惯可能不同。

## 范围

1. 准备测试样本（找几个真实 WMA Lossless 文件，覆盖）：
   - 16-bit 44.1k 立体声
   - 24-bit 96k 立体声（如果能找到）

2. 用现有 ProbeAPE-style 调试套路（已删除，但模式可复用）单独跑 WMA Lossless 文件，对比：
   - ffmpeg CLI 解出的总帧数
   - PurePlay FFmpegDecoder 解出的总帧数

3. 如有偏差，对照 `Sources/PurePlayCore/Decoder/FFmpegDecoder.swift` 检查：
   - `codecPar.pointee.bits_per_raw_sample` 是否为 0（如是，已有 fallback 到 `bits_per_coded_sample`）
   - `codec.sample_fmt` 是否正确通过 `av_get_packed_sample_fmt` 处理
   - swresample 输出是否与目标 ASBD 匹配

4. 实测听感：连接 DAC 输出，比对 WMA Lossless 与同源 FLAC，应无可闻差异。

## 验收

- [ ] WMA Lossless 16-bit 文件完整播放，总帧数与 ffprobe 一致 ± 1
- [ ] WMA Lossless 24-bit（若有样本）完整播放
- [ ] 无杂音 / click / 提前 EOF

## 风险

- WMA Lossless 在极少数文件上可能 codec 内部解码失败（FFmpeg 上游已知 bug）；这些走 F7 标灰路径

## 文件

- `Sources/PurePlayCore/Decoder/FFmpegDecoder.swift`（可能微调）
