# F6 — SpectrumAnalyzer 频率轴 bug 修复

**Milestone**: v1.6
**Depends on**: 无
**Blocks**: E1, E2（v1.7 EQ canvas 频谱叠加的前置）
**估时**: 半天

## 上下文

`Sources/PurePlayCore/Audio/SpectrumAnalyzer.swift:72-73` 有逻辑 bug：

```swift
let minLog: Float = log10(20.0)
let maxLog: Float = log10(Float(halfSize - 1))   // ⚠ halfSize 是 bin 数，不是 Hz
```

在 44.1 kHz / 1024-pt FFT 时，bin 索引范围 [0, 511]，对应频率 [0, 22050] Hz。但代码把 bin 索引当 Hz 使用，导致：

- `minLog = log10(20) ≈ 1.301`
- `maxLog = log10(511) ≈ 2.708`
- frac 在 [0, 1] 映射到 log 频率轴范围 [20 Hz, 511 Hz]（错误）

**真实意图** 应当是把 bin 0-511 映射到 Hz 域 [0, 22050]，然后在 [20Hz, 22050Hz] 之间按 log 分配 bandCount 个带。

## 范围

修改 SpectrumAnalyzer 接口以接收采样率，并修正频率→bin 转换：

### 1. 构造器新增 `sampleRate` 参数

```swift
public init(bandCount: Int = 32, fftSize: Int = 1024,
            sampleRate: Float = 44_100,      // 新增
            attackTime: Float = 0.05,         // 同时为 E1 预留
            releaseTime: Float = 0.3) {
    // ...
    self.sampleRate = sampleRate
}

private let sampleRate: Float
```

### 2. process() 内重写频段映射

```swift
let halfSize = fftSize / 2
let binHz = sampleRate / Float(fftSize)   // bin 间隔（Hz）
let minHz: Float = 20.0
let maxHz: Float = sampleRate / 2

var newBands = [Float](repeating: 0, count: bandCount)
let minLog = log10(minHz)
let maxLog = log10(maxHz)
for b in 0..<bandCount {
    let lowFrac = Float(b) / Float(bandCount)
    let highFrac = Float(b + 1) / Float(bandCount)
    let lowHz = pow(10, minLog + (maxLog - minLog) * lowFrac)
    let highHz = pow(10, minLog + (maxLog - minLog) * highFrac)
    let lowIdx = max(1, Int(lowHz / binHz))
    let highIdx = min(halfSize - 1, max(lowIdx + 1, Int(highHz / binHz)))
    var sum: Float = 0
    for i in lowIdx...highIdx { sum += magnitudes[i] }
    let avg = sum / Float(highIdx - lowIdx + 1)
    let db = 10 * log10(max(avg, 1e-9))
    let normalized = max(0, min(1, (db + 60) / 60))
    newBands[b] = normalized
}
```

### 3. 调用方更新

查找所有 `SpectrumAnalyzer(...)` 构造调用：

```bash
grep -rn "SpectrumAnalyzer(" Sources/
```

每处补 `sampleRate:` 参数，传入当前播放采样率。Player 切换曲目时需重建（或加 `setSampleRate(_:)` setter）。

### 4. 测试

`Tests/PurePlayCoreTests/TestRunner.swift` 加单元测试：

```swift
runTest("spectrumAnalyzerFrequencyMapping") {
    let analyzer = SpectrumAnalyzer(bandCount: 32, fftSize: 1024,
                                     sampleRate: 44100, smoothing: 0)
    // 生成 1 kHz 单频
    var samples = [Float](repeating: 0, count: 1024)
    for i in 0..<1024 {
        samples[i] = sin(2 * .pi * 1000 * Float(i) / 44100)
    }
    samples.withUnsafeBufferPointer { ptr in
        analyzer.process(samples: ptr.baseAddress!, frameCount: 1024, channels: 1)
    }
    let bands = analyzer.currentBands()
    // log(1000) 位于 log(20)..log(22050) 的 (3-1.3)/(4.34-1.3) ≈ 0.56 处
    // 32 band 中应在 ~18 号 band 附近达到峰值
    let peakBand = bands.enumerated().max(by: { $0.element < $1.element })?.offset ?? -1
    try assertTrue((16...20).contains(peakBand), "peak band = \(peakBand), expected ~18")
}
```

## 验收

- [ ] 20 Hz / 100 Hz / 1 kHz / 10 kHz 四个单频测试，频谱峰值分别落在对应 band（log 轴上）
- [ ] 不同采样率（44.1k / 96k / 192k / 384k）下频率轴对齐
- [ ] 现有 SpectrumAnalyzer UI 视觉无回归（低频不再被压在最左侧死区）
- [ ] 新单元测试通过

## 风险

- 调用方多处需要更新 `sampleRate` 参数；可以加默认值 44100 缓解
- 这是 E1（attack/release）和 E2（EQ canvas 叠加）的前置；如果 E1/E2 在 v1.7，F6 不能滑出 v1.6

## 文件

- `Sources/PurePlayCore/Audio/SpectrumAnalyzer.swift:72-85`
- 所有 `SpectrumAnalyzer(...)` 调用点
- `Tests/PurePlayCoreTests/TestRunner.swift`（新增单元测试）
