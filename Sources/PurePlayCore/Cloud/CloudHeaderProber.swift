import Foundation

/// 云盘文件头部探测器
///
/// 在播放云盘文件前，只下载前 64KB 头部数据快速识别格式与基本参数，
/// 避免按文件扩展名盲猜（用户可能改后缀，或文件无后缀）。
///
/// 探测顺序（按 magic bytes）：
///   - "RIFF"..."WAVE" → WAV
///   - "fLaC"           → FLAC
///   - "FORM"..."AIFF"  → AIFF
///   - "FORM"..."AIFC"  → AIFC
///   - "DSD "           → DSF
///   - "FRM8"..."DSD "  → DFF
///   - "ID3"            → MP3 (with ID3 tag)
///   - 0xFF 0xFB/0xFA   → MP3 (raw frame)
///   - "ftyp"...."M4A"  → ALAC/AAC in m4a
///   - "OggS"           → Ogg/Opus/Vorbis
///
/// 当容器能直接读出 sampleRate/channels/bitDepth 时，输出 AudioFormat。
public enum CloudHeaderProber {

    public enum DetectedFormat: String, Sendable {
        case wav, flac, aiff, aifc, dsf, dff
        case mp3, m4a, ogg
        case unknown
    }

    public struct ProbeResult: Sendable {
        public let format: DetectedFormat
        public let extensionHint: String     // 推荐传给 DecoderRegistry 的扩展名
        public let audioFormat: AudioFormat? // 容器头能算出来时给出；否则 nil
    }

    /// 探测一段头部数据
    public static func probe(headerBytes: Data) -> ProbeResult {
        guard headerBytes.count >= 12 else {
            return ProbeResult(format: .unknown, extensionHint: "", audioFormat: nil)
        }
        let b = [UInt8](headerBytes)

        // RIFF/WAVE
        if matches(b, 0, ascii: "RIFF") || matches(b, 0, ascii: "RF64") {
            if b.count >= 12 && matches(b, 8, ascii: "WAVE") {
                let af = parseWAVFormat(b)
                return ProbeResult(format: .wav, extensionHint: "wav", audioFormat: af)
            }
        }
        // FLAC
        if matches(b, 0, ascii: "fLaC") {
            let af = parseFLACFormat(b)
            return ProbeResult(format: .flac, extensionHint: "flac", audioFormat: af)
        }
        // AIFF / AIFC
        if matches(b, 0, ascii: "FORM") && b.count >= 12 {
            if matches(b, 8, ascii: "AIFF") {
                return ProbeResult(format: .aiff, extensionHint: "aiff", audioFormat: nil)
            }
            if matches(b, 8, ascii: "AIFC") {
                return ProbeResult(format: .aifc, extensionHint: "aiff", audioFormat: nil)
            }
        }
        // DSF
        if matches(b, 0, ascii: "DSD ") {
            let af = parseDSFFormat(b)
            return ProbeResult(format: .dsf, extensionHint: "dsf", audioFormat: af)
        }
        // DFF (DSDIFF)
        if matches(b, 0, ascii: "FRM8") && b.count >= 16 && matches(b, 12, ascii: "DSD ") {
            return ProbeResult(format: .dff, extensionHint: "dff", audioFormat: nil)
        }
        // OggS
        if matches(b, 0, ascii: "OggS") {
            return ProbeResult(format: .ogg, extensionHint: "ogg", audioFormat: nil)
        }
        // MP3 with ID3 tag
        if matches(b, 0, ascii: "ID3") {
            return ProbeResult(format: .mp3, extensionHint: "mp3", audioFormat: nil)
        }
        // Raw MP3 frame sync
        if b.count >= 2 && b[0] == 0xFF && (b[1] & 0xE0) == 0xE0 {
            return ProbeResult(format: .mp3, extensionHint: "mp3", audioFormat: nil)
        }
        // M4A / MP4 (ISO base media): bytes 4..8 == "ftyp"
        if b.count >= 12 && matches(b, 4, ascii: "ftyp") {
            return ProbeResult(format: .m4a, extensionHint: "m4a", audioFormat: nil)
        }
        return ProbeResult(format: .unknown, extensionHint: "", audioFormat: nil)
    }

    /// 便捷：从云盘客户端拉取前 64KB 并探测
    public static func probe(client: QuarkAPIClient,
                             fid: String,
                             fileSize: Int64,
                             headerBytes: Int = 64 * 1024) async throws -> ProbeResult {
        let end = min(Int64(headerBytes), fileSize)
        let request = try await client.makeDownloadRequest(fid: fid, range: 0..<end)
        let session = URLSession.shared
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse,
           http.statusCode != 200 && http.statusCode != 206 {
            throw PurePlayError.ioError("Header probe HTTP \(http.statusCode)")
        }
        return probe(headerBytes: data)
    }

    // MARK: - Per-format parsers

    private static func parseWAVFormat(_ b: [UInt8]) -> AudioFormat? {
        // 简化：在前 N 字节里扫描 "fmt " chunk
        guard let fmtStart = findSubsequence(b, ascii: "fmt ", from: 12) else { return nil }
        let fmtBodyStart = fmtStart + 8   // skip "fmt " + 4-byte size
        guard b.count >= fmtBodyStart + 16 else { return nil }
        let formatTag = UInt16(b[fmtBodyStart]) | (UInt16(b[fmtBodyStart + 1]) << 8)
        let channels  = Int(UInt16(b[fmtBodyStart + 2]) | (UInt16(b[fmtBodyStart + 3]) << 8))
        let sampleRate = Double(UInt32(b[fmtBodyStart + 4]) |
                                (UInt32(b[fmtBodyStart + 5]) << 8) |
                                (UInt32(b[fmtBodyStart + 6]) << 16) |
                                (UInt32(b[fmtBodyStart + 7]) << 24))
        let bitsPerSample = Int(UInt16(b[fmtBodyStart + 14]) | (UInt16(b[fmtBodyStart + 15]) << 8))
        let sf: SampleFormat
        switch (formatTag, bitsPerSample) {
        case (1, 16): sf = .int16
        case (1, 24): sf = .int24
        case (1, 32): sf = .int32
        case (3, 32): sf = .float32
        case (0xFFFE, 16): sf = .int16
        case (0xFFFE, 24): sf = .int24
        case (0xFFFE, 32): sf = .int32
        default: return nil
        }
        return AudioFormat(sampleRate: sampleRate, channels: channels, sampleFormat: sf)
    }

    private static func parseFLACFormat(_ b: [UInt8]) -> AudioFormat? {
        // FLAC: 4 字节 "fLaC" + 第一个 metadata block 必须是 STREAMINFO
        // block header (4 bytes): bit7 last-block flag, bits 0..6 block type (0=STREAMINFO), 24-bit length
        guard b.count > 4 + 4 + 18 else { return nil }
        let blockType = b[4] & 0x7F
        guard blockType == 0 else { return nil }
        let streamInfoStart = 8
        guard b.count >= streamInfoStart + 18 else { return nil }
        // STREAMINFO bytes:
        //  16  minBlockSize (uint16 BE)
        //  16  maxBlockSize
        //  24  minFrameSize
        //  24  maxFrameSize
        //  20  sample rate
        //   3  channels - 1
        //   5  bits/sample - 1
        //  36  total samples
        // 128  MD5
        let p = streamInfoStart + 10   // 跳过 4 × (block size + frame size)
        let byte0 = UInt32(b[p])
        let byte1 = UInt32(b[p + 1])
        let byte2 = UInt32(b[p + 2])
        let byte3 = UInt32(b[p + 3])
        let sampleRate = Double((byte0 << 12) | (byte1 << 4) | (byte2 >> 4))
        let channels   = Int(((byte2 >> 1) & 0x7) + 1)
        let bitsPerSample = Int((((byte2 & 0x1) << 4) | ((byte3 >> 4))) + 1)
        let sf: SampleFormat
        switch bitsPerSample {
        case 16: sf = .int16
        case 24: sf = .int24
        case 32: sf = .int32
        default: sf = .int24
        }
        return AudioFormat(sampleRate: sampleRate, channels: channels,
                           sampleFormat: sf, sourceBitDepth: bitsPerSample)
    }

    private static func parseDSFFormat(_ b: [UInt8]) -> AudioFormat? {
        // DSF 28B + fmt 52B 在 64KB 内必到
        guard b.count >= 28 + 52 else { return nil }
        let fmtStart = 28
        guard matches(b, fmtStart, ascii: "fmt ") else { return nil }
        let channelNum = Int(UInt32(b[fmtStart + 24]) |
                             (UInt32(b[fmtStart + 25]) << 8) |
                             (UInt32(b[fmtStart + 26]) << 16) |
                             (UInt32(b[fmtStart + 27]) << 24))
        let sampleFreq = Int(UInt32(b[fmtStart + 28]) |
                             (UInt32(b[fmtStart + 29]) << 8) |
                             (UInt32(b[fmtStart + 30]) << 16) |
                             (UInt32(b[fmtStart + 31]) << 24))
        let dopCarrier = Double(sampleFreq) / 16.0
        return AudioFormat(sampleRate: dopCarrier,
                           channels: channelNum,
                           sampleFormat: .int24,
                           isDSD: true,
                           sourceBitDepth: 1)
    }

    // MARK: - Helpers

    private static func matches(_ b: [UInt8], _ offset: Int, ascii: String) -> Bool {
        let bytes = Array(ascii.utf8)
        guard b.count >= offset + bytes.count else { return false }
        for i in 0..<bytes.count where b[offset + i] != bytes[i] {
            return false
        }
        return true
    }

    private static func findSubsequence(_ b: [UInt8], ascii: String, from: Int) -> Int? {
        let needle = Array(ascii.utf8)
        let limit = b.count - needle.count
        if limit < from { return nil }
        var i = from
        while i <= limit {
            var match = true
            for k in 0..<needle.count {
                if b[i + k] != needle[k] { match = false; break }
            }
            if match { return i }
            i += 1
        }
        return nil
    }
}
