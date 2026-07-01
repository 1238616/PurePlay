# E1 — SpectrumAnalyzer 非对称 attack/release 平滑

**Milestone**: v1.7
**Depends on**: F6（频率轴 bug 修复）
**Blocks**: E2
**估时**: 半天

## 上下文

当前 `SpectrumAnalyzer` 用对称 smoothing 系数（默认 0.6），导致频谱响应迟钝：beat drop 不够脆，长尾衰减不够自然。

根据 grilling 决策（Q7）：非对称 attack/release——快攻（信号上升）、慢释（信号衰减），更符合人耳对动态的感知。

## 范围

### 1. 构造器接口

`Sources/PurePlayCore/Audio/SpectrumAnalyzer.swift`：

```swift
public init(bandCount: Int = 32,
            fftSize: Int = 1024,
            sampleRate: Float = 44_100,        // F6 加的
            attackTime: Float = 0.05,           // 50ms 时间常数
            releaseTime: Float = 0.3) {         // 300ms 时间常数
    // 假设 process() 每 fftSize/sampleRate 秒调用一次
    let frameRate = sampleRate / Float(fftSize)   // ≈ 43Hz @ 44.1k/1024
    self.attackCoef = 1 - exp(-1 / (attackTime * frameRate))
    self.releaseCoef = 1 - exp(-1 / (releaseTime * frameRate))
}

private let attackCoef: Float
private let releaseCoef: Float
```

移除原 `smoothing: Float = 0.6` 参数（向后兼容性：保留旧构造器作为 deprecated wrapper）：

```swift
@available(*, deprecated, message: "Use attackTime/releaseTime instead")
public convenience init(bandCount: Int, fftSize: Int, smoothing: Float) {
    let attack = smoothing > 0 ? -1 / (log(1 - smoothing) * 43) : 0.05
    self.init(bandCount: bandCount, fftSize: fftSize,
              attackTime: attack, releaseTime: attack)
}
```

### 2. process() 内平滑逻辑

替换：

```swift
// 原代码：
for i in 0..<bandCount {
    smoothedBands[i] = smoothedBands[i] * smoothing + newBands[i] * (1 - smoothing)
}
```

为：

```swift
for i in 0..<bandCount {
    let target = newBands[i]
    let current = smoothedBands[i]
    let coef = (target > current) ? attackCoef : releaseCoef
    smoothedBands[i] = current + (target - current) * coef
}
```

### 3. 默认值与可调性

UI 不暴露给用户（这是内部美学参数）。如果未来需要，可加偏好开关。

## 验收

- [ ] 单频脉冲测试：1 kHz 突然出现 → 频谱对应 band 在 < 50ms 内达到 90% 目标值
- [ ] 单频脉冲消失后：band 在 > 250ms 后才衰减到 10%
- [ ] 对比 v1.5.x 视觉：beat drop 节奏明显更脆，长尾不卡顿
- [ ] CPU 占用变化 < 0.5%

## 风险

- `exp` 调用在每帧都执行，性能影响极小但需确认（应该在 init 时计算好系数，process 内只查表）
- 不同采样率下 frameRate 不同，attackCoef 会变；F6 已传 sampleRate，可在 init 时正确计算

## 文件

- `Sources/PurePlayCore/Audio/SpectrumAnalyzer.swift:87-90`（平滑循环）
- `Sources/PurePlayCore/Audio/SpectrumAnalyzer.swift:19-33`（构造器）
