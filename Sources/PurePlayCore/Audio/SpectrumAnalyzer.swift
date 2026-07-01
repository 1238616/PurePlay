import Foundation
import Accelerate

public final class SpectrumAnalyzer: @unchecked Sendable {
    public let bandCount: Int
    public let fftSize: Int

    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private var window: [Float]
    private var realBuffer: [Float]
    private var imagBuffer: [Float]
    private var magnitudes: [Float]
    private var bandValues: [Float]
    private var smoothedBands: [Float]
    private let attackCoef: Float
    private let releaseCoef: Float
    private var sampleRate: Float
    private let lock = NSLock()

    public init(bandCount: Int = 32,
                fftSize: Int = 1024,
                sampleRate: Float = 44_100,
                attackTime: Float = 0.05,
                releaseTime: Float = 0.3) {
        precondition((fftSize & (fftSize - 1)) == 0, "fftSize must be a power of two")
        self.bandCount = bandCount
        self.fftSize = fftSize
        self.sampleRate = sampleRate
        // process() runs once per fftSize input samples → frameRate ≈ sampleRate / fftSize
        let frameRate = max(1, sampleRate / Float(fftSize))
        self.attackCoef = Self.coefForTimeConstant(attackTime, frameRate: frameRate)
        self.releaseCoef = Self.coefForTimeConstant(releaseTime, frameRate: frameRate)
        self.log2n = vDSP_Length(log2(Double(fftSize)))
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        self.window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        self.realBuffer = [Float](repeating: 0, count: fftSize / 2)
        self.imagBuffer = [Float](repeating: 0, count: fftSize / 2)
        self.magnitudes = [Float](repeating: 0, count: fftSize / 2)
        self.bandValues = [Float](repeating: 0, count: bandCount)
        self.smoothedBands = [Float](repeating: 0, count: bandCount)
    }

    @available(*, deprecated, message: "Use attackTime/releaseTime + sampleRate initializer")
    public convenience init(bandCount: Int, fftSize: Int, smoothing: Float) {
        // Map old symmetric smoothing onto attack/release time constants
        // smoothing was a per-frame retention coefficient (smoothed = old * s + new * (1-s)).
        // Inverting: timeConstant = -1 / (log(s) * frameRate). Assume default 44.1k/1024 → frameRate ≈ 43Hz.
        let assumedFrameRate: Float = 44_100 / 1024
        let tc: Float
        if smoothing > 0 && smoothing < 1 {
            tc = -1 / (log(smoothing) * assumedFrameRate)
        } else {
            tc = 0.05
        }
        self.init(bandCount: bandCount, fftSize: fftSize,
                  sampleRate: 44_100, attackTime: tc, releaseTime: tc)
    }

    private static func coefForTimeConstant(_ tc: Float, frameRate: Float) -> Float {
        guard tc > 0 else { return 1.0 }
        return 1 - exp(-1 / (tc * frameRate))
    }

    /// Update the analyzer's sample rate (e.g. when track changes).
    /// Note: attack/release coefficients were computed at init time for the original rate;
    /// rebuilding the analyzer is preferred for major rate changes. This setter only
    /// affects the next frequency-to-bin mapping.
    public func setSampleRate(_ rate: Float) {
        lock.lock()
        sampleRate = rate
        lock.unlock()
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    public func process(samples: UnsafePointer<Float>, frameCount: Int, channels: Int) {
        guard frameCount >= fftSize else { return }
        var mono = [Float](repeating: 0, count: fftSize)
        if channels == 1 {
            mono.withUnsafeMutableBufferPointer { buf in
                memcpy(buf.baseAddress!, samples, fftSize * MemoryLayout<Float>.size)
            }
        } else {
            for i in 0..<fftSize {
                var sum: Float = 0
                for c in 0..<channels { sum += samples[i * channels + c] }
                mono[i] = sum / Float(channels)
            }
        }
        vDSP_vmul(mono, 1, window, 1, &mono, 1, vDSP_Length(fftSize))

        let halfSize = fftSize / 2
        realBuffer.withUnsafeMutableBufferPointer { realPtr in
            imagBuffer.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                mono.withUnsafeBufferPointer { monoPtr in
                    monoPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(halfSize))
                    }
                }
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(halfSize))
            }
        }
        var normFactor: Float = 1.0 / Float(fftSize * fftSize)
        vDSP_vsmul(magnitudes, 1, &normFactor, &magnitudes, 1, vDSP_Length(halfSize))

        // Map bin indices to Hz using current sample rate, then distribute log-spaced bands
        // between 20Hz and Nyquist.
        let currentRate: Float = {
            lock.lock(); defer { lock.unlock() }
            return sampleRate
        }()
        let nyquist = max(1, currentRate / 2)
        let binHz = nyquist / Float(halfSize)
        let minHz: Float = 20.0
        let maxHz: Float = nyquist
        let minLog = log10(minHz)
        let maxLog = log10(maxHz)
        let span = max(1e-6, maxLog - minLog)

        var newBands = [Float](repeating: 0, count: bandCount)
        for b in 0..<bandCount {
            let lowFrac = Float(b) / Float(bandCount)
            let highFrac = Float(b + 1) / Float(bandCount)
            let lowHz = pow(10, minLog + span * lowFrac)
            let highHz = pow(10, minLog + span * highFrac)
            let lowIdx = max(1, min(halfSize - 1, Int(lowHz / binHz)))
            let highIdx = min(halfSize - 1, max(lowIdx + 1, Int(highHz / binHz)))
            var sum: Float = 0
            for i in lowIdx...highIdx { sum += magnitudes[i] }
            let avg = sum / Float(highIdx - lowIdx + 1)
            let db = 10 * log10(max(avg, 1e-9))
            let normalized = max(0, min(1, (db + 60) / 60))
            newBands[b] = normalized
        }

        lock.lock()
        for i in 0..<bandCount {
            let target = newBands[i]
            let current = smoothedBands[i]
            let coef = (target > current) ? attackCoef : releaseCoef
            smoothedBands[i] = current + (target - current) * coef
        }
        bandValues = smoothedBands
        lock.unlock()
    }

    public func currentBands() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return bandValues
    }

    public func reset() {
        lock.lock()
        smoothedBands = [Float](repeating: 0, count: bandCount)
        bandValues = [Float](repeating: 0, count: bandCount)
        lock.unlock()
    }
}
