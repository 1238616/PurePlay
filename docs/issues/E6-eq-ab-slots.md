# E6 — A/B EQ 双槽 + B 键切换 + Copy A→B

**Milestone**: v1.7
**Depends on**: F12（EQ 迁移）
**Blocks**: 无
**估时**: 2 天

## 上下文

根据 grilling 决策（Q11）：EQ 编辑器顶部有 A/B 双槽切换按钮，B 键键盘快捷键 toggle，「Copy A→B」按钮把 A 槽内容复制到 B 槽（B 空时高亮提示）。

F12 已经准备好 `eqSlotA` / `eqSlotB` / `activeEQSlot` 偏好存储。

## 范围

### 1. EQ Engine 双槽支持

`Sources/PurePlayCore/DSP/`（搜索 EQ 引擎）支持「当前活动槽」概念：

```swift
public final class EQEngine {
    public enum Slot { case a, b }
    private(set) var activeSlot: Slot = .a
    private var bandsA: [EQBand] = []
    private var bandsB: [EQBand] = []

    public var activeBands: [EQBand] {
        get { activeSlot == .a ? bandsA : bandsB }
        set {
            if activeSlot == .a { bandsA = newValue } else { bandsB = newValue }
            persist()
            rebuildCoefficients()
        }
    }

    public func switchSlot(to slot: Slot) {
        guard slot != activeSlot else { return }
        activeSlot = slot
        AudioPreferences.activeEQSlot = (slot == .a ? "A" : "B")
        rebuildCoefficients()    // 立即生效（配合 E7 系数插值就不会 click）
    }

    public func copyAToB() {
        bandsB = bandsA
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        AudioPreferences.eqSlotA = try? encoder.encode(bandsA)
        AudioPreferences.eqSlotB = try? encoder.encode(bandsB)
    }
}
```

### 2. UI 切换按钮

EQ Panel 顶部：

```
[A]  [B]            Copy A→B
^^^  current active (高亮)
```

- 单击 A/B 切换活动槽
- B 槽为空时按钮文字灰显（`(空)`），点击会从 A 复制后进入 B
- Copy A→B 按钮在 B 槽为空时高亮（脉冲动画或亮色边框）

### 3. 键盘快捷键

`Sources/PurePlayApp/` 主窗口加 keyDown 监听：

```swift
.onKeyPress(.init("b")) {
    eqEngine.switchSlot(to: eqEngine.activeSlot == .a ? .b : .a)
    return .handled
}
```

只在 EQ Panel 显示时生效（避免与库搜索等冲突）。或者用全局 `@FocusState` 判断。

### 4. 视觉反馈

切换 A↔B 时：
- 顶部按钮高亮平滑过渡（< 150ms 动画）
- EQ 曲线视图重绘（节点位置变化）
- 配合 E7 系数插值，无 click 噪音

### 5. 持久化

`AudioPreferences`（F12 已加好）:
- `eqSlotA` / `eqSlotB`：每次 bands 变化即写入（debounce 500ms 避免频繁 IO）
- `activeEQSlot`：每次切换即写入

## 验收

- [ ] EQ Panel 顶部显示 [A] [B] 按钮，当前活动槽高亮
- [ ] 单击 [B] 切换到 B 槽，EQ 曲线更新
- [ ] B 键键盘快捷键 toggle A↔B
- [ ] B 槽为空时显示「(空)」+ Copy A→B 按钮脉冲提示
- [ ] 点击 Copy A→B 后 B 槽填充
- [ ] 切换 A↔B 无 click 噪音（依赖 E7）
- [ ] 切换响应延迟 < 100 ms（按下 B 键到 EQ 实际生效）
- [ ] 重启 app 后 A/B 槽内容保留，activeEQSlot 保持上次状态

## 风险

- A/B 槽频繁切换可能引起 UserDefaults 写入风暴：用 500ms debounce
- 旧 v1.5 用户的 EQ 配置（在 A 槽）和新 A/B UI 工作流要协调：F12 已迁移，B 槽默认空白引导用户主动 copy

## 文件

- `Sources/PurePlayCore/DSP/EQEngine.swift`（或对应文件）
- `Sources/PurePlayApp/`（EQ Panel UI + B 键快捷键）
- `Sources/PurePlayCore/Util/AudioPreferences.swift`（F12 已加 key）
