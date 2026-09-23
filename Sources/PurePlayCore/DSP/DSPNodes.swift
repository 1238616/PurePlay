import Foundation
import os

// MARK: - Parametric EQ Model

public enum FilterType: String, Codable, Sendable {
    case peaking
    case lowShelf
    case highShelf
    case lowPass12
    case highPass12

    public var displayName: String {
        switch self {
        case .peaking:    return "Peak"
        case .lowShelf:   return "Low Shelf"
        case .highShelf:  return "High Shelf"
        case .lowPass12:  return "Low Pass 12 dB/oct"
        case .highPass12: return "High Pass 12 dB/oct"
        }
    }

    /// Whether the filter uses the gain parameter (false for LP/HP — they only use freq/Q).
    public var usesGain: Bool {
        switch self {
        case .peaking, .lowShelf, .highShelf: return true
        case .lowPass12, .highPass12:         return false
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = FilterType(rawValue: raw) ?? .peaking
    }
}

public struct ParametricBand: Codable, Sendable, Equatable {
    public var type: FilterType
    public var frequency: Double
    public var gain: Float
    public var q: Double
    public var enabled: Bool

    public init(type: FilterType = .peaking, frequency: Double = 1000,
                gain: Float = 0, q: Double = 1.414, enabled: Bool = true) {
        self.type = type
        self.frequency = frequency
        self.gain = gain
        self.q = q
        self.enabled = enabled
    }

    public static let frequencyRange: ClosedRange<Double> = 20...20000
    public static let gainRange: ClosedRange<Float> = -24...24
    public static let qRange: ClosedRange<Double> = 0.1...30
    public static let maxBands = 20
}

// MARK: - Gain Node

/// 简单增益（用于 ReplayGain 与 Pre-amp）
public final class GainNode: DSPNode {
    public var isEnabled: Bool = true
    public let name = "Gain"

    public var gainDB: Float
    private var linearGain: Float

    public init(gainDB: Float) {
        self.gainDB = gainDB
        self.linearGain = pow(10, gainDB / 20)
    }

    public func setGain(dB: Float) {
        self.gainDB = dB
        self.linearGain = pow(10, dB / 20)
    }

    public func configure(inputFormat: AudioFormat) -> AudioFormat { inputFormat }

    public func process(input: UnsafePointer<Float>,
                        output: UnsafeMutablePointer<Float>,
                        frameCount: Int) {
        // process 的 frameCount 是音频帧数（不含通道数）
        // 这里每帧的样本数无法从 DSPNode 直接拿到；约定 buffer 已 packed
        // 调用方传入的 frameCount × channels = 实际样本数
        let n = frameCount
        let g = linearGain
        for i in 0..<n {
            output[i] = input[i] * g
        }
    }
}

// 注：LinearResamplerNode（1:1 直通占位符）已删除（issue #5）。
// 它的 configure() 声称输出 targetRate 但 process() 只逐样本拷贝，
// 会让 AudioPipeline 按错误采样率配置硬件 → 变速变调播放。
// 重采样统一由 SincResampler 在 AudioPipeline 的变长路径中完成。

/// Parametric EQ — up to 20 bands with user-configurable frequency, Q, gain, and filter type.
/// Uses RBJ Audio EQ Cookbook biquad formulas (peaking, low shelf, high shelf).
public final class ParametricEQNode: DSPNode {
    public var isEnabled: Bool = true
    public let name = "ParametricEQ"

    public private(set) var bands: [ParametricBand]

    public private(set) var preamp: Float = 0

    public static let graphicFrequencies: [Double] = [
        31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000
    ]

    private var sampleRate: Double = 44100
    private var channels: Int = 2
    private var needsRecalc = true
    private var preampLinear: Float = 1.0

    // Hot-update plumbing — UI thread writes pending via apply(), audio thread
    // pulls it at block boundary using trylock (never blocks).
    private var updateLock = os_unfair_lock_s()
    private var pendingBands: [ParametricBand]? = nil
    private var pendingPreamp: Float? = nil

    private var coeffs: [[Double]] = []
    private var states: [[[Double]]] = []

    /// Block-level coefficient interpolation state (E7 — click-free transitions).
    /// `prevCoeffs` is the coefficient set at the start of the current transition.
    /// `coeffs` is always the target (steady-state) coefficient set.
    /// During a transition the per-block applied coefficients are
    /// `lerp(prevCoeffs, coeffs, alpha)` where alpha advances from 0 → 1
    /// over `transitionSamplesTotal` frames.
    private var prevCoeffs: [[Double]] = []
    private var transitionSamplesRemaining: Int = 0
    private var transitionSamplesTotal: Int = 0
    private static let transitionMs: Double = 93.0

    public init(bands: [ParametricBand] = [], preamp: Float = 0) {
        self.bands = bands
        self.preamp = preamp
        self.preampLinear = pow(10, preamp / 20.0)
    }

    public convenience init(graphicGains: [Float]) {
        let bands = zip(Self.graphicFrequencies, graphicGains).map { freq, gain in
            ParametricBand(type: .peaking, frequency: freq, gain: gain, q: 1.414)
        }
        self.init(bands: bands)
    }

    /// Thread-safe hot update — UI thread calls this; the audio thread picks
    /// up the change at the start of the next process() block (via trylock).
    /// The audio thread never blocks: if the lock is held, the previous
    /// coefficients are used for one more block and the update lands on the
    /// next one.
    public func apply(bands: [ParametricBand], preamp: Float) {
        os_unfair_lock_lock(&updateLock)
        pendingBands = bands
        pendingPreamp = preamp
        os_unfair_lock_unlock(&updateLock)
    }

    public func configure(inputFormat: AudioFormat) -> AudioFormat {
        sampleRate = inputFormat.sampleRate
        channels = inputFormat.channels
        needsRecalc = true
        recalcCoefficients()
        return inputFormat
    }

    private func recalcCoefficients() {
        let activeBands = bands.filter { band in
            guard band.enabled else { return false }
            return band.type.usesGain ? band.gain != 0 : true
        }

        // E7: snapshot the currently-applied coefficient set as prevCoeffs so we
        // can linearly interpolate to the new (target) set over ~93 ms.
        let prevApplied: [[Double]] = currentAppliedCoefficients()
        let oldBandCount = coeffs.count
        let newBandCount = activeBands.count

        coeffs = []
        if oldBandCount != newBandCount {
            states = Array(repeating: Array(repeating: [0, 0, 0, 0], count: channels),
                           count: newBandCount)
        }

        for band in activeBands {
            let nyquist = sampleRate / 2.0
            let f0 = min(max(band.frequency, 1.0), nyquist - 1.0)
            let dbGain = Double(band.gain)
            let q = max(0.01, band.q)
            let a = pow(10, dbGain / 40.0)
            let w0 = 2.0 * .pi * f0 / sampleRate
            let sinW0 = sin(w0)
            let cosW0 = cos(w0)
            let alpha = sinW0 / (2.0 * q)

            let c: [Double]
            switch band.type {
            case .peaking:
                let b0 = 1.0 + alpha * a
                let b1 = -2.0 * cosW0
                let b2 = 1.0 - alpha * a
                let a0 = 1.0 + alpha / a
                let a1 = -2.0 * cosW0
                let a2 = 1.0 - alpha / a
                c = [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]

            case .lowShelf:
                let sqrtA = sqrt(a)
                let twoSqrtAAlpha = 2.0 * sqrtA * alpha
                let b0 = a * ((a + 1) - (a - 1) * cosW0 + twoSqrtAAlpha)
                let b1 = 2.0 * a * ((a - 1) - (a + 1) * cosW0)
                let b2 = a * ((a + 1) - (a - 1) * cosW0 - twoSqrtAAlpha)
                let a0 = (a + 1) + (a - 1) * cosW0 + twoSqrtAAlpha
                let a1 = -2.0 * ((a - 1) + (a + 1) * cosW0)
                let a2 = (a + 1) + (a - 1) * cosW0 - twoSqrtAAlpha
                c = [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]

            case .highShelf:
                let sqrtA = sqrt(a)
                let twoSqrtAAlpha = 2.0 * sqrtA * alpha
                let b0 = a * ((a + 1) + (a - 1) * cosW0 + twoSqrtAAlpha)
                let b1 = -2.0 * a * ((a - 1) + (a + 1) * cosW0)
                let b2 = a * ((a + 1) + (a - 1) * cosW0 - twoSqrtAAlpha)
                let a0 = (a + 1) - (a - 1) * cosW0 + twoSqrtAAlpha
                let a1 = 2.0 * ((a - 1) - (a + 1) * cosW0)
                let a2 = (a + 1) - (a - 1) * cosW0 - twoSqrtAAlpha
                c = [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]

            case .lowPass12:
                // RBJ LPF: H(s) = 1 / (s^2 + s/Q + 1)
                let b0 = (1.0 - cosW0) / 2.0
                let b1 = 1.0 - cosW0
                let b2 = (1.0 - cosW0) / 2.0
                let a0 = 1.0 + alpha
                let a1 = -2.0 * cosW0
                let a2 = 1.0 - alpha
                c = [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]

            case .highPass12:
                // RBJ HPF: H(s) = s^2 / (s^2 + s/Q + 1)
                let b0 = (1.0 + cosW0) / 2.0
                let b1 = -(1.0 + cosW0)
                let b2 = (1.0 + cosW0) / 2.0
                let a0 = 1.0 + alpha
                let a1 = -2.0 * cosW0
                let a2 = 1.0 - alpha
                c = [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
            }
            coeffs.append(c)
        }

        // E7: build prevCoeffs to match the target band count exactly. Pad with
        // passthrough biquad [1, 0, 0, 0, 0] when the new set has more bands;
        // truncate otherwise. This guarantees lerp endpoints are well-defined.
        let passthrough: [Double] = [1, 0, 0, 0, 0]
        var newPrev: [[Double]] = []
        newPrev.reserveCapacity(newBandCount)
        for i in 0..<newBandCount {
            if i < prevApplied.count {
                newPrev.append(prevApplied[i])
            } else {
                newPrev.append(passthrough)
            }
        }
        prevCoeffs = newPrev

        let total = Int((Self.transitionMs / 1000.0) * sampleRate)
        if total > 0 && oldBandCount > 0 {
            transitionSamplesTotal = total
            transitionSamplesRemaining = total
        } else {
            transitionSamplesTotal = 0
            transitionSamplesRemaining = 0
        }
        needsRecalc = false
    }

    /// Returns the coefficient set currently being applied (accounting for an
    /// in-progress transition). Used to snapshot a smooth handoff when the user
    /// changes the EQ again mid-transition.
    private func currentAppliedCoefficients() -> [[Double]] {
        guard transitionSamplesRemaining > 0,
              transitionSamplesTotal > 0,
              prevCoeffs.count == coeffs.count else {
            return coeffs
        }
        let alpha = 1.0 - Double(transitionSamplesRemaining) / Double(transitionSamplesTotal)
        var out: [[Double]] = []
        out.reserveCapacity(coeffs.count)
        for i in 0..<coeffs.count {
            let p = prevCoeffs[i]
            let t = coeffs[i]
            out.append([
                p[0] + (t[0] - p[0]) * alpha,
                p[1] + (t[1] - p[1]) * alpha,
                p[2] + (t[2] - p[2]) * alpha,
                p[3] + (t[3] - p[3]) * alpha,
                p[4] + (t[4] - p[4]) * alpha,
            ])
        }
        return out
    }

    public func process(input: UnsafePointer<Float>,
                        output: UnsafeMutablePointer<Float>,
                        frameCount: Int) {
        // E8 hot-update: pull pending values from UI thread without blocking.
        if os_unfair_lock_trylock(&updateLock) {
            if let newBands = pendingBands {
                bands = newBands
                pendingBands = nil
                needsRecalc = true
            }
            if let newPreamp = pendingPreamp {
                preamp = newPreamp
                preampLinear = pow(10, newPreamp / 20.0)
                pendingPreamp = nil
            }
            os_unfair_lock_unlock(&updateLock)
        }

        if needsRecalc { recalcCoefficients() }

        if input != UnsafePointer(output) {
            memcpy(output, input, frameCount * MemoryLayout<Float>.size)
        }

        let totalSamples = frameCount
        let ch = channels
        let frames = totalSamples / ch

        if preampLinear != 1.0 {
            for i in 0..<totalSamples {
                output[i] *= preampLinear
            }
        }

        guard !coeffs.isEmpty else { return }

        // E7: compute the per-block coefficient set. While transitioning we
        // linearly interpolate between prevCoeffs and coeffs by the alpha at
        // the *start* of this block. The coefficients are held constant for
        // the whole block (block-level interpolation) to keep the biquad
        // stable; the transition advances block-by-block.
        let isTransitioning = transitionSamplesRemaining > 0
            && transitionSamplesTotal > 0
            && prevCoeffs.count == coeffs.count
        let appliedCoeffs: [[Double]]
        if isTransitioning {
            let alpha = 1.0 - Double(transitionSamplesRemaining) / Double(transitionSamplesTotal)
            var out: [[Double]] = []
            out.reserveCapacity(coeffs.count)
            for i in 0..<coeffs.count {
                let p = prevCoeffs[i]
                let t = coeffs[i]
                out.append([
                    p[0] + (t[0] - p[0]) * alpha,
                    p[1] + (t[1] - p[1]) * alpha,
                    p[2] + (t[2] - p[2]) * alpha,
                    p[3] + (t[3] - p[3]) * alpha,
                    p[4] + (t[4] - p[4]) * alpha,
                ])
            }
            appliedCoeffs = out
        } else {
            appliedCoeffs = coeffs
        }

        for band in 0..<appliedCoeffs.count {
            let c = appliedCoeffs[band]
            let b0 = c[0], b1 = c[1], b2 = c[2], a1 = c[3], a2 = c[4]

            for chIdx in 0..<ch {
                var x1 = states[band][chIdx][0]
                var x2 = states[band][chIdx][1]
                var y1 = states[band][chIdx][2]
                var y2 = states[band][chIdx][3]

                for f in 0..<frames {
                    let idx = f * ch + chIdx
                    let x0 = Double(output[idx])
                    let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                    output[idx] = Float(y0)
                    x2 = x1; x1 = x0
                    y2 = y1; y1 = y0
                }

                states[band][chIdx] = [x1, x2, y1, y2]
            }
        }

        if isTransitioning {
            transitionSamplesRemaining = max(0, transitionSamplesRemaining - frames)
        }
    }

    public func magnitudeAt(frequency: Double) -> Double {
        if needsRecalc { recalcCoefficients() }
        guard !coeffs.isEmpty else { return preamp == 0 ? 1.0 : Double(preampLinear) }
        let w = 2.0 * .pi * frequency / sampleRate
        var totalMag = Double(preampLinear)
        for c in coeffs {
            let b0 = c[0], b1 = c[1], b2 = c[2], a1 = c[3], a2 = c[4]
            let cosW = cos(w)
            let cos2W = cos(2.0 * w)
            let sinW = sin(w)
            let sin2W = sin(2.0 * w)
            let numReal = b0 + b1 * cosW + b2 * cos2W
            let numImag = -(b1 * sinW + b2 * sin2W)
            let denReal = 1.0 + a1 * cosW + a2 * cos2W
            let denImag = -(a1 * sinW + a2 * sin2W)
            let numMagSq = numReal * numReal + numImag * numImag
            let denMagSq = denReal * denReal + denImag * denImag
            totalMag *= sqrt(numMagSq / denMagSq)
        }
        return totalMag
    }

    public func magnitudeDBAt(frequency: Double) -> Double {
        20.0 * log10(max(magnitudeAt(frequency: frequency), 1e-10))
    }
}

/// TPDF Dither — adds triangular probability density function noise
/// before truncation from higher to lower bit depth
///
/// **已停用（issue #9）**：在 float 域预量化 + 抖动后，CoreAudio HAL 还会
/// 再做一次不带抖动的 float→int 量化 — 噪声整形形同虚设。真正的 dither
/// 现由 `PCMOutputConverter` 在 float → 整数输出的实际量化点施加。
/// 本类保留仅供单元测试与实验，`DSPChain.build` 不再自动接线。
/// 另：`Float.random`（SystemRandomNumberGenerator）逐样本调用开销过高，
/// PCMOutputConverter 用 xorshift32 取代。
public final class DitherNode: DSPNode {
    public var isEnabled: Bool = true
    public let name = "Dither"

    public let targetBitDepth: Int
    private var channels: Int = 2

    public init(targetBitDepth: Int = 16) {
        self.targetBitDepth = targetBitDepth
    }

    public func configure(inputFormat: AudioFormat) -> AudioFormat { inputFormat }

    public func process(input: UnsafePointer<Float>,
                        output: UnsafeMutablePointer<Float>,
                        frameCount: Int) {
        let maxVal = Float(1 << (targetBitDepth - 1))
        let invMax = 1.0 / maxVal

        for i in 0..<frameCount {
            let tpdf = (Float.random(in: -1...1) + Float.random(in: -1...1)) * invMax
            let dithered = input[i] + tpdf
            let quantized = (dithered * maxVal).rounded(.toNearestOrAwayFromZero) * invMax
            output[i] = max(-1.0, min(1.0, quantized))
        }
    }
}

/// libbs2b 官方预设（issue #17-3）
///
/// fcutHz / feedX10 直接对应 Boris Mikhaylov libbs2b 的
/// BS2B_DEFAULT_CLEVEL / BS2B_CMOY_CLEVEL / BS2B_JMEIER_CLEVEL
/// （level = feedX10 << 16 | fcutHz）。
public struct BS2BPreset: Equatable, Sendable {
    public let name: String
    /// 低通截止频率 Hz（官方合法范围 300...2000）
    public let fcutHz: Int
    /// 馈送电平，0.1 dB 单位（官方合法范围 10...150）
    public let feedX10: Int

    /// libbs2b BS2B_MINFEED = 10（1.0 dB）— intensity 缩放下限
    public static let minFeedX10 = 10

    public init(name: String, fcutHz: Int, feedX10: Int) {
        self.name = name
        self.fcutHz = fcutHz
        self.feedX10 = feedX10
    }

    /// 官方 BS2B_DEFAULT_CLEVEL：700 Hz，4.5 dB
    public static let standard = BS2BPreset(name: "Default", fcutHz: 700, feedX10: 45)
    /// 官方 BS2B_CMOY_CLEVEL：700 Hz，6.0 dB（Chu Moy 经典耳机）
    public static let chuMoy = BS2BPreset(name: "Chu Moy", fcutHz: 700, feedX10: 60)
    /// 官方 BS2B_JMEIER_CLEVEL：650 Hz，9.5 dB（Jan Meier）
    public static let janMeier = BS2BPreset(name: "Jan Meier", fcutHz: 650, feedX10: 95)

    /// 配置字符串（"default"/"cmoy"/"jmeier"）→ 预设；未知值归一化为 standard
    public static func fromConfig(_ s: String) -> BS2BPreset {
        switch s {
        case "cmoy":   return .chuMoy
        case "jmeier": return .janMeier
        default:       return .standard
        }
    }
}

/// BS2B Crossfeed — Boris Mikhaylov libbs2b 原始算法移植（issue #17-3）
///
/// 取代旧的"Meier 简化版"（单低通 + 能量守恒混合）。官方算法对每声道
/// 并联两条一阶 IIR：
/// - Lowpass    lo[n] = a0_lo·x[n] + b1_lo·lo[n-1]              （对侧低频注入）
/// - Highboost  hi[n] = a0_hi·x[n] + a1_hi·x[n-1] + b1_hi·hi[n-1]（本声道高频保留）
/// - out[L] = (hi[L] + lo[R])·gain，out[R] = (hi[R] + lo[L])·gain
///
/// 系数按 libbs2b init() 精确公式从 (fcut, feed) 推导：
///   GB_lo = feed·(-5/6) − 3 dB；GB_hi = feed/6 − 3 dB
///   G_lo = 10^(GB_lo/20)；G_hi = 1 − 10^(GB_hi/20)
///   Fc_hi = fcut·2^((GB_lo − 20·log10(G_hi))/12)
///   x = exp(−2π·Fc/srate)；b1_lo = b1_hi 各自取 x；
///   a0_lo = G_lo·(1−x_lo)；a0_hi = 1 − G_hi·(1−x_hi)；a1_hi = −x_hi
///   gain = 1/(1 − G_hi + G_lo)（低音补偿 — DC 处总增益精确为 1）
///
/// intensity ∈ [0,1]：0 = 旁通；>0 时 feed 电平从官方 MINFEED(1.0 dB) 线性
/// 缩放到 preset.feedX10 — intensity = 1 即精确等于官方预设参数。
public final class CrossfeedNode: DSPNode {
    public var isEnabled: Bool = true
    public let name = "Crossfeed"
    public var intensity: Float {
        didSet { recomputeCoefficients() }
    }
    public var preset: BS2BPreset {
        didSet { recomputeCoefficients() }
    }

    private var sampleRate: Double = 44100
    private var channels: Int = 2
    private var bypass: Bool = true

    // libbs2b 系数
    private var a0Lo: Float = 0
    private var b1Lo: Float = 0
    private var a0Hi: Float = 1
    private var a1Hi: Float = 0
    private var b1Hi: Float = 0
    private var gain: Float = 1
    // 每声道滤波器状态：lo / hi / asis（前一输入样本，hi 滤波器 a1 项用）
    private var loState = [Float](repeating: 0, count: 2)
    private var hiState = [Float](repeating: 0, count: 2)
    private var asisState = [Float](repeating: 0, count: 2)

    public init(intensity: Float, preset: BS2BPreset = .standard) {
        self.intensity = max(0, min(1, intensity))
        self.preset = preset
        recomputeCoefficients()
    }

    public func configure(inputFormat: AudioFormat) -> AudioFormat {
        sampleRate = inputFormat.sampleRate
        channels = inputFormat.channels
        for i in 0..<2 { loState[i] = 0; hiState[i] = 0; asisState[i] = 0 }
        recomputeCoefficients()
        return inputFormat
    }

    private func recomputeCoefficients() {
        bypass = (intensity <= 0) || channels != 2 || sampleRate < 1
        guard !bypass else { return }

        // feed 由 intensity 缩放：官方 MINFEED(1.0 dB) → preset.feedX10
        let minFeed = Double(BS2BPreset.minFeedX10)
        let feedX10 = (minFeed + Double(intensity) * Double(preset.feedX10) - minFeed * Double(intensity))
        let feed = feedX10 / 10.0

        let gbLo = feed * -5.0 / 6.0 - 3.0
        let gbHi = feed / 6.0 - 3.0
        let gLo = pow(10.0, gbLo / 20.0)
        let gHi = 1.0 - pow(10.0, gbHi / 20.0)
        let fcLo = Double(preset.fcutHz)
        let fcHi = fcLo * pow(2.0, (gbLo - 20.0 * log10(gHi)) / 12.0)

        let xLo = exp(-2.0 * Double.pi * fcLo / sampleRate)
        b1Lo = Float(xLo)
        a0Lo = Float(gLo * (1.0 - xLo))

        let xHi = exp(-2.0 * Double.pi * fcHi / sampleRate)
        b1Hi = Float(xHi)
        a0Hi = Float(1.0 - gHi * (1.0 - xHi))
        a1Hi = Float(-xHi)

        gain = Float(1.0 / (1.0 - gHi + gLo))
    }

    public func process(input: UnsafePointer<Float>,
                        output: UnsafeMutablePointer<Float>,
                        frameCount: Int) {
        if bypass || channels != 2 {
            // 旁通 / mono：直通
            if input != UnsafePointer(output) {
                memcpy(output, input, frameCount * MemoryLayout<Float>.size)
            }
            return
        }
        let stereoFrames = frameCount / 2
        let a0lo = a0Lo, b1lo = b1Lo
        let a0hi = a0Hi, a1hi = a1Hi, b1hi = b1Hi
        let g = gain
        var loL = loState[0], loR = loState[1]
        var hiL = hiState[0], hiR = hiState[1]
        var asL = asisState[0], asR = asisState[1]

        for i in 0..<stereoFrames {
            let l = input[i * 2]
            let r = input[i * 2 + 1]
            // Lowpass：对侧低频注入源
            let nloL = a0lo * l + b1lo * loL
            let nloR = a0lo * r + b1lo * loR
            // Highboost：本声道高频保留（a1 项用上一输入样本）
            let nhiL = a0hi * l + a1hi * asL + b1hi * hiL
            let nhiR = a0hi * r + a1hi * asR + b1hi * hiR
            loL = nloL; loR = nloR
            hiL = nhiL; hiR = nhiR
            asL = l; asR = r
            // Crossfeed 混合 + 低音补偿
            output[i * 2]     = (nhiL + nloR) * g
            output[i * 2 + 1] = (nhiR + nloL) * g
        }
        loState[0] = loL; loState[1] = loR
        hiState[0] = hiL; hiState[1] = hiR
        asisState[0] = asL; asisState[1] = asR
    }
}
