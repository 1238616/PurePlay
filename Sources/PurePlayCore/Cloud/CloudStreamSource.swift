import Foundation

/// 云盘流式音频源 — 实现 AudioSource 协议
///
/// 设计：稀疏块缓存 + 按需 HTTP Range 拉取
///   - 文件被划分为固定大小的块（默认 1MB）
///   - 每块独立按需通过 HTTP Range 请求拉取
///   - read() 阻塞等待目标块抵达；Seek 立即返回（按需异步加载）
///   - 顺序播放时同时预取后续 N 块（行进式 prefetch）
///
/// 与旧实现的差异：
///   - 不再"全量后台下载"，节省内存与带宽
///   - Seek 真正按 Range 取数据，不重启整个下载
///   - 多块并发可控（最多 maxConcurrentRangeRequests）
public final class CloudStreamSource: AudioSource, @unchecked Sendable {

    private let client: QuarkAPIClient
    public let fid: String
    public let totalBytes: Int64

    /// 块大小（默认 1MB）
    public let chunkSize: Int64
    /// 预缓冲阈值：开始播放前至少要 ready 多少字节
    public let prebufferBytes: Int64
    /// 顺序播放时同时 prefetch 的后续块数
    public let prefetchAheadChunks: Int
    /// 最大并发 Range 请求
    public let maxConcurrentRangeRequests: Int

    /// 块状态
    private enum ChunkState {
        case missing
        case downloading
        case ready(Data)
        case failed(retries: Int)
    }

    private var chunks: [Int: ChunkState] = [:]
    private var position: Int64 = 0
    private let lock = NSLock()
    private let cv = NSCondition()    // 用于 read() 阻塞等待
    private var activeFetches: Int = 0
    private var closed = false

    /// 下载进度回调（ready 字节数 / 总字节数）
    public var onProgress: ((Int64, Int64) -> Void)?

    public var currentPosition: Int64 {
        lock.lock(); defer { lock.unlock() }
        return position
    }

    public var downloadedBytes: Int64 {
        lock.lock(); defer { lock.unlock() }
        return readyBytesLocked()
    }

    public var isFullyCached: Bool {
        downloadedBytes >= totalBytes
    }

    public init(client: QuarkAPIClient,
                fid: String,
                fileSize: Int64,
                chunkSize: Int64 = 1 * 1024 * 1024,
                prebufferBytes: Int64 = 5 * 1024 * 1024,
                prefetchAheadChunks: Int = 4,
                maxConcurrentRangeRequests: Int = 3) {
        self.client = client
        self.fid = fid
        self.totalBytes = fileSize
        self.chunkSize = chunkSize
        self.prebufferBytes = min(prebufferBytes, max(fileSize, 0))
        self.prefetchAheadChunks = prefetchAheadChunks
        self.maxConcurrentRangeRequests = maxConcurrentRangeRequests
    }

    /// 开始（仅触发首批 prebuffer prefetch）
    public func startDownload() async throws {
        await prefetchChunks(startingAt: 0, count: chunksToReachByte(prebufferBytes))
    }

    /// 等待 prebuffer 达到阈值
    public func waitForPrebuffer() async throws {
        let target = prebufferBytes
        while true {
            lock.lock()
            let ready = readyBytesLocked()
            let stopped = closed
            lock.unlock()
            if stopped { throw PurePlayError.ioError("Stream closed") }
            if ready >= target { return }
            if ready >= totalBytes { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: - AudioSource Protocol

    public func read(into buffer: UnsafeMutableRawPointer, length: Int) throws -> Int {
        let maxWait: TimeInterval = 10.0
        let deadline = Date().addingTimeInterval(maxWait)

        while true {
            lock.lock()
            if closed { lock.unlock(); return 0 }
            let pos = position
            if pos >= totalBytes { lock.unlock(); return 0 }

            let chunkIdx = Int(pos / chunkSize)
            let chunkOffset = Int(pos - Int64(chunkIdx) * chunkSize)

            if case .ready(let data) = chunks[chunkIdx] {
                let remainInChunk = data.count - chunkOffset
                let toRead = min(length, max(0, remainInChunk))
                if toRead > 0 {
                    data.withUnsafeBytes { raw in
                        let src = raw.baseAddress!.advanced(by: chunkOffset)
                        buffer.copyMemory(from: src, byteCount: toRead)
                    }
                    position += Int64(toRead)
                    evictOldChunks(currentChunk: chunkIdx)
                    lock.unlock()
                    // 顺序播放：行进式预取后续块
                    Task { [weak self] in
                        guard let self else { return }
                        await self.prefetchChunks(startingAt: chunkIdx + 1,
                                                  count: self.prefetchAheadChunks)
                    }
                    return toRead
                }
                lock.unlock()
                // chunk 是 ready 但 chunkOffset 已到末尾 — 推进到下一块
                continue
            }

            // 该 chunk 还没 ready：触发下载并等待
            let isDownloading: Bool
            if case .downloading = chunks[chunkIdx] {
                isDownloading = true
            } else if case .failed(let retries) = chunks[chunkIdx], retries >= 3 {
                lock.unlock()
                throw PurePlayError.ioError("Cloud chunk \(chunkIdx) failed after \(retries) retries")
            } else {
                isDownloading = false
            }
            lock.unlock()

            if !isDownloading {
                Task { [weak self] in
                    await self?.fetchChunk(chunkIdx)
                }
            }

            // 等待 chunk ready（条件变量）
            cv.lock()
            cv.wait(until: Date().addingTimeInterval(0.05))
            cv.unlock()

            if Date() > deadline {
                throw PurePlayError.ioError("Cloud read timeout at byte \(pos)")
            }
        }
    }

    public func seek(to offset: Int64) throws {
        guard offset >= 0 && offset <= totalBytes else {
            throw PurePlayError.ioError("Cloud seek out of bounds: \(offset)")
        }
        lock.lock()
        position = offset
        lock.unlock()

        // 异步触发目标块及若干后续块的拉取（即返回；下一次 read 会阻塞等待）
        let startChunk = Int(offset / chunkSize)
        Task { [weak self] in
            guard let self else { return }
            await self.prefetchChunks(startingAt: startChunk,
                                      count: 1 + self.prefetchAheadChunks)
        }
    }

    public func close() {
        lock.lock()
        closed = true
        chunks.removeAll()
        lock.unlock()
        cv.lock(); cv.broadcast(); cv.unlock()
    }

    /// 把所有 ready 块拼接导出（仅 isFullyCached 时有意义）
    public func exportToCache() -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard readyBytesLocked() >= totalBytes else { return nil }
        let totalChunks = Int((totalBytes + chunkSize - 1) / chunkSize)
        var out = Data(capacity: Int(totalBytes))
        for i in 0..<totalChunks {
            guard case .ready(let d) = chunks[i] else { return nil }
            out.append(d)
        }
        return out
    }

    // MARK: - Private chunk machinery

    /// 淘汰已读过的旧块（保留当前块前 2 块热区，避免小幅回退 seek 重新拉取）
    /// 调用方必须已持有 lock
    private func evictOldChunks(currentChunk: Int) {
        let threshold = currentChunk - 2
        guard threshold > 0 else { return }
        for key in chunks.keys where key < threshold {
            if case .ready = chunks[key] {
                chunks.removeValue(forKey: key)
            }
        }
    }

    private func chunksToReachByte(_ bytes: Int64) -> Int {
        let n = Int((bytes + chunkSize - 1) / chunkSize)
        return max(1, n)
    }

    private func readyBytesLocked() -> Int64 {
        var n: Int64 = 0
        for (_, state) in chunks {
            if case .ready(let d) = state { n += Int64(d.count) }
        }
        return n
    }

    /// 异步触发若干块的拉取（已 ready / 正在下载的跳过；服从并发上限）
    private func prefetchChunks(startingAt startChunk: Int, count: Int) async {
        let totalChunks = Int((totalBytes + chunkSize - 1) / chunkSize)
        for i in 0..<count {
            let idx = startChunk + i
            if idx >= totalChunks { break }
            await fetchChunk(idx)
        }
    }

    /// 实际拉取单个 chunk；幂等 + 并发安全
    private func fetchChunk(_ chunkIdx: Int) async {
        // 状态检查 + 转移到 downloading
        lock.lock()
        if closed { lock.unlock(); return }
        var retryCount = 0
        if let state = chunks[chunkIdx] {
            switch state {
            case .ready, .downloading:
                lock.unlock(); return
            case .failed(let r):
                if r >= 3 { lock.unlock(); return }
                retryCount = r
            case .missing:
                break
            }
        }
        while activeFetches >= maxConcurrentRangeRequests {
            lock.unlock()
            try? await Task.sleep(nanoseconds: 10_000_000)
            lock.lock()
            if closed { lock.unlock(); return }
        }
        chunks[chunkIdx] = .downloading
        activeFetches += 1
        lock.unlock()

        // 指数退避：重试时等待 1s × 2^retryCount
        if retryCount > 0 {
            let delayNs = UInt64(1_000_000_000) << UInt64(min(retryCount - 1, 3))
            try? await Task.sleep(nanoseconds: delayNs)
        }

        let totalChunks = Int((totalBytes + chunkSize - 1) / chunkSize)
        let start = Int64(chunkIdx) * chunkSize
        let end = (chunkIdx == totalChunks - 1) ? totalBytes : start + chunkSize

        do {
            let request = try await client.makeDownloadRequest(fid: fid, range: start..<end)
            let session = URLSession.shared
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse,
               http.statusCode != 200 && http.statusCode != 206 {
                throw PurePlayError.ioError("Range fetch status \(http.statusCode)")
            }
            lock.lock()
            chunks[chunkIdx] = .ready(data)
            activeFetches -= 1
            let ready = readyBytesLocked()
            let progressCallback = onProgress
            lock.unlock()
            progressCallback?(ready, totalBytes)
            cv.lock(); cv.broadcast(); cv.unlock()
        } catch {
            lock.lock()
            chunks[chunkIdx] = .failed(retries: retryCount + 1)
            activeFetches -= 1
            lock.unlock()
            cv.lock(); cv.broadcast(); cv.unlock()
        }
    }

    // MARK: - Testing hooks

    /// 测试用：手动注入一个块的 ready 数据
    public func _testInjectChunk(index: Int, data: Data) {
        lock.lock()
        chunks[index] = .ready(data)
        lock.unlock()
        cv.lock(); cv.broadcast(); cv.unlock()
    }
}
