#if canImport(CFFmpeg)
import Foundation
import CFFmpeg

private let kAVErrorEOF: Int32 = {
    let e = Int32(Character("E").asciiValue!)
    let o = Int32(Character("O").asciiValue!)
    let f = Int32(Character("F").asciiValue!)
    let sp = Int32(Character(" ").asciiValue!)
    return -(e | (o << 8) | (f << 16) | (sp << 24))
}()

final class FFmpegAVIOAdapter {
    private let source: AudioSource
    private var buffer: UnsafeMutablePointer<UInt8>
    private let bufferSize: Int32 = 32768
    private(set) var avioContext: UnsafeMutablePointer<AVIOContext>?

    init(source: AudioSource) {
        self.source = source
        self.buffer = av_malloc(Int(bufferSize)).assumingMemoryBound(to: UInt8.self)

        let opaque = Unmanaged.passUnretained(self).toOpaque()
        self.avioContext = avio_alloc_context(
            buffer,
            bufferSize,
            0,
            opaque,
            FFmpegAVIOAdapter.readPacket,
            nil,
            FFmpegAVIOAdapter.seek
        )
    }

    deinit {
        if let ctx = avioContext {
            av_free(ctx.pointee.buffer)
            avio_context_free(&avioContext)
        }
    }

    private static let readPacket: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt8>?, Int32) -> Int32 = { opaque, buf, bufSize in
        guard let opaque = opaque, let buf = buf else { return kAVErrorEOF }
        let adapter = Unmanaged<FFmpegAVIOAdapter>.fromOpaque(opaque).takeUnretainedValue()

        do {
            let bytesRead = try adapter.source.read(into: buf, length: Int(bufSize))
            if bytesRead == 0 { return kAVErrorEOF }
            return Int32(bytesRead)
        } catch {
            return kAVErrorEOF
        }
    }

    private static let seek: @convention(c) (UnsafeMutableRawPointer?, Int64, Int32) -> Int64 = { opaque, offset, whence in
        guard let opaque = opaque else { return -1 }
        let adapter = Unmanaged<FFmpegAVIOAdapter>.fromOpaque(opaque).takeUnretainedValue()

        let seekWhence = whence & ~AVSEEK_FORCE
        switch seekWhence {
        case SEEK_SET:
            do {
                try adapter.source.seek(to: offset)
                return adapter.source.currentPosition
            } catch { return -1 }
        case SEEK_CUR:
            let newPos = adapter.source.currentPosition + offset
            do {
                try adapter.source.seek(to: newPos)
                return adapter.source.currentPosition
            } catch { return -1 }
        case SEEK_END:
            let newPos = adapter.source.totalBytes + offset
            do {
                try adapter.source.seek(to: newPos)
                return adapter.source.currentPosition
            } catch { return -1 }
        case AVSEEK_SIZE:
            return adapter.source.totalBytes
        default:
            return -1
        }
    }
}
#endif
