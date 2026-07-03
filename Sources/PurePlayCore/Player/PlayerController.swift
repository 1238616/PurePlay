import Foundation

/// 播放状态
public enum PlaybackState: Equatable, Sendable {
    case stopped
    case playing
    case paused
    case buffering
}

/// 播放列表条目 — 统一本地与云盘
public enum TrackSource: Sendable {
    case local(URL)
    case cloud(fid: String, fileName: String, fileSize: Int64)

    public var displayName: String {
        switch self {
        case .local(let url):
            return url.deletingPathExtension().lastPathComponent
        case .cloud(_, let fileName, _):
            return (fileName as NSString).deletingPathExtension
        }
    }

    public var fileExtension: String {
        switch self {
        case .local(let url):
            return url.pathExtension.lowercased()
        case .cloud(_, let fileName, _):
            return (fileName as NSString).pathExtension.lowercased()
        }
    }

    public var isCloud: Bool {
        if case .cloud = self { return true }
        return false
    }
}

/// 播放模式
public enum PlayMode: Int, CaseIterable, Sendable {
    case sequential = 0   // 顺序播放，播完停止
    case loopAll    = 1   // 列表循环
    case repeatOne  = 2   // 单曲循环
    case shuffle    = 3   // 随机播放

    public var displayName: String {
        switch self {
        case .sequential: return "顺序"
        case .loopAll:    return "循环"
        case .repeatOne:  return "单曲"
        case .shuffle:    return "随机"
        }
    }

    public var iconName: String {
        switch self {
        case .sequential: return "arrow.right"
        case .loopAll:    return "repeat"
        case .repeatOne:  return "repeat.1"
        case .shuffle:    return "shuffle"
        }
    }

    public func next() -> PlayMode {
        PlayMode(rawValue: (rawValue + 1) % PlayMode.allCases.count)!
    }
}

/// 播放控制器
/// 管理播放队列、状态转换、管线生命周期
/// 支持本地文件和云盘文件统一播放
public final class PlayerController: @unchecked Sendable {

    public private(set) var state: PlaybackState = .stopped
    public var currentTrackIndex: Int = -1
    public var queue: [TrackSource] = []
    public var playMode: PlayMode = .loopAll
    public private(set) var volume: Float = 0.75

    private var pipeline: AudioPipeline?
    private let output: AudioOutputBackend
    public var dspPreferences: DSPPreferences

    /// 用户偏好：是否在起播时尝试独占设备（Hog Mode）
    public private(set) var isHogModeEnabled: Bool

    /// 本次播放是否真的拿到了 Hog（用于 stop 时幂等释放）
    private var hogAcquiredForCurrentPlay: Bool = false

    /// Optional spectrum analyzer attached to every new pipeline.
    public var spectrumAnalyzer: SpectrumAnalyzer?

    /// Optional waveform buffer attached to every new pipeline (UI scrolling waveform).
    public var waveformBuffer: WaveformBuffer?

    /// 云盘客户端（外部注入，用于云文件播放）
    public var cloudClient: AnyObject?  // QuarkAPIClient, set by AppDelegate

    /// 曲目结束回调
    public var onTrackFinished: (() -> Void)?

    /// 曲目切换回调（无缝换曲触发，传入新的 currentTrackIndex）
    public var onTrackChanged: ((Int) -> Void)?

    public init(output: AudioOutputBackend, dspPreferences: DSPPreferences = DSPPreferences()) {
        self.output = output
        self.dspPreferences = dspPreferences
        self.isHogModeEnabled = AudioPreferences.hogEnabled
    }

    // MARK: - 设备 / Hog Mode

    public func listOutputDevices() -> [AudioDevice] {
        output.listDevices()
    }

    public func currentOutputDevice() -> AudioDevice? {
        output.currentDevice
    }

    /// 设置输出设备。如果正在播放，自动重启当前曲目以让 HALOutput 重新绑定
    /// 传 nil 含义：恢复系统默认输出（DefaultOutput AudioUnit）
    public func setOutputDevice(_ device: AudioDevice?) throws {
        let wasPlaying = state == .playing
        let resumeIndex = currentTrackIndex
        let resumeQueue = queue

        if state != .stopped {
            stop()
        }

        if let dev = device {
            try output.setDevice(dev)
            AudioPreferences.deviceUID = dev.uid
        } else {
            // 没有 setDevice(nil) 接口；这里仅清持久化偏好，currentDevice 由 backend 内部保留
            // 简单做法：让用户重启 app 才彻底切回 DefaultOutput
            AudioPreferences.deviceUID = nil
        }

        if wasPlaying && resumeIndex >= 0 && resumeIndex < resumeQueue.count {
            self.queue = resumeQueue
            let track = resumeQueue[resumeIndex]
            switch track {
            case .local:
                try? playFromQueue(index: resumeIndex)
            case .cloud:
                // 云盘曲目需要异步恢复；通知外部调用方处理
                self.currentTrackIndex = resumeIndex
                state = .buffering
            }
        }
    }

    public func setHogModePreference(_ on: Bool) {
        isHogModeEnabled = on
        AudioPreferences.hogEnabled = on
    }

    public var isHogModeActive: Bool {
        output.isHogMode
    }

    public func pipelineHardwareRateMatched() -> Bool {
        pipeline?.didMatchHardwareRate ?? false
    }

    /// 当前活跃的信号路径快照（PurePlay 独创：UI 用此渲染 SignalPathBar）
    /// 无活跃管线时返回 nil
    public func currentSignalPath() -> SignalPath? {
        guard let p = pipeline else { return nil }
        return SignalPath.build(
            decoderFormat: p.decoder.format,
            dspChain: p.dspChain,
            outputFormat: p.outputFormat,
            device: output.currentDevice,
            isHogMode: output.isHogMode,
            hardwareRateMatched: p.didMatchHardwareRate
        )
    }

    private func acquireHogIfNeeded() {
        guard isHogModeEnabled, output.currentDevice != nil, !output.isHogMode else { return }
        do {
            try output.acquireHogMode()
            hogAcquiredForCurrentPlay = true
        } catch {
            hogAcquiredForCurrentPlay = false
        }
    }

    private func releaseHogIfHeld() {
        guard hogAcquiredForCurrentPlay else { return }
        try? output.releaseHogMode()
        hogAcquiredForCurrentPlay = false
    }

    // MARK: - 统一播放入口

    public func play(source: TrackSource) throws {
        stop()
        switch source {
        case .local(let url):
            try playLocal(url: url)
        case .cloud:
            state = .buffering
            // Cloud playback is async — caller must use playCloudAsync
        }
    }

    /// 播放本地文件
    public func playLocal(url: URL) throws {
        stop()
        let ext = url.pathExtension.lowercased()
        let source = try LocalFileSource(url: url)
        let decoder = try DecoderRegistry.shared.makeDecoder(source: source, fileExtension: ext)
        let pipe = AudioPipeline(decoder: decoder, output: output, dspPreferences: dspPreferences)
        pipe.spectrumAnalyzer = spectrumAnalyzer
        pipe.waveformBuffer = waveformBuffer
        self.pipeline = pipe
        acquireHogIfNeeded()
        try pipe.start()
        output.setVolume(volume)
        state = .playing
        startEndDetection()
    }

    /// 播放云盘文件（异步，需要预缓冲）
    public func playCloud(source cloudSource: CloudStreamSource, fileExtension: String) async throws {
        stop()
        state = .buffering

        try await cloudSource.startDownload()
        guard state == .buffering else { return }
        try await cloudSource.waitForPrebuffer()
        guard state == .buffering else { return }

        let decoder = try DecoderRegistry.shared.makeDecoder(source: cloudSource, fileExtension: fileExtension)
        let pipe = AudioPipeline(decoder: decoder, output: output, dspPreferences: dspPreferences)
        pipe.spectrumAnalyzer = spectrumAnalyzer
        pipe.waveformBuffer = waveformBuffer
        self.pipeline = pipe
        acquireHogIfNeeded()
        try pipe.start()
        output.setVolume(volume)
        state = .playing
        startEndDetection()
    }

    /// 兼容旧 API
    public func play(url: URL) throws {
        try playLocal(url: url)
    }

    public func playFromQueue(index: Int) throws {
        guard index >= 0 && index < queue.count else { return }
        currentTrackIndex = index
        let track = queue[index]
        switch track {
        case .local(let url):
            try playLocal(url: url)
        case .cloud:
            // Cloud tracks require async handling via playFromQueueAsync
            // This synchronous method cannot start cloud playback
            throw PurePlayError.ioError("Cloud tracks require async playback - use playCloudTrackAtIndex")
        }
    }

    /// 异步版本的播放队列（支持云盘）
    public func playFromQueueAsync(index: Int, cloudSourceFactory: ((String, Int64) async throws -> CloudStreamSource)?) async throws {
        guard index >= 0 && index < queue.count else { return }
        currentTrackIndex = index
        let track = queue[index]
        switch track {
        case .local(let url):
            try playLocal(url: url)
        case .cloud(let fid, let fileName, let fileSize):
            guard let factory = cloudSourceFactory else { return }
            state = .buffering
            let ext = (fileName as NSString).pathExtension.lowercased()
            let source = try await factory(fid, fileSize)
            try await playCloud(source: source, fileExtension: ext)
        }
    }

    public func stop() {
        releaseHogIfHeld()
        pipeline?.stop()
        pipeline = nil
        state = .stopped
        endDetectionTimer?.invalidate()
        endDetectionTimer = nil
    }

    public func pause() {
        guard state == .playing else { return }
        output.stop()
        state = .paused
        endDetectionTimer?.invalidate()
    }

    public func resume() throws {
        guard state == .paused, let pipe = pipeline else { return }
        try output.start(format: pipe.outputFormat) { [weak pipe] buffer, frames in
            guard let pipe else { return 0 }
            let bytesNeeded = frames * pipe.outputFormat.bytesPerFrame
            let read = pipe.ringBuffer.read(into: buffer, length: bytesNeeded)
            if read < bytesNeeded {
                memset(buffer.advanced(by: read), 0, bytesNeeded - read)
            }
            return read / pipe.outputFormat.bytesPerFrame
        }
        state = .playing
        startEndDetection()
    }

    public func togglePlayPause() throws {
        switch state {
        case .playing: pause()
        case .paused: try resume()
        default: break
        }
    }

    public func setVolume(_ newVolume: Float) {
        volume = max(0.0, min(1.0, newVolume))
        output.setVolume(volume)
    }

    public func next() throws {
        guard let idx = nextTrackIndex() else {
            stop()
            return
        }
        try playFromQueue(index: idx)
    }

    public func previous() throws {
        guard let idx = previousTrackIndex() else { return }
        try playFromQueue(index: idx)
    }

    /// 根据播放模式计算上一曲索引（与 nextTrackIndex 对称，不触发播放）
    public func previousTrackIndex() -> Int? {
        guard !queue.isEmpty else { return nil }
        if currentTrackIndex > 0 {
            return currentTrackIndex - 1
        }
        if playMode == .loopAll {
            return queue.count - 1
        }
        return nil
    }

    /// 根据播放模式计算下一曲索引
    public func nextTrackIndex() -> Int? {
        guard !queue.isEmpty else { return nil }
        switch playMode {
        case .sequential:
            let next = currentTrackIndex + 1
            return next < queue.count ? next : nil
        case .loopAll:
            return (currentTrackIndex + 1) % queue.count
        case .repeatOne:
            return currentTrackIndex >= 0 ? currentTrackIndex : nil
        case .shuffle:
            if queue.count <= 1 { return 0 }
            var random = Int.random(in: 0..<queue.count)
            while random == currentTrackIndex {
                random = Int.random(in: 0..<queue.count)
            }
            return random
        }
    }

    /// 当前解码器格式
    public var currentFormat: AudioFormat? {
        pipeline?.decoder.format
    }

    /// 当前播放进度（帧）
    public var currentFrame: Int64 {
        pipeline?.decoder.currentFrame ?? 0
    }

    /// 总帧数
    public var totalFrames: Int64 {
        pipeline?.decoder.totalFrames ?? 0
    }

    /// 跳转到 [0, 1] 区间的播放比例。供进度条调用。
    public func seek(toFraction fraction: Double) throws {
        guard let pipe = pipeline else { return }
        let total = pipe.decoder.totalFrames
        guard total > 0 else { return }
        let clamped = max(0.0, min(1.0, fraction))
        let target = Int64(Double(total) * clamped)
        try pipe.seek(toFrame: target)
    }

    /// 跳转到指定秒数（含负值/超长保护）
    public func seek(toSeconds seconds: Double) throws {
        guard let pipe = pipeline else { return }
        let rate = pipe.decoder.format.sampleRate
        guard rate > 0 else { return }
        let target = Int64(max(0.0, seconds) * rate)
        try pipe.seek(toFrame: target)
    }

    /// 是否 bit-perfect 模式
    public var isBitPerfect: Bool {
        pipeline?.dspChain.isBypass ?? true
    }

    /// 是否启用 gapless 衔接（默认开）
    /// 当下一曲的解码格式与当前完全一致时，直接 swap decoder，
    /// 不重启 AudioUnit；否则回退到标准 stop/start 流程
    public var isGaplessEnabled: Bool = true

    /// 尝试无缝衔接到下一曲。
    /// 成功条件：本地文件 + 下一曲解码格式与当前完全一致。
    /// - Returns: true 表示已 swap；调用方应保持 endDetectionTimer 继续运行
    @discardableResult
    public func tryGaplessAdvance() -> Bool {
        guard isGaplessEnabled, let pipe = pipeline else { return false }
        guard let idx = nextTrackIndex() else { return false }
        let next = queue[idx]
        guard case .local(let url) = next else { return false }
        let ext = url.pathExtension.lowercased()
        var dec: AudioDecoder?
        do {
            let src = try LocalFileSource(url: url)
            dec = try DecoderRegistry.shared.makeDecoder(source: src, fileExtension: ext)
            guard pipe.canSwapDecoder(dec!) else {
                dec!.close()
                return false
            }
            try pipe.swapDecoder(dec!)
            currentTrackIndex = idx
            let newIdx = idx
            DispatchQueue.main.async { [weak self] in
                self?.onTrackChanged?(newIdx)
            }
            return true
        } catch {
            dec?.close()
            return false
        }
    }

    // MARK: - End Detection

    private var endDetectionTimer: Timer?
    private var decoderEndedRingSnapshot: Int = -1

    private func startEndDetection() {
        endDetectionTimer?.invalidate()
        decoderEndedRingSnapshot = -1
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let pipe = self.pipeline, pipe.decoder.isAtEnd {
                let ringAvail = pipe.ringBuffer.availableToRead
                if ringAvail > 0 {
                    if self.decoderEndedRingSnapshot < 0 {
                        self.decoderEndedRingSnapshot = ringAvail
                    } else if ringAvail >= self.decoderEndedRingSnapshot {
                        // Ring not draining — output likely dead, don't wait forever
                    } else {
                        self.decoderEndedRingSnapshot = ringAvail
                        return
                    }
                }
                if self.tryGaplessAdvance() {
                    self.decoderEndedRingSnapshot = -1
                    return
                }
                self.endDetectionTimer?.invalidate()
                self.endDetectionTimer = nil
                self.decoderEndedRingSnapshot = -1
                self.onTrackFinished?()
            }
        }
        // Explicitly attach to the main RunLoop. playCloud() is async and may
        // resume on the cooperative thread pool where no RunLoop runs, which
        // would otherwise leave the timer dead and break auto-advance for
        // cloud tracks (playlist loop / sequential / shuffle).
        RunLoop.main.add(timer, forMode: .common)
        endDetectionTimer = timer
    }
}
