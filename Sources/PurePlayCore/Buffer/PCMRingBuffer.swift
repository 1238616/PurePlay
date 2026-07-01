import Foundation
import Atomics

/// 单生产者 / 单消费者 无锁环形缓冲区
/// 借鉴 VLC `coreaudio_common.c` 的 ringbuf 设计
///
/// 注意：必须保证只有一个生产者线程（解码线程）调用 write()，
/// 只有一个消费者线程（音频回调线程）调用 read()。
public final class PCMRingBuffer: @unchecked Sendable {

    private let buffer: UnsafeMutableRawPointer
    public let capacity: Int

    private let writePos = ManagedAtomic<Int>(0)
    private let readPos = ManagedAtomic<Int>(0)

    public init(capacity: Int) {
        precondition(capacity > 0, "capacity must be positive")
        // 64-byte 对齐，避免 false sharing
        var ptr: UnsafeMutableRawPointer? = nil
        posix_memalign(&ptr, 64, capacity)
        precondition(ptr != nil, "posix_memalign failed")
        self.buffer = ptr!
        self.capacity = capacity
        memset(self.buffer, 0, capacity)
    }

    deinit {
        free(buffer)
    }

    /// 当前可读字节数
    public var availableToRead: Int {
        let w = writePos.load(ordering: .acquiring)
        let r = readPos.load(ordering: .acquiring)
        return w - r
    }

    /// 当前可写字节数
    public var availableToWrite: Int {
        capacity - availableToRead
    }

    /// 重置（仅在停止状态下调用）
    public func reset() {
        writePos.store(0, ordering: .releasing)
        readPos.store(0, ordering: .releasing)
        memset(buffer, 0, capacity)
    }

    /// 生产者写入
    @discardableResult
    public func write(_ src: UnsafeRawPointer, length: Int) -> Int {
        let r = readPos.load(ordering: .acquiring)
        let w = writePos.load(ordering: .relaxed)
        let space = capacity - (w - r)
        let toWrite = min(length, space)
        guard toWrite > 0 else { return 0 }

        let writeOffset = w % capacity
        let firstChunk = min(toWrite, capacity - writeOffset)
        memcpy(buffer.advanced(by: writeOffset), src, firstChunk)
        if toWrite > firstChunk {
            memcpy(buffer, src.advanced(by: firstChunk), toWrite - firstChunk)
        }

        writePos.store(w + toWrite, ordering: .releasing)
        return toWrite
    }

    /// 消费者读取；不足时返回实际读取量（调用方决定是否填充静音）
    @discardableResult
    public func read(into dst: UnsafeMutableRawPointer, length: Int) -> Int {
        let w = writePos.load(ordering: .acquiring)
        let r = readPos.load(ordering: .relaxed)
        let avail = w - r
        let toRead = min(length, avail)
        guard toRead > 0 else { return 0 }

        let readOffset = r % capacity
        let firstChunk = min(toRead, capacity - readOffset)
        memcpy(dst, buffer.advanced(by: readOffset), firstChunk)
        if toRead > firstChunk {
            memcpy(dst.advanced(by: firstChunk),
                   buffer,
                   toRead - firstChunk)
        }

        readPos.store(r + toRead, ordering: .releasing)
        return toRead
    }
}
