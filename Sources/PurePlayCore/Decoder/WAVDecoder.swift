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
    /// 源数据为 64-bit float — 磁盘 8B/样本，decode 输出降转为 float32
    private let sourceIsFloat64: Bool
    /// 磁盘上每帧字节数（float64 源 = channels×8，其余与 format.bytesPerFrame 相同）
    private let diskBytesPerFrame: Int
    /// float64 解码复用的 scratch（避免每帧分配）
    private var f64Scratch: [UInt8] = []

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
        /// EXTENSIBLE SubFormat GUID 的 Data1（0x0001 = PCM, 0x0003 = IEEE Float）
        var subFormatCode: UInt32 = 0
        /// RF64 ds64 chunk 提供的 64-bit data 尺寸
        var ds64DataSize: Int64? = nil

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
                // WAVE_FORMAT_EXTENSIBLE：SubFormat GUID 位于 fmt 数据偏移 24
                // 专业录音设备的 32-bit float WAV 常用 EXTENSIBLE 封装，
                // 仅看 bitsPerSample 会把 float 误判为整数（issue #3）
                if formatTag == 0xFFFE && size >= 28 {
                    subFormatCode = UInt32(fmtData[24]) | (UInt32(fmtData[25]) << 8) |
                                    (UInt32(fmtData[26]) << 16) | (UInt32(fmtData[27]) << 24)
                }
                fmtFound = true
                let fmtPad = size & 1   // RIFF chunk 偶字节对齐
                if fmtPad != 0 { try source.seek(to: cursor + Int64(size + fmtPad)) }
                cursor += Int64(size + fmtPad)
            } else if id == "ds64" {
                // RF64：真实 64-bit 尺寸在 ds64 chunk（riffSize/dataSize/sampleCount，各 LE64）
                // data chunk 的 32-bit size 字段此时是占位符 0xFFFFFFFF（issue #4）
                let bodyLen = max(size, 24)
                var body = [UInt8](repeating: 0, count: bodyLen)
                let r = try body.withUnsafeMutableBufferPointer {
                    try source.read(into: $0.baseAddress!, length: size)
                }
                if r >= 24 {
                    var v: UInt64 = 0
                    for i in 0..<8 { v |= UInt64(body[8 + i]) << (8 * i) }
                    ds64DataSize = Int64(bitPattern: v)
                }
                let pad = size & 1
                try source.seek(to: cursor + Int64(size + pad))
                cursor += Int64(size + pad)
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

        // RF64：data chunk 的 32-bit size 是占位符 0xFFFFFFFF，真实尺寸取自 ds64（issue #4）
        if riff == "RF64", let real = ds64DataSize {
            dataLength = real
        } else if dataLength == 0xFFFFFFFF, let real = ds64DataSize {
            dataLength = real
        }

        // formatTag: 1=PCM, 3=IEEE Float, 0xFFFE=WAVE_FORMAT_EXTENSIBLE
        // EXTENSIBLE 的真实格式由 SubFormat GUID Data1 决定：
        //   0x0001 = KSDATAFORMAT_SUBTYPE_PCM, 0x0003 = KSDATAFORMAT_SUBTYPE_IEEE_FLOAT
        let isFloat: Bool
        switch formatTag {
        case 1:
            isFloat = false
        case 3:
            isFloat = true
        case 0xFFFE:
            guard subFormatCode == 0x0001 || subFormatCode == 0x0003 else {
                throw PurePlayError.invalidWAVHeader(
                    "Unsupported EXTENSIBLE SubFormat GUID code=0x\(String(subFormatCode, radix: 16))")
            }
            isFloat = (subFormatCode == 0x0003)
        default:
            throw PurePlayError.invalidWAVHeader("Unsupported format tag=\(formatTag)")
        }

        let sampleFormat: SampleFormat
        switch (isFloat, bitsPerSample) {
        case (false, 16): sampleFormat = .int16
        case (false, 24): sampleFormat = .int24
        case (false, 32): sampleFormat = .int32
        case (true, 32):  sampleFormat = .float32
        case (true, 64):  sampleFormat = .float32   // 64-bit float 解码侧降为 float32
        default:
            throw PurePlayError.invalidWAVHeader("Unsupported PCM format float=\(isFloat) bits=\(bitsPerSample)")
        }
        let isFloat64Source = isFloat && bitsPerSample == 64

        self.format = AudioFormat(sampleRate: sampleRate,
                                  channels: channels,
                                  sampleFormat: sampleFormat)
        self.sourceIsFloat64 = isFloat64Source
        // 磁盘上每帧字节数：float64 源为 8B/样本，其余与输出格式一致
        self.diskBytesPerFrame = channels * (isFloat64Source ? 8 : sampleFormat.bytesPerSample)
        self.dataChunkOffset = dataOffset
        self.dataChunkLength = dataLength
        let dBF = Int64(diskBytesPerFrame)
        self.totalFrames = dBF > 0 ? dataLength / dBF : 0

        // 定位到数据区起点
        try source.seek(to: dataOffset)
    }

    public func decode(into buffer: UnsafeMutableRawPointer, maxFrames: Int) throws -> Int {
        guard maxFrames > 0 else { return 0 }
        let remainingFrames = totalFrames - currentFrame
        guard remainingFrames > 0 else { return 0 }

        let framesToRead = min(maxFrames, Int(remainingFrames))

        if sourceIsFloat64 {
            // 64-bit float 源：读入复用 scratch，再降转为 float32 写调用方 buffer
            let bytesToRead = framesToRead * diskBytesPerFrame
            if f64Scratch.count < bytesToRead {
                f64Scratch = [UInt8](repeating: 0, count: bytesToRead)
            }
            var totalRead = 0
            while totalRead < bytesToRead {
                let n = try f64Scratch.withUnsafeMutableBufferPointer {
                    try source.read(into: $0.baseAddress!.advanced(by: totalRead),
                                    length: bytesToRead - totalRead)
                }
                if n <= 0 { break }
                totalRead += n
            }
            let framesRead = totalRead / diskBytesPerFrame
            let sampleCount = framesRead * format.channels
            f64Scratch.withUnsafeBufferPointer { raw in
                raw.baseAddress!.withMemoryRebound(to: Double.self, capacity: sampleCount) { dp in
                    let out = buffer.assumingMemoryBound(to: Float.self)
                    for i in 0..<sampleCount {
                        out[i] = Float(dp[i])
                    }
                }
            }
            currentFrame += Int64(framesRead)
            return framesRead
        }

        let bytesPerFrame = diskBytesPerFrame
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
        try source.seek(to: dataChunkOffset + clamped * Int64(diskBytesPerFrame))
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
