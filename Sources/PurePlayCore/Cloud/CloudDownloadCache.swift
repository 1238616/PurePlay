import Foundation

/// LRU 磁盘缓存 — 管理云盘已下载文件
public final class CloudDownloadCache: @unchecked Sendable {

    public struct CacheEntry: Codable {
        public let fid: String
        public let fileName: String
        public let fileSize: Int64
        public var lastAccessed: Date
    }

    private let cacheDir: URL
    private let maxSize: Int64
    private var entries: [String: CacheEntry] = [:]
    private let lock = NSLock()
    private let indexFile: URL

    public init(maxSizeBytes: Int64 = 2 * 1024 * 1024 * 1024,  // 2GB
                cacheDir: URL? = nil) {
        let dir = cacheDir ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PurePlay/Cloud", isDirectory: true)
        self.cacheDir = dir
        self.maxSize = maxSizeBytes
        self.indexFile = dir.appendingPathComponent(".cache_index.json")

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        loadIndex()
    }

    /// 检查文件是否已缓存
    public func cachedURL(for fid: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[fid] else { return nil }
        let path = cacheDir.appendingPathComponent(fid)
        guard FileManager.default.fileExists(atPath: path.path) else {
            entries.removeValue(forKey: fid)
            return nil
        }
        entry.lastAccessed = Date()
        entries[fid] = entry
        return path
    }

    /// 缓存文件数据
    public func cache(fid: String, fileName: String, data: Data) throws {
        lock.lock()
        let path = cacheDir.appendingPathComponent(fid)
        lock.unlock()

        try data.write(to: path, options: .atomic)

        lock.lock()
        entries[fid] = CacheEntry(fid: fid, fileName: fileName,
                                  fileSize: Int64(data.count),
                                  lastAccessed: Date())
        lock.unlock()

        evictIfNeeded()
        saveIndex()
    }

    /// 当前缓存总大小
    public var currentSize: Int64 {
        lock.lock(); defer { lock.unlock() }
        return entries.values.reduce(0) { $0 + $1.fileSize }
    }

    /// 缓存文件数量
    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    /// LRU 淘汰
    public func evictIfNeeded() {
        lock.lock()
        var total = entries.values.reduce(Int64(0)) { $0 + $1.fileSize }
        guard total > maxSize else { lock.unlock(); return }

        var sorted = entries.values.sorted { $0.lastAccessed < $1.lastAccessed }
        while total > maxSize && !sorted.isEmpty {
            let oldest = sorted.removeFirst()
            let path = cacheDir.appendingPathComponent(oldest.fid)
            try? FileManager.default.removeItem(at: path)
            entries.removeValue(forKey: oldest.fid)
            total -= oldest.fileSize
        }
        lock.unlock()
        saveIndex()
    }

    /// 清理所有缓存
    public func clearAll() {
        lock.lock()
        for entry in entries.values {
            let path = cacheDir.appendingPathComponent(entry.fid)
            try? FileManager.default.removeItem(at: path)
        }
        entries.removeAll()
        lock.unlock()
        saveIndex()
    }

    // MARK: - Index Persistence

    private func saveIndex() {
        lock.lock()
        let snapshot = entries
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: indexFile, options: .atomic)
        }
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexFile),
              let loaded = try? JSONDecoder().decode([String: CacheEntry].self, from: data) else { return }
        entries = loaded
    }
}
