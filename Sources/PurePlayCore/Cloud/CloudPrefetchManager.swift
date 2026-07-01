import Foundation

/// 云盘队列预取管理器
///
/// 负责在当前曲目接近结尾时，提前为队列中下一首云盘文件触发预下载，
/// 让用户感受到"即点即播"。预下载策略：
///   - 当前曲剩余 ≤ `triggerThresholdSeconds` 秒时启动
///   - 同一时刻仅维护一个预取任务（旧任务自动取消）
///   - 预取量默认 8MB（覆盖大多数 FLAC 24/96 的开头几秒）
///   - 若下一曲已是本地文件或已完全缓存，跳过
///
/// 调用方约定：
///   - tick(currentDuration:currentTime:) 由播放循环每秒调用一次
///   - nextCloudSource(_:) 由 PrefetchManager 在需要时回调，请求外部
///     构造一个 CloudStreamSource（外部持有 QuarkAPIClient 与文件目录）
public final class CloudPrefetchManager: @unchecked Sendable {

    public let triggerThresholdSeconds: Double
    public let prefetchBytes: Int64

    /// 调用方根据队列状态返回下一首云盘的 (fid, fileSize)，无下一曲返回 nil
    public var nextCloudInfoProvider: (() -> (fid: String, fileSize: Int64)?)?
    /// 调用方根据 (fid, fileSize) 构造 CloudStreamSource
    public var cloudSourceBuilder: ((String, Int64) -> CloudStreamSource)?

    /// 当前正在预取的 source（外部可观察）
    public private(set) var prefetching: CloudStreamSource?
    /// 上一次预取触发的曲目 fid（去重）
    private var lastTriggeredFid: String?
    private let lock = NSLock()
    private var currentTask: Task<Void, Never>?

    public init(triggerThresholdSeconds: Double = 30,
                prefetchBytes: Int64 = 8 * 1024 * 1024) {
        self.triggerThresholdSeconds = triggerThresholdSeconds
        self.prefetchBytes = prefetchBytes
    }

    /// 由播放循环周期性调用
    public func tick(currentDuration: Double, currentTime: Double) {
        let remaining = currentDuration - currentTime
        guard remaining > 0 && remaining <= triggerThresholdSeconds else { return }
        triggerIfNeeded()
    }

    /// 手动触发：把下一首 prefetch 启动起来
    public func triggerIfNeeded() {
        lock.lock()
        guard let provider = nextCloudInfoProvider,
              let info = provider() else {
            lock.unlock()
            return
        }
        if lastTriggeredFid == info.fid {
            lock.unlock()
            return
        }
        lastTriggeredFid = info.fid
        guard let builder = cloudSourceBuilder else {
            lock.unlock()
            return
        }
        let source = builder(info.fid, info.fileSize)
        prefetching = source
        lock.unlock()

        currentTask?.cancel()
        currentTask = Task { [weak self] in
            guard let self else { return }
            try? await source.startDownload()
            // 让 source 自己慢慢拉块；prebuffer 完成即视为成功
            try? await source.waitForPrebuffer()
            _ = self.prefetching   // keep alive
        }
    }

    /// 取出预取好的 source 并清空内部状态
    public func consumePrefetch(for fid: String) -> CloudStreamSource? {
        lock.lock(); defer { lock.unlock() }
        guard let src = prefetching, src.fid == fid else { return nil }
        prefetching = nil
        lastTriggeredFid = nil
        return src
    }

    public func cancel() {
        lock.lock()
        currentTask?.cancel()
        currentTask = nil
        prefetching?.close()
        prefetching = nil
        lastTriggeredFid = nil
        lock.unlock()
    }
}
