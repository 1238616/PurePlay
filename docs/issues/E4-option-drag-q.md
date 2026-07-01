# E4 — Option-drag 改 Q + 保留滚轮

**Milestone**: v1.7
**Depends on**: 无
**Blocks**: 无
**估时**: 半天

## 上下文

当前 EQ 曲线编辑器拖动节点改变频率（X）和增益（Y），Q 值只能通过滚轮或字段输入修改。根据 grilling 决策（Q9）：Option+拖动竖直方向改 Q（保持向上窄/向下宽的直觉），同时保留滚轮调 Q。

## 范围

### 1. ParametricEQEditor 鼠标处理

定位 EQ 节点拖动逻辑（搜索 `DragGesture` 或 `NSPanGestureRecognizer`）：

```bash
grep -rn "DragGesture\|onDrag\|NSEvent.*drag" Sources/PurePlayApp/
```

修改拖动 handler：

```swift
.gesture(
    DragGesture()
        .modifiers(.option)
        .onChanged { value in
            // Option+drag: 竖直方向改 Q
            let dy = -value.translation.height   // 向上为正
            let qDelta = Float(dy) * 0.01        // 50px = ΔQ 0.5
            band.q = max(0.1, min(10, band.q + qDelta))
        }
        .simultaneously(with: DragGesture()
            .onChanged { value in
                // 普通 drag: freq + gain
                guard !NSEvent.modifierFlags.contains(.option) else { return }
                band.frequency = freqFromX(value.location.x)
                band.gainDB = gainFromY(value.location.y)
            }
        )
)
```

### 2. 滚轮调 Q（保留现有逻辑）

确认现有 `NSEvent.scrollWheel` 处理在节点上方时仍然修改 Q：

```bash
grep -rn "scrollWheel\|onMouseScrolled" Sources/PurePlayApp/
```

不做修改，保持现状。

### 3. 视觉反馈

Option 键按下时，节点上方显示 Q 值的临时浮动 tooltip（"Q = 1.2"），方便用户确认调整方向。

```swift
@State private var showQTooltip = false

.background(
    Group {
        if showQTooltip {
            Text("Q = \(band.q, specifier: "%.2f")")
                .padding(4)
                .background(.regularMaterial)
                .offset(y: -30)
        }
    }
)
.onContinuousHover { phase in
    // 检测 modifierFlags 变化
    showQTooltip = NSEvent.modifierFlags.contains(.option)
}
```

### 4. 灵敏度

50px 竖直拖动 → ΔQ = 0.5（grilling 验收条件）。在高 DPI 屏幕上需用 logical pixels（SwiftUI 默认就是）。

## 验收

- [ ] 在 EQ 节点上 Option+拖动 50px 向上 → Q 增加 ~0.5
- [ ] 拖动 50px 向下 → Q 减少 ~0.5（窄→宽的方向直觉）
- [ ] 不按 Option 时拖动只改 freq + gain，不影响 Q
- [ ] 滚轮调 Q 行为未变
- [ ] Option 按下时节点旁显示 Q 浮动 tooltip
- [ ] Q 值 clamp 到 [0.1, 10]

## 风险

- SwiftUI `DragGesture.modifiers(.option)` 与无修饰键的 `DragGesture` 同时识别，可能因优先级冲突无法触发；如出问题可用 `NSGestureRecognizer` 在 NSViewRepresentable 里实现
- macOS Option 键还可能被系统快捷键截获；测试要覆盖

## 文件

- `Sources/PurePlayApp/`（ParametricEQEditor 拖动 handler）
