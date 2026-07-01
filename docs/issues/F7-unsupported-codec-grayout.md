# F7 — 不支持 codec：标灰 + tooltip + 自动跳过

**Milestone**: v1.6
**Depends on**: F1
**Blocks**: 无
**估时**: 1 天

## 上下文

F1 引入 matroska demuxer 后，`.mka` 可能携带 PurePlay 未启用的 codec（AC-3/DTS/TrueHD/MLP/E-AC-3 等）。当前 FFmpegDecoder 初始化失败的行为不明确，可能导致：

- 自动播放队列卡死或弹错误对话框
- 用户不知道为什么这首没播

根据 grilling 决策（Q24）：**标灰 + tooltip + 自动跳过**，不弹对话框、不扩 codec。

## 范围

### 1. 增加明确错误类型

`Sources/PurePlayCore/Decoder/FFmpegDecoder.swift` 或上层 `DecoderError`：

```swift
public enum DecoderError: Error, LocalizedError {
    // 已有 case ...
    case codecNotSupported(codecName: String)   // 新增

    public var errorDescription: String? {
        switch self {
        case .codecNotSupported(let name):
            return "Codec not supported: \(name)"
        // ...
        }
    }
}
```

FFmpegDecoder 初始化检测 `avcodec_find_decoder` 返回 nil 时抛出 `codecNotSupported(codecName: String(cString: avcodec_get_name(codecID)))`。

### 2. 库扫描层捕获错误并标记

`Sources/PurePlayCore/Library/ScanService.swift` 或对应曲目模型加 `unsupportedCodecName: String?` 字段。扫描时尝试 probe（不必完整解码，只用 `avformat_open_input` + `av_find_best_stream` + `avcodec_find_decoder` 验证），失败则填 codec 名。

### 3. 播放队列跳过逻辑

`QueueManager` 检测 `track.unsupportedCodecName != nil` 时：
- 自动跳到下一首
- 不弹对话框
- 不在播放历史记录

### 4. UI 层

`Sources/PurePlayApp/`（曲目列表视图）：
- `track.unsupportedCodecName != nil` 的行 → 灰色文字（约 50% 不透明度）
- 双击/Enter 播放该行 → 短暂提示 toast「不支持的格式：AC-3」
- Hover tooltip：`"Codec not supported: ac3"`

## 验收

- [ ] AC-3 内嵌的 `.mka` 文件加库后显示为灰色
- [ ] Tooltip 正确显示 codec 名（`ac3`、`dts`、`truehd` 等）
- [ ] 自动播放队列遇到灰色行自动跳过，不弹对话框
- [ ] 双击灰色行有 toast 提示
- [ ] 库扫描时不会因不支持 codec 崩溃

## 风险

- 库扫描时探测 codec 增加 IO；可缓存到曲目元数据避免重复探测
- 同一 `.mka` 内可能有多个音频流（极少数情况），取 `av_find_best_stream` 选中的那个

## 文件

- `Sources/PurePlayCore/Decoder/FFmpegDecoder.swift`
- `Sources/PurePlayCore/Library/ScanService.swift`
- `Sources/PurePlayCore/Player/QueueManager.swift`
- `Sources/PurePlayApp/`（曲目列表视图）
