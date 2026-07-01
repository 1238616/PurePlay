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

        if let target = preferences.resamplerTargetRate,
           target != inputFormat.sampleRate {
            nodes.append(LinearResamplerNode(targetRate: target))
        }

        if preferences.eqEnabled && !preferences.parametricBands.isEmpty {
            nodes.append(ParametricEQNode(bands: preferences.parametricBands,
                                          preamp: preferences.preamp))
        }

        if preferences.crossfeedEnabled && inputFormat.channels == 2 {
            nodes.append(CrossfeedNode(intensity: preferences.crossfeedIntensity))
        }

        if preferences.ditherEnabled {
            nodes.append(DitherNode(targetBitDepth: preferences.ditherTargetBitDepth))
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

    public var resamplerTargetRate: Double? = nil

    public var eqEnabled: Bool = false
    public var parametricBands: [ParametricBand] = []
    public var preamp: Float = 0

    public var crossfeedEnabled: Bool = false
    public var crossfeedIntensity: Float = 0.5

    public var ditherEnabled: Bool = false
    public var ditherTargetBitDepth: Int = 16

    public init() {}
}
