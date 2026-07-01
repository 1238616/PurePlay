# F4 — DSD1024 enum / allowlist / PCM 输出路径

**Milestone**: v1.6
**Depends on**: 无
**Blocks**: F5, F11
**估时**: 半天

## 上下文

当前 `DSDRate` enum 只到 DSD512（22.5792 MHz），DSF/DFF 解码器的速率 allowlist 也只覆盖 4 项。需要扩展到 DSD1024（45.1584 MHz）。

根据 grilling 决策（Q15-Q19）：
- DSD1024 **只走 PCM 下采样路径**，不走 DoP（无 DAC 能承载 2822.4 kHz PCM）
- 默认输出 384 kHz PCM，可在偏好里切换到 768 kHz（F11）
- SRC 路径复用现有 `DSD2PCM (8× FIR) + SincResampler`，零架构变更

## 范围

### 1. `DoPPacker.swift`

```swift
public enum DSDRate: Int, CaseIterable, Sendable {
    case dsd64   = 2_822_400
    case dsd128  = 5_644_800
    case dsd256  = 11_289_600
    case dsd512  = 22_579_200
    case dsd1024 = 45_158_400   // 新增

    public var recommendedPCMRate: Double {
        switch self {
        case .dsd64:   return 88_200
        case .dsd128:  return 176_400
        case .dsd256:  return 352_800
        case .dsd512:  return 352_800
        case .dsd1024: return 384_000   // 默认；可被 AudioPreferences.dsdMaxPCMRate 覆盖到 768_000
        }
    }

    public var displayName: String {
        switch self {
        case .dsd64:   return "DSD64"
        case .dsd128:  return "DSD128"
        case .dsd256:  return "DSD256"
        case .dsd512:  return "DSD512"
        case .dsd1024: return "DSD1024"
        }
    }
}
```

### 2. DSF/DFF allowlist 扩到 5 项

- `Sources/PurePlayCore/Decoder/DSFDecoder.swift:84`
- `Sources/PurePlayCore/Decoder/DFFDecoder.swift:154`

```swift
guard [2_822_400, 5_644_800, 11_289_600, 22_579_200, 45_158_400].contains(sampleFreq) else {
    throw DecoderError.unsupportedRate(sampleFreq)
}
```

### 3. 验证 SRC 路径

`DSD2PCMConverter` 已是「字节 → 1 sample」的 8× 抽取，DSD1024 输入后 outputRate = 45.1584M / 8 = 5.6448 MHz float。无需改动。

后续 `SincResampler(inputRate: 5_644_800, outputRate: 384_000)` 比例 = 0.068×，需要确认其行为：

```bash
grep -n "tapsPerOutput\|taps" Sources/PurePlayCore/DSP/SincResampler.swift
```

如果发现 SincResampler tap 数不够（产生混叠），暂不改——v1.6 实测如果有问题，作为 v1.7 优化项。

## 验收

- [ ] `DSDRate.dsd1024` 新 case，rawValue = 45_158_400
- [ ] DSF/DFF 解码器接受 DSD1024 文件不再抛 `unsupportedRate`
- [ ] 一个 DSD1024 `.dsf` 文件能完整播完输出 384 kHz PCM
- [ ] DSD64/128/256/512 现有路径无回归（手动各播一个文件）

## 风险

- SincResampler 在 0.068× 极端比例下可能出现混叠；如听感不佳，v1.7 加中间抽取级
- DSD1024 文件稀少，找测试样本可能困难（可用 HQPlayer 上变换生成）

## 文件

- `Sources/PurePlayCore/DSD/DoPPacker.swift:4-36`
- `Sources/PurePlayCore/Decoder/DSFDecoder.swift:84`
- `Sources/PurePlayCore/Decoder/DFFDecoder.swift:154`
