import Foundation

/// DFF (DSDIFF, Philips DSD Interchange File Format) 解码器
///
/// 与 DSF 的关键差异：
/// - **大端字节序**（DSF 是小端）
/// - **MSB-first DSD 位序**（DSF 是 LSB-first）
/// - **声道按字节交错**（DSF 是 4096-byte blocks per channel）：
///     字节流 = L0, R0, L1, R1, L2, R2, ...
/// - 顶层容器 "FRM8" 而不是 RIFF/DSF
///
/// 实现限制：
/// - 仅支持立体声
/// - 仅支持未压缩 DSD（PROP/SND/CMPR 字段为 "DSD "）
/// - 跳过 ID3 / Comments / 其它可选 chunk
public final class DFFDecoder: AudioDecoder {

    public let format: AudioFormat
    public let totalFrames: Int64
    public private(set) var currentFrame: Int64 = 0

    public var isAtEnd: Bool { currentFrame >= totalFrames }

    private let source: AudioSource
    private let dataChunkOffset: Int64
    private let dataChunkLength: Int64
    private let channels: Int
    private let dsdRate: Int
    private let packer: DoPPacker

    /// I/O 缓冲：一次读 8KB 交错 DSD 字节
    private var ioBuffer: [UInt8]
    private var ioBufferValid: Int = 0
    private var ioBufferPos: Int = 0

    public init(source: AudioSource) throws {
        self.source = source

        // === FRM8 容器头 ===
        var headBuf = [UInt8](repeating: 0, count: 16)
        let r0 = try headBuf.withUnsafeMutableBufferPointer {
            try source.read(into: $0.baseAddress!, length: 16)
        }
        guard r0 == 16,
              headBuf[0] == 0x46, headBuf[1] == 0x52, headBuf[2] == 0x4D, headBuf[3] == 0x38,
              headBuf[12] == 0x44, headBuf[13] == 0x53, headBuf[14] == 0x44, headBuf[15] == 0x20
        else {
            throw PurePlayError.invalidWAVHeader("Not a DFF file (bad FRM8/DSD header)")
        }
        // bytes 4..12 = form size (BE 64-bit, unused for now)

        // 现在解析 PROP chunk（含 FS / CHNL / CMPR）
        var dataOffset: Int64 = 0
        var dataLength: Int64 = 0
        var sampleFreq: Int = 0
        var channelNum: Int = 0
        var bitsPerSample: Int = 1  // DSD 默认

        // 当前文件位置 = 16
        var cursor: Int64 = 16
        while true {
            var chunkHead = [UInt8](repeating: 0, count: 12)
            let rh = try chunkHead.withUnsafeMutableBufferPointer {
                try source.read(into: $0.baseAddress!, length: 12)
            }
            if rh < 12 { break }
            let chunkID = String(bytes: chunkHead[0..<4], encoding: .ascii) ?? ""
            let chunkSize = Self.readU64BE(chunkHead, offset: 4)
            cursor += 12
            let payloadStart = cursor

            if chunkID == "PROP" {
                // PROP chunk: 4字节 type ("SND ") 之后是嵌套 chunks
                var propType = [UInt8](repeating: 0, count: 4)
                _ = try propType.withUnsafeMutableBufferPointer {
                    try source.read(into: $0.baseAddress!, length: 4)
                }
                cursor += 4
                let propEnd = payloadStart + Int64(chunkSize)
                while cursor < propEnd {
                    var ph = [UInt8](repeating: 0, count: 12)
                    let rp = try ph.withUnsafeMutableBufferPointer {
                        try source.read(into: $0.baseAddress!, length: 12)
                    }
                    guard rp == 12 else { break }
                    let pid = String(bytes: ph[0..<4], encoding: .ascii) ?? ""
                    let psize = Self.readU64BE(ph, offset: 4)
                    cursor += 12

                    if pid == "FS  " {
                        // 4 字节 BE 采样率
                        var b = [UInt8](repeating: 0, count: 4)
                        _ = try b.withUnsafeMutableBufferPointer {
                            try source.read(into: $0.baseAddress!, length: 4)
                        }
                        sampleFreq = Int(Self.readU32BE(b, offset: 0))
                        cursor += 4
                        let pad = Int64(psize) - 4
                        if pad > 0 {
                            try source.seek(to: cursor + pad)
                            cursor += pad
                        }
                    } else if pid == "CHNL" {
                        // 2 字节 numChannels + numChannels × 4 字节 channel ID
                        var b = [UInt8](repeating: 0, count: 2)
                        _ = try b.withUnsafeMutableBufferPointer {
                            try source.read(into: $0.baseAddress!, length: 2)
                        }
                        channelNum = Int(UInt16(b[0]) << 8 | UInt16(b[1]))
                        cursor += 2
                        let remainder = Int64(psize) - 2
                        if remainder > 0 {
                            try source.seek(to: cursor + remainder)
                            cursor += remainder
                        }
                    } else {
                        // 跳过其它 SND 子块
                        try source.seek(to: cursor + Int64(psize))
                        cursor += Int64(psize)
                    }
                    // PROP 子块按偶数字节对齐
                    if (psize % 2) != 0 && cursor < propEnd {
                        try source.seek(to: cursor + 1)
                        cursor += 1
                    }
                }
            } else if chunkID == "DSD " {
                dataOffset = payloadStart
                dataLength = Int64(chunkSize)
                // 找到数据块即停止解析头部
                break
            } else {
                // 跳过未知 chunk（FVER / ID3 / DIIN / COMT 等）
                let skipTo = payloadStart + Int64(chunkSize)
                try source.seek(to: skipTo)
                cursor = skipTo
                // 偶数对齐
                if (chunkSize % 2) != 0 {
                    try source.seek(to: cursor + 1)
                    cursor += 1
                }
            }
        }

        guard sampleFreq > 0 else {
            throw PurePlayError.unsupportedFormat("DFF: missing FS chunk")
        }
        guard channelNum == 2 else {
            throw PurePlayError.unsupportedFormat("DFF: only stereo supported (got \(channelNum))")
        }
        guard dataLength > 0 else {
            throw PurePlayError.invalidWAVHeader("DFF: missing DSD data chunk")
        }
        guard [2_822_400, 5_644_800, 11_289_600, 22_579_200, 45_158_400].contains(sampleFreq) else {
            throw PurePlayError.unsupportedFormat("DFF: unknown DSD rate \(sampleFreq)")
        }

        self.channels = channelNum
        self.dsdRate = sampleFreq
        self.dataChunkOffset = dataOffset
        self.dataChunkLength = dataLength

        // DoP frame = 16 DSD bits per channel = 2 bytes per channel.
        // 交错布局：每帧 channels × 2 字节 = 4 bytes（stereo）
        // total DoP frames = dataLength / (channels * 2)
        self.totalFrames = dataLength / Int64(channelNum * 2)

        let dopRate = Double(sampleFreq) / 16.0
        self.format = AudioFormat(
            sampleRate: dopRate,
            channels: channelNum,
            sampleFormat: .int24,
            isDSD: true,
            sourceBitDepth: 1
        )
        _ = bitsPerSample  // reserved

        // DFF = MSB-first（不需要 bit-reverse）
        self.packer = DoPPacker(bitOrder: .msbFirst, channels: channelNum)
        self.ioBuffer = [UInt8](repeating: 0, count: 8192)

        // 定位到 DSD 数据起点
        try source.seek(to: dataChunkOffset)
    }

    // MARK: AudioDecoder

    public func decode(into buffer: UnsafeMutableRawPointer, maxFrames: Int) throws -> Int {
        guard maxFrames > 0 else { return 0 }
        let remaining = totalFrames - currentFrame
        guard remaining > 0 else { return 0 }

        let bytesPerFrameOut = channels * 3
        let bytesPerFrameDSD = channels * 2
        let framesWanted = min(maxFrames, Int(remaining))
        var framesProduced = 0
        let outBase = buffer.assumingMemoryBound(to: UInt8.self)

        var dsdFrame = [UInt8](repeating: 0, count: bytesPerFrameDSD)
        var dopBE = [UInt8](repeating: 0, count: bytesPerFrameOut)

        while framesProduced < framesWanted {
            // 1 frame 需要 4 interleaved DSD bytes
            // 重填 IO 缓冲
            if ioBufferPos + bytesPerFrameDSD > ioBufferValid {
                // 把残留部分前移
                let leftover = ioBufferValid - ioBufferPos
                if leftover > 0 {
                    for i in 0..<leftover {
                        ioBuffer[i] = ioBuffer[ioBufferPos + i]
                    }
                }
                let n = try ioBuffer.withUnsafeMutableBufferPointer { buf -> Int in
                    let target = buf.baseAddress!.advanced(by: leftover)
                    return try source.read(into: target, length: buf.count - leftover)
                }
                ioBufferValid = leftover + n
                ioBufferPos = 0
                if ioBufferValid < bytesPerFrameDSD { break }
            }

            // interleaved 取 L0, R0, L1, R1 → 重排成 packer 期望的格式：
            // packer 要求 ch0 的 2 字节连续，再 ch1 的 2 字节
            let b0 = ioBuffer[ioBufferPos]     // L0
            let b1 = ioBuffer[ioBufferPos + 1] // R0
            let b2 = ioBuffer[ioBufferPos + 2] // L1
            let b3 = ioBuffer[ioBufferPos + 3] // R1
            ioBufferPos += 4
            dsdFrame[0] = b0
            dsdFrame[1] = b2
            dsdFrame[2] = b1
            dsdFrame[3] = b3

            let written = dsdFrame.withUnsafeBufferPointer { src -> Int in
                dopBE.withUnsafeMutableBufferPointer { dst -> Int in
                    packer.pack(dsdInterleaved: src.baseAddress!,
                                dsdBytes: bytesPerFrameDSD,
                                outPCM: dst.baseAddress!,
                                outCapacity: bytesPerFrameOut)
                }
            }
            guard written == bytesPerFrameOut else { break }

            // BE → 调用方 buffer：每个 24-bit sample 字节翻转，marker 落在 LE 最高字节
            let outOffset = framesProduced * bytesPerFrameOut
            for c in 0..<channels {
                let src = c * 3
                let dst = outOffset + c * 3
                outBase[dst] = dopBE[src + 2]
                outBase[dst + 1] = dopBE[src + 1]
                outBase[dst + 2] = dopBE[src]
            }
            framesProduced += 1
        }

        currentFrame += Int64(framesProduced)
        return framesProduced
    }

    public func seek(to frame: Int64) throws {
        let clamped = max(0, min(frame, totalFrames))
        // 1 DoP frame = channels × 2 字节 interleaved
        let byteOffset = clamped * Int64(channels * 2)
        try source.seek(to: dataChunkOffset + byteOffset)
        ioBufferValid = 0
        ioBufferPos = 0
        currentFrame = clamped
        packer.resetMarker()
    }

    public func close() {
        source.close()
    }

    // MARK: helpers

    private static func readU32BE(_ b: [UInt8], offset: Int) -> UInt32 {
        (UInt32(b[offset]) << 24) |
        (UInt32(b[offset + 1]) << 16) |
        (UInt32(b[offset + 2]) << 8) |
        UInt32(b[offset + 3])
    }

    private static func readU64BE(_ b: [UInt8], offset: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(b[offset + i]) }
        return v
    }
}

public enum DFFDecoderFactory: DecoderFactory {
    public static let supportedExtensions: Set<String> = ["dff"]
    public static let priority: Int = 95   // 与 DSF 同级，CoreAudio 之上

    public static func canDecode(source: AudioSource, fileExtension: String) -> Bool {
        supportedExtensions.contains(fileExtension.lowercased())
    }

    public static func makeDecoder(source: AudioSource, fileExtension: String) throws -> AudioDecoder {
        try DFFDecoder(source: source)
    }
}
