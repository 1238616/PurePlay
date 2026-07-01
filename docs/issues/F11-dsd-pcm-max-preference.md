# F11 — DSD PCM 上限偏好（dsdMaxPCMRate）

**Milestone**: v1.6
**Depends on**: F4
**Blocks**: 无
**估时**: 半天

## 上下文

根据 grilling 决策（Q16）：DSD1024 默认下采到 384 kHz，用户可在偏好里上调到 768 kHz。

## 范围

### 1. AudioPreferences 新增 key

`Sources/PurePlayCore/Util/AudioPreferences.swift`:

```swift
public var dsdMaxPCMRate: Double {
    get {
        let v = UserDefaults.standard.double(forKey: "dsdMaxPCMRate")
        return v > 0 ? v : 384_000   // 默认 384k
    }
    set {
        UserDefaults.standard.set(newValue, forKey: "dsdMaxPCMRate")
    }
}
```

接受值：`384_000`、`768_000`（其他值视为非法，clamp 到 384k）。

### 2. DSDRate.recommendedPCMRate 集成偏好

由于 `DSDRate` 是 enum 无法直接读 UserDefaults，需要在 `DSDStrategyChooser` 层注入：

```swift
public enum DSDStrategyChooser {
    public static func choose(
        rate: DSDRate,
        dac: DACCapabilities,
        preference: DSDPreference,
        userMaxPCM: Double = AudioPreferences.shared.dsdMaxPCMRate   // 新增
    ) -> DSDOutputStrategy {
        let dacSupports = dac.supportsDoP(for: rate)
        let cappedPCM = min(rate.recommendedPCMRate, userMaxPCM)
        switch preference {
        case .preferDoP where dacSupports:
            return .dop(carrierRate: rate.dopCarrierRate)
        case .alwaysPCM, .preferDoP:
            return .pcm(targetRate: cappedPCM)
        case .auto:
            return dacSupports
                ? .dop(carrierRate: rate.dopCarrierRate)
                : .pcm(targetRate: cappedPCM)
        }
    }
}
```

DSD1024 时 `recommendedPCMRate = 384_000`，`userMaxPCM` 默认 384_000 时输出 384k；用户切到 768_000 时输出 768k。

DSD64-512 时 `recommendedPCMRate` 已是 88.2/176.4/352.8k，与 userMaxPCM 取 min 不影响（除非用户故意切到 384k 以下，那就 cap 到 88.2k 起步——这是合理行为）。

### 3. 偏好窗口 UI

`Sources/PurePlayApp/`（偏好面板）「音频输出」分组下新增：

```
DSD PCM 上限：[● 384 kHz （兼容性高）  ○ 768 kHz （高保真，需 DAC 支持）]
              说明：DSD1024 文件会下采样到此速率。低端 DAC 请保持 384 kHz。
```

切换时立即生效（不需要重启，但当前播放曲目可能需要重新打开输出）。

## 验收

- [ ] 偏好面板显示 384k / 768k 单选
- [ ] 切到 768k 后，播放 DSD1024 文件输出 768 kHz PCM（在 CoreAudio device 配置上可见）
- [ ] 切回 384k 后，播放 DSD1024 输出 384 kHz
- [ ] 切换不影响 DSD64/128/256/512 的现有路径（仍输出 88.2/176.4/352.8/352.8 kHz）
- [ ] 偏好持久化（重启 app 后保持）

## 风险

- 切换时正在播放的曲目需要重新打开 CoreAudio 输出，可能短暂静音
- 用户切到 768k 但 DAC 不支持时，CoreAudio 会回退到设备最大支持速率；UI 上需提示

## 文件

- `Sources/PurePlayCore/Util/AudioPreferences.swift`
- `Sources/PurePlayCore/DSD/DoPPacker.swift:165`（`DSDStrategyChooser.choose`）
- `Sources/PurePlayApp/`（偏好面板）
