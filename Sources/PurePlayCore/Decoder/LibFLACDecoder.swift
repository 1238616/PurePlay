import Foundation
#if canImport(CFLAC)
import CFLAC

/// libFLAC-based FLAC decoder
///
/// Activates only when the `CFLAC` module is available (issue #13):
///   ./scripts/build_libflac.sh   → Frameworks/libFLAC/{include,lib}
///   swift build -Xcc -IFrameworks/libFLAC/include \
///               -Xcc -fmodule-map-file=Modules/CFLAC/module.modulemap \
///               -Xlinker -LFrameworks/libFLAC/lib
///
/// Advantages over the CoreAudio path:
///   - Reference implementation: bit-exact decode, ground-truth for MD5 verify
///   - Streaming API: works directly on AudioSource — no need to dump to
///     a temp file for cloud / non-URL sources
///   - Native bit-depth output (int16/int24 packed), no float32 container
///
/// Registration is automatic: DecoderRegistry init calls
/// `register(LibFLACDecoderFactory.self)` under the same canImport guard,
/// and priority 100 > CoreAudioDecoderFactory (90).
public final class LibFLACDecoder: AudioDecoder {

    public private(set) var format: AudioFormat
    public private(set) var totalFrames: Int64
    public private(set) var currentFrame: Int64 = 0
    public var isAtEnd: Bool { currentFrame >= totalFrames }

    private let source: AudioSource
    private var decoderRef: UnsafeMutablePointer<FLAC__StreamDecoder>?
    /// issue #13: 预分配交错缓冲 — 旧实现 write 回调里逐样本 append，
    /// 每个 FLAC block（最大 4608×2）触发多轮扩容拷贝
    private var pendingPCM: [Int32] = []
    private var pendingCount: Int = 0          // 有效样本数
    private var pendingChannelOffset: Int = 0  // 已消费样本数
    /// issue #13: errorCallback 旧实现为空 — 解码错误只能靠 process_single
    /// 返回值猜测。现在记录状态字符串，decode/seek 抛出时附带上下文。
    private var lastError: String?
    private var bitsPerSample: Int
    private var channels: Int
    /// STREAMINFO 在 metadata 回调里捕获（比 get_* getter 更可靠 —
    /// getter 在某些 libFLAC 版本 / 时序下返回 0）
    private var capturedChannels: Int = 0
    private var capturedBits: Int = 0
    private var capturedRate: Int = 0
    private var capturedTotal: Int64 = 0
    /// seek_absolute 后 libFLAC 投递的是包含目标样本的整个 FLAC block
    /// （起点 ≤ target）— 记录目标，write 回调里跳过 target 之前的样本
    private var seekTarget: Int64?

    public init(source: AudioSource) throws {
        // self 必须在取 Unmanaged 指针（供 C 回调反查）之前完成全部存储属性
        // 初始化。format/bits/channels/totalFrames 的真实值来自 metadata 解析
        // （发生在 init_stream 之后），故先置占位默认值 — 期间只有 read/
        // metadata/error 回调会触发，write 回调（用到 channels）在 decode
        // 阶段才运行，那时这些字段已填好真值。
        self.source = source
        self.decoderRef = nil
        self.pendingPCM = []
        self.pendingCount = 0
        self.pendingChannelOffset = 0
        self.lastError = nil
        self.bitsPerSample = 0
        self.channels = 0
        self.seekTarget = nil
        self.format = AudioFormat(sampleRate: 0, channels: 0,
                                  sampleFormat: .int16, sourceBitDepth: 0)
        self.totalFrames = 0

        guard let dec = FLAC__stream_decoder_new() else {
            throw PurePlayError.decodeFailed("FLAC: cannot allocate decoder")
        }
        self.decoderRef = dec

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // issue #13: seek/tell/length/eof 四个回调旧实现传 nil —
        // seek_absolute 因此永远返回 SEEK_UNSUPPORTED，进度条无法拖动。
        // AudioSource 协议恰好提供 seek/currentPosition/totalBytes 全部所需。
        let initStatus = FLAC__stream_decoder_init_stream(
            dec,
            Self.readCallback,
            Self.seekCallback,
            Self.tellCallback,
            Self.lengthCallback,
            Self.eofCallback,
            Self.writeCallback,
            Self.metadataCallback,
            Self.errorCallback,
            selfPtr
        )
        guard initStatus == FLAC__STREAM_DECODER_INIT_STATUS_OK else {
            FLAC__stream_decoder_delete(dec)
            self.decoderRef = nil
            throw PurePlayError.decodeFailed("FLAC: init_stream failed (\(initStatus))")
        }

        // Drive metadata parsing
        if FLAC__stream_decoder_process_until_end_of_metadata(dec) == 0 {
            let detail = lastError.map { ": \($0)" } ?? ""
            FLAC__stream_decoder_delete(dec)
            self.decoderRef = nil
            throw PurePlayError.decodeFailed("FLAC: metadata parse failed\(detail)")
        }

        // 优先用 metadata 回调捕获的 STREAMINFO；回调未触发（异常流）时
        // 回退到 getter，仍为 0 则视为不可解码
        let cb = capturedChannels > 0 ? capturedChannels
                 : Int(FLAC__stream_decoder_get_channels(dec))
        let bps = capturedBits > 0 ? capturedBits
                  : Int(FLAC__stream_decoder_get_bits_per_sample(dec))
        let sr  = capturedRate > 0 ? capturedRate
                  : Int(FLAC__stream_decoder_get_sample_rate(dec))
        let total = capturedTotal > 0 ? capturedTotal
                    : Int64(FLAC__stream_decoder_get_total_samples(dec))

        self.channels = Int(cb)
        self.bitsPerSample = Int(bps)
        let sf: SampleFormat
        switch bps {
        case 16: sf = .int16
        case 24: sf = .int24
        case 32: sf = .int32
        default:
            FLAC__stream_decoder_delete(dec)
            self.decoderRef = nil
            throw PurePlayError.decodeFailed("FLAC: unsupported bits/sample \(bps)")
        }
        self.format = AudioFormat(sampleRate: Double(sr),
                                  channels: Int(cb),
                                  sampleFormat: sf,
                                  sourceBitDepth: Int(bps))
        // STREAMINFO totalSamples 允许为 0（未知长度流）— 此时不能把
        // totalFrames 置 0，否则 isAtEnd 立即为真、管线一帧都播不出
        self.totalFrames = total > 0 ? Int64(total) : Int64.max
    }

    deinit {
        if let dec = decoderRef {
            FLAC__stream_decoder_finish(dec)
            FLAC__stream_decoder_delete(dec)
        }
    }

    public func decode(into buffer: UnsafeMutableRawPointer, maxFrames: Int) throws -> Int {
        guard let dec = decoderRef else { return 0 }
        let bytesPerFrame = format.bytesPerFrame
        var framesProduced = 0

        while framesProduced < maxFrames {
            // 1. Drain pendingPCM into caller buffer
            let pendingFrames = (pendingCount - pendingChannelOffset) / channels
            if pendingFrames > 0 {
                let take = min(maxFrames - framesProduced, pendingFrames)
                let outOffset = framesProduced * bytesPerFrame
                writeInterleavedSamples(into: buffer.advanced(by: outOffset),
                                        frames: take)
                framesProduced += take
                continue
            }
            // 2. Pending exhausted — decode one more FLAC frame
            pendingCount = 0
            pendingChannelOffset = 0
            if FLAC__stream_decoder_get_state(dec)
                == FLAC__STREAM_DECODER_END_OF_STREAM {
                break
            }
            if FLAC__stream_decoder_process_single(dec) == 0 {
                let detail = lastError ?? stateName(dec)
                throw PurePlayError.decodeFailed("FLAC: process_single failed (\(detail))")
            }
            if pendingCount == 0 {
                // process_single 成功但无输出：EOS 或 metadata-only frame
                break
            }
        }

        currentFrame += Int64(framesProduced)
        return framesProduced
    }

    public func seek(to frame: Int64) throws {
        guard let dec = decoderRef else { return }
        let clamped = totalFrames == Int64.max ? max(0, frame)
                                             : max(0, min(frame, totalFrames))
        let target = UInt64(clamped)
        // libFLAC 1.4 的 seek_absolute 在调用内部就会解码并投递裁剪后的
        // 首个 block（write 回调在 seek_absolute 返回前触发）— seekTarget
        // 必须提前设置，且返回后不能清空 pending（那正是首块数据）
        pendingCount = 0
        pendingChannelOffset = 0
        seekTarget = Int64(clamped)
        if FLAC__stream_decoder_seek_absolute(dec, target) == 0 {
            // issue #13: 旧实现在这里盲目 flush（把解码器状态搞坏后仍抛错）。
            // 现在保留状态并报告 seek 错误原因（errorCallback / state）。
            seekTarget = nil
            pendingCount = 0
            pendingChannelOffset = 0
            let detail = lastError ?? stateName(dec)
            throw PurePlayError.decodeFailed("FLAC: seek to \(target) failed (\(detail))")
        }
        currentFrame = Int64(target)
    }

    public func close() {
        source.close()
    }

    // libFLAC 的 FLAC__StreamDecoderStateString / ErrorStatusString 是
    // 不完整 C 数组（`const char *const x[]`）— Swift 拒绝引用，本地映射
    private func stateName(_ dec: UnsafeMutablePointer<FLAC__StreamDecoder>) -> String {
        switch FLAC__stream_decoder_get_state(dec) {
        case FLAC__STREAM_DECODER_SEARCH_FOR_METADATA: return "SEARCH_FOR_METADATA"
        case FLAC__STREAM_DECODER_READ_METADATA:       return "READ_METADATA"
        case FLAC__STREAM_DECODER_READ_FRAME:          return "READ_FRAME"
        case FLAC__STREAM_DECODER_END_OF_STREAM:       return "END_OF_STREAM"
        case FLAC__STREAM_DECODER_SEEK_ERROR:          return "SEEK_ERROR"
        case FLAC__STREAM_DECODER_ABORTED:             return "ABORTED"
        default:                                       return "UNKNOWN"
        }
    }

    private static func errorStatusName(_ s: FLAC__StreamDecoderErrorStatus) -> String {
        switch s {
        case FLAC__STREAM_DECODER_ERROR_STATUS_LOST_SYNC:          return "LOST_SYNC"
        case FLAC__STREAM_DECODER_ERROR_STATUS_BAD_HEADER:         return "BAD_HEADER"
        case FLAC__STREAM_DECODER_ERROR_STATUS_FRAME_CRC_MISMATCH: return "FRAME_CRC_MISMATCH"
        case FLAC__STREAM_DECODER_ERROR_STATUS_UNPARSEABLE_STREAM: return "UNPARSEABLE_STREAM"
        case FLAC__STREAM_DECODER_ERROR_STATUS_BAD_METADATA:       return "BAD_METADATA"
        default:                                               return "UNKNOWN"
        }
    }

    // MARK: - Sample writing

    private func writeInterleavedSamples(into buffer: UnsafeMutableRawPointer,
                                         frames: Int) {
        let bytesPerSample = format.sampleFormat.bytesPerSample
        let outBase = buffer.assumingMemoryBound(to: UInt8.self)
        var idx = pendingChannelOffset
        for f in 0..<frames {
            for c in 0..<channels {
                let s = pendingPCM[idx]; idx += 1
                let outPos = (f * channels + c) * bytesPerSample
                switch bitsPerSample {
                case 16:
                    let v = Int16(truncatingIfNeeded: s)
                    outBase[outPos]     = UInt8(truncatingIfNeeded: v & 0xFF)
                    outBase[outPos + 1] = UInt8(truncatingIfNeeded: (Int(v) >> 8) & 0xFF)
                case 24:
                    outBase[outPos]     = UInt8(truncatingIfNeeded: s & 0xFF)
                    outBase[outPos + 1] = UInt8(truncatingIfNeeded: (s >> 8) & 0xFF)
                    outBase[outPos + 2] = UInt8(truncatingIfNeeded: (s >> 16) & 0xFF)
                case 32:
                    let v = s
                    outBase[outPos]     = UInt8(truncatingIfNeeded: v & 0xFF)
                    outBase[outPos + 1] = UInt8(truncatingIfNeeded: (v >> 8) & 0xFF)
                    outBase[outPos + 2] = UInt8(truncatingIfNeeded: (v >> 16) & 0xFF)
                    outBase[outPos + 3] = UInt8(truncatingIfNeeded: (v >> 24) & 0xFF)
                default: break
                }
            }
        }
        pendingChannelOffset = idx
    }

    // MARK: - C trampolines

    private static let readCallback: FLAC__StreamDecoderReadCallback = {
        (_, buffer, bytesPtr, clientData) -> FLAC__StreamDecoderReadStatus in
        guard let buf = buffer, let bp = bytesPtr, let cd = clientData else {
            return FLAC__STREAM_DECODER_READ_STATUS_ABORT
        }
        let me = Unmanaged<LibFLACDecoder>.fromOpaque(cd).takeUnretainedValue()
        let want = bp.pointee
        do {
            let n = try me.source.read(into: UnsafeMutableRawPointer(buf), length: Int(want))
            bp.pointee = size_t(n)
            return n == 0
                ? FLAC__STREAM_DECODER_READ_STATUS_END_OF_STREAM
                : FLAC__STREAM_DECODER_READ_STATUS_CONTINUE
        } catch {
            me.lastError = "read: \(error.localizedDescription)"
            return FLAC__STREAM_DECODER_READ_STATUS_ABORT
        }
    }

    /// issue #13: 以下为旧实现传 nil 的四个回调 —
    /// libFLAC 需要它们才能实现 FLAC__stream_decoder_seek_absolute
    private static let seekCallback: FLAC__StreamDecoderSeekCallback = {
        (_, absoluteByteOffset, clientData) -> FLAC__StreamDecoderSeekStatus in
        guard let cd = clientData else { return FLAC__STREAM_DECODER_SEEK_STATUS_ERROR }
        let me = Unmanaged<LibFLACDecoder>.fromOpaque(cd).takeUnretainedValue()
        do {
            try me.source.seek(to: Int64(bitPattern: absoluteByteOffset))
            return FLAC__STREAM_DECODER_SEEK_STATUS_OK
        } catch {
            me.lastError = "seek: \(error.localizedDescription)"
            return FLAC__STREAM_DECODER_SEEK_STATUS_ERROR
        }
    }

    private static let tellCallback: FLAC__StreamDecoderTellCallback = {
        (_, absoluteByteOffsetPtr, clientData) -> FLAC__StreamDecoderTellStatus in
        guard let bp = absoluteByteOffsetPtr, let cd = clientData else {
            return FLAC__STREAM_DECODER_TELL_STATUS_ERROR
        }
        let me = Unmanaged<LibFLACDecoder>.fromOpaque(cd).takeUnretainedValue()
        let pos = me.source.currentPosition
        guard pos >= 0 else { return FLAC__STREAM_DECODER_TELL_STATUS_UNSUPPORTED }
        bp.pointee = UInt64(pos)
        return FLAC__STREAM_DECODER_TELL_STATUS_OK
    }

    private static let lengthCallback: FLAC__StreamDecoderLengthCallback = {
        (_, lengthPtr, clientData) -> FLAC__StreamDecoderLengthStatus in
        guard let lp = lengthPtr, let cd = clientData else {
            return FLAC__STREAM_DECODER_LENGTH_STATUS_ERROR
        }
        let me = Unmanaged<LibFLACDecoder>.fromOpaque(cd).takeUnretainedValue()
        let total = me.source.totalBytes
        guard total > 0 else { return FLAC__STREAM_DECODER_LENGTH_STATUS_UNSUPPORTED }
        lp.pointee = UInt64(total)
        return FLAC__STREAM_DECODER_LENGTH_STATUS_OK
    }

    private static let eofCallback: FLAC__StreamDecoderEofCallback = {
        (_, clientData) -> FLAC__bool in
        guard let cd = clientData else { return 1 }
        let me = Unmanaged<LibFLACDecoder>.fromOpaque(cd).takeUnretainedValue()
        let total = me.source.totalBytes
        return (total > 0 && me.source.currentPosition >= total) ? 1 : 0
    }

    private static let writeCallback: FLAC__StreamDecoderWriteCallback = {
        (_, framePtr, samplesPtr, clientData) -> FLAC__StreamDecoderWriteStatus in
        guard let frame = framePtr, let samples = samplesPtr, let cd = clientData else {
            return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT
        }
        let me = Unmanaged<LibFLACDecoder>.fromOpaque(cd).takeUnretainedValue()
        let blockSize = Int(frame.pointee.header.blocksize)
        let ch = me.channels
        let total = blockSize * ch
        // issue #13: 预分配一次、直接下标写入 — 不再逐样本 append
        if me.pendingPCM.count < total {
            me.pendingPCM = [Int32](repeating: 0, count: total)
        }
        var idx = 0
        for f in 0..<blockSize {
            for c in 0..<ch {
                guard let plane = samples[c] else {
                    me.lastError = "write: null channel plane \(c)"
                    return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT
                }
                me.pendingPCM[idx] = plane[f]
                idx += 1
            }
        }
        me.pendingCount = total
        me.pendingChannelOffset = 0

        // libFLAC 1.4+ 的 seek_absolute 在内部完成解码并按精确样本裁剪：
        // seek 后第一个 write 回调的 blocksize 就是 target 到 block 末尾的
        // 剩余样本数，header.sample_number == target — 无需再手动裁剪。
        // 仅在旧版本投递未裁剪 block（blockStart < target）时修正
        // currentFrame 并丢弃 target 之前的样本。
        if let target = me.seekTarget {
            me.seekTarget = nil
            let header = frame.pointee.header
            let blockStart: Int64 =
                header.number_type == FLAC__FRAME_NUMBER_TYPE_SAMPLE_NUMBER
                ? Int64(header.number.sample_number)
                : Int64(header.number.frame_number) * Int64(blockSize)
            if blockStart < target {
                let skipFrames = min(target - blockStart, Int64(blockSize))
                me.pendingChannelOffset = Int(skipFrames) * ch
                me.currentFrame = target
            } else {
                // 已裁剪投递：seek() 预设的 currentFrame 恰好正确
                me.currentFrame = blockStart
            }
        }
        return FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE
    }

    private static let metadataCallback: FLAC__StreamDecoderMetadataCallback = {
        (_, metadata, clientData) in
        guard let md = metadata, let cd = clientData else { return }
        guard md.pointee.type == FLAC__METADATA_TYPE_STREAMINFO else { return }
        let me = Unmanaged<LibFLACDecoder>.fromOpaque(cd).takeUnretainedValue()
        let si = md.pointee.data.stream_info
        me.capturedChannels = Int(si.channels)
        me.capturedBits     = Int(si.bits_per_sample)
        me.capturedRate     = Int(si.sample_rate)
        me.capturedTotal    = Int64(si.total_samples)
    }

    private static let errorCallback: FLAC__StreamDecoderErrorCallback = {
        (_, status, clientData) in
        guard let cd = clientData else { return }
        let me = Unmanaged<LibFLACDecoder>.fromOpaque(cd).takeUnretainedValue()
        // issue #13: 旧实现为空 — 错误被吞。记录状态字符串供 decode/seek 抛出。
        me.lastError = LibFLACDecoder.errorStatusName(status)
    }
}

public enum LibFLACDecoderFactory: DecoderFactory {
    public static let supportedExtensions: Set<String> = ["flac"]
    /// 100 — higher than CoreAudioDecoderFactory (90), so libFLAC wins
    public static let priority: Int = 100

    public static func canDecode(source: AudioSource, fileExtension: String) -> Bool {
        supportedExtensions.contains(fileExtension.lowercased())
    }

    public static func makeDecoder(source: AudioSource, fileExtension: String) throws -> AudioDecoder {
        try LibFLACDecoder(source: source)
    }
}

#endif  // canImport(CFLAC)
