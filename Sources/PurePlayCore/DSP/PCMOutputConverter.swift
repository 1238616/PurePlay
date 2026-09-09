import Foundation

/// 软限幅器（issue #7）
///
/// 背景：EQ / preamp / ReplayGain 提升增益后 float 峰值可能超过 ±1.0。
/// float 域内这合法，但转换成整数输出时会变成硬削波 — 削平的波顶产生
/// 大量奇次谐波，听感刺耳。本节点是链末最后一道防线：
///   |x| ≤ threshold：原样直通（零失真，绝大多数信号走这条路）
///   |x| > threshold：y = T + (1-T)·tanh((|x|-T)/(1-T))，奇对称
/// 输出渐近逼近 1.0 但永不越过 — 无记忆非线性映射，零延迟、零状态。
public final class SoftLimiterNode: DSPNode {
    public var isEnabled: Bool = true
    public let name = "SoftLimiter"

    /// 软膝拐点（线性幅度）。默认 0.8 ≈ -1.94 dBFS
    public let threshold: Float
    private let knee: Float   // = 1 - threshold

    public init(threshold: Float = 0.8) {
        let t = max(0.01, min(0.99, threshold))
        self.threshold = t
        self.knee = 1 - t
    }

    public func configure(inputFormat: AudioFormat) -> AudioFormat { inputFormat }

    /// 与 GainNode 同约定：frameCount 实为样本数（帧数 × 声道数）
    public func process(input: UnsafePointer<Float>,
                        output: UnsafeMutablePointer<Float>,
                        frameCount: Int) {
        for i in 0..<frameCount {
            let x = input[i]
            let a = abs(x)
            guard a > threshold else {
                output[i] = x
                continue
            }
            let y = threshold + knee * tanh((a - threshold) / knee)
            output[i] = x > 0 ? y : -y
        }
    }
}

/// float → 整数 PCM 输出转换器（issue #9）
///
/// 背景：DSP 开启时管线曾固定输出 float32，把最终量化交给 CoreAudio HAL —
/// 不带 dither 且不可控；旧 DitherNode 在 float 域"预量化"，随后 HAL 再做
/// 一次未整形的 float→int，噪声整形形同虚设。本类把量化点收进 PurePlay：
///   1. 按源文件原生位深输出（16-bit 源 → int16，24-bit 源 → int24）
///   2. TPDF dither 施加在**真正的量化点**（开启时），这是标准位置
///   3. xorshift32 PRNG 取代 Float.random — 热路径逐样本调用，
///      SystemRandomNumberGenerator 的熵开销与锁竞争不可接受
///
/// 数学：q = clamp( Q(x·2^(B-1) + d), [-2^(B-1), 2^(B-1)-1] )
///   d ∈ [-1,+1) LSB 三角分布（两个均匀分布之和）
///   带 dither 用 floor（截断）→ 无偏量化；不带 dither 用四舍五入。
public final class PCMOutputConverter {
    public let targetFormat: SampleFormat
    public let ditherEnabled: Bool

    private let scale: Double        // 2^(B-1)
    private let maxCode: Int64
    private let minCode: Int64
    /// xorshift32 状态（非零即可；黄金比例常数做种子）
    private var rng: UInt32 = 0x9E37_79B9

    public init(targetFormat: SampleFormat, ditherEnabled: Bool) {
        precondition(targetFormat.isInteger, "PCMOutputConverter requires an integer target format")
        let bits = targetFormat.bitDepth
        self.targetFormat = targetFormat
        self.ditherEnabled = ditherEnabled
        self.scale = pow(2.0, Double(bits - 1))
        self.maxCode = (Int64(1) << Int64(bits - 1)) - 1
        self.minCode = -(Int64(1) << Int64(bits - 1))
    }

    /// 将 interleaved float 样本转换为 interleaved 目标整数格式（小端）
    public func convert(input: UnsafePointer<Float>,
                        output: UnsafeMutableRawPointer,
                        sampleCount: Int) {
        let out = output.assumingMemoryBound(to: UInt8.self)
        switch targetFormat {
        case .int16:
            for i in 0..<sampleCount {
                let q = quantize(input[i])
                out[i * 2]     = UInt8(truncatingIfNeeded: q)
                out[i * 2 + 1] = UInt8(truncatingIfNeeded: q >> 8)
            }
        case .int24:
            for i in 0..<sampleCount {
                let q = quantize(input[i])
                out[i * 3]     = UInt8(truncatingIfNeeded: q)
                out[i * 3 + 1] = UInt8(truncatingIfNeeded: q >> 8)
                out[i * 3 + 2] = UInt8(truncatingIfNeeded: q >> 16)
            }
        case .int32:
            for i in 0..<sampleCount {
                let q = quantize(input[i])
                out[i * 4]     = UInt8(truncatingIfNeeded: q)
                out[i * 4 + 1] = UInt8(truncatingIfNeeded: q >> 8)
                out[i * 4 + 2] = UInt8(truncatingIfNeeded: q >> 16)
                out[i * 4 + 3] = UInt8(truncatingIfNeeded: q >> 24)
            }
        case .float32:
            // precondition 已挡住；防御性退化为直拷
            memcpy(output, input, sampleCount * 4)
        }
    }

    // MARK: - 量化核心

    private func quantize(_ x: Float) -> Int64 {
        // 先 clamp 到 ±2 满幅 — 防止 Int64(±inf) 运行时陷阱（上游限幅器
        // 失效或未启用时 EQ 提升可产生 >1.0 甚至 inf 的样本）
        let xc = Double(max(-2.0, min(2.0, x)))
        let q: Int64
        if ditherEnabled {
            // dither + floor（截断）= 无偏量化：三角抖动覆盖 ±1 LSB
            q = Int64((xc * scale + Double(tpdfLSB())).rounded(.down))
        } else {
            q = Int64((xc * scale).rounded())
        }
        return min(max(q, minCode), maxCode)
    }

    /// 三角分布 dither：两个独立均匀分布之和，范围 [-1, +1) LSB
    private func tpdfLSB() -> Float {
        uniform01() + uniform01() - 1
    }

    /// xorshift32 → [0,1) 均匀分布（24-bit 精度，足够 TPDF dither 用）
    private func uniform01() -> Float {
        rng ^= rng << 13
        rng ^= rng >> 17
        rng ^= rng << 5
        return Float(rng >> 8) / 16_777_216.0   // 2^24
    }
}
