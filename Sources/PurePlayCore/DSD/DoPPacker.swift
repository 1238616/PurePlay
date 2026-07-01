import Foundation

/// DSD 速率
public enum DSDRate: Int, CaseIterable, Sendable {
    case dsd64   = 2_822_400
    case dsd128  = 5_644_800
    case dsd256  = 11_289_600
    case dsd512  = 22_579_200
    case dsd1024 = 45_158_400

    public var multiplier: Int {
        rawValue / 44100
    }

    /// DoP 承载所需 PCM 采样率（24-bit）
    public var dopCarrierRate: Double {
        Double(rawValue) / 16.0
    }

    public var recommendedPCMRate: Double {
        switch self {
        case .dsd64:   return 88_200
        case .dsd128:  return 176_400
        case .dsd256:  return 352_800
        case .dsd512:  return 352_800   // 上限到 352.8k
        case .dsd1024: return 384_000   // 默认；可被 AudioPreferences.dsdMaxPCMRate 覆盖到 768_000
        }
    }

    public var displayName: String {
        switch self {
        case .dsd64:   return "DSD64"
        case .dsd128:  return "DSD128"
        case .dsd256:  return "DSD256"
        case .dsd512:  return "DSD512"
        case .dsd1024: return "DSD1024"
        }
    }
}

/// DoP (DSD over PCM) v1.1 打包器
/// 协议：
///   每 24-bit PCM sample 高字节 = 0x05 或 0xFA（交替）
///   低 16 bit = 16 个 DSD bits
///
/// 输入：DSD bitstream（每字节 8 个 1-bit DSD samples）
/// 输出：24-bit big-endian PCM 样本流（packed 3 字节）
public final class DoPPacker {

    private var markerToggle: UInt8 = 0x05

    /// 字节序模式
    public enum BitOrder {
        case lsbFirst   // DSF 容器
        case msbFirst   // DFF 容器
    }

    public let bitOrder: BitOrder
    public let channels: Int

    public init(bitOrder: BitOrder = .lsbFirst, channels: Int = 2) {
        self.bitOrder = bitOrder
        self.channels = channels
    }

    /// 将 dsdBytes 打包为 DoP 24-bit big-endian PCM 立体声
    /// 注意：DSD 输入必须按声道交错（声道 0 字节, 声道 1 字节, ...）
    ///
    /// 输入 dsdBytesPerChannel 字节 →
    /// 输出 (dsdBytesPerChannel / 2) 个 DoP 帧，每帧 channels × 3 字节
    ///
    /// - Returns: 写入的 PCM 字节数
    @discardableResult
    public func pack(dsdInterleaved: UnsafePointer<UInt8>,
                     dsdBytes: Int,
                     outPCM: UnsafeMutablePointer<UInt8>,
                     outCapacity: Int) -> Int {
        // 每个 DoP 帧需要 2 字节 DSD / channel
        let dsdBytesPerFrame = 2 * channels
        guard dsdBytesPerFrame > 0, dsdBytes >= dsdBytesPerFrame else { return 0 }
        let framesAvailable = dsdBytes / dsdBytesPerFrame
        let bytesPerFrame = channels * 3
        let framesByCapacity = outCapacity / bytesPerFrame
        let frames = min(framesAvailable, framesByCapacity)

        for f in 0..<frames {
            for c in 0..<channels {
                let dsdBase = f * dsdBytesPerFrame + c * 2
                let b0 = dsdInterleaved[dsdBase]
                let b1 = dsdInterleaved[dsdBase + 1]
                let (hi, lo): (UInt8, UInt8) = {
                    switch bitOrder {
                    case .msbFirst: return (b0, b1)
                    case .lsbFirst: return (Self.reverse(b0), Self.reverse(b1))
                    }
                }()
                let pcmOffset = f * bytesPerFrame + c * 3
                outPCM[pcmOffset] = markerToggle
                outPCM[pcmOffset + 1] = hi
                outPCM[pcmOffset + 2] = lo
            }
            // 每帧切换标记字节
            markerToggle = (markerToggle == 0x05) ? 0xFA : 0x05
        }
        return frames * bytesPerFrame
    }

    /// 检测某个 24-bit PCM 字节流的高字节是否符合 DoP 标记交替
    /// 用于解包验证
    public static func isDoPStream(_ pcm24BE: UnsafePointer<UInt8>,
                                   length: Int,
                                   channels: Int) -> Bool {
        let frames = length / (channels * 3)
        guard frames >= 2 else { return false }
        var expected: UInt8 = pcm24BE[0]
        guard expected == 0x05 || expected == 0xFA else { return false }
        for f in 0..<frames {
            for c in 0..<channels {
                let marker = pcm24BE[f * channels * 3 + c * 3]
                if marker != expected { return false }
            }
            expected = (expected == 0x05) ? 0xFA : 0x05
        }
        return true
    }

    /// 比特反转表
    private static func reverse(_ b: UInt8) -> UInt8 {
        var x = b
        x = (x >> 4) | (x << 4)
        x = ((x & 0xCC) >> 2) | ((x & 0x33) << 2)
        x = ((x & 0xAA) >> 1) | ((x & 0x55) << 1)
        return x
    }

    public func resetMarker() {
        markerToggle = 0x05
    }
}

/// DSD 输出策略决策
public enum DSDOutputStrategy: Equatable {
    case dop(carrierRate: Double)
    case pcm(targetRate: Double)
}

public enum DSDPreference {
    case preferDoP
    case alwaysPCM
    case auto
}

public struct DACCapabilities: Sendable {
    public let maxPCMRate: Double
    public let isWhitelisted: Bool

    public init(maxPCMRate: Double, isWhitelisted: Bool = false) {
        self.maxPCMRate = maxPCMRate
        self.isWhitelisted = isWhitelisted
    }

    public func supportsDoP(for rate: DSDRate) -> Bool {
        maxPCMRate >= rate.dopCarrierRate
    }
}

public enum DSDStrategyChooser {
    public static func choose(rate: DSDRate,
                              dac: DACCapabilities,
                              preference: DSDPreference,
                              userMaxPCM: Double = AudioPreferences.dsdMaxPCMRate) -> DSDOutputStrategy {
        let dacSupports = dac.supportsDoP(for: rate)
        // For DSD1024 the recommended PCM is 384k by default; if the user opts into
        // 768k via preferences, expose that. For lower DSD rates the recommended
        // ceiling is already ≤ 352.8k so userMaxPCM never lowers them below sane values.
        let cappedPCM: Double
        if rate == .dsd1024 {
            cappedPCM = max(rate.recommendedPCMRate, min(768_000, userMaxPCM))
        } else {
            cappedPCM = rate.recommendedPCMRate
        }
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
