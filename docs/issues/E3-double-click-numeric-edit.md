# E3 — 数字字段双击编辑 + 单位解析

**Milestone**: v1.7
**Depends on**: 无
**Blocks**: 无
**估时**: 1 天

## 上下文

当前 EQ 编辑器的数字字段（frequency / gain / Q）需要拖动调整，无法精确输入数值。根据 grilling 决策（Q8）：双击进入编辑模式 + 单位后缀解析。

## 范围

### 1. EditableNumericField 组件

新建 `Sources/PurePlayApp/Components/EditableNumericField.swift`：

```swift
struct EditableNumericField: View {
    @Binding var value: Double
    let unit: Unit
    @State private var isEditing = false
    @State private var text = ""

    enum Unit {
        case hz, dB, q

        func format(_ v: Double) -> String {
            switch self {
            case .hz:
                return v >= 1000 ? String(format: "%.2gk", v / 1000) : String(format: "%.0f", v)
            case .dB:
                return String(format: "%+.1f dB", v)
            case .q:
                return String(format: "%.2f", v)
            }
        }

        func parse(_ s: String) -> Double? {
            let trimmed = s.trimmingCharacters(in: .whitespaces).lowercased()
            switch self {
            case .hz:
                // "8.2k", "8200", "8200hz", "8.2khz"
                let cleaned = trimmed
                    .replacingOccurrences(of: "hz", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if cleaned.hasSuffix("k") {
                    return Double(cleaned.dropLast()).map { $0 * 1000 }
                }
                return Double(cleaned)
            case .dB:
                // "+3", "+3dB", "-2.5", "3"
                let cleaned = trimmed.replacingOccurrences(of: "db", with: "")
                    .trimmingCharacters(in: .whitespaces)
                return Double(cleaned)
            case .q:
                return Double(trimmed)
            }
        }
    }

    var body: some View {
        if isEditing {
            TextField("", text: $text, onCommit: commit)
                .textFieldStyle(.roundedBorder)
                .onAppear { text = unit.format(value) }
                .onExitCommand { isEditing = false }
        } else {
            Text(unit.format(value))
                .onTapGesture(count: 2) {
                    text = unit.format(value)
                    isEditing = true
                }
        }
    }

    private func commit() {
        if let v = unit.parse(text) {
            value = v
        }
        isEditing = false
    }
}
```

### 2. EQ 编辑器集成

替换每个 freq/gain/Q 字段的现有 `Text` / `Slider` 标签为 `EditableNumericField`：

```swift
EditableNumericField(value: $band.frequency, unit: .hz)
EditableNumericField(value: $band.gainDB, unit: .dB)
EditableNumericField(value: $band.q, unit: .q)
```

### 3. 取值范围 clamping

`@Binding var value: Double` 的 setter 在 EQ band model 层 clamp：

```swift
var frequency: Double {
    get { _frequency }
    set { _frequency = max(20, min(22050, newValue)) }
}
var gainDB: Double {
    get { _gainDB }
    set { _gainDB = max(-24, min(24, newValue)) }
}
var q: Double {
    get { _q }
    set { _q = max(0.1, min(10, newValue)) }
}
```

非法输入（如 "abc"）保持原值，TextField 失焦时显示原数值。

## 验收

- [ ] 双击 frequency 字段进入编辑，输入 `8.2k` → 解析为 8200 Hz
- [ ] 输入 `8200hz` 也解析为 8200
- [ ] 输入 `+3dB` 在 gain 字段解析为 +3.0
- [ ] 输入 `abc` 非法值，回车后还原原值
- [ ] Esc 取消编辑，还原原值
- [ ] 单击不进入编辑（保留拖动手势）
- [ ] 双击编辑与拖动手势无冲突（250ms 双击窗口检测）

## 风险

- 双击 vs 单击+拖动 的手势识别：SwiftUI 的 `onTapGesture(count: 2)` 与 `DragGesture` 同时存在时可能冲突；用 `simultaneously(with:)` 或显式优先级
- 数字格式化在不同 locale 下小数点可能是逗号；强制 `Locale(identifier: "en_US_POSIX")` 解析

## 文件

- `Sources/PurePlayApp/Components/EditableNumericField.swift`（新增）
- `Sources/PurePlayApp/`（EQ 编辑器视图集成）
- `Sources/PurePlayCore/DSP/`（EQ band model clamping）
