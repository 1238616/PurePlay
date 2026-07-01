# E8 — AutoEQ 文件名提取耳机型号 + 「当前耳机」状态栏标签

**Milestone**: v1.7
**Depends on**: 无
**Blocks**: 无
**估时**: 半天

## 上下文

AutoEQ 项目（https://github.com/jaakkopasanen/AutoEq）的 ParametricEQ 文件命名约定为：

```
Sennheiser HD 600 ParametricEQ.txt
Audeze LCD-X 2021 ParametricEQ.txt
HiFiMAN Sundara ParametricEQ.txt
```

文件名中**移除尾部 ` ParametricEQ.txt`** 即可得到耳机型号。

根据 grilling 决策（Q13）：解析时提取耳机型号 + EQ Panel 状态栏显示「当前耳机：Sennheiser HD 600」标签。flat preset 列表（不分文件夹）。

## 范围

### 1. AutoEQParser 扩展

`Sources/PurePlayCore/EQ/AutoEQParser.swift`（或对应文件）：

```swift
public struct AutoEQResult {
    public let bands: [EQBand]
    public let preamp: Double
    public let headphoneName: String?   // 新增
}

public enum AutoEQParser {
    public static func parse(file url: URL) throws -> AutoEQResult {
        let content = try String(contentsOf: url, encoding: .utf8)
        let bands = parseBands(content)
        let preamp = parsePreamp(content)
        let headphoneName = extractHeadphoneName(from: url.lastPathComponent)
        return AutoEQResult(bands: bands, preamp: preamp, headphoneName: headphoneName)
    }

    static func extractHeadphoneName(from filename: String) -> String? {
        // "Sennheiser HD 600 ParametricEQ.txt" -> "Sennheiser HD 600"
        var name = filename
        // 去除扩展名
        if let ext = filename.split(separator: ".").last {
            name = String(filename.dropLast(ext.count + 1))
        }
        // 去除常见 AutoEQ 后缀
        let suffixes = [" ParametricEQ", " GraphicEQ", " FixedBandEQ", " ParamEQ"]
        for suffix in suffixes {
            if name.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
                break
            }
        }
        return name.isEmpty ? nil : name
    }
}
```

### 2. AudioPreferences 存储

```swift
public var currentHeadphoneName: String? {
    get { UserDefaults.standard.string(forKey: "currentHeadphoneName") }
    set {
        if let v = newValue {
            UserDefaults.standard.set(v, forKey: "currentHeadphoneName")
        } else {
            UserDefaults.standard.removeObject(forKey: "currentHeadphoneName")
        }
    }
}
```

### 3. 导入时设置

AutoEQ 文件被拖入或通过菜单加载时：

```swift
let result = try AutoEQParser.parse(file: url)
eqEngine.activeBands = result.bands
if let name = result.headphoneName {
    AudioPreferences.currentHeadphoneName = name
}
```

如果用户手动改了 band（脱离 AutoEQ 原配置）后，是否清空 headphoneName？v1.7 暂定**不清空**（保留作为「上次导入的耳机」参考），用户可以通过「Clear」按钮显式清除。

### 4. EQ Panel 状态栏

EQ Panel 顶部或底部状态栏显示：

```
[A] [B]      Copy A→B      ┃   当前耳机：Sennheiser HD 600    [清除]
```

- 「当前耳机」标签左侧加耳机 icon
- 标签为空时显示「(未导入 AutoEQ 文件)」灰显
- 「清除」按钮：弹出 confirm，清除 `currentHeadphoneName` 同时**保留** A/B 槽数据（不清 EQ）

### 5. 边界情况

- 文件名是中文/特殊字符：保留原样（AutoEQ 项目主要是英文耳机名，但用户可能自命名）
- 文件名没有 ` ParametricEQ` 后缀：fallback 直接用 filename 去扩展名
- 拖入多个 AutoEQ 文件：取最后一个的耳机名（其他 band 数据被前一个覆盖，符合直觉）

## 验收

- [ ] 拖入 `Sennheiser HD 600 ParametricEQ.txt` → 状态栏显示「当前耳机：Sennheiser HD 600」
- [ ] 拖入 `Audeze LCD-X 2021 ParametricEQ.txt` → 状态栏更新为「Audeze LCD-X 2021」
- [ ] 拖入无标准后缀的文件（如 `my_custom.txt`）→ 状态栏显示「my_custom」
- [ ] 重启 app 后状态栏保留上次耳机名
- [ ] 「清除」按钮点击后状态栏变为「(未导入 AutoEQ 文件)」，A/B 槽数据保留
- [ ] 用户改 A 槽 band 后状态栏耳机名不变（除非手动清除）

## 风险

- 用户改了 EQ 后状态栏仍显示原耳机名，可能误导「这是当前生效的 EQ」；UI 可以加 tooltip「上次导入：Sennheiser HD 600（已修改）」
- 中文文件名可能含全角空格，正则匹配后缀需 normalize

## 文件

- `Sources/PurePlayCore/EQ/AutoEQParser.swift`（或对应文件）
- `Sources/PurePlayCore/Util/AudioPreferences.swift`
- `Sources/PurePlayApp/`（EQ Panel 状态栏）
