import Foundation

/// 音频源抽象 — 本地文件 / 云盘流 都实现此协议
/// 借鉴 VLC `access_t` + `stream_t`
public protocol AudioSource: AnyObject, Sendable {
    var totalBytes: Int64 { get }
    var currentPosition: Int64 { get }

    /// 同步读 — 由解码器在解码线程调用
    func read(into buffer: UnsafeMutableRawPointer, length: Int) throws -> Int

    /// 跳转到指定字节偏移
    func seek(to offset: Int64) throws

    /// 关闭源
    func close()
}

/// 本地文件源（基础实现 — 标准 fread）
public final class LocalFileSource: AudioSource, @unchecked Sendable {
    private let handle: FileHandle
    public let totalBytes: Int64
    public let url: URL

    public init(url: URL) throws {
        self.url = url
        guard let h = try? FileHandle(forReadingFrom: url) else {
            throw PurePlayError.ioError("Cannot open \(url.path)")
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        self.handle = h
        self.totalBytes = (attrs[.size] as? Int64) ?? 0
    }

    public var currentPosition: Int64 {
        (try? Int64(handle.offset())) ?? 0
    }

    public func read(into buffer: UnsafeMutableRawPointer, length: Int) throws -> Int {
        let data = handle.readData(ofLength: length)
        guard !data.isEmpty else { return 0 }
        data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: data.count)
        return data.count
    }

    public func seek(to offset: Int64) throws {
        try handle.seek(toOffset: UInt64(offset))
    }

    public func close() {
        try? handle.close()
    }

    deinit { close() }
}

/// 内存源 — 用于测试与小文件
public final class MemorySource: AudioSource, @unchecked Sendable {
    private let data: Data
    private var position: Int64 = 0

    public init(data: Data) {
        self.data = data
    }

    public var totalBytes: Int64 { Int64(data.count) }
    public var currentPosition: Int64 { position }

    public func read(into buffer: UnsafeMutableRawPointer, length: Int) throws -> Int {
        let remaining = Int64(data.count) - position
        guard remaining > 0 else { return 0 }
        let toRead = min(Int(remaining), length)
        data.withUnsafeBytes { raw in
            let src = raw.baseAddress!.advanced(by: Int(position))
            buffer.copyMemory(from: src, byteCount: toRead)
        }
        position += Int64(toRead)
        return toRead
    }

    public func seek(to offset: Int64) throws {
        guard offset >= 0 && offset <= Int64(data.count) else {
            throw PurePlayError.ioError("Seek out of bounds: \(offset)")
        }
        position = offset
    }

    public func close() {}
}
