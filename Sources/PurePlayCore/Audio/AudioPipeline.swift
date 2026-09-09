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
    /// 输出格式。init 时按 DSP/重采样偏好确定；start() 里若设备不支持
    /// 该采样率，会接入 SincResampler 并更新为设备目标率（issue #5）
    public private(set) var outputFormat: AudioFormat

    /// 变长重采样器（issue #5）：非 nil 时 decodeLoop 走 float → SincResampler → ring 路径。
    /// 来源：用户偏好 resamplerTargetRate，或 start() 时设备不支持源率的主动重采样。
    /// DSD/DoP 永不重采样（会损毁标记字节）。
    public private(set) var resampler: SincResampler?

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

    /// 软件音量（线性增益）— 仅在 DSP float 路径 (!dspChain.isBypass) 生效。
    /// bit-perfect / DoP（整数直通）路径**永不**应用增益：
    /// 任何乘法都会破坏 bit-perfect；DoP 时还会损毁 24-bit 样本高位的
    /// 0x05/0xFA 标记字节，导致 DAC 失锁输出强噪声（issue #1）。
    private let _volumeGainBits = ManagedAtomic<UInt32>(Float(1.0).bitPattern)

    /// 当前软件音量线性增益（1.0 = unity）
    public var volumeGain: Float {
        Float(bitPattern: _volumeGainBits.load(ordering: .acquiring))
    }

    /// 设置软件音量（线性增益，clamp 到 0...4）。
    /// 仅当 DSP 链非 bypass 时被 decodeLoop 应用；bit-perfect 路径固定 unity。
    public func setVolume(linearGain gain: Float) {
        let clamped = max(0, min(4.0, gain))
        _volumeGainBits.store(clamped.bitPattern, ordering: .releasing)
    }

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

        // issue #5：用户偏好的重采样由 SincResampler 在变长路径处理。
        // 仅非 bit-perfect、非 DSD 时启用 — 重采样必然改变样本流，
        // 与 bit-perfect 语义互斥；DoP 重采样会损毁 0x05/0xFA 标记字节。
        if !effectivePrefs.bitPerfect, !decoder.format.isDSD,
           let target = effectivePrefs.resamplerTargetRate,
           target > 0, abs(target - decoder.format.sampleRate) > 0.5 {
            self.resampler = SincResampler(inputRate: decoder.format.sampleRate,
                                           outputRate: target,
                                           channels: decoder.format.channels)
        }

        // 输出格式 = 重采样目标率 > DSP 链输出 > 解码器原始格式
        let outFmt: AudioFormat
        if let r = resampler {
            outFmt = AudioFormat(sampleRate: r.outputRate,
                                 channels: decoder.format.channels,
                                 sampleFormat: .float32)
        } else if chain.isBypass {
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

        // 切硬件采样率以匹配源文件（仅当用户选了具体设备）
        if let dev = output.currentDevice {
            let deviceCurrent = output.readNominalSampleRate()
            let fallback = deviceCurrent > 0 ? deviceCurrent : dev.maxSampleRate
            let target = SampleRateManager.pickTargetRate(
                source: outputFormat.sampleRate,
                supported: dev.supportedRates,
                deviceDefault: fallback
            )
            if abs(target - outputFormat.sampleRate) > 0.5 {
                // issue #5：设备不支持当前输出率 — 主动接 SincResampler 重采样
                // 到设备目标率（-95dB Kaiser 多相，优于系统 mixer 内置 SRC），
                // 而非放任 CoreAudio 偷偷重采样。DSD/DoP 除外：重采样会损毁
                // 0x05/0xFA 标记字节，此时保持旧行为（回退设备率，标记为未匹配）。
                if !decoder.format.isDSD {
                    resampler = SincResampler(inputRate: decoder.format.sampleRate,
                                              outputRate: target,
                                              channels: outputFormat.channels)
                    outputFormat = AudioFormat(sampleRate: target,
                                               channels: outputFormat.channels,
                                               sampleFormat: .float32)
                }
                didMatchHardwareRate = false
            } else {
                didMatchHardwareRate = true
            }
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
        } else {
            didMatchHardwareRate = false
        }

        // 通知频谱分析器当前采样率，保持 bin→Hz 映射正确
        // （放在重采样决策之后 — 分析的是输出域样本）
        spectrumAnalyzer?.setSampleRate(Float(outputFormat.sampleRate))

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
        // issue #5：float 路径 = DSP 链非 bypass 或 SincResampler 在线
        let hasResampler = resampler != nil
        let needsFloatPath = !dspChain.isBypass || hasResampler
        let needsConversion = needsFloatPath && decoder.format.sampleFormat != .float32
        let floatSamples = chunkFrames * channels
        let floatBuffer = needsConversion
            ? UnsafeMutablePointer<Float>.allocate(capacity: floatSamples)
            : nil
        let analyzerBuffer = (!needsFloatPath && decoder.format.sampleFormat != .float32)
            ? UnsafeMutablePointer<Float>.allocate(capacity: floatSamples)
            : nil
        // 重采样输出缓冲（变长，按最坏比例估算容量）
        let resampleCapacityFrames = hasResampler
            ? resampler!.estimatedOutputFrames(forInputFrames: chunkFrames) : 0
        let resampleBuffer = hasResampler
            ? UnsafeMutablePointer<Float>.allocate(capacity: resampleCapacityFrames * channels)
            : nil
        defer {
            decodeBuffer.deallocate()
            floatBuffer?.deallocate()
            analyzerBuffer?.deallocate()
            resampleBuffer?.deallocate()
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

            // 背压按最坏输出帧数估算（重采样上变频时输出帧数 > 输入帧数）
            let estOutFrames = hasResampler ? resampleCapacityFrames : chunkFrames
            let outputBytes = estOutFrames * outputBPF
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

            if !needsFloatPath {
                // bit-perfect 直通：原始字节进 ring，不做任何处理（issue #1/#5 保证）
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
                continue
            }

            // float 域路径：[intToFloat] → DSP 链 → 音量 → [SincResampler] → ring
            let work: UnsafeMutablePointer<Float>
            if decoder.format.sampleFormat == .float32 {
                work = decodeBuffer.assumingMemoryBound(to: Float.self)
            } else if let fb = floatBuffer {
                Self.intToFloat(src: decodeBuffer, dst: fb,
                                sampleCount: frames * channels,
                                sampleFormat: decoder.format.sampleFormat)
                work = fb
            } else {
                continue    // 理论不可达：needsFloatPath 时 floatBuffer 必已分配
            }
            dspChain.process(buffer: work, frameCount: frames * channels)
            applyVolume(work, sampleCount: frames * channels)

            if let r = resampler, let rb = resampleBuffer {
                // issue #5：变长重采样（-95dB Kaiser 多相 sinc）
                let outFrames = r.process(input: work, inputFrames: frames,
                                          output: rb,
                                          outputCapacityFrames: resampleCapacityFrames)
                guard outFrames > 0 else { continue }
                ringBuffer.write(rb, length: outFrames * channels * 4)
                spectrumAnalyzer?.process(samples: rb, frameCount: outFrames, channels: channels)
                waveformBuffer?.push(samples: rb, frameCount: outFrames, channels: channels)
            } else {
                ringBuffer.write(work, length: frames * outputBPF)
                spectrumAnalyzer?.process(samples: work, frameCount: frames, channels: channels)
                waveformBuffer?.push(samples: work, frameCount: frames, channels: channels)
            }
        }
    }

    /// 在 float 域应用软件音量（仅非 bypass 的 DSP 路径调用）。
    /// unity 增益时零开销直通。
    private func applyVolume(_ buf: UnsafeMutablePointer<Float>, sampleCount: Int) {
        let g = Float(bitPattern: _volumeGainBits.load(ordering: .acquiring))
        guard g != 1.0 else { return }
        for i in 0..<sampleCount { buf[i] *= g }
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
