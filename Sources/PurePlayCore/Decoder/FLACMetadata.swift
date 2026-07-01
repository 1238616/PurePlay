import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#endif

/// FLAC STREAMINFO（metadata block type 0）解析
/// 规范：https://xiph.org/flac/format.html#metadata_block_streaminfo
/// 仅做头部 + 一个 STREAMINFO + 可选 VORBIS_COMMENT 抽取，不解码音频帧
public struct FLACStreamInfo: Sendable {
    public let minBlockSize: Int
    public let maxBlockSize: Int
    public let minFrameSize: Int
    public let maxFrameSize: Int
    public let sampleRate: Int
    public let channels: Int
    public let bitsPerSample: Int
    public let totalSamples: Int64
    public let md5Signature: [UInt8]   // 16 bytes，全 0 表示未填充

    public var hasMD5: Bool {
        md5Signature.contains { $0 != 0 }
    }
}

/// FLAC 元数据 + Vorbis Comment 读取
public enum FLACMetadata {

    /// FLAC 文件签名 "fLaC"
    public static let signature: [UInt8] = [0x66, 0x4C, 0x61, 0x43]

    public struct ParseResult: Sendable {
        public let streamInfo: FLACStreamInfo
        public let vorbisComments: [String: String]
        public let audioStartOffset: Int64
    }

    /// 从本地文件读取 STREAMINFO 与所有 VORBIS_COMMENT
    /// - Returns: 非 FLAC 文件返回 nil
    public static func read(from url: URL) throws -> ParseResult? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try read(handle: handle)
    }

    /// 从已打开句柄读取；句柄位置会被移动
    public static func read(handle: FileHandle) throws -> ParseResult? {
        try handle.seek(toOffset: 0)
        guard let sig = try handle.read(upToCount: 4), sig.count == 4,
              [UInt8](sig) == signature else {
            return nil
        }

        var streamInfo: FLACStreamInfo?
        var comments: [String: String] = [:]
        var offset: Int64 = 4

        while true {
            guard let header = try handle.read(upToCount: 4), header.count == 4 else {
                break
            }
            offset += 4
            let isLast = (header[0] & 0x80) != 0
            let type = Int(header[0] & 0x7F)
            let length = (Int(header[1]) << 16) | (Int(header[2]) << 8) | Int(header[3])

            guard let body = try handle.read(upToCount: length), body.count == length else {
                break
            }
            offset += Int64(length)

            switch type {
            case 0: // STREAMINFO
                streamInfo = parseStreamInfo(body)
            case 4: // VORBIS_COMMENT
                comments.merge(parseVorbisComment(body)) { _, new in new }
            default:
                break
            }

            if isLast { break }
        }

        guard let info = streamInfo else { return nil }
        return ParseResult(streamInfo: info, vorbisComments: comments, audioStartOffset: offset)
    }

    private static func parseStreamInfo(_ data: Data) -> FLACStreamInfo? {
        guard data.count >= 34 else { return nil }
        let bytes = [UInt8](data)

        let minBlock = (Int(bytes[0]) << 8) | Int(bytes[1])
        let maxBlock = (Int(bytes[2]) << 8) | Int(bytes[3])
        let minFrame = (Int(bytes[4]) << 16) | (Int(bytes[5]) << 8) | Int(bytes[6])
        let maxFrame = (Int(bytes[7]) << 16) | (Int(bytes[8]) << 8) | Int(bytes[9])

        // 20-bit sample rate
        let sr = (UInt32(bytes[10]) << 12)
               | (UInt32(bytes[11]) << 4)
               | (UInt32(bytes[12]) >> 4)
        // 3-bit channels (value = ch - 1)
        let ch = Int((bytes[12] >> 1) & 0x07) + 1
        // 5-bit bits per sample (value = bps - 1)
        let bps = (Int(bytes[12] & 0x01) << 4) | Int(bytes[13] >> 4)
        let bitsPerSample = bps + 1
        // 36-bit total samples
        let total = (UInt64(bytes[13] & 0x0F) << 32)
                  | (UInt64(bytes[14]) << 24)
                  | (UInt64(bytes[15]) << 16)
                  | (UInt64(bytes[16]) << 8)
                  | UInt64(bytes[17])

        let md5 = Array(bytes[18..<34])

        return FLACStreamInfo(
            minBlockSize: minBlock,
            maxBlockSize: maxBlock,
            minFrameSize: minFrame,
            maxFrameSize: maxFrame,
            sampleRate: Int(sr),
            channels: ch,
            bitsPerSample: bitsPerSample,
            totalSamples: Int64(total),
            md5Signature: md5
        )
    }

    private static func parseVorbisComment(_ data: Data) -> [String: String] {
        // Vorbis Comment 在 FLAC 内为 little-endian
        var p = 0
        let bytes = [UInt8](data)
        func readU32() -> UInt32? {
            guard p + 4 <= bytes.count else { return nil }
            let v = UInt32(bytes[p]) | (UInt32(bytes[p+1]) << 8)
                  | (UInt32(bytes[p+2]) << 16) | (UInt32(bytes[p+3]) << 24)
            p += 4
            return v
        }
        guard let vendorLen = readU32() else { return [:] }
        p += Int(vendorLen)  // 跳过 vendor string
        guard let count = readU32() else { return [:] }

        var result: [String: String] = [:]
        for _ in 0..<count {
            guard let len = readU32(),
                  p + Int(len) <= bytes.count else { break }
            let raw = Data(bytes[p..<(p + Int(len))])
            p += Int(len)
            guard let entry = String(data: raw, encoding: .utf8) else { continue }
            // KEY=VALUE
            if let eq = entry.firstIndex(of: "=") {
                let key = entry[..<eq].uppercased()
                let value = String(entry[entry.index(after: eq)...])
                result[String(key)] = value
            }
        }
        return result
    }
}

/// FLAC MD5 验证器
/// FLAC 规范：解码后的样本以 little-endian 整数（按 bitsPerSample 对齐）逐声道交错送入 MD5
/// - 16-bit: 2 bytes/sample
/// - 24-bit: 3 bytes/sample
/// - 32-bit: 4 bytes/sample
public final class FLACMD5Verifier {

    public let bitsPerSample: Int
    public let channels: Int
    private var context: CC_MD5_CTX

    public init(bitsPerSample: Int, channels: Int) {
        self.bitsPerSample = bitsPerSample
        self.channels = channels
        self.context = CC_MD5_CTX()
        CC_MD5_Init(&context)
    }

    /// 输入 int32 packed PCM（CoreAudioDecoder 的整数输出格式）
    /// 按源 bitsPerSample 截断后写入 MD5
    public func updateInt32(_ pcm: UnsafePointer<Int32>, sampleCount: Int) {
        let bps = bitsPerSample
        switch bps {
        case 16:
            var scratch = [UInt8](repeating: 0, count: sampleCount * 2)
            for i in 0..<sampleCount {
                let s = pcm[i] >> 16   // int32 容器低 16 位为有效数据；CoreAudioDecoder 已左对齐至高位
                let v = Int16(truncatingIfNeeded: s)
                scratch[i * 2]     = UInt8(truncatingIfNeeded: UInt16(bitPattern: v))
                scratch[i * 2 + 1] = UInt8(truncatingIfNeeded: UInt16(bitPattern: v) >> 8)
            }
            scratch.withUnsafeBufferPointer { p in
                CC_MD5_Update(&context, p.baseAddress, CC_LONG(p.count))
            }
        case 24:
            var scratch = [UInt8](repeating: 0, count: sampleCount * 3)
            for i in 0..<sampleCount {
                let s = pcm[i] >> 8    // 24-bit 数据在 int32 容器的高 24 位
                let u = UInt32(bitPattern: s)
                scratch[i * 3]     = UInt8(truncatingIfNeeded: u)
                scratch[i * 3 + 1] = UInt8(truncatingIfNeeded: u >> 8)
                scratch[i * 3 + 2] = UInt8(truncatingIfNeeded: u >> 16)
            }
            scratch.withUnsafeBufferPointer { p in
                CC_MD5_Update(&context, p.baseAddress, CC_LONG(p.count))
            }
        case 32:
            pcm.withMemoryRebound(to: UInt8.self, capacity: sampleCount * 4) { p in
                CC_MD5_Update(&context, p, CC_LONG(sampleCount * 4))
            }
        default:
            // 8 / 12 / 20 等罕见位深：暂不支持，按 16-bit fallback
            break
        }
    }

    public func finalize() -> [UInt8] {
        var digest = [UInt8](repeating: 0, count: 16)
        digest.withUnsafeMutableBufferPointer { p in
            CC_MD5_Final(p.baseAddress, &context)
        }
        return digest
    }
}
