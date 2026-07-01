# F9 — 轻量 audio thread CPU% + DSP 延迟 HUD

**Milestone**: v1.6
**Depends on**: 无
**Blocks**: 无
**估时**: 1 天

## 上下文

v1.7 引入 EQ 复杂度 + DSD1024（v1.6）后，audio thread 负载可能逼近 buffer 时长上限，导致 underrun。需要轻量监控让用户和开发者看到实时负载。

根据 grilling 决策（Q25）：右下角小角标显示 audio thread CPU% + DSP 延迟，偏好可开关，默认关闭。

## 范围

### 1. 采集逻辑

CoreAudio render callback 入口/出口加时间戳：

```swift
final class CoreAudioOutput {
    private var renderTimeNS: UInt64 = 0    // 累计 render callback 总耗时（ns）
    private var realTimeNS: UInt64 = 0      // 累计实时时间（ns）
    private var lastSampleNS: UInt64 = 0    // 上次窗口结束时间

    private let renderCallback: AURenderCallback = { (refCon, ...) -> OSStatus in
        let start = mach_absolute_time_ns()
        // ... 原有 render 逻辑 ...
        let end = mach_absolute_time_ns()
        let owner = ...
        owner.recordRenderTime(start: start, end: end, frames: inNumberFrames)
        return noErr
    }

    fileprivate func recordRenderTime(start: UInt64, end: UInt64, frames: UInt32) {
        let dt = end - start
        renderTimeNS += dt
        let frameDurationNS = UInt64(Double(frames) * 1e9 / sampleRate)
        realTimeNS += frameDurationNS
        // 每 100ms 滑动窗口结算一次
    }

    // 主线程读取（atomic snapshot）
    func currentMetrics() -> (cpuPercent: Float, dspMs: Float, bufferMs: Float) { ... }
}
```

使用 `mach_absolute_time()` + `mach_timebase_info` 转 ns。

### 2. 指标计算

- **CPU%** = renderTimeNS / realTimeNS × 100（100ms 滑动窗口）
- **DSP ms** = 当前 callback 平均耗时（ms）
- **buffer ms** = 当前 callback frames × 1000 / sampleRate

### 3. UI 角标

`Sources/PurePlayApp/` 主窗口右下角加 HUD 视图：

```
[CPU 4.2%]  [DSP 1.8ms / 5.8ms]
```

颜色规则：
- DSP / buffer < 0.80 → 绿色
- 0.80 ≤ ratio < 0.95 → 黄色
- ratio ≥ 0.95 → 红色

### 4. 偏好开关

`AudioPreferences`:

```swift
public var showPerformanceHUD: Bool {
    get { UserDefaults.standard.bool(forKey: "showPerformanceHUD") }
    set { UserDefaults.standard.set(newValue, forKey: "showPerformanceHUD") }
}
```

默认 `false`，在偏好窗口「显示」分组下加开关「显示性能指标」。

## 验收

- [ ] 偏好开关启用后，主窗口右下角显示稳定 CPU% 和 DSP/buffer 数值
- [ ] 播放 FLAC 44.1k：CPU% < 5%（M1 air baseline）
- [ ] 播放 DSD64：CPU% < 10%
- [ ] 播放 DSD1024 (768k)：CPU% < 25%（v1.6 实测后调整文档）
- [ ] HUD 颜色随负载变化（绿/黄/红）
- [ ] 偏好关闭后 HUD 完全隐藏，无 CPU 占用

## 风险

- `mach_absolute_time` 在 audio thread 安全（无锁、不阻塞）
- 滑动窗口更新需要 atomic 操作，避免 tearing
- 主线程读 audio thread 写的数据，需用 `os_unfair_lock` 或 atomic snapshot

## 文件

- `Sources/PurePlayCore/Audio/CoreAudioOutput.swift`（或对应输出文件）
- `Sources/PurePlayCore/Util/AudioPreferences.swift`
- `Sources/PurePlayApp/`（HUD 视图 + 偏好开关）
