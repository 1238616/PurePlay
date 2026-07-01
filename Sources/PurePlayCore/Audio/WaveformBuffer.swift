import Foundation

/// 滚动波形缓冲 — 把音频帧聚合成 (peak, rms) 桶，供 Metal/CALayer 滚动渲染
///
/// 设计：
///   - 输入由解码线程（PCMRingBuffer 写入端旁路 tap）调用 push(samples:)
///   - 输出由 UI 主线程 60 Hz 读取 snapshot(count:) → 最新 N 个 bin
///   - 每个 bin 聚合 `framesPerBin` 帧的双通道平均：返回 `peak`（绝对最大值）+
///     `rms`（均方根）。0..1 归一化（输入 Float [-1, 1]）
///   - 线程安全：单生产者 / 单消费者 + 自旋锁；不会阻塞解码线程
///
/// 推荐参数：
///   - framesPerBin = sampleRate / 1000 * 8   （每 bin 约 8 ms 音频）
///   - capacityBins = 1024（≈ 8 秒滚动窗口）
public final class WaveformBuffer: @unchecked Sendable {

    public struct Bin: Equatable, Sendable {
        public let peak: Float   // [0, 1]
        public let rms: Float    // [0, 1]
        public init(peak: Float, rms: Float) {
            self.peak = peak; self.rms = rms
        }
        public static let zero = Bin(peak: 0, rms: 0)
    }

    public let capacityBins: Int
    /// 每个 bin 聚合的输入帧数（运行期可由 reconfigure 更新）
    public private(set) var framesPerBin: Int

    /// 环形 buffer 内容
    private var bins: [Bin]
    /// 下一个写入位置（mod capacity）
    private var writeIndex: Int = 0
    /// 已写入的累计 bin 数（用于计算 snapshot 起点）
    private var totalBinsWritten: Int = 0

    /// 当前 bin 的累积状态（跨多次 push 拼装一个 bin）
    private var accFramesInBin: Int = 0
    private var accPeak: Float = 0
    private var accSquareSum: Float = 0
    private var accSampleCount: Int = 0

    private let lock = NSLock()

    public init(capacityBins: Int = 1024, framesPerBin: Int = 256) {
        precondition(capacityBins > 0 && framesPerBin > 0)
        self.capacityBins = capacityBins
        self.framesPerBin = framesPerBin
        self.bins = Array(repeating: .zero, count: capacityBins)
    }

    /// 切换 frames-per-bin（采样率变化时调用）
    public func reconfigure(framesPerBin: Int) {
        guard framesPerBin > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        self.framesPerBin = framesPerBin
        accFramesInBin = 0
        accPeak = 0
        accSquareSum = 0
        accSampleCount = 0
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        for i in 0..<capacityBins { bins[i] = .zero }
        writeIndex = 0
        totalBinsWritten = 0
        accFramesInBin = 0
        accPeak = 0
        accSquareSum = 0
        accSampleCount = 0
    }

    /// 解码线程调用 — 推入 interleaved float32 PCM
    /// 单声道也支持；多声道下取各通道幅值的最大值作为 peak
    public func push(samples: UnsafePointer<Float>, frameCount: Int, channels: Int) {
        guard frameCount > 0 && channels > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        let fpb = framesPerBin
        var f = 0
        while f < frameCount {
            // 取当前帧各通道最大幅值 + 累加平方
            var framePeak: Float = 0
            for c in 0..<channels {
                let s = samples[f * channels + c]
                let a = s < 0 ? -s : s
                if a > framePeak { framePeak = a }
                accSquareSum += s * s
            }
            accSampleCount += channels
            if framePeak > accPeak { accPeak = framePeak }
            accFramesInBin += 1
            f += 1

            if accFramesInBin >= fpb {
                let rms = accSampleCount > 0
                    ? (accSquareSum / Float(accSampleCount)).squareRoot()
                    : 0
                let peak = min(1, accPeak)
                bins[writeIndex] = Bin(peak: peak, rms: min(1, rms))
                writeIndex = (writeIndex + 1) % capacityBins
                totalBinsWritten += 1
                accFramesInBin = 0
                accPeak = 0
                accSquareSum = 0
                accSampleCount = 0
            }
        }
    }

    /// UI 线程调用 — 复制最新 N 个 bin（按时间顺序，最早→最新）
    /// 若内部尚未填满 N 个 bin，前面用 .zero 补齐
    public func snapshot(count: Int) -> [Bin] {
        let n = min(count, capacityBins)
        lock.lock(); defer { lock.unlock() }
        var out = [Bin](repeating: .zero, count: n)
        let available = min(totalBinsWritten, capacityBins)
        let need = min(n, available)
        // 最新 bin 在 writeIndex - 1 处；倒着填
        var srcIdx = (writeIndex - 1 + capacityBins) % capacityBins
        for k in 0..<need {
            out[n - 1 - k] = bins[srcIdx]
            srcIdx = (srcIdx - 1 + capacityBins) % capacityBins
        }
        return out
    }

    public var binsWritten: Int {
        lock.lock(); defer { lock.unlock() }
        return totalBinsWritten
    }
}
