# F10 — 样本文件端到端解码测试

**Milestone**: v1.6
**Depends on**: F1, F2, F3, F4
**Blocks**: 无（但是 v1.6 发布前置）
**估时**: 1.5 天

## 上下文

v1.5.x APE 6 秒 bug 在用户手上爆发，根因是单元测试只覆盖了「Factory 能识别 .ape」，没有覆盖「能完整解出 240 秒的 PCM」。需要建立 sample-based 端到端解码测试，杜绝同类回归。

根据 grilling 决策（Q23）：加 sample 文件 + 断言总帧数 + 无错误码。**不做** bit-exact PCM 比对（样本会太大）。

## 范围

### 1. 准备样本文件

新建 `Tests/Resources/` 目录，放入：

| 文件名 | 内容 | 时长 | 预期帧数 |
|--------|------|------|---------|
| `sample.ape` | 5s @ 44.1kHz int24 stereo（APE Normal compression） | 5s | 220500 |
| `sample.wma` | 5s @ 44.1kHz WMA v2 stereo | 5s | 220500 |
| `sample.wmal.wma` | 5s @ 44.1kHz WMA Lossless stereo | 5s | 220500 |
| `sample.mka` | 5s @ 44.1kHz FLAC-in-MKA stereo | 5s | 220500 |
| `sample.dsf64.dsf` | 5s @ DSD64 stereo | 5s | 14_112_000 DSD samples |
| `sample.dsd1024.dsf` | 2s @ DSD1024 stereo（如能找到/合成） | 2s | 90_316_800 DSD samples |

总体积目标 < 10 MB。git 直接提交（不用 LFS）。

生成方法：
```bash
# 起点：5s 44.1k stereo WAV（440Hz + 880Hz 双频）
ffmpeg -f lavfi -i "sine=frequency=440:duration=5:sample_rate=44100" \
       -f lavfi -i "sine=frequency=880:duration=5:sample_rate=44100" \
       -filter_complex "amerge=inputs=2" -ac 2 -y sample.wav

# APE
ffmpeg -i sample.wav -c:a ape sample.ape
# WMA v2
ffmpeg -i sample.wav -c:a wmav2 sample.wma
# WMA Lossless
ffmpeg -i sample.wav -c:a wmalossless sample.wmal.wma
# MKA-FLAC
ffmpeg -i sample.wav -c:a flac -f matroska sample.mka
# DSD64 - 需要 ffmpeg 支持 dsd 编码或用其他工具
```

DSD 文件可能需要 SACD 工具或 HQPlayer 上变换；找现成的公开 demo 即可。

### 2. 测试套件

`Tests/PurePlayCoreTests/TestRunner.swift` 末尾新增：

```swift
runTest("decodeAPESampleFullLength") {
    let url = testResourceURL("sample.ape")
    try assertDecodedFrameCount(url, expected: 220500, tolerance: 1)
}

runTest("decodeWMAv2SampleFullLength") {
    let url = testResourceURL("sample.wma")
    try assertDecodedFrameCount(url, expected: 220500, tolerance: 1)
}

runTest("decodeWMALosslessSampleFullLength") {
    let url = testResourceURL("sample.wmal.wma")
    try assertDecodedFrameCount(url, expected: 220500, tolerance: 1)
}

runTest("decodeMKAFLACSampleFullLength") {
    let url = testResourceURL("sample.mka")
    try assertDecodedFrameCount(url, expected: 220500, tolerance: 1)
}

runTest("decodeDSD64SampleFullLength") {
    let url = testResourceURL("sample.dsf64.dsf")
    // DSD 帧数会通过 DSD2PCM 转换，应得 5 * 352800 = 1764000 PCM frames @ 352.8k
    try assertDecodedFrameCount(url, expected: 1_764_000, tolerance: 64)
}

#if canImport(CFFmpeg)
runTest("decodeDSD1024SampleFullLength") {
    let url = testResourceURL("sample.dsd1024.dsf")
    // 2 * 384000 = 768000 PCM frames @ 384k
    try assertDecodedFrameCount(url, expected: 768_000, tolerance: 64)
}
#endif

// helper
func testResourceURL(_ name: String) -> URL {
    let testsDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return testsDir.appendingPathComponent("Resources").appendingPathComponent(name)
}

func assertDecodedFrameCount(_ url: URL, expected: Int, tolerance: Int) throws {
    let source = try FileSource(url: url)
    let decoder = try DecoderRegistry.shared.makeDecoder(
        source: source, fileExtension: url.pathExtension.lowercased()
    )
    let buf = UnsafeMutableRawPointer.allocate(byteCount: 4096 * 8, alignment: 16)
    defer { buf.deallocate() }
    var total = 0
    while !decoder.isAtEnd {
        let n = try decoder.decode(buffer: buf, maxFrames: 4096)
        if n == 0 { break }
        total += n
    }
    try assertTrue(abs(total - expected) <= tolerance,
                   "frames=\(total), expected ±\(tolerance) of \(expected)")
}
```

### 3. Package.swift 测试资源声明

```swift
.executableTarget(
    name: "PurePlayTests",
    dependencies: ["PurePlayCore"],
    path: "Tests/PurePlayCoreTests",
    resources: [.copy("../Resources")]   // 新增
)
```

或者通过相对路径直接读（更简单，不走 Bundle.module）。

## 验收

- [ ] 6 个新测试全部通过
- [ ] `swift test` 总时长增加 < 10s
- [ ] APE 解码帧数 = 220500 ± 1（v1.5.11 修复后的回归 guard）
- [ ] WMA Lossless 帧数与 ffprobe 一致
- [ ] `.mka` (FLAC) 帧数与 ffprobe 一致
- [ ] DSD64 PCM 输出帧数 ≈ 5 × 352800 ± 64
- [ ] DSD1024 PCM 输出帧数 ≈ 2 × 384000 ± 64

## 风险

- DSD1024 样本难找；如不可得，可暂时跳过该测试（标 skip）+ 用 DSF 头部 manual 校验代替
- 样本文件不能侵犯版权（用纯音生成，不用商业音乐）
- 二进制 sample 进 git，未来要慎重——若样本数 > 20 个，考虑迁移到 git-lfs

## 文件

- `Tests/Resources/`（新增 6 个样本）
- `Tests/PurePlayCoreTests/TestRunner.swift`（新增 6 个测试）
- `Package.swift`（resources 声明，如需要）
