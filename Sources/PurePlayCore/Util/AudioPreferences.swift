import Foundation

/// 输出设备 / Hog Mode 等偏好持久化
/// 跨重启恢复用户选择的 DAC 与独占模式开关
public enum AudioPreferences {

    private static let deviceUIDKey = "ppl.outputDeviceUID"
    private static let hogEnabledKey = "ppl.hogModeEnabled"

    public static var deviceUID: String? {
        get { UserDefaults.standard.string(forKey: deviceUIDKey) }
        set {
            if let v = newValue, !v.isEmpty {
                UserDefaults.standard.set(v, forKey: deviceUIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: deviceUIDKey)
            }
        }
    }

    public static var hogEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: hogEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: hogEnabledKey) }
    }

    // MARK: - EQ 持久化

    private static let eqEnabledKey = "ppl.eqEnabled"
    private static let eqGainsKey = "ppl.eqGains"
    private static let parametricBandsKey = "ppl.parametricBands"
    private static let preampKey = "ppl.preamp"

    public static var eqEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: eqEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: eqEnabledKey) }
    }

    public static var preamp: Float {
        get { Float(UserDefaults.standard.double(forKey: preampKey)) }
        set { UserDefaults.standard.set(Double(newValue), forKey: preampKey) }
    }

    public static var parametricBands: [ParametricBand]? {
        get {
            if let data = UserDefaults.standard.data(forKey: parametricBandsKey) {
                return try? JSONDecoder().decode([ParametricBand].self, from: data)
            }
            if let legacyGains = legacyEQGains {
                let migrated = migrateGraphicToParametric(legacyGains)
                parametricBands = migrated
                UserDefaults.standard.removeObject(forKey: eqGainsKey)
                return migrated
            }
            return nil
        }
        set {
            if let v = newValue, let data = try? JSONEncoder().encode(v) {
                UserDefaults.standard.set(data, forKey: parametricBandsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: parametricBandsKey)
            }
        }
    }

    private static var legacyEQGains: [Float]? {
        guard let arr = UserDefaults.standard.array(forKey: eqGainsKey) as? [Double] else { return nil }
        return arr.map { Float($0) }
    }

    private static func migrateGraphicToParametric(_ gains: [Float]) -> [ParametricBand] {
        let frequencies = ParametricEQNode.graphicFrequencies
        return zip(frequencies, gains).map { freq, gain in
            ParametricBand(type: .peaking, frequency: freq, gain: gain, q: 1.414)
        }
    }

    // MARK: - DSD PCM 上限偏好 (F11)

    private static let dsdMaxPCMRateKey = "ppl.dsdMaxPCMRate"

    /// DSD 文件下采样的 PCM 上限速率。
    /// 合法值：384_000（默认，兼容性高）或 768_000（高保真，需 DAC 支持）。
    /// 任何其它值在读取时 clamp 到 384_000。
    public static var dsdMaxPCMRate: Double {
        get {
            let v = UserDefaults.standard.double(forKey: dsdMaxPCMRateKey)
            switch v {
            case 768_000: return 768_000
            case 384_000: return 384_000
            default:      return 384_000
            }
        }
        set {
            let clamped = (newValue >= 768_000) ? 768_000.0 : 384_000.0
            UserDefaults.standard.set(clamped, forKey: dsdMaxPCMRateKey)
        }
    }

    // MARK: - EQ A/B 双槽 (F12 / E6)

    private static let eqSlotAKey = "ppl.eqSlotA"
    private static let eqSlotBKey = "ppl.eqSlotB"
    private static let activeEQSlotKey = "ppl.activeEQSlot"
    private static let eqMigrationVersionKey = "ppl.eqMigrationVersion"

    /// A 槽数据。写入时同步双写 v1.5 旧 key (parametricBandsKey) 以保持兼容回退。
    public static var eqSlotA: Data? {
        get { UserDefaults.standard.data(forKey: eqSlotAKey) }
        set {
            if let v = newValue {
                UserDefaults.standard.set(v, forKey: eqSlotAKey)
                UserDefaults.standard.set(v, forKey: parametricBandsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: eqSlotAKey)
                UserDefaults.standard.removeObject(forKey: parametricBandsKey)
            }
        }
    }

    public static var eqSlotB: Data? {
        get { UserDefaults.standard.data(forKey: eqSlotBKey) }
        set {
            if let v = newValue {
                UserDefaults.standard.set(v, forKey: eqSlotBKey)
            } else {
                UserDefaults.standard.removeObject(forKey: eqSlotBKey)
            }
        }
    }

    public static var activeEQSlot: String {
        get { UserDefaults.standard.string(forKey: activeEQSlotKey) ?? "A" }
        set {
            let normalized = (newValue == "B") ? "B" : "A"
            UserDefaults.standard.set(normalized, forKey: activeEQSlotKey)
        }
    }

    /// 一次性迁移：把 v1.5 单槽 `parametricBandsKey` 复制到 `eqSlotA`。
    /// 幂等：通过 `eqMigrationVersion` 标记防重复执行。
    public static func performEQMigrationIfNeeded() {
        let ud = UserDefaults.standard
        if ud.integer(forKey: eqMigrationVersionKey) >= 1 { return }
        if let oldData = ud.data(forKey: parametricBandsKey),
           ud.data(forKey: eqSlotAKey) == nil {
            ud.set(oldData, forKey: eqSlotAKey)
        }
        ud.set(1, forKey: eqMigrationVersionKey)
    }

    // MARK: - AutoEQ 耳机型号 (E8)

    private static let currentHeadphoneNameKey = "ppl.currentHeadphoneName"

    public static var currentHeadphoneName: String? {
        get { UserDefaults.standard.string(forKey: currentHeadphoneNameKey) }
        set {
            if let v = newValue, !v.isEmpty {
                UserDefaults.standard.set(v, forKey: currentHeadphoneNameKey)
            } else {
                UserDefaults.standard.removeObject(forKey: currentHeadphoneNameKey)
            }
        }
    }
}
