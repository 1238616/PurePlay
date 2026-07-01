import Foundation

/// 极简 WAV 解码器（PCM 与 IEEE Float）
/// 参考 dr_wav 的解析方式，只支持 RIFF/WAVE 容器
public final class WAVDecoder: AudioDecoder {

    public let format: AudioFormat
    public private(set) var totalFrames: Int64
    public private(set) var currentFrame: Int64 = 0

    private let source: AudioSource
    private let dataChunkOffset: Int64
    private let dataChunkLength: Int64

    public var isAtEnd: Bool { currentFrame >= totalFrames }

    public init(source: AudioSource) throws {
        self.source = source

        // 读取 RIFF 头部
        var header = [UInt8](repeating: 0, count: 12)
        let read = try header.withUnsafeMutableBufferPointer {
            try source.read(into: $0.baseAddress!, length: 12)
        }
        guard read == 12 else {
            throw PurePlayError.invalidWAVHeader("Header too short")
        }

        let riff = String(bytes: header[0..<4], encoding: .ascii) ?? ""
        let wave = String(bytes: header[8..<12], encoding: .ascii) ?? ""

        guard riff == "RIFF" || riff == "RF64",
              wave == "WAVE" else {
            throw PurePlayError.invalidWAVHeader("Not a WAVE file (riff=\(riff), form=\(wave))")
        }

        // 寻找 fmt 与 data 子块
        var fmtFound = false
        var dataFound = false
        var sampleRate: Double = 0
        var channels: Int = 0
        var bitsPerSample: Int = 0
        var formatTag: UInt16 = 0
        var dataOffset: Int64 = 0
        var dataLength: Int64 = 0

        // 当前位置 = 12（RIFF header 之后）
        var cursor: Int64 = 12

        while !(fmtFound && dataFound) {
            var chunkHeader = [UInt8](repeating: 0, count: 8)
            let n = try chunkHeader.withUnsafeMutableBufferPointer {
                try source.read(into: $0.baseAddress!, length: 8)
            }
            if n < 8 { break }

            let id = String(bytes: chunkHeader[0..<4], encoding: .ascii) ?? ""
            let size = Int(UInt32(chunkHeader[4]) | (UInt32(chunkHeader[5]) << 8) |
                          (UInt32(chunkHeader[6]) << 16) | (UInt32(chunkHeader[7]) << 24))
            cursor += 8

            if id == "fmt " {
                var fmtData = [UInt8](repeating: 0, count: size)
                let r = try fmtData.withUnsafeMutableBufferPointer {
                    try source.read(into: $0.baseAddress!, length: size)
                }
                guard r == size else {
                    throw PurePlayError.invalidWAVHeader("fmt chunk truncated")
                }
                formatTag = UInt16(fmtData[0]) | (UInt16(fmtData[1]) << 8)
                channels  = Int(UInt16(fmtData[2]) | (UInt16(fmtData[3]) << 8))
                let sr    = UInt32(fmtData[4]) | (UInt32(fmtData[5]) << 8) |
                            (UInt32(fmtData[6]) << 16) | (UInt32(fmtData[7]) << 24)
                sampleRate = Double(sr)
                bitsPerSample = Int(UInt16(fmtData[14]) | (UInt16(fmtData[15]) << 8))
                fmtFound = true
                cursor += Int64(size)
            } else if id == "data" {
                dataOffset = cursor
                dataLength = Int64(size)
                dataFound = true
                // 不读取数据，留给 decode() 按需消耗
                if !fmtFound {
                    // 极少数文件 data 在 fmt 之前，这里用 seek 跳过
                    try source.seek(to: cursor + Int64(size))
                    cursor += Int64(size)
                } else {
                    break
                }
            } else {
                // 跳过未知子块
                let pad = (size & 1)  // 偶字节对齐
                try source.seek(to: cursor + Int64(size + pad))
                cursor += Int64(size + pad)
            }
        }

        guard fmtFound && dataFound else {
            throw PurePlayError.invalidWAVHeader("Missing fmt or data chunk")
        }

        // formatTag: 1=PCM, 3=IEEE Float, 0xFFFE=WAVE_FORMAT_EXTENSIBLE
        let sampleFormat: SampleFormat
        switch (formatTag, bitsPerSample) {
        case (1, 16): sampleFormat = .int16
        case (1, 24): sampleFormat = .int24
        case (1, 32): sampleFormat = .int32
        case (3, 32): sampleFormat = .float32
        case (0xFFFE, 16): sampleFormat = .int16
        case (0xFFFE, 24): sampleFormat = .int24
        case (0xFFFE, 32): sampleFormat = .int32
        default:
            throw PurePlayError.invalidWAVHeader("Unsupported PCM format tag=\(formatTag) bits=\(bitsPerSample)")
        }

        self.format = AudioFormat(sampleRate: sampleRate,
                                  channels: channels,
                                  sampleFormat: sampleFormat)
        self.dataChunkOffset = dataOffset
        self.dataChunkLength = dataLength
        let bytesPerFrame = Int64(channels * sampleFormat.bytesPerSample)
        self.totalFrames = bytesPerFrame > 0 ? dataLength / bytesPerFrame : 0

        // 定位到数据区起点
        try source.seek(to: dataOffset)
    }

    public func decode(into buffer: UnsafeMutableRawPointer, maxFrames: Int) throws -> Int {
        guard maxFrames > 0 else { return 0 }
        let bytesPerFrame = format.bytesPerFrame
        let remainingFrames = totalFrames - currentFrame
        guard remainingFrames > 0 else { return 0 }

        let framesToRead = min(maxFrames, Int(remainingFrames))
        let bytesToRead = framesToRead * bytesPerFrame

        var totalRead = 0
        while totalRead < bytesToRead {
            let n = try source.read(
                into: buffer.advanced(by: totalRead),
                length: bytesToRead - totalRead
            )
            if n <= 0 { break }
            totalRead += n
        }

        let framesRead = totalRead / bytesPerFrame
        currentFrame += Int64(framesRead)
        return framesRead
    }

    public func seek(to frame: Int64) throws {
        let clamped = max(0, min(frame, totalFrames))
        let bytesPerFrame = Int64(format.bytesPerFrame)
        try source.seek(to: dataChunkOffset + clamped * bytesPerFrame)
        currentFrame = clamped
    }

    public func close() {
        source.close()
    }
}

public enum WAVDecoderFactory: DecoderFactory {
    public static let supportedExtensions: Set<String> = ["wav", "wave"]
    public static let priority: Int = 100

    public static func canDecode(source: AudioSource, fileExtension: String) -> Bool {
        supportedExtensions.contains(fileExtension)
    }

    public static func makeDecoder(source: AudioSource, fileExtension: String) throws -> AudioDecoder {
        try WAVDecoder(source: source)
    }
}
