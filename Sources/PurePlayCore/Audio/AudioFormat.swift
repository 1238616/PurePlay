import Foundation

/// PCM 样本格式
public enum SampleFormat: Equatable, Sendable {
    case int16
    case int24      // packed 24-bit, 3 bytes per sample
    case int32
    case float32

    public var bytesPerSample: Int {
        switch self {
        case .int16:   return 2
        case .int24:   return 3
        case .int32:   return 4
        case .float32: return 4
        }
    }

    public var bitDepth: Int {
        switch self {
        case .int16:   return 16
        case .int24:   return 24
        case .int32:   return 32
        case .float32: return 32
        }
    }

    public var isInteger: Bool {
        self != .float32
    }
}

/// 音频格式描述（贯穿解码 → DSP → 输出全链路）
public struct AudioFormat: Equatable, Sendable {
    public let sampleRate: Double
    public let channels: Int
    public let sampleFormat: SampleFormat

    /// DSD 标记：当为 true 时，sampleRate 表示 DSD bitstream 速率（如 2_822_400）
    public let isDSD: Bool

    /// 源文件原生位深（UI 显示用）。nil 时回落到 sampleFormat.bitDepth。
    /// 用于：FLAC 24bit 包成 int32 容器时，UI 仍显示 24bit。
    public let sourceBitDepth: Int?

    public init(sampleRate: Double,
                channels: Int,
                sampleFormat: SampleFormat,
                isDSD: Bool = false,
                sourceBitDepth: Int? = nil) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.sampleFormat = sampleFormat
        self.isDSD = isDSD
        self.sourceBitDepth = sourceBitDepth
    }

    /// 每帧字节数（一帧 = N 声道 × bytesPerSample）
    public var bytesPerFrame: Int {
        channels * sampleFormat.bytesPerSample
    }

    /// UI 显示位深（源原生）
    public var bitDepth: Int { sourceBitDepth ?? sampleFormat.bitDepth }

    /// 容器位深（CoreAudio ASBD `mBitsPerChannel` 用）
    public var containerBitDepth: Int { sampleFormat.bitDepth }

    /// 原始 DSD bitstream 速率（仅 isDSD=true 时有意义）。
    /// DoP 协议下 sampleRate 表示 DoP carrier rate = DSD rate / 16，
    /// 因此还原 DSD 速率 = sampleRate * 16（DSD64=2_822_400, DSD128=5_644_800 …）。
    public var dsdRateRaw: Double {
        isDSD ? sampleRate * 16.0 : 0
    }

    /// 整数 PCM 立体声 96kHz/24bit 之类的便捷构造
    public static func pcm(rate: Double, channels: Int = 2, bitDepth: Int = 24) -> AudioFormat {
        let fmt: SampleFormat
        switch bitDepth {
        case 16: fmt = .int16
        case 24: fmt = .int24
        case 32: fmt = .int32
        default: fmt = .float32
        }
        return AudioFormat(sampleRate: rate, channels: channels, sampleFormat: fmt)
    }
}

/// 文件格式枚举（驱动 DecoderRegistry）
public enum AudioFileFormat: String, CaseIterable, Sendable {
    case flac, ape, wav, aiff
    case dsf, dff       // DSD
    case alac, m4a
    case mp3, ogg, opus
    case wavpack = "wv"
    case tta
    case wma, mka, aac
    case unknown

    public static func from(fileExtension ext: String) -> AudioFileFormat {
        AudioFileFormat(rawValue: ext.lowercased()) ?? .unknown
    }

    public var isLossless: Bool {
        switch self {
        case .flac, .ape, .wav, .aiff, .alac, .wavpack, .dsf, .dff, .tta: return true
        default: return false
        }
    }

    public var isDSD: Bool {
        self == .dsf || self == .dff
    }
}
