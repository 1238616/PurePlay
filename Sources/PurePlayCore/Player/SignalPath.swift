import Foundation

/// 信号路径描述 — 在 PurePlayCore 内构建，UI 层渲染
///
/// PurePlay 独创：让发烧友看见整条信号路径的每个节点状态。
/// 设计目标：
///   1. 任何 DSP 节点变化、采样率匹配状态变化都能立即反映
///   2. 是否真正 bit-perfect 一眼可知（"Bit-Perfect"指示灯）
///   3. 文本格式适合状态栏、底栏、tooltip
public struct SignalPath: Sendable, Equatable {

    /// 源段：解码器输出的原始格式
    public struct Source: Sendable, Equatable {
        public let format: String        // "FLAC 24/96", "DSD64", "WAV 16/44.1"
        public let isDSD: Bool
        public init(format: String, isDSD: Bool) {
            self.format = format
            self.isDSD = isDSD
        }
    }

    /// DSP 段：链上每个启用节点的名称
    public struct DSP: Sendable, Equatable {
        public let enabledNodes: [String]   // ["EQ", "Crossfeed"]; [] = bypass
        public var isBypass: Bool { enabledNodes.isEmpty }
        public init(enabledNodes: [String]) {
            self.enabledNodes = enabledNodes
        }
    }

    /// 输出段：硬件端实际格式与设备
    public struct Output: Sendable, Equatable {
        public let format: String           // "96kHz/24bit" 或 "DoP DSD64"
        public let deviceName: String
        public let isHogMode: Bool
        public let hardwareRateMatched: Bool
        public init(format: String, deviceName: String,
                    isHogMode: Bool, hardwareRateMatched: Bool) {
            self.format = format
            self.deviceName = deviceName
            self.isHogMode = isHogMode
            self.hardwareRateMatched = hardwareRateMatched
        }
    }

    public let source: Source
    public let dsp: DSP
    public let output: Output

    public init(source: Source, dsp: DSP, output: Output) {
        self.source = source
        self.dsp = dsp
        self.output = output
    }

    /// 用户可见的"信号路径文本"
    /// 示例： "FLAC 24/96 → Bit-Perfect → ES9038 Hog 96kHz/24bit ✓"
    public var displayText: String {
        let mid: String
        if dsp.isBypass {
            mid = "Bit-Perfect"
        } else {
            mid = dsp.enabledNodes.joined(separator: " → ")
        }
        let hogTag = output.isHogMode ? " Hog" : ""
        let matchTag = output.hardwareRateMatched ? " ✓" : " ⚠"
        return "\(source.format) → \(mid) → \(output.deviceName)\(hogTag) \(output.format)\(matchTag)"
    }

    /// 真 bit-perfect 判定：DSP 全 bypass + 硬件率匹配
    public var isBitPerfect: Bool {
        dsp.isBypass && output.hardwareRateMatched
    }

    // MARK: - Builder

    public static func build(decoderFormat: AudioFormat,
                             dspChain: DSPChain,
                             outputFormat: AudioFormat,
                             device: AudioDevice?,
                             isHogMode: Bool,
                             hardwareRateMatched: Bool) -> SignalPath {

        let source = Source(
            format: formatSource(decoderFormat),
            isDSD: decoderFormat.isDSD
        )

        let nodes = dspChain.nodes.filter { $0.isEnabled }.map { $0.name }
        let dsp = DSP(enabledNodes: nodes)

        let output = Output(
            format: formatOutput(outputFormat),
            deviceName: device?.name ?? "System Output",
            isHogMode: isHogMode,
            hardwareRateMatched: hardwareRateMatched
        )

        return SignalPath(source: source, dsp: dsp, output: output)
    }

    private static func formatSource(_ f: AudioFormat) -> String {
        if f.isDSD {
            let mult = Int(f.dsdRateRaw / 2_822_400.0)
            return "DSD\(64 * mult)"
        }
        return "PCM \(Int(f.sampleRate))/\(f.bitDepth)"
    }

    private static func formatOutput(_ f: AudioFormat) -> String {
        if f.isDSD {
            let mult = Int(f.dsdRateRaw / 2_822_400.0)
            return "DoP DSD\(64 * mult)"
        }
        let khz = Int(f.sampleRate / 100) / 10  // 简化整数 kHz
        let frac = Int((f.sampleRate / 100).truncatingRemainder(dividingBy: 10))
        if frac == 0 {
            return "\(khz)kHz/\(f.bitDepth)bit"
        }
        return "\(khz).\(frac)kHz/\(f.bitDepth)bit"
    }
}
