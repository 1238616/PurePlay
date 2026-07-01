import Foundation
#if canImport(CFLAC)
import CFLAC

/// libFLAC-based FLAC decoder
///
/// Activates only when the `CFLAC` module is available (i.e. after running
/// `scripts/build_libflac.sh` and adding the binaryTarget to Package.swift).
///
/// Advantages over the CoreAudio path:
///   - Reference implementation: bit-exact decode, ground-truth for MD5 verify
///   - Streaming API: works directly on AudioSource — no need to dump to
///     a temp file for cloud / non-URL sources
///   - Lower decode-side memory footprint
///
/// Registration:
///   DecoderRegistry.shared.register(LibFLACDecoderFactory.self)
public final class LibFLACDecoder: AudioDecoder {

    public let format: AudioFormat
    public private(set) var totalFrames: Int64
    public private(set) var currentFrame: Int64 = 0
    public var isAtEnd: Bool { currentFrame >= totalFrames }

    private let source: AudioSource
    private var decoderRef: OpaquePointer?      // FLAC__StreamDecoder *
    private var pendingPCM: [Int32]             // interleaved int32 samples (sign-extended)
    private var pendingChannelOffset: Int = 0
    private var error: Error?
    /// Streaminfo cache used after construction
    private let bitsPerSample: Int
    private let channels: Int

    public init(source: AudioSource) throws {
        self.source = source
        guard let dec = FLAC__stream_decoder_new() else {
            throw PurePlayError.decodeFailed("FLAC: cannot allocate decoder")
        }
        self.decoderRef = dec
        self.pendingPCM = []

        // We need to read STREAMINFO before exposing AudioFormat
        // Set callbacks: read / write / metadata / error
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let initStatus = FLAC__stream_decoder_init_stream(
            dec,
            Self.readCallback,
            nil,                                 // seek
            nil,                                 // tell
            nil,                                 // length
            nil,                                 // eof
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
            FLAC__stream_decoder_delete(dec)
            self.decoderRef = nil
            throw PurePlayError.decodeFailed("FLAC: metadata parse failed")
        }

        // After metadata callback we have channel/bits/totalSamples populated below
        let cb = FLAC__stream_decoder_get_channels(dec)
        let bps = FLAC__stream_decoder_get_bits_per_sample(dec)
        let sr  = FLAC__stream_decoder_get_sample_rate(dec)
        let total = FLAC__stream_decoder_get_total_samples(dec)

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
        self.totalFrames = Int64(total)
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
            let pendingFrames = (pendingPCM.count - pendingChannelOffset) / channels
            if pendingFrames > 0 {
                let take = min(maxFrames - framesProduced, pendingFrames)
                let outOffset = framesProduced * bytesPerFrame
                writeInterleavedSamples(into: buffer.advanced(by: outOffset),
                                        frames: take)
                framesProduced += take
                continue
            }
            // 2. Pending exhausted — decode one more FLAC frame
            pendingPCM.removeAll(keepingCapacity: true)
            pendingChannelOffset = 0
            if FLAC__stream_decoder_get_state(dec).rawValue
                == FLAC__STREAM_DECODER_END_OF_STREAM.rawValue {
                break
            }
            if FLAC__stream_decoder_process_single(dec) == 0 {
                throw PurePlayError.decodeFailed("FLAC: process_single failed")
            }
            if pendingPCM.isEmpty { break }     // no more frames
        }

        currentFrame += Int64(framesProduced)
        return framesProduced
    }

    public func seek(to frame: Int64) throws {
        guard let dec = decoderRef else { return }
        let target = UInt64(max(0, min(frame, totalFrames)))
        if FLAC__stream_decoder_seek_absolute(dec, target) == 0 {
            // Some streams (no SEEKTABLE) refuse — try flush + retry once
            FLAC__stream_decoder_flush(dec)
            throw PurePlayError.decodeFailed("FLAC: seek failed")
        }
        pendingPCM.removeAll(keepingCapacity: true)
        pendingChannelOffset = 0
        currentFrame = Int64(target)
    }

    public func close() {
        source.close()
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
            me.error = error
            return FLAC__STREAM_DECODER_READ_STATUS_ABORT
        }
    }

    private static let writeCallback: FLAC__StreamDecoderWriteCallback = {
        (_, framePtr, samplesPtr, clientData) -> FLAC__StreamDecoderWriteStatus in
        guard let frame = framePtr, let samples = samplesPtr, let cd = clientData else {
            return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT
        }
        let me = Unmanaged<LibFLACDecoder>.fromOpaque(cd).takeUnretainedValue()
        let blockSize = Int(frame.pointee.header.blocksize)
        let ch = me.channels
        me.pendingPCM.reserveCapacity(blockSize * ch)
        for f in 0..<blockSize {
            for c in 0..<ch {
                let plane = samples[c]
                me.pendingPCM.append(plane![f])
            }
        }
        me.pendingChannelOffset = 0
        return FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE
    }

    private static let metadataCallback: FLAC__StreamDecoderMetadataCallback = {
        _, _, _ in
        // STREAMINFO is read lazily via FLAC__stream_decoder_get_* getters
    }

    private static let errorCallback: FLAC__StreamDecoderErrorCallback = {
        _, _, _ in
        // Errors surface via process_single return value; nothing to do
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
