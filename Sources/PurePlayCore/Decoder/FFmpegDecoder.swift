#if canImport(CFFmpeg)
import Foundation
import CFFmpeg

public final class FFmpegDecoder: AudioDecoder {
    public let format: AudioFormat
    public let totalFrames: Int64
    public private(set) var currentFrame: Int64 = 0
    private var _reachedEOF: Bool = false
    public var isAtEnd: Bool {
        return _reachedEOF
    }

    private let source: AudioSource
    private var formatCtx: UnsafeMutablePointer<AVFormatContext>?
    private var codecCtx: UnsafeMutablePointer<AVCodecContext>?
    private var swrCtx: OpaquePointer?
    private var avioAdapter: FFmpegAVIOAdapter?
    private var audioStreamIndex: Int32 = -1
    private var packet: UnsafeMutablePointer<AVPacket>?
    private var frame: UnsafeMutablePointer<AVFrame>?

    private var pendingBuffer: [UInt8] = []
    private var pendingOffset: Int = 0
    private let bytesPerOutputFrame: Int

    public init(source: AudioSource, fileExtension: String) throws {
        self.source = source

        self.packet = av_packet_alloc()
        self.frame = av_frame_alloc()

        // Let FFmpeg auto-detect format from file content (magic bytes).
        // Forcing by extension (e.g. "dts" → raw DTS demuxer) fails for
        // files that use a different container (e.g. DTS inside WAV).
        var fmtCtxOpt: UnsafeMutablePointer<AVFormatContext>?

        if let localSource = source as? LocalFileSource {
            // Local files: use FFmpeg native file I/O (avoids AVIO overhead/issues)
            fmtCtxOpt = nil
            let path = localSource.url.path
            let openResult = avformat_open_input(&fmtCtxOpt, path, nil, nil)
            guard openResult == 0 else {
                throw PurePlayError.decodeFailed("FFmpeg: avformat_open_input failed (\(openResult))")
            }
        } else {
            // Streaming sources: use custom AVIO adapter
            let adapter = FFmpegAVIOAdapter(source: source)
            self.avioAdapter = adapter

            let fmtCtx = avformat_alloc_context()
            guard fmtCtx != nil else {
                throw PurePlayError.decodeFailed("FFmpeg: failed to allocate format context")
            }
            fmtCtx!.pointee.pb = adapter.avioContext

            fmtCtxOpt = fmtCtx
            let openResult = avformat_open_input(&fmtCtxOpt, nil, nil, nil)
            guard openResult == 0 else {
                throw PurePlayError.decodeFailed("FFmpeg: avformat_open_input failed (\(openResult))")
            }
        }

        self.formatCtx = fmtCtxOpt

        // Give FFmpeg more time to analyse raw bitstreams (e.g. DTS)
        // where codec params like channel count may not be immediately known.
        formatCtx!.pointee.probesize = 10_000_000        // 10 MB (default 5 MB)
        formatCtx!.pointee.max_analyze_duration = 10_000_000  // 10 s

        guard avformat_find_stream_info(formatCtx, nil) >= 0 else {
            throw PurePlayError.decodeFailed("FFmpeg: avformat_find_stream_info failed")
        }

        // av_find_best_stream can fail for formats where channels=0
        // (e.g. raw DTS: "unspecified number of channels"). Fall back to
        // picking the first audio-type stream manually.
        var streamIdx = av_find_best_stream(formatCtx, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        if streamIdx < 0 {
            let n = Int(formatCtx!.pointee.nb_streams)
            for i in 0..<n {
                let s = formatCtx!.pointee.streams[i]!
                if s.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO {
                    streamIdx = Int32(i)
                    break
                }
            }
        }
        guard streamIdx >= 0 else {
            throw PurePlayError.decodeFailed("FFmpeg: no audio stream found")
        }
        self.audioStreamIndex = streamIdx

        let stream = formatCtx!.pointee.streams[Int(streamIdx)]!
        let codecPar = stream.pointee.codecpar!

        guard let codec = avcodec_find_decoder(codecPar.pointee.codec_id) else {
            throw PurePlayError.decodeFailed("FFmpeg: no decoder for codec \(codecPar.pointee.codec_id)")
        }

        guard let ctx = avcodec_alloc_context3(codec) else {
            throw PurePlayError.decodeFailed("FFmpeg: failed to allocate codec context")
        }
        self.codecCtx = ctx

        avcodec_parameters_to_context(ctx, codecPar)
        guard avcodec_open2(ctx, codec, nil) == 0 else {
            throw PurePlayError.decodeFailed("FFmpeg: avcodec_open2 failed")
        }

        let sampleRate = Int(ctx.pointee.sample_rate)
        let channels = Int(ctx.pointee.ch_layout.nb_channels)

        // 优先用 codec 实际输出的 sample_fmt 判断（avcodec_open2 后已确定）
        // APE 等格式 bits_per_raw_sample 可能为 0，但 sample_fmt 始终可靠。
        // WMA Lossless 16/24-bit 报为 S16P/S32P planar，依赖 bits_per_raw_sample 区分。
        let codecSampleFmt = ctx.pointee.sample_fmt
        let bitsPerRaw = Int(ctx.pointee.bits_per_raw_sample)
        let bitsPerCoded = Int(codecPar.pointee.bits_per_coded_sample)
        let decision = FFmpegSampleFormatSelector.decide(
            codecSampleFormat: codecSampleFmt.rawValue,
            bitsPerRawSample: bitsPerRaw,
            bitsPerCodedSample: bitsPerCoded
        )
        let sampleFormat = decision.sampleFormat
        let outAVFormat: AVSampleFormat = (decision.outAVFormatCode == FFmpegSampleFormatSelector.AVFmtCode.s16)
            ? AV_SAMPLE_FMT_S16
            : AV_SAMPLE_FMT_S32
        let sourceBits = FFmpegSampleFormatSelector.effectiveBitDepth(
            bitsPerRawSample: bitsPerRaw,
            bitsPerCodedSample: bitsPerCoded
        )

        self.format = AudioFormat(
            sampleRate: Double(sampleRate),
            channels: channels,
            sampleFormat: sampleFormat,
            sourceBitDepth: sourceBits
        )
        self.bytesPerOutputFrame = channels * sampleFormat.bytesPerSample

        var swrContext = swr_alloc()
        guard swrContext != nil else {
            throw PurePlayError.decodeFailed("FFmpeg: swr_alloc failed")
        }

        var outLayout = AVChannelLayout()
        av_channel_layout_default(&outLayout, Int32(channels))

        swr_alloc_set_opts2(
            &swrContext,
            &outLayout,
            outAVFormat,
            Int32(sampleRate),
            &ctx.pointee.ch_layout,
            ctx.pointee.sample_fmt,
            ctx.pointee.sample_rate,
            0,
            nil
        )

        guard swr_init(swrContext) >= 0 else {
            throw PurePlayError.decodeFailed("FFmpeg: swr_init failed")
        }
        self.swrCtx = swrContext

        if stream.pointee.duration > 0 {
            let timeBase = stream.pointee.time_base
            let durationSec = Double(stream.pointee.duration) * Double(timeBase.num) / Double(timeBase.den)
            self.totalFrames = Int64(durationSec * Double(sampleRate))
        } else if formatCtx!.pointee.duration > 0 {
            let durationSec = Double(formatCtx!.pointee.duration) / Double(AV_TIME_BASE)
            self.totalFrames = Int64(durationSec * Double(sampleRate))
        } else {
            self.totalFrames = 0
        }
    }

    deinit {
        if let swr = swrCtx {
            var mutableSwr: OpaquePointer? = swr
            swr_free(&mutableSwr)
        }
        if codecCtx != nil {
            avcodec_free_context(&codecCtx)
        }
        if formatCtx != nil {
            avformat_close_input(&formatCtx)
        }
        av_packet_free(&packet)
        av_frame_free(&frame)
    }

    private func processFrame(frame: UnsafeMutablePointer<AVFrame>, outPtr: UnsafeMutablePointer<UInt8>, maxBytes: Int, written: inout Int) {
        let nbSamples = Int(frame.pointee.nb_samples)
        let channels = format.channels

        // swr_convert always writes outAVFormat: S32 (4 bytes/sample) for int24/int32, S16 for int16.
        // Allocate for the actual swr output size, not the packed int24 size.
        let bytesPerSwrSample = (format.sampleFormat == .int24) ? 4 : bytesPerOutputFrame / channels
        let swrBufSize = nbSamples * channels * bytesPerSwrSample
        var tempBuf = [UInt8](repeating: 0, count: swrBufSize)

        tempBuf.withUnsafeMutableBufferPointer { ptr in
            var outBufPtr: UnsafeMutablePointer<UInt8>? = ptr.baseAddress
            withUnsafeMutablePointer(to: &outBufPtr) { outPtrPtr in
                let srcData = frame.pointee.extended_data!
                srcData.withMemoryRebound(to: UnsafePointer<UInt8>?.self, capacity: channels) { srcPtr in
                    swr_convert(
                        swrCtx,
                        outPtrPtr,
                        Int32(nbSamples),
                        srcPtr,
                        Int32(nbSamples)
                    )
                }
            }
        }

        if format.sampleFormat == .int24 {
            // Repack S32 (little-endian, 24-bit value in bytes 0-2) → packed int24 (3 bytes)
            var packed = [UInt8]()
            packed.reserveCapacity(nbSamples * channels * 3)
            for i in 0..<(nbSamples * channels) {
                let offset = i * 4
                packed.append(tempBuf[offset])
                packed.append(tempBuf[offset + 1])
                packed.append(tempBuf[offset + 2])
            }
            tempBuf = packed
        }

        let available = tempBuf.count
        let toCopy = min(available, maxBytes - written)
        memcpy(outPtr + written, tempBuf, toCopy)
        written += toCopy

        if toCopy < available {
            pendingBuffer = Array(tempBuf[toCopy...])
            pendingOffset = 0
        }
    }

    public func decode(into buffer: UnsafeMutableRawPointer, maxFrames: Int) throws -> Int {
        let maxBytes = maxFrames * bytesPerOutputFrame
        var written = 0
        let outPtr = buffer.assumingMemoryBound(to: UInt8.self)

        while written < maxBytes {
            // 1) 优先消费 pendingBuffer（上一次 processFrame 的尾巴）
            if pendingOffset < pendingBuffer.count {
                let available = pendingBuffer.count - pendingOffset
                let toCopy = min(available, maxBytes - written)
                pendingBuffer.withUnsafeBufferPointer { ptr in
                    memcpy(outPtr + written, ptr.baseAddress! + pendingOffset, toCopy)
                }
                pendingOffset += toCopy
                written += toCopy
                if pendingOffset >= pendingBuffer.count {
                    pendingBuffer.removeAll(keepingCapacity: true)
                    pendingOffset = 0
                }
                continue
            }

            // 2) 再尝试从 codec 已有的 buffered frame 中收取
            let recvBefore = avcodec_receive_frame(codecCtx, frame)
            if recvBefore == 0 {
                processFrame(frame: frame!, outPtr: outPtr, maxBytes: maxBytes, written: &written)
                av_frame_unref(frame)
                continue
            }
            if recvBefore != AVERROR_EAGAIN && recvBefore != FFMPEG_AVERROR_EOF && recvBefore < 0 {
                var errBuf = [CChar](repeating: 0, count: 256)
                av_strerror(recvBefore, &errBuf, 256)
                FFmpegDecoder.logError("avcodec_receive_frame error: code=\(recvBefore) (\(String(cString: errBuf)))")
            }
            if recvBefore == FFMPEG_AVERROR_EOF {
                _reachedEOF = true
                break
            }
            // recvBefore == EAGAIN：codec 需要更多 packet，继续往下读

            // 3) 读取下一个 packet 并送入 codec
            let readResult = av_read_frame(formatCtx, packet)
            if readResult < 0 {
                // 通知 codec 流结束，并 flush 剩余 buffered frames
                avcodec_send_packet(codecCtx, nil)
                while true {
                    let r = avcodec_receive_frame(codecCtx, frame)
                    if r < 0 { break }
                    processFrame(frame: frame!, outPtr: outPtr, maxBytes: maxBytes, written: &written)
                    av_frame_unref(frame)
                    if written >= maxBytes { break }
                }
                _reachedEOF = true
                if readResult != FFMPEG_AVERROR_EOF {
                    var errBuf = [CChar](repeating: 0, count: 256)
                    av_strerror(readResult, &errBuf, 256)
                    FFmpegDecoder.logError("av_read_frame failed: code=\(readResult) (\(String(cString: errBuf)))")
                }
                break
            }

            if packet!.pointee.stream_index != audioStreamIndex {
                av_packet_unref(packet)
                continue
            }

            let sendResult = avcodec_send_packet(codecCtx, packet)
            av_packet_unref(packet)
            if sendResult < 0 && sendResult != AVERROR_EAGAIN {
                var errBuf = [CChar](repeating: 0, count: 256)
                av_strerror(sendResult, &errBuf, 256)
                FFmpegDecoder.logError("avcodec_send_packet failed: code=\(sendResult) (\(String(cString: errBuf)))")
            }
            // 不论 send 是否成功，下一轮 while 会再次尝试 receive_frame
        }

        let framesDecoded = written / bytesPerOutputFrame
        currentFrame += Int64(framesDecoded)
        return framesDecoded
    }

    public func seek(to targetFrame: Int64) throws {
        let stream = formatCtx!.pointee.streams[Int(audioStreamIndex)]!
        let timeBase = stream.pointee.time_base
        let targetTs = av_rescale_q(
            targetFrame,
            AVRational(num: 1, den: Int32(format.sampleRate)),
            timeBase
        )

        let result = av_seek_frame(formatCtx, audioStreamIndex, targetTs, AVSEEK_FLAG_BACKWARD)
        guard result >= 0 else {
            throw PurePlayError.decodeFailed("FFmpeg: av_seek_frame failed (\(result))")
        }

        avcodec_flush_buffers(codecCtx)
        pendingBuffer.removeAll(keepingCapacity: true)
        pendingOffset = 0
        _reachedEOF = false
        currentFrame = targetFrame
    }

    public func close() {
        source.close()
    }

    // MARK: - Logging

    private static func logError(_ message: String) {
        FileHandle.standardError.write(Data("[FFmpegDecoder] \(message)\n".utf8))
    }
}

// MARK: - Factory

public enum FFmpegDecoderFactory: DecoderFactory {
    public static let supportedExtensions: Set<String> = [
        "ape", "wv", "tta", "opus", "ogg", "wma", "mka", "dts"
    ]
    public static let priority: Int = 80

    public static func canDecode(source: AudioSource, fileExtension: String) -> Bool {
        supportedExtensions.contains(fileExtension.lowercased())
    }

    public static func makeDecoder(source: AudioSource, fileExtension: String) throws -> AudioDecoder {
        try FFmpegDecoder(source: source, fileExtension: fileExtension)
    }
}
#endif

#if os(macOS) || os(iOS)
private let AVERROR_EAGAIN: Int32 = -35
#else
private let AVERROR_EAGAIN: Int32 = -11
#endif

// AVERROR_EOF = -MKTAG('E','O','F',' ') = -('E' | 'O'<<8 | 'F'<<16 | ' '<<24)
private let FFMPEG_AVERROR_EOF: Int32 = -0x20464F45
