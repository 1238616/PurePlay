import Foundation

/// AIFF / AIFC 解码器（PCM 大端）
///
/// AIFF 协议关键点：
/// - 容器 "FORM" + size(BE32) + "AIFF" 或 "AIFC"
/// - COMM chunk：numChannels(BE16), numFrames(BE32), sampleSize(BE16),
///   sampleRate(IEEE 754 80-bit BE)，AIFC 多 4 字节 compressionType
/// - SSND chunk：offset(BE32) + blockSize(BE32) + 大端 PCM 数据
/// - 仅支持未压缩 PCM（AIFC 的 compressionType = "NONE" 或 "sowt"）
///
/// 输出始终为本机字节序的整数 PCM（与 WAVDecoder 一致），让 CoreAudio Hog Mode
/// 直接 bit-perfect 投递。
public final class AIFFDecoder: AudioDecoder {

    public let format: AudioFormat
    public private(set) var totalFrames: Int64
    public private(set) var currentFrame: Int64 = 0

    public var isAtEnd: Bool { currentFrame >= totalFrames }

    private let source: AudioSource
    private let dataChunkOffset: Int64
    private let dataChunkLength: Int64
    /// SSND 数据是否已经是 little-endian（AIFC "sowt"），其他情况都是 BE
    private let isLittleEndianData: Bool

    public init(source: AudioSource) throws {
        self.source = source

        // === FORM 头 12 字节 ===
        var head = [UInt8](repeating: 0, count: 12)
        let r0 = try head.withUnsafeMutableBufferPointer {
            try source.read(into: $0.baseAddress!, length: 12)
        }
        guard r0 == 12,
              head[0] == 0x46, head[1] == 0x4F, head[2] == 0x52, head[3] == 0x4D
        else {
            throw PurePlayError.invalidWAVHeader("Not an AIFF file (bad FORM header)")
        }
        let kind = String(bytes: head[8..<12], encoding: .ascii) ?? ""
        guard kind == "AIFF" || kind == "AIFC" else {
            throw PurePlayError.invalidWAVHeader("FORM type \(kind) not supported")
        }
        let isAIFC = (kind == "AIFC")

        var sampleRate: Double = 0
        var channels: Int = 0
        var bitsPerSample: Int = 0
        var numFrames: UInt32 = 0
        var ssndOffset: Int64 = 0
        var ssndDataLen: Int64 = 0
        var commFound = false
        var ssndFound = false
        var leData = false

        var cursor: Int64 = 12

        while !(commFound && ssndFound) {
            var ch = [UInt8](repeating: 0, count: 8)
            let n = try ch.withUnsafeMutableBufferPointer {
                try source.read(into: $0.baseAddress!, length: 8)
            }
            if n < 8 { break }
            let id = String(bytes: ch[0..<4], encoding: .ascii) ?? ""
            let size = Int(Self.readU32BE(ch, offset: 4))
            cursor += 8

            if id == "COMM" {
                var body = [UInt8](repeating: 0, count: size)
                let rb = try body.withUnsafeMutableBufferPointer {
                    try source.read(into: $0.baseAddress!, length: size)
                }
                guard rb == size, size >= 18 else {
                    throw PurePlayError.invalidWAVHeader("COMM chunk truncated")
                }
                channels = Int(UInt16(body[0]) << 8 | UInt16(body[1]))
                numFrames = Self.readU32BE(body, offset: 2)
                bitsPerSample = Int(UInt16(body[6]) << 8 | UInt16(body[7]))
                sampleRate = Self.readIEEE80(body, offset: 8)

                if isAIFC && size >= 22 {
                    let compressionType = String(bytes: body[18..<22], encoding: .ascii) ?? "NONE"
                    if compressionType == "sowt" {
                        leData = true
                    } else if compressionType != "NONE" && compressionType != "twos" {
                        throw PurePlayError.unsupportedFormat("AIFC compression \(compressionType) not supported")
                    }
                }
                commFound = true
                cursor += Int64(size + (size & 1))   // pad to even
                if (size & 1) != 0 {
                    try source.seek(to: cursor)
                }
            } else if id == "SSND" {
                // 先读 8 字节：offset + blockSize
                var hdr = [UInt8](repeating: 0, count: 8)
                let rh = try hdr.withUnsafeMutableBufferPointer {
                    try source.read(into: $0.baseAddress!, length: 8)
                }
                guard rh == 8 else {
                    throw PurePlayError.invalidWAVHeader("SSND truncated")
                }
                let offset = Self.readU32BE(hdr, offset: 0)
                cursor += 8
                ssndOffset = cursor + Int64(offset)
                ssndDataLen = Int64(size - 8)
                ssndFound = true
                let skip = Int64(size - 8 + (size & 1))
                try source.seek(to: cursor + skip)
                cursor += skip
            } else {
                let pad = (size & 1)
                try source.seek(to: cursor + Int64(size + pad))
                cursor += Int64(size + pad)
            }
        }

        guard commFound, ssndFound else {
            throw PurePlayError.invalidWAVHeader("Missing COMM or SSND chunk")
        }

        let sampleFormat: SampleFormat
        switch bitsPerSample {
        case 16: sampleFormat = .int16
        case 24: sampleFormat = .int24
        case 32: sampleFormat = .int32
        default:
            throw PurePlayError.unsupportedFormat("AIFF unsupported sample size \(bitsPerSample)")
        }

        self.format = AudioFormat(sampleRate: sampleRate,
                                  channels: channels,
                                  sampleFormat: sampleFormat)
        self.dataChunkOffset = ssndOffset
        self.dataChunkLength = ssndDataLen
        self.isLittleEndianData = leData
        _ = numFrames  // numFrames 仅校验；以 SSND 长度为准
        let bytesPerFrame = Int64(channels * sampleFormat.bytesPerSample)
        self.totalFrames = bytesPerFrame > 0 ? ssndDataLen / bytesPerFrame : 0

        try source.seek(to: dataChunkOffset)
    }

    public func decode(into buffer: UnsafeMutableRawPointer, maxFrames: Int) throws -> Int {
        guard maxFrames > 0 else { return 0 }
        let bytesPerFrame = format.bytesPerFrame
        let remaining = totalFrames - currentFrame
        guard remaining > 0 else { return 0 }
        let framesToRead = min(maxFrames, Int(remaining))
        let bytesToRead = framesToRead * bytesPerFrame

        var totalRead = 0
        while totalRead < bytesToRead {
            let n = try source.read(into: buffer.advanced(by: totalRead),
                                    length: bytesToRead - totalRead)
            if n <= 0 { break }
            totalRead += n
        }
        let framesRead = totalRead / bytesPerFrame

        // AIFF / AIFC ("NONE", "twos") 是大端；翻字节序得本机 LE
        if !isLittleEndianData {
            swapBytes(buffer: buffer, frames: framesRead)
        }

        currentFrame += Int64(framesRead)
        return framesRead
    }

    public func seek(to frame: Int64) throws {
        let clamped = max(0, min(frame, totalFrames))
        let bpf = Int64(format.bytesPerFrame)
        try source.seek(to: dataChunkOffset + clamped * bpf)
        currentFrame = clamped
    }

    public func close() {
        source.close()
    }

    // MARK: byte swap

    private func swapBytes(buffer: UnsafeMutableRawPointer, frames: Int) {
        let bps = format.sampleFormat.bytesPerSample
        let samples = frames * format.channels
        let p = buffer.assumingMemoryBound(to: UInt8.self)
        switch bps {
        case 2:
            for i in 0..<samples {
                let a = p[i * 2]
                p[i * 2] = p[i * 2 + 1]
                p[i * 2 + 1] = a
            }
        case 3:
            for i in 0..<samples {
                let a = p[i * 3]
                p[i * 3] = p[i * 3 + 2]
                p[i * 3 + 2] = a
            }
        case 4:
            for i in 0..<samples {
                let a = p[i * 4]
                let b = p[i * 4 + 1]
                p[i * 4] = p[i * 4 + 3]
                p[i * 4 + 1] = p[i * 4 + 2]
                p[i * 4 + 2] = b
                p[i * 4 + 3] = a
            }
        default: break
        }
    }

    // MARK: helpers

    private static func readU32BE(_ b: [UInt8], offset: Int) -> UInt32 {
        (UInt32(b[offset]) << 24) |
        (UInt32(b[offset + 1]) << 16) |
        (UInt32(b[offset + 2]) << 8) |
        UInt32(b[offset + 3])
    }

    /// 80-bit IEEE 754 extended precision → Double
    private static func readIEEE80(_ b: [UInt8], offset: Int) -> Double {
        let sign = (b[offset] & 0x80) != 0
        let exp = Int((UInt16(b[offset] & 0x7F) << 8) | UInt16(b[offset + 1]))
        var mantissa: UInt64 = 0
        for i in 0..<8 {
            mantissa = (mantissa << 8) | UInt64(b[offset + 2 + i])
        }
        if exp == 0 && mantissa == 0 { return 0 }
        let unbiasedExp = exp - 16383
        let value = Double(mantissa) * pow(2.0, Double(unbiasedExp - 63))
        return sign ? -value : value
    }
}

public enum AIFFDecoderFactory: DecoderFactory {
    public static let supportedExtensions: Set<String> = ["aiff", "aif", "aifc"]
    public static let priority: Int = 100   // 与 WAV 同级

    public static func canDecode(source: AudioSource, fileExtension: String) -> Bool {
        supportedExtensions.contains(fileExtension.lowercased())
    }

    public static func makeDecoder(source: AudioSource, fileExtension: String) throws -> AudioDecoder {
        try AIFFDecoder(source: source)
    }
}
