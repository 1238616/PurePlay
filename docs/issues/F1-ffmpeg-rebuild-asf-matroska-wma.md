# F1 — FFmpeg 重编：补 asf + matroska demuxer 与 WMA 解码器家族

**Milestone**: v1.6
**Depends on**: 无（最先做，是 F2/F3/F8 的前置）
**Blocks**: F2, F3, F8
**估时**: 半天

## 上下文

PurePlay 当前用自编 FFmpeg（仅启用 ape/wavpack/tta/opus/vorbis/flac/aac/alac/mp3/pcm 等），**未启用 asf 和 matroska demuxer**，也**未启用任何 WMA 系列解码器**。这导致：

- `.wma` 文件：demuxer 缺失，`av_open_input` 立即失败
- `.mka` 文件（Matroska 音频）：同样无法打开
- WMA Lossless：即使 demuxer 补上，也没解码器

## 范围

编辑 `scripts/build_ffmpeg.sh`，在 `--disable-everything` 后的 enable 列表中追加：

```diff
-    --enable-demuxer=ape,wv,tta,ogg,opus,flac,wav,aiff,dsf,mov,mp3,aac
+    --enable-demuxer=ape,wv,tta,ogg,opus,flac,wav,aiff,dsf,mov,mp3,aac,asf,matroska
-    --enable-decoder=ape,wavpack,tta,opus,vorbis,flac,pcm_s16le,...,alac
+    --enable-decoder=ape,wavpack,tta,opus,vorbis,flac,pcm_s16le,pcm_s24le,pcm_s32le,pcm_s16be,pcm_s24be,pcm_s32be,pcm_f32le,mp3,aac,alac,wmalossless,wmapro,wmav2,wmav1,wmavoice
```

执行：
1. `./scripts/build_ffmpeg.sh` 重新编译（约 5-10 min）
2. 检查 `Frameworks/FFmpeg/lib/libavcodec.dylib` 体积变化（预估 +50KB）
3. 用 ffprobe 校验：`./Frameworks/FFmpeg/bin/ffprobe -decoders | grep wma` 应该列出 5 项

## 验收

- [ ] 重编后 `libavcodec.dylib` 含 wmalossless/wmapro/wmav2/wmav1/wmavoice 解码器
- [ ] 重编后 `libavformat.dylib` 含 asf 和 matroska demuxer
- [ ] APE / FLAC / Opus 等现有格式无回归（手动播一首确认）
- [ ] dylib 总体积增加 < 200 KB

## 风险

- FFmpeg 重编版本号变化可能引入 ABI 不兼容（unlikely，但需重新 build 整个 app 验证）
- asf 是较老 demuxer，可能在某些畸形 WMA 文件上崩溃；下游 FFmpegDecoder 已有错误码透传

## 文件

- `scripts/build_ffmpeg.sh:54-55`
