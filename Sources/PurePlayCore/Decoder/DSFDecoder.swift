import Foundation

/// DSF (DSD Stream File) 解码器。
///
/// 输出 DoP v1.1（DSD over PCM）：每 24-bit 样本高字节为 0x05/0xFA 标记，
/// 低 16 bit 承载 16 个 DSD bits。AudioUnit 接收 native LE 24-bit 整数；
/// DSFDecoder 在写入调用方 buffer 前对每个 24-bit 样本做字节翻转，
/// 让低 byte 方向的高位仍是 DoP 标记字节，DAC 端 little-endian 读取后看到
/// 的最高字节即标记，DoP 协议成立。
///
/// issue #10：PCM 回退模式（pcmMode: true）
/// DAC 不支持 DoP 载波率时，用 DSD2PCMConverter（96-tap FIR 查表）把 DSD
/// 转成 float32 PCM，输出率 = dsdRate/8（DSD64 → 352.8kHz）；后续由管线
/// SincResampler 按设备/用户偏好收敛。DSF 是 LSB-first，喂转换器前逐字节
/// bit-reverse 成 MSB-first。
///
/// 限制：
/// - 仅支持立体声 DSD (channelType=2, channelNum=2)
/// - 仅支持 blockSizePerChannel = 4096（DSF spec 标准值）
/// - 仅支持 LSB-first（DSF spec 中的 bitsPerSample==1）
public final class DSFDecoder: AudioDecoder {

    public let format: AudioFormat
    public let totalFrames: Int64
    public private(set) var currentFrame: Int64 = 0

    public var isAtEnd: Bool { currentFrame >= totalFrames }

    private let source: AudioSource
    private let dataChunkOffset: Int64
    private let blockSizePerChannel: Int = 4096
    private let channels: Int
    private let dsdRate: Int
    private let pcmMode: Bool
    private let packer: DoPPacker?
    private let converter: DSD2PCMConverter?

    /// 当前块对缓存：channels × blockSizePerChannel 字节
    private var blockBuffer: [UInt8]
    /// 块内剩余偏移（0..blockSizePerChannel）
    private var posInBlock: Int = 0
    /// 已加载块对的字节数（块对完整时 = channels * blockSizePerChannel）
    private var blockValid: Int = 0
    /// PCM 模式去交错暂存（LSB→MSB 反转后的 interleaved DSD 字节）
    private var pcmScratch: [UInt8] = []

    public init(source: AudioSource, pcmMode: Bool = false) throws {
        self.source = source

        // === DSD chunk (28 bytes) ===
        var dsdHeader = [UInt8](repeating: 0, count: 28)
        let r1 = try dsdHeader.withUnsafeMutableBufferPointer {
            try source.read(into: $0.baseAddress!, length: 28)
        }
        guard r1 == 28,
              dsdHeader[0] == 0x44, dsdHeader[1] == 0x53,
              dsdHeader[2] == 0x44, dsdHeader[3] == 0x20 else {  // "DSD "
            throw PurePlayError.invalidWAVHeader("Not a DSF file (bad DSD magic)")
        }

        // === fmt chunk (52 bytes) ===
        var fmtChunk = [UInt8](repeating: 0, count: 52)
        let r2 = try fmtChunk.withUnsafeMutableBufferPointer {
            try source.read(into: $0.baseAddress!, length: 52)
        }
        guard r2 == 52,
              fmtChunk[0] == 0x66, fmtChunk[1] == 0x6D,
              fmtChunk[2] == 0x74, fmtChunk[3] == 0x20 else {   // "fmt "
            throw PurePlayError.invalidWAVHeader("DSF: missing fmt chunk")
        }
        // chunk size at [4..12], expect 52
        let fmtSize = Self.readU64LE(fmtChunk, offset: 4)
        guard fmtSize == 52 else {
            throw PurePlayError.unsupportedFormat("DSF: non-standard fmt chunk size \(fmtSize)")
        }
        // formatVersion @ 12, formatID @ 16, channelType @ 20, channelNum @ 24,
        // sampleFreq @ 28, bitsPerSample @ 32, sampleCount @ 36 (8B), blockSize @ 44, reserved @ 48
        let channelNum = Int(Self.readU32LE(fmtChunk, offset: 24))
        let sampleFreq = Int(Self.readU32LE(fmtChunk, offset: 28))
        let bitsPerSample = Int(Self.readU32LE(fmtChunk, offset: 32))
        let sampleCountPerChannel = Self.readU64LE(fmtChunk, offset: 36)
        let blockSize = Int(Self.readU32LE(fmtChunk, offset: 44))

        guard channelNum == 2 else {
            throw PurePlayError.unsupportedFormat("DSF: only stereo supported (got \(channelNum))")
        }
        guard bitsPerSample == 1 else {
            // 1 = LSB-first per DSF spec; 8 (MSB-first) is rare and not handled here
            throw PurePlayError.unsupportedFormat("DSF: bitsPerSample \(bitsPerSample) not supported")
        }
        guard blockSize == 4096 else {
            throw PurePlayError.unsupportedFormat("DSF: block size \(blockSize) ≠ 4096")
        }
        guard [2_822_400, 5_644_800, 11_289_600, 22_579_200, 45_158_400].contains(sampleFreq) else {
            throw PurePlayError.unsupportedFormat("DSF: unknown DSD rate \(sampleFreq)")
        }

        self.channels = channelNum
        self.dsdRate = sampleFreq
        self.pcmMode = pcmMode

        // === data chunk header (12 bytes: "data" + 8B size) ===
        var dataHeader = [UInt8](repeating: 0, count: 12)
        let r3 = try dataHeader.withUnsafeMutableBufferPointer {
            try source.read(into: $0.baseAddress!, length: 12)
        }
        guard r3 == 12,
              dataHeader[0] == 0x64, dataHeader[1] == 0x61,
              dataHeader[2] == 0x74, dataHeader[3] == 0x61 else {   // "data"
            throw PurePlayError.invalidWAVHeader("DSF: missing data chunk")
        }
        // current source position = 28 + 52 + 12 = 92
        self.dataChunkOffset = 92

        if pcmMode {
            // issue #10：DSD2PCM → float32 @ dsdRate/8（1 DSD 字节 → 1 PCM 样本）
            self.format = AudioFormat(
                sampleRate: Double(sampleFreq) / 8.0,
                channels: channelNum,
                sampleFormat: .float32,
                isDSD: false,
                sourceBitDepth: nil
            )
            self.totalFrames = Int64(sampleCountPerChannel) / 8
            self.packer = nil
            self.converter = DSD2PCMConverter(channels: channelNum,
                                              dsdBitstreamRate: Double(sampleFreq))
        } else {
            // DoP carrier rate = DSD rate / 16
            let dopRate = Double(sampleFreq) / 16.0
            self.format = AudioFormat(
                sampleRate: dopRate,
                channels: channelNum,
                sampleFormat: .int24,
                isDSD: true,
                sourceBitDepth: 1
            )

            // 1 DoP frame = 16 DSD bits per channel = 2 DSD bytes per channel
            // total DoP frames = sampleCountPerChannel / 16
            self.totalFrames = Int64(sampleCountPerChannel) / 16

            self.packer = DoPPacker(bitOrder: .lsbFirst, channels: channelNum)
            self.converter = nil
        }
        self.blockBuffer = [UInt8](repeating: 0, count: channelNum * blockSize)
    }

    // MARK: AudioDecoder

    public func decode(into buffer: UnsafeMutableRawPointer, maxFrames: Int) throws -> Int {
        if pcmMode { return try decodePCM(into: buffer, maxFrames: maxFrames) }
        guard let packer else { return 0 }
        guard maxFrames > 0 else { return 0 }
        let remainingFrames = totalFrames - currentFrame
        guard remainingFrames > 0 else { return 0 }

        // 每帧 DoP = 6 bytes (2 ch × 3 bytes); 输入 4 DSD bytes (2 ch × 2 bytes)
        let bytesPerFrameOut = channels * 3
        let bytesPerFrameDSD = channels * 2
        let framesWanted = min(maxFrames, Int(remainingFrames))

        var framesProduced = 0
        let outBase = buffer.assumingMemoryBound(to: UInt8.self)

        // 临时帧 buffer：交错 DSD 输入 + DoP 输出
        var dsdInterleaved = [UInt8](repeating: 0, count: bytesPerFrameDSD)
        var dopBE = [UInt8](repeating: 0, count: bytesPerFrameOut)

        while framesProduced < framesWanted {
            // 确保块缓存有足够 2 字节/声道供本帧使用
            // 用 blockValid 做阈值：初始 blockValid=0 → 首轮必加载第一块对
            // （旧代码误用 blockSizePerChannel，首块永不加载 → 开头一块静音）
            if posInBlock + 2 > blockValid / channels {
                // 当前块对已用尽 → 加载下一块对
                let n = try blockBuffer.withUnsafeMutableBufferPointer { buf -> Int in
                    return try source.read(into: buf.baseAddress!, length: buf.count)
                }
                if n == 0 { break }
                blockValid = n
                posInBlock = 0
            }
            // 块对内：先 ch0 整 4096 字节，再 ch1 整 4096 字节
            // 取出 (ch0[pos], ch0[pos+1], ch1[pos], ch1[pos+1])
            let ch0Base = 0
            let ch1Base = blockSizePerChannel
            dsdInterleaved[0] = blockBuffer[ch0Base + posInBlock]
            dsdInterleaved[1] = blockBuffer[ch0Base + posInBlock + 1]
            dsdInterleaved[2] = blockBuffer[ch1Base + posInBlock]
            dsdInterleaved[3] = blockBuffer[ch1Base + posInBlock + 1]
            posInBlock += 2

            // 打包 1 帧 DoP（BE 24-bit）
            let written = dsdInterleaved.withUnsafeBufferPointer { src -> Int in
                dopBE.withUnsafeMutableBufferPointer { dst -> Int in
                    packer.pack(dsdInterleaved: src.baseAddress!,
                                dsdBytes: bytesPerFrameDSD,
                                outPCM: dst.baseAddress!,
                                outCapacity: bytesPerFrameOut)
                }
            }
            guard written == bytesPerFrameOut else { break }

            // BE → 调用方 buffer，对每个 24-bit 样本做字节翻转
            let outOffset = framesProduced * bytesPerFrameOut
            for c in 0..<channels {
                let src = c * 3
                let dst = outOffset + c * 3
                outBase[dst] = dopBE[src + 2]      // lo
                outBase[dst + 1] = dopBE[src + 1]  // hi
                outBase[dst + 2] = dopBE[src]      // marker (highest byte in LE)
            }
            framesProduced += 1
        }

        currentFrame += Int64(framesProduced)
        return framesProduced
    }

    /// issue #10：PCM 回退路径 — 块对内去交错 + LSB→MSB bit-reverse，
    /// 喂 DSD2PCMConverter，1 DSD 字节/声道 → 1 float 样本/声道
    private func decodePCM(into buffer: UnsafeMutableRawPointer, maxFrames: Int) throws -> Int {
        guard let conv = converter, maxFrames > 0 else { return 0 }
        let remainingFrames = totalFrames - currentFrame
        guard remainingFrames > 0 else { return 0 }
        let framesWanted = min(maxFrames, Int(remainingFrames))
        let out = buffer.assumingMemoryBound(to: Float.self)

        if pcmScratch.count < framesWanted * channels {
            pcmScratch = [UInt8](repeating: 0x69, count: framesWanted * channels)
        }

        var framesProduced = 0
        while framesProduced < framesWanted {
            // PCM 模式每帧只消耗 1 DSD 字节/声道
            // blockValid 阈值：初始 0 → 首轮必加载第一块对
            if posInBlock >= blockValid / channels {
                let n = try blockBuffer.withUnsafeMutableBufferPointer { buf -> Int in
                    return try source.read(into: buf.baseAddress!, length: buf.count)
                }
                if n == 0 { break }
                blockValid = n
                posInBlock = 0
            }
            let want = min(framesWanted - framesProduced, blockSizePerChannel - posInBlock)
            for f in 0..<want {
                for c in 0..<channels {
                    let b = blockBuffer[c * blockSizePerChannel + posInBlock + f]
                    pcmScratch[f * channels + c] = DoPPacker.reverse(b)
                }
            }
            let produced = pcmScratch.withUnsafeBufferPointer { src -> Int in
                conv.process(dsdInterleaved: src.baseAddress!,
                             inputFrames: want,
                             output: out.advanced(by: framesProduced * channels),
                             outputCapacityFrames: framesWanted - framesProduced)
            }
            guard produced > 0 else { break }
            posInBlock += produced
            framesProduced += produced
            if produced < want { break }
        }

        currentFrame += Int64(framesProduced)
        return framesProduced
    }

    public func seek(to frame: Int64) throws {
        let clamped = max(0, min(frame, totalFrames))
        // DoP：1 帧 = 2 DSD 字节/声道；PCM：1 帧 = 1 DSD 字节/声道
        let dsdByteOffsetInChannel = Int(clamped) * (pcmMode ? 1 : 2)
        let blockIndex = dsdByteOffsetInChannel / blockSizePerChannel
        let inBlock = dsdByteOffsetInChannel % blockSizePerChannel

        // 块对在文件中的偏移
        let blockPairOffset = dataChunkOffset + Int64(blockIndex * channels * blockSizePerChannel)
        try source.seek(to: blockPairOffset)
        let n = try blockBuffer.withUnsafeMutableBufferPointer { buf -> Int in
            return try source.read(into: buf.baseAddress!, length: buf.count)
        }
        blockValid = n
        posInBlock = inBlock
        currentFrame = clamped
        if pcmMode {
            converter?.reset()
        } else {
            packer?.resetMarker()
        }
    }

    public func close() {
        source.close()
    }

    // MARK: helpers

    private static func readU32LE(_ b: [UInt8], offset: Int) -> UInt32 {
        UInt32(b[offset]) |
        (UInt32(b[offset + 1]) << 8) |
        (UInt32(b[offset + 2]) << 16) |
        (UInt32(b[offset + 3]) << 24)
    }

    private static func readU64LE(_ b: [UInt8], offset: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(b[offset + i]) << (8 * i) }
        return v
    }
}

public enum DSFDecoderFactory: DecoderFactory {
    public static let supportedExtensions: Set<String> = ["dsf"]
    public static let priority: Int = 95   // 高于 CoreAudio (90)

    public static func canDecode(source: AudioSource, fileExtension: String) -> Bool {
        supportedExtensions.contains(fileExtension.lowercased())
    }

    public static func makeDecoder(source: AudioSource, fileExtension: String) throws -> AudioDecoder {
        try DSFDecoder(source: source)
    }
}
