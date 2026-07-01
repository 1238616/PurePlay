import Foundation
import Atomics

/// 音频管线编排器
/// 借鉴 VLC `src/audio_output/output.c` + `dec.c`
///
/// File → Source → Decoder → [DSPChain] → RingBuffer → Output
public final class AudioPipeline {

    public private(set) var decoder: AudioDecoder
    public let dspChain: DSPChain
    public let ringBuffer: PCMRingBuffer
    public let output: AudioOutputBackend
    public let outputFormat: AudioFormat

    /// Optional spectrum analyzer that taps the decoded float buffer.
    public var spectrumAnalyzer: SpectrumAnalyzer?

    /// Optional waveform buffer that taps the decoded float buffer (UI scrolling waveform)
    public var waveformBuffer: WaveformBuffer?

    /// 起播时硬件采样率是否成功匹配源文件（true = 真 bit-perfect 路径）
    public private(set) var didMatchHardwareRate: Bool = false

    private var decodeThread: Thread?
    private let _isRunning = ManagedAtomic<Bool>(false)
    private var isRunning: Bool { _isRunning.load(ordering: .acquiring) }

    /// 保护 decoder.seek / decoder.decode 互斥；ring buffer reset 也在锁内执行
    private let seekLock = NSLock()

    /// 便捷初始化：给定解码器和配置，自动构建管线
    public init(decoder: AudioDecoder,
                output: AudioOutputBackend,
                dspPreferences: DSPPreferences = DSPPreferences()) {
        self.decoder = decoder
        self.output = output

        // DSD (DoP) 必须 bit-perfect — 任何 DSP 都会破坏标记字节
        // 静默强制空链；UI 层负责告知用户 "EQ bypassed for DSD"
        let effectivePrefs: DSPPreferences = {
            if decoder.format.isDSD {
                var p = dspPreferences
                p.bitPerfect = true
                return p
            }
            return dspPreferences
        }()

        // DSP 链（Bit-Perfect 模式下空链）
        let chain = DSPChain.build(inputFormat: decoder.format, preferences: effectivePrefs)
        self.dspChain = chain

        // 输出格式 = DSP 链输出；如果空链，则 = 解码器原始格式
        let outFmt: AudioFormat
        if chain.isBypass {
            outFmt = decoder.format
        } else {
            outFmt = AudioFormat(sampleRate: chain.outputFormat.sampleRate,
                                 channels: chain.outputFormat.channels,
                                 sampleFormat: .float32)
        }
        self.outputFormat = outFmt

        // 2 秒 ring buffer
        let bufferDuration = 2.0
        let bytesPerSecond = outFmt.sampleRate * Double(outFmt.bytesPerFrame)
        let capacity = max(65536, Int(bytesPerSecond * bufferDuration))
        self.ringBuffer = PCMRingBuffer(capacity: capacity)
    }

    /// 启动管线
    public func start() throws {
        guard !isRunning else { throw PurePlayError.alreadyPlaying }
        _isRunning.store(true, ordering: .releasing)

        // 通知频谱分析器当前采样率，保持 bin→Hz 映射正确
        spectrumAnalyzer?.setSampleRate(Float(decoder.format.sampleRate))

        // 切硬件采样率以匹配源文件（仅当用户选了具体设备）
        if let dev = output.currentDevice {
            let deviceCurrent = output.readNominalSampleRate()
            let fallback = deviceCurrent > 0 ? deviceCurrent : dev.maxSampleRate
            let target = SampleRateManager.pickTargetRate(
                source: outputFormat.sampleRate,
                supported: dev.supportedRates,
                deviceDefault: fallback
            )
            // 构造 PhysicalFormat 目标格式（带原生位深，真正 bit-perfect）
            let physicalTarget = AudioFormat(
                sampleRate: target,
                channels: outputFormat.channels,
                sampleFormat: outputFormat.sampleFormat,
                sourceBitDepth: outputFormat.sourceBitDepth
            )
            // 优先尝试 PhysicalFormat；失败回退到 NominalSampleRate
            let physicalOK = output.setPhysicalFormat(physicalTarget)
            if !physicalOK {
                do {
                    try SampleRateManager.switchAndWait(output: output, to: target)
                } catch {
                    didMatchHardwareRate = false
                }
            }
            didMatchHardwareRate = abs(target - outputFormat.sampleRate) < 0.5
        } else {
            didMatchHardwareRate = false
        }

        // 启动解码线程
        let thread = Thread { [weak self] in
            self?.decodeLoop()
        }
        thread.name = "PurePlay-Decode"
        thread.qualityOfService = .userInteractive
        self.decodeThread = thread
        thread.start()

        // 启动音频输出
        try output.start(format: outputFormat) { [weak self] buffer, frames in
            guard let self else { return 0 }
            let bytesNeeded = frames * self.outputFormat.bytesPerFrame
            let read = self.ringBuffer.read(into: buffer, length: bytesNeeded)
            let framesRead = read / self.outputFormat.bytesPerFrame
            if read < bytesNeeded {
                memset(buffer.advanced(by: read), 0, bytesNeeded - read)
            }
            return framesRead
        }
    }

    /// 停止管线
    public func stop() {
        _isRunning.store(false, ordering: .releasing)
        output.stop()
        decodeThread?.cancel()
        decodeThread = nil
        ringBuffer.reset()
    }

    /// 跳转到指定帧。从任意线程调用安全。
    /// ring buffer 中的旧数据被丢弃；输出回调在新数据到达前可能短暂读到静音。
    public func seek(toFrame frame: Int64) throws {
        seekLock.lock()
        defer { seekLock.unlock() }
        try decoder.seek(to: frame)
        ringBuffer.reset()
    }

    /// 是否可以无缝替换底层 decoder（gapless 前置条件）
    /// 要求新 decoder.format 与当前 decoder.format 完全一致
    public func canSwapDecoder(_ other: AudioDecoder) -> Bool {
        let a = decoder.format
        let b = other.format
        return a.sampleRate == b.sampleRate
            && a.channels == b.channels
            && a.sampleFormat == b.sampleFormat
            && a.isDSD == b.isDSD
    }

    /// 替换底层 decoder 用于 gapless 切换。
    /// **不**重置 ring buffer — 旧曲尾部已写入的内容继续播放，
    /// 新 decoder 开始填充 ring buffer 后无缝衔接。
    /// 调用方应在旧曲 decoder.isAtEnd 后立即调用本方法。
    public func swapDecoder(_ next: AudioDecoder) throws {
        guard canSwapDecoder(next) else {
            throw PurePlayError.unsupportedFormat("Gapless format mismatch")
        }
        seekLock.lock()
        defer { seekLock.unlock() }
        decoder.close()
        decoder = next
    }

    // MARK: 解码循环

    private func decodeLoop() {
        let decoderBPF = decoder.format.bytesPerFrame
        let outputBPF = outputFormat.bytesPerFrame
        let channels = decoder.format.channels
        let chunkFrames = 4096
        let decodeBytes = chunkFrames * decoderBPF
        let decodeBuffer = UnsafeMutableRawPointer.allocate(byteCount: decodeBytes, alignment: 16)
        let needsConversion = !dspChain.isBypass && decoder.format.sampleFormat != .float32
        let floatSamples = chunkFrames * channels
        let floatBuffer = needsConversion
            ? UnsafeMutablePointer<Float>.allocate(capacity: floatSamples)
            : nil
        let analyzerBuffer = (decoder.format.sampleFormat != .float32)
            ? UnsafeMutablePointer<Float>.allocate(capacity: floatSamples)
            : nil
        defer {
            decodeBuffer.deallocate()
            floatBuffer?.deallocate()
            analyzerBuffer?.deallocate()
        }

        while isRunning && !Thread.current.isCancelled {
            // 检查当前 decoder 是否到末尾（在 seekLock 下读取，避免竞争 swapDecoder）
            seekLock.lock()
            let currentDecoder = decoder
            let atEnd = currentDecoder.isAtEnd
            seekLock.unlock()

            if atEnd {
                let currentDecoderID = ObjectIdentifier(currentDecoder)
                let graceWindow: TimeInterval = 0.25
                let step: TimeInterval = 0.01
                var waited: TimeInterval = 0
                while waited < graceWindow {
                    Thread.sleep(forTimeInterval: step)
                    waited += step
                    seekLock.lock()
                    let swapped = ObjectIdentifier(decoder) != currentDecoderID
                    seekLock.unlock()
                    if swapped { break }
                    if !isRunning || Thread.current.isCancelled { break }
                }
                seekLock.lock()
                let finalSwapped = ObjectIdentifier(decoder) != currentDecoderID
                seekLock.unlock()
                if !finalSwapped {
                    break   // 无人接力，正常结束
                }
                continue
            }

            let outputBytes = chunkFrames * outputBPF
            if ringBuffer.availableToWrite < outputBytes {
                Thread.sleep(forTimeInterval: 0.005)
                continue
            }

            let frames: Int
            do {
                seekLock.lock()
                defer { seekLock.unlock() }
                frames = try decoder.decode(into: decodeBuffer, maxFrames: chunkFrames)
            } catch {
                break
            }
            guard frames > 0 else { continue }

            if dspChain.isBypass {
                ringBuffer.write(decodeBuffer, length: frames * decoderBPF)
                if decoder.format.sampleFormat == .float32 {
                    let fp = decodeBuffer.assumingMemoryBound(to: Float.self)
                    spectrumAnalyzer?.process(samples: fp, frameCount: frames, channels: channels)
                    waveformBuffer?.push(samples: fp, frameCount: frames, channels: channels)
                } else if let ab = analyzerBuffer {
                    Self.intToFloat(src: decodeBuffer, dst: ab,
                                    sampleCount: frames * channels,
                                    sampleFormat: decoder.format.sampleFormat)
                    spectrumAnalyzer?.process(samples: ab, frameCount: frames, channels: channels)
                    waveformBuffer?.push(samples: ab, frameCount: frames, channels: channels)
                }
            } else if decoder.format.sampleFormat == .float32 {
                let fp = decodeBuffer.assumingMemoryBound(to: Float.self)
                dspChain.process(buffer: fp, frameCount: frames * channels)
                ringBuffer.write(decodeBuffer, length: frames * outputBPF)
                spectrumAnalyzer?.process(samples: fp, frameCount: frames, channels: channels)
                waveformBuffer?.push(samples: fp, frameCount: frames, channels: channels)
            } else if let fb = floatBuffer {
                let totalSamples = frames * channels
                Self.intToFloat(src: decodeBuffer, dst: fb,
                                sampleCount: totalSamples,
                                sampleFormat: decoder.format.sampleFormat)
                dspChain.process(buffer: fb, frameCount: totalSamples)
                ringBuffer.write(fb, length: frames * outputBPF)
                spectrumAnalyzer?.process(samples: fb, frameCount: frames, channels: channels)
                waveformBuffer?.push(samples: fb, frameCount: frames, channels: channels)
            }
        }
    }

    private static func intToFloat(src: UnsafeRawPointer, dst: UnsafeMutablePointer<Float>,
                                   sampleCount: Int, sampleFormat: SampleFormat) {
        switch sampleFormat {
        case .int16:
            let p = src.assumingMemoryBound(to: Int16.self)
            for i in 0..<sampleCount {
                dst[i] = Float(p[i]) / 32768.0
            }
        case .int24:
            let p = src.assumingMemoryBound(to: UInt8.self)
            for i in 0..<sampleCount {
                let b0 = Int32(p[i * 3])
                let b1 = Int32(p[i * 3 + 1])
                let b2 = Int32(p[i * 3 + 2])
                var val = b0 | (b1 << 8) | (b2 << 16)
                if val & 0x800000 != 0 { val |= ~0xFFFFFF }  // sign extend
                dst[i] = Float(val) / 8388608.0
            }
        case .int32:
            let p = src.assumingMemoryBound(to: Int32.self)
            for i in 0..<sampleCount {
                dst[i] = Float(p[i]) / 2147483648.0
            }
        case .float32:
            memcpy(dst, src, sampleCount * 4)
        }
    }
}
