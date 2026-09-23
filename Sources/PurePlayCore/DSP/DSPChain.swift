import Foundation

/// DSP 节点接口（借鉴 VLC `aout_filter_t`）
public protocol DSPNode: AnyObject {
    var isEnabled: Bool { get set }
    var name: String { get }

    /// 当输入格式变化时调用，返回输出格式（可与输入相同）
    func configure(inputFormat: AudioFormat) -> AudioFormat

    /// 处理 frameCount 帧
    /// 输入与输出可重叠（in-place）；要求 sampleFormat = .float32
    func process(input: UnsafePointer<Float>,
                 output: UnsafeMutablePointer<Float>,
                 frameCount: Int)
}

/// DSP Chain — 自动组装多个节点
/// 借鉴 VLC `src/audio_output/filters.c` 的 aout_FiltersPipelineCreate
public final class DSPChain {
    public private(set) var nodes: [DSPNode]
    public let inputFormat: AudioFormat
    public let outputFormat: AudioFormat

    public init(nodes: [DSPNode], inputFormat: AudioFormat) {
        self.nodes = nodes
        self.inputFormat = inputFormat
        var fmt = inputFormat
        for node in nodes {
            fmt = node.configure(inputFormat: fmt)
        }
        self.outputFormat = fmt
    }

    /// 构造器 — 根据用户偏好自动组装节点
    public static func build(inputFormat: AudioFormat,
                             preferences: DSPPreferences) -> DSPChain {
        // Bit-Perfect 模式：完全空链
        if preferences.bitPerfect {
            return DSPChain(nodes: [], inputFormat: inputFormat)
        }

        var nodes: [DSPNode] = []

        if preferences.replayGainEnabled {
            nodes.append(GainNode(gainDB: preferences.replayGainDB))
        }

        // issue #5：重采样不进 DSPChain — 它改变帧数，等长 in-place 接口装不下。
        // 由 AudioPipeline 用 SincResampler 在独立的变长路径中处理
        // preferences.resamplerTargetRate。

        if preferences.eqEnabled && !preferences.parametricBands.isEmpty {
            nodes.append(ParametricEQNode(bands: preferences.parametricBands,
                                          preamp: preferences.preamp))
        }

        if preferences.crossfeedEnabled && inputFormat.channels == 2 {
            nodes.append(CrossfeedNode(
                intensity: preferences.crossfeedIntensity,
                preset: BS2BPreset.fromConfig(preferences.crossfeedPreset)))
        }

        // issue #9：dither 不再挂在 float 链中 — 量化噪声整形必须发生在
        // **真正的量化点**（float → 整数输出转换），由 AudioPipeline 内的
        // PCMOutputConverter 结合 ditherEnabled/ditherTargetBitDepth 执行。
        // 旧 DitherNode 在 float 域预量化后 HAL 还会再量化一次，形同虚设；
        // 类保留供单测与实验，但不再自动接线。

        // issue #7：链末软限幅 — EQ/preamp/Gain 提升后峰值超过 ±1.0 时，
        // 整数输出量化会产生硬削波。阈值 0.8 以下零失真直通，超过部分
        // tanh 软膝渐近压向 1.0，永不越界。
        if preferences.limiterEnabled {
            nodes.append(SoftLimiterNode())
        }

        return DSPChain(nodes: nodes, inputFormat: inputFormat)
    }

    /// 处理一批帧；in-place 工作
    public func process(buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        for node in nodes where node.isEnabled {
            node.process(input: buffer, output: buffer, frameCount: frameCount)
        }
    }

    public var isBypass: Bool {
        nodes.allSatisfy { !$0.isEnabled }
    }

    /// Find the first node of a given type. Used for hot-updating in-place
    /// without leaking the full nodes array.
    public func firstNode<T: DSPNode>(of type: T.Type) -> T? {
        for node in nodes {
            if let typed = node as? T { return typed }
        }
        return nil
    }
}

/// DSP 偏好配置
public struct DSPPreferences: Sendable {
    public var bitPerfect: Bool = true

    public var replayGainEnabled: Bool = false
    public var replayGainDB: Float = 0

    /// 目标重采样率（issue #5/#17：倍率上采样选项的基础）。
    /// 由 AudioPipeline 经 SincResampler（-95dB Kaiser 多相）消费；
    /// bit-perfect 或 DSD/DoP 路径下被忽略（重采样必然改变样本流）。
    public var resamplerTargetRate: Double? = nil

    public var eqEnabled: Bool = false
    public var parametricBands: [ParametricBand] = []
    public var preamp: Float = 0

    public var crossfeedEnabled: Bool = false
    public var crossfeedIntensity: Float = 0.5
    /// BS2B 预设名（issue #17-3）："default"(700Hz/4.5dB) /
    /// "cmoy"(700Hz/6dB) / "jmeier"(650Hz/9.5dB)。未知值归一化为 default。
    public var crossfeedPreset: String = "default"

    /// TPDF dither — 由 PCMOutputConverter 在 float → 整数量化点施加（issue #9）
    public var ditherEnabled: Bool = false
    /// dither/降位目标位深：≤16 → 输出 int16，否则 int24
    public var ditherTargetBitDepth: Int = 16

    /// 链末软限幅（issue #7）：防止 EQ/preamp 提升后整数输出量化硬削波。
    /// 阈值 0.8 以下完全直通，无听感代价。
    public var limiterEnabled: Bool = true

    public init() {}
}
