# E7 — ParametricEQNode 系数线性插值（块级 ~93ms 过渡）

**Milestone**: v1.7
**Depends on**: 无
**Blocks**: E6 的「无 click 切换」体验
**估时**: 1.5 天

## 上下文

当前 ParametricEQNode 在用户改 freq/Q/gain 时**立即更新系数**，导致 biquad 状态与新系数不匹配，产生明显 click 噪音。在频繁交互（拖动节点、A/B 切换）时尤其严重。

根据 grilling 决策（Q12）：每个 block 开头检测系数变化，把变化在 ~93ms 内分块线性插值过渡。

## 范围

### 1. ParametricEQNode 双系数缓冲

`Sources/PurePlayCore/DSP/ParametricEQNode.swift`（或对应文件）：

```swift
public final class ParametricEQNode {
    private struct Coefficients { var b0, b1, b2, a1, a2: Float }

    // 每个 band 维护当前系数 + 目标系数 + 过渡剩余 block 数
    private struct BandState {
        var current: Coefficients
        var target: Coefficients
        var transitionBlocksRemaining: Int
        var transitionTotalBlocks: Int
        // 双延迟线（biquad state）
        var z1: Float = 0
        var z2: Float = 0
    }

    private var bands: [BandState]
    private let sampleRate: Float

    /// 期望过渡时间：~93ms
    /// 在典型 buffer size 512 samples @ 44.1k 时：~11.6ms/block → 8 blocks
    /// 在 buffer size 256 samples @ 384k 时：~0.67ms/block → 140 blocks
    private let transitionMs: Float = 93

    public func updateBand(_ index: Int, freq: Double, q: Double, gainDB: Double, type: FilterType) {
        let newCoefs = computeCoefficients(...)
        bands[index].target = newCoefs
        let blockMs = Float(currentBlockSize) * 1000.0 / sampleRate
        bands[index].transitionTotalBlocks = max(1, Int(transitionMs / blockMs))
        bands[index].transitionBlocksRemaining = bands[index].transitionTotalBlocks
    }

    public func process(_ samples: UnsafeMutablePointer<Float>, count: Int) {
        for b in 0..<bands.count {
            // 如果在过渡中：本 block 内系数线性插值
            if bands[b].transitionBlocksRemaining > 0 {
                let alpha = 1.0 - Float(bands[b].transitionBlocksRemaining - 1) / Float(bands[b].transitionTotalBlocks)
                let interp = lerp(bands[b].current, bands[b].target, alpha)
                // process 用 interp 作为本 block 的系数（不在 block 内变化，只 block 间变化）
                processBiquadBlock(samples, count: count, coefs: interp, state: &bands[b])
                bands[b].transitionBlocksRemaining -= 1
                if bands[b].transitionBlocksRemaining == 0 {
                    bands[b].current = bands[b].target
                }
            } else {
                processBiquadBlock(samples, count: count, coefs: bands[b].current, state: &bands[b])
            }
        }
    }

    private func lerp(_ a: Coefficients, _ b: Coefficients, _ t: Float) -> Coefficients {
        Coefficients(
            b0: a.b0 + (b.b0 - a.b0) * t,
            b1: a.b1 + (b.b1 - a.b1) * t,
            b2: a.b2 + (b.b2 - a.b2) * t,
            a1: a.a1 + (b.a1 - a.a1) * t,
            a2: a.a2 + (b.a2 - a.a2) * t
        )
    }
}
```

### 2. block-level 插值 vs sample-level 插值的选择

**block-level**（采用）：每个 block 用一组固定系数，block 间线性递进。简单、可向量化、稳定。在 ~93ms 时间常数下用户感知不到台阶。

**sample-level**（不采用）：每个 sample 重算系数。质量略高但 CPU 翻倍，且在 biquad 上系数变化过快可能让 IIR 失稳。

### 3. A/B 切换接入

E6 的 `switchSlot(to:)` 不要直接 rebuild 系数，而是调用 ParametricEQNode 的 `updateAllBands(to: newBands)`，触发整体过渡：

```swift
public func updateAllBands(to bands: [EQBand]) {
    for (i, band) in bands.enumerated() {
        updateBand(i, freq: band.frequency, q: band.q, gainDB: band.gainDB, type: band.type)
    }
}
```

### 4. 边界情况

- band 数量变化（A 有 8 段，B 有 12 段）：扩张时新 band 起点是「直通」系数（b0=1，其余=0），逐步过渡到目标
- band 类型变化（peak→lowPass）：当前/目标系数是不同滤波器类型的系数集，线性插值在 biquad 上仍是合法的（系数空间连续）

### 5. 性能

- 每 block 多一次 lerp（5 个 Float 加法）→ 可忽略
- 不增加 IIR 处理本身的 CPU

## 验收

- [ ] 大幅改 Q（0.3 → 5.0）瞬间不再有 click 噪音（耳朵 + 输出录音 Spectrum 验证）
- [ ] A/B 槽切换无 click 噪音
- [ ] 拖动 EQ 节点连续移动时音质平滑
- [ ] 静音 → 调 EQ → 解除静音：无残留爆音
- [ ] CPU 占用增加 < 0.5%

## 风险

- 极端情况：用户在过渡中再次改系数。需要正确处理：把 `current` 设为当前插值后的值（即不是原 current，而是 lerp 结果），重新启动过渡到新目标
- 不同 sample rate 下 block 数量差异大（DSD1024 768k 时 140 blocks），过渡仍是 ~93ms，行为一致
- biquad 状态（z1/z2）在过渡中不要 reset；继续累积，避免 transient

## 文件

- `Sources/PurePlayCore/DSP/ParametricEQNode.swift`（或对应文件）
- `Sources/PurePlayCore/DSP/EQEngine.swift`（A/B 切换接入）
