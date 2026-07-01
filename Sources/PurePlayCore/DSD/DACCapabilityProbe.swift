import Foundation

/// 已知支持 DSD over DoP 的 USB DAC 数据库
///
/// 来自社区维护的兼容性列表与厂商规格表的并集。运行时通过设备 `name`
/// 子字符串匹配；找到则认为该设备明确支持指定 DSD 速率。
///
/// 设计要点：
/// - 名字匹配为大小写不敏感的子字符串
/// - 同一型号可声明最高支持的 DSD 速率，下属速率默认 inclusive
/// - 用户可通过设置 UI 添加自定义条目
public struct DSDCapableDevice: Sendable, Equatable {
    /// 名字片段，与 `AudioDevice.name` 子字符串匹配（大小写不敏感）
    public let nameSubstring: String
    /// 厂商
    public let vendor: String
    /// 该设备明确支持的最高 DSD 速率（同时含义为 inclusive 支持更低速率）
    public let maxDSD: DSDRate

    public init(nameSubstring: String, vendor: String, maxDSD: DSDRate) {
        self.nameSubstring = nameSubstring
        self.vendor = vendor
        self.maxDSD = maxDSD
    }
}

/// 内置 DSD-capable DAC 白名单
///
/// 数据维度：按厂商分类的常见型号；不能覆盖所有产品，但能在 PCM 速率
/// 探测之外提供"信心加分"，让 PurePlay 优先选 DoP 路径。
public enum KnownDSDDevices {

    public static let builtIn: [DSDCapableDevice] = [
        // RME
        DSDCapableDevice(nameSubstring: "ADI-2",       vendor: "RME",     maxDSD: .dsd256),
        DSDCapableDevice(nameSubstring: "Babyface",    vendor: "RME",     maxDSD: .dsd128),

        // Schiit
        DSDCapableDevice(nameSubstring: "Modi Multibit", vendor: "Schiit", maxDSD: .dsd64),
        DSDCapableDevice(nameSubstring: "Bifrost 2",    vendor: "Schiit", maxDSD: .dsd64),

        // Topping
        DSDCapableDevice(nameSubstring: "D90",         vendor: "Topping", maxDSD: .dsd512),
        DSDCapableDevice(nameSubstring: "D70",         vendor: "Topping", maxDSD: .dsd512),
        DSDCapableDevice(nameSubstring: "D50",         vendor: "Topping", maxDSD: .dsd512),
        DSDCapableDevice(nameSubstring: "D30",         vendor: "Topping", maxDSD: .dsd256),

        // SMSL
        DSDCapableDevice(nameSubstring: "SU-9",        vendor: "SMSL",    maxDSD: .dsd512),
        DSDCapableDevice(nameSubstring: "M500",        vendor: "SMSL",    maxDSD: .dsd512),

        // iFi
        DSDCapableDevice(nameSubstring: "iDSD",        vendor: "iFi",     maxDSD: .dsd512),
        DSDCapableDevice(nameSubstring: "Zen DAC",     vendor: "iFi",     maxDSD: .dsd256),

        // Chord
        DSDCapableDevice(nameSubstring: "Mojo",        vendor: "Chord",   vendorMaxIsDoP: .dsd256),
        DSDCapableDevice(nameSubstring: "Hugo",        vendor: "Chord",   vendorMaxIsDoP: .dsd512),

        // Cambridge Audio
        DSDCapableDevice(nameSubstring: "DacMagic",    vendor: "Cambridge", maxDSD: .dsd256),

        // ESS-based generic (silicon supports up to DSD512 typically)
        DSDCapableDevice(nameSubstring: "ES9038",      vendor: "ESS",     maxDSD: .dsd512),
        DSDCapableDevice(nameSubstring: "ES9028",      vendor: "ESS",     maxDSD: .dsd512),
        DSDCapableDevice(nameSubstring: "ES9018",      vendor: "ESS",     maxDSD: .dsd256),

        // AKM-based generic
        DSDCapableDevice(nameSubstring: "AK4499",      vendor: "AKM",     maxDSD: .dsd512),
        DSDCapableDevice(nameSubstring: "AK4497",      vendor: "AKM",     maxDSD: .dsd512),
        DSDCapableDevice(nameSubstring: "AK4493",      vendor: "AKM",     maxDSD: .dsd256),
    ]

    /// 匹配设备名称；返回声明的最高 DSD 速率（nil = 未匹配）
    public static func matches(name: String) -> DSDRate? {
        let lower = name.lowercased()
        for d in builtIn where lower.contains(d.nameSubstring.lowercased()) {
            return d.maxDSD
        }
        return nil
    }
}

private extension DSDCapableDevice {
    /// 兼容写法：方便 KnownDSDDevices 内部用 "vendorMaxIsDoP" 参数名（语义等价）
    init(nameSubstring: String, vendor: String, vendorMaxIsDoP: DSDRate) {
        self.init(nameSubstring: nameSubstring, vendor: vendor, maxDSD: vendorMaxIsDoP)
    }
}

/// DAC 能力探测器 — 综合多源信息判定 DAC 能否处理某 DSD 速率
///
/// 信息源优先级：
///   1. 设备名匹配 KnownDSDDevices 白名单（最强 — 厂商规格）
///   2. CoreAudio AvailableNominalSampleRates 包含 DoP carrier rate（必要条件）
///   3. 单独的 maxPCMRate 推断（弱证据）
public struct DACCapabilityProbe {

    public struct Result: Sendable {
        public let device: AudioDevice
        public let maxPCMRate: Double
        public let supportsDSD64: Bool
        public let supportsDSD128: Bool
        public let supportsDSD256: Bool
        public let supportsDSD512: Bool
        public let isWhitelisted: Bool
        public let whitelistMaxDSD: DSDRate?

        public func supports(_ rate: DSDRate) -> Bool {
            switch rate {
            case .dsd64:   return supportsDSD64
            case .dsd128:  return supportsDSD128
            case .dsd256:  return supportsDSD256
            case .dsd512:  return supportsDSD512
            case .dsd1024: return false   // PCM-only fallback; no DAC carries 2.8224 MHz PCM (Q15/Q19)
            }
        }
    }

    public static func probe(_ device: AudioDevice) -> Result {
        let rates = device.supportedRates
        let maxRate = rates.max() ?? device.maxSampleRate

        // 名字白名单
        let whitelistMatch = KnownDSDDevices.matches(name: device.name)

        // 速率匹配（DoP carrier 必须出现在 supportedRates 中）
        func hasRate(_ r: Double) -> Bool {
            rates.contains { abs($0 - r) < 0.5 }
        }

        // 综合判定：DoP carrier 速率"出现"或被白名单声明
        func supports(_ rate: DSDRate) -> Bool {
            let carrier = rate.dopCarrierRate
            let rateSupported = hasRate(carrier) || maxRate >= carrier
            if let w = whitelistMatch {
                return rate.rawValue <= w.rawValue && (rateSupported || true)
            }
            return rateSupported
        }

        return Result(
            device: device,
            maxPCMRate: maxRate,
            supportsDSD64:  supports(.dsd64),
            supportsDSD128: supports(.dsd128),
            supportsDSD256: supports(.dsd256),
            supportsDSD512: supports(.dsd512),
            isWhitelisted:  whitelistMatch != nil,
            whitelistMaxDSD: whitelistMatch
        )
    }
}
