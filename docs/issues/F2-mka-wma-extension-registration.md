# F2 — `.mka` / `.wma` 扩展名注册与端到端验证

**Milestone**: v1.6
**Depends on**: F1
**Blocks**: F10 (端到端测试)
**估时**: 1 小时

## 上下文

F1 完成后，FFmpeg 已能解析 asf/matroska 容器并解码 WMA。但 `FFmpegDecoderFactory` 的 `supportedExtensions` 集合可能尚未包含 `wma`/`mka`，需要在注册表层补上。

## 范围

1. 查找 `FFmpegDecoderFactory.supportedExtensions`：

```bash
grep -rn "supportedExtensions" Sources/PurePlayCore/Decoder/
```

2. 把 `wma`、`mka` 加入：

```swift
public static let supportedExtensions: Set<String> = [
    "ape", "wv", "tta", "ogg", "opus",
    "wma", "mka",   // 新增
]
```

3. 在 `Tests/PurePlayCoreTests/TestRunner.swift:3777` 的 `ffmpegDecoderFactoryExtensions` 测试中补对应断言：

```swift
try assertTrue(FFmpegDecoderFactory.supportedExtensions.contains("wma"))
try assertTrue(FFmpegDecoderFactory.supportedExtensions.contains("mka"))
```

4. 手动验证：
   - 拖一个 `.wma`（v2 或 lossless）到 PurePlay，能进入播放列表并完整播完
   - 拖一个 `.mka`（FLAC 内嵌）能完整播完

## 验收

- [ ] FFmpegDecoderFactory 识别 `.wma` / `.mka` 扩展名
- [ ] TestRunner 新断言通过
- [ ] 手动播放 `.wma`（v2/lossless 各一）成功
- [ ] 手动播放 `.mka`（FLAC 内嵌）成功

## 文件

- `Sources/PurePlayCore/Decoder/FFmpegDecoder.swift`
- `Tests/PurePlayCoreTests/TestRunner.swift:3777`
