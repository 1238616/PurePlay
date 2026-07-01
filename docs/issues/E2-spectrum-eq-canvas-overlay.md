# E2 — SpectrumAnalyzer 接到 EQ canvas（EQ-pre 半透明源频谱叠加）

**Milestone**: v1.7
**Depends on**: F6, E1
**Blocks**: 无
**估时**: 2 天

## 上下文

根据 grilling 决策（Q5/Q6）：在 EQ canvas 上半透明叠加**源信号实时频谱**（EQ-pre，即在 EQ 处理之前采样），让用户「看到自己在修什么」。

复用现有 48-band SpectrumAnalyzer（Q6），频谱时间响应已由 E1 优化。

## 范围

### 1. 信号路径接入

在 DSP 处理链 EQ **前**插入 spectrum tap：

```
Decoder → [SpectrumTap pre-EQ] → ParametricEQNode → [SpectrumTap post-EQ optional] → Resampler → CoreAudio
```

`SpectrumTap` 是 pass-through 节点，每 block 把 PCM 拷一份给 `SpectrumAnalyzer`。位置在 `Sources/PurePlayCore/DSP/` 或 `Audio/`。

### 2. EQ Panel 视图改造

`Sources/PurePlayApp/`（EQ 编辑器视图）背景层加 `SpectrumOverlayView`：

```swift
struct SpectrumOverlayView: View {
    @ObservedObject var spectrumModel: SpectrumModel  // 周期性更新 bands

    var body: some View {
        Canvas { context, size in
            let bands = spectrumModel.bands  // [Float] 48 个
            let logMinHz: CGFloat = log10(20)
            let logMaxHz: CGFloat = log10(22050)
            for (i, level) in bands.enumerated() {
                let lowFrac = CGFloat(i) / CGFloat(bands.count)
                let highFrac = CGFloat(i + 1) / CGFloat(bands.count)
                let x0 = lowFrac * size.width
                let x1 = highFrac * size.width
                let h = CGFloat(level) * size.height
                let rect = CGRect(x: x0, y: size.height - h, width: x1 - x0, height: h)
                context.fill(Path(rect), with: .color(.cyan.opacity(0.3)))
            }
        }
    }
}
```

频率轴必须与 EQ 曲线视图的频率轴对齐（log scale 20-22050 Hz）。

### 3. 数据流

`SpectrumModel` 是 `ObservableObject`，60Hz 通过 `Timer.publish` 拉取 `SpectrumAnalyzer.currentBands()` 并 publish。

```swift
class SpectrumModel: ObservableObject {
    @Published var bands: [Float] = []
    private weak var analyzer: SpectrumAnalyzer?
    private var timer: Timer?

    init(analyzer: SpectrumAnalyzer) {
        self.analyzer = analyzer
        timer = Timer.scheduledTimer(withTimeInterval: 1.0/60, repeats: true) { [weak self] _ in
            self?.bands = self?.analyzer?.currentBands() ?? []
        }
    }
}
```

### 4. 视觉参数

- 颜色：默认 `Color.cyan.opacity(0.3)`（评审时可调）
- 频率轴：log 20Hz - 22050Hz（与 EQ 曲线一致）
- 幅度轴：0-1（已 dB 归一化），映射到画布高度
- 不开播时频谱为空，显示静态网格

### 5. 性能

- 60Hz 重绘 48 个矩形 = 2880 draws/s，Canvas 完全可承受
- 不重绘整个 EQ Panel，只重绘 SpectrumOverlayView（独立 ZStack 层）

## 验收

- [ ] 播放任何曲目时，EQ canvas 背景能看到实时频谱柱状图
- [ ] 频谱柱与 EQ 曲线频率轴对齐（1 kHz 处的频谱柱中心 = 1 kHz EQ 节点的 x 坐标）
- [ ] 不开播时频谱为空（无残影）
- [ ] CPU 占用增加 < 1%（M1 air）
- [ ] EQ 节点拖动不被频谱遮挡（频谱在底层）

## 风险

- 60Hz 更新频谱在低端机可能引起 UI 卡顿；可降到 30Hz 兜底
- 不同采样率下频谱轴要重算（F6 已支持 sampleRate 注入）
- 信号路径侵入 DSP 链可能引入延迟；SpectrumTap 必须 zero-copy（只 memcpy 而不 process）

## 文件

- `Sources/PurePlayCore/DSP/SpectrumTap.swift`（新增）
- `Sources/PurePlayCore/DSP/`（DSP chain 接入）
- `Sources/PurePlayApp/`（EQ Panel 视图 + SpectrumOverlayView + SpectrumModel）
