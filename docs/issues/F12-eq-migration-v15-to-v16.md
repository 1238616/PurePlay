# F12 — v1.5 → v1.6 EQ 迁移（单槽 → A 槽 + 双写）

**Milestone**: v1.6
**Depends on**: 无（独立 utility）
**Blocks**: E6（A/B 双槽）的前置兼容性
**估时**: 半天

## 上下文

根据 grilling 决策（Q26/Q27）：
- v1.7 引入 A/B 双槽（`eqSlotA` / `eqSlotB`）
- v1.5.x 用户只有单槽 `parametricBandsKey`
- v1.6 首次启动检测旧 key 存在 + 新 key 不存在时：把旧内容复制到 `eqSlotA`，`eqSlotB` 留空
- 旧 key 保留，v1.6 写入时同时写新 key 和旧 key（兼容回退到 v1.5）

**注意**：A/B 双槽实现在 v1.7（E6），但 F12 现在就准备好迁移代码，避免老用户 v1.6 升 v1.7 时出现配置丢失。

## 范围

### 1. AudioPreferences 新增

`Sources/PurePlayCore/Util/AudioPreferences.swift`:

```swift
private let eqSlotAKey = "eqSlotA"
private let eqSlotBKey = "eqSlotB"
private let activeEQSlotKey = "activeEQSlot"
private let parametricBandsKey = "parametricBands"   // 已有的旧 key
private let eqMigrationVersionKey = "eqMigrationVersion"

public var eqSlotA: Data? {
    get { UserDefaults.standard.data(forKey: eqSlotAKey) }
    set {
        if let v = newValue {
            UserDefaults.standard.set(v, forKey: eqSlotAKey)
            // 双写旧 key（向后兼容 v1.5）
            UserDefaults.standard.set(v, forKey: parametricBandsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: eqSlotAKey)
            UserDefaults.standard.removeObject(forKey: parametricBandsKey)
        }
    }
}

public var eqSlotB: Data? {
    get { UserDefaults.standard.data(forKey: eqSlotBKey) }
    set {
        if let v = newValue {
            UserDefaults.standard.set(v, forKey: eqSlotBKey)
        } else {
            UserDefaults.standard.removeObject(forKey: eqSlotBKey)
        }
    }
}

public var activeEQSlot: String {
    get { UserDefaults.standard.string(forKey: activeEQSlotKey) ?? "A" }
    set { UserDefaults.standard.set(newValue, forKey: activeEQSlotKey) }
}

/// 一次性迁移：v1.5 单槽 -> v1.6 A 槽。重复调用安全（幂等）。
public static func performEQMigrationIfNeeded() {
    let ud = UserDefaults.standard
    let currentVersion = ud.integer(forKey: "eqMigrationVersion")
    if currentVersion >= 1 { return }   // 已迁移过

    // 旧 key 有数据 + 新 key 没数据 → 复制
    if let oldData = ud.data(forKey: "parametricBands"),
       ud.data(forKey: "eqSlotA") == nil {
        ud.set(oldData, forKey: "eqSlotA")
    }
    ud.set(1, forKey: "eqMigrationVersion")
}
```

### 2. 启动调用

在 app 启动早期（`Sources/PurePlayApp/main.swift` 或 `AppDelegate.applicationDidFinishLaunching`）调用：

```swift
AudioPreferences.performEQMigrationIfNeeded()
```

### 3. EQ 读取顺序

EQ 引擎读取 EQ 时按 `activeEQSlot` 决定读 A 还是 B（默认 A）。如果新 key 为空，回退读旧 `parametricBandsKey`（防御性）：

```swift
public func loadActiveEQBands() -> [EQBand]? {
    let slot = activeEQSlot
    let data: Data? = (slot == "B") ? eqSlotB : (eqSlotA ?? UserDefaults.standard.data(forKey: parametricBandsKey))
    return data.flatMap { try? JSONDecoder().decode([EQBand].self, from: $0) }
}
```

## 验收

- [ ] v1.5.11 装好 EQ 配置后升级到 v1.6 build，启动一次 → `eqSlotA` 自动填充与 `parametricBandsKey` 相同的数据
- [ ] `eqSlotB` 在迁移后为 nil
- [ ] `activeEQSlot` 默认为 "A"
- [ ] `eqMigrationVersion` 设为 1，再次启动不重复迁移
- [ ] 写入 `eqSlotA` 后 `parametricBandsKey` 同步更新（向后兼容）
- [ ] 全新用户（无旧 key）启动 v1.6，`eqSlotA` / `eqSlotB` 都为 nil，行为与新装 v1.5 一致

## 文件

- `Sources/PurePlayCore/Util/AudioPreferences.swift`
- `Sources/PurePlayApp/main.swift`（或 AppDelegate）
