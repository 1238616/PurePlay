# E5 — LP/HP 滤波器（RBJ 12 dB/oct）

**Milestone**: v1.7
**Depends on**: 无
**Blocks**: 无
**估时**: 1 天

## 上下文

当前 EQ 只支持 Peak / LowShelf / HighShelf 三种滤波器类型。根据 grilling 决策（Q10）：v1.7 加 LowPass / HighPass（12 dB/oct，RBJ 单 biquad 实现），UI 预留 slope 字段为将来 24/48 dB/oct 占位但不实现。

## 范围

### 1. FilterType enum 扩展

`Sources/PurePlayCore/DSP/`（搜索 `enum FilterType`）:

```swift
public enum FilterType: String, Codable, CaseIterable {
    case peak       = "peak"
    case lowShelf   = "lowShelf"
    case highShelf  = "highShelf"
    case lowPass12  = "lowPass12"    // 新增
    case highPass12 = "highPass12"   // 新增

    public var displayName: String {
        switch self {
        case .peak: return "Peak"
        case .lowShelf: return "Low Shelf"
        case .highShelf: return "High Shelf"
        case .lowPass12: return "Low Pass 12dB/oct"
        case .highPass12: return "High Pass 12dB/oct"
        }
    }

    public var usesGain: Bool {
        switch self {
        case .peak, .lowShelf, .highShelf: return true
        case .lowPass12, .highPass12: return false
        }
    }
}
```

### 2. RBJ 系数计算

`Sources/PurePlayCore/DSP/`（搜索现有 RBJ 实现，参照 LPF/HPF 公式）:

参考：https://www.w3.org/2011/audio/audio-eq-cookbook.html

```swift
func computeCoefficients(type: FilterType, freq: Double, q: Double, gainDB: Double, sampleRate: Double) -> BiquadCoefficients {
    let omega = 2 * .pi * freq / sampleRate
    let sinW = sin(omega)
    let cosW = cos(omega)
    let alpha = sinW / (2 * q)

    switch type {
    case .lowPass12:
        let b0 = (1 - cosW) / 2
        let b1 = 1 - cosW
        let b2 = (1 - cosW) / 2
        let a0 = 1 + alpha
        let a1 = -2 * cosW
        let a2 = 1 - alpha
        return BiquadCoefficients(b0: b0/a0, b1: b1/a0, b2: b2/a0, a1: a1/a0, a2: a2/a0)

    case .highPass12:
        let b0 = (1 + cosW) / 2
        let b1 = -(1 + cosW)
        let b2 = (1 + cosW) / 2
        let a0 = 1 + alpha
        let a1 = -2 * cosW
        let a2 = 1 - alpha
        return BiquadCoefficients(b0: b0/a0, b1: b1/a0, b2: b2/a0, a1: a1/a0, a2: a2/a0)

    case .peak, .lowShelf, .highShelf:
        // 已有实现
    }
}
```

### 3. EQ band model 扩展

```swift
public struct EQBand: Codable {
    public var frequency: Double
    public var gainDB: Double
    public var q: Double
    public var type: FilterType
    public var slope: Slope = .db12       // 新增（占位，目前只支持 db12）
    public var isEnabled: Bool = true

    public enum Slope: String, Codable {
        case db12   // = 1 biquad stage
        // case db24   // = 2 stages, 预留 v1.8
        // case db48   // = 4 stages, 预留 v1.8
    }
}
```

### 4. UI

EQ 编辑器的「滤波器类型」下拉菜单加 Low Pass / High Pass 选项。`slope` 字段在 UI 上以禁用 dropdown 显示「12 dB/oct」（占位，将来启用）。

当用户选择 LP/HP 时，gain 字段隐藏或灰显（`FilterType.usesGain == false`）。

## 验收

- [ ] EQ 编辑器下拉菜单可选 LowPass / HighPass
- [ ] LP @ 200 Hz：播放白噪声，听感上高频被显著衰减；用频谱分析器（外部工具或 F6 修复后的 SpectrumAnalyzer）验证 -3dB 点在 ~200 Hz
- [ ] HP @ 5 kHz：播放白噪声，低频被衰减；-3dB 点在 ~5 kHz
- [ ] 切换 LP/HP 时 gain 字段隐藏或灰显
- [ ] slope 字段在 UI 显示为禁用的「12 dB/oct」
- [ ] LP/HP 也能保存/加载（JSON 编解码正常）
- [ ] LP/HP 在 EQ 曲线视图上正确绘制（陡降形状，不绘制 Peak 钟形）—— 见风险

## 风险

- 当前 EQ 曲线视图可能只支持 Peak 钟形绘制；LP/HP 的可视化要么按通用 frequency response 绘制（推荐），要么先用钟形近似（v1.7 评审时定）
- A/B 槽存储 LP/HP 时，旧 JSON schema 解析新 case 会失败：需在 EQBand Codable 实现里加 `decoderKeyNotFound` fallback 到 `.peak`

## 文件

- `Sources/PurePlayCore/DSP/`（FilterType enum 和 RBJ 系数计算）
- `Sources/PurePlayCore/DSP/`（EQBand model）
- `Sources/PurePlayApp/`（EQ 编辑器 UI）
