# F5 — DACCapabilityProbe 处理 DSD1024（永远 false，不加字段）

**Milestone**: v1.6
**Depends on**: F4
**Blocks**: 无
**估时**: 30 分钟

## 上下文

`DACCapabilityProbe.Result.supports(_:)`（`DACCapabilityProbe.swift:109`）的 switch 必须穷举所有 `DSDRate` case。F4 加 `.dsd1024` 后会编译报错。

根据 grilling 决策（Q19）：**不加 `supportsDSD1024` 字段**，switch 里直接返回 `false`。理由：现实中无 DAC 能承载 2822.4 kHz PCM（DSD1024 DoP carrier），让上层 `DSDStrategyChooser` 自动 fallback 到 PCM 下采样路径（F4）。

## 范围

### 1. `DACCapabilityProbe.swift:109`

```swift
public func supports(_ rate: DSDRate) -> Bool {
    switch rate {
    case .dsd64:   return supportsDSD64
    case .dsd128:  return supportsDSD128
    case .dsd256:  return supportsDSD256
    case .dsd512:  return supportsDSD512
    case .dsd1024: return false   // Q15/Q19: 无 DAC 支持 DoP 承载，恒走 PCM 下采样
    }
}
```

### 2. `DoPPacker.swift:165` `DSDStrategyChooser.choose`

确认 `dac.supportsDoP(for: .dsd1024)` 返回 false 后，所有 preference 分支都会落到 `.pcm(targetRate: rate.recommendedPCMRate)`（默认 384k）。

```swift
public func supportsDoP(for rate: DSDRate) -> Bool {
    maxPCMRate >= rate.dopCarrierRate   // DSD1024 的 dopCarrierRate = 2_822_400，几乎无 DAC 满足
}
```

无需修改逻辑——`dopCarrierRate` 已是 `rawValue / 16` = 2822400，自动判 false。

### 3. 查找其他需要扩展 switch 的位置

```bash
grep -rn "switch.*rate" Sources/PurePlayCore/DSD/
grep -rn "case .dsd512" Sources/PurePlayCore/
```

所有「按 DSDRate switch」的地方都加 `.dsd1024` 分支。

## 验收

- [ ] `swift build` 编译通过（no `switch must be exhaustive`）
- [ ] `DACCapabilityProbe.Result.supports(.dsd1024)` 在任何 DAC 上返回 false
- [ ] `DSDStrategyChooser.choose(rate: .dsd1024, ...)` 返回 `.pcm(targetRate: 384000)`（默认）

## 文件

- `Sources/PurePlayCore/DSD/DACCapabilityProbe.swift:109`
- 其他 switch DSDRate 的位置（按 grep 结果补全）
