import Foundation
#if canImport(AudioToolbox)
import AudioToolbox

/// FLAC 解码器 — 使用 macOS 内置 AudioToolbox (ExtAudioFile)
/// macOS 11+ 原生支持 FLAC 解码，无需第三方库
public final class CoreAudioDecoder: AudioDecoder {

    public let format: AudioFormat
    public let totalFrames: Int64
    public private(set) var currentFrame: Int64 = 0

    private var extAudioFile: ExtAudioFileRef?
    private let clientFormat: AudioStreamBasicDescription

    /// issue #6：MP3 encoder delay（LAME Xing tag）— 文件帧域与逻辑帧域的固定偏移。
    /// 起播时通过 pendingSkipFrames 丢弃开头 delay 帧；seek 时加回偏移。
    /// AAC 不走这里（ExtAudioFile 自动补偿 priming，只需修正 totalFrames）。
    private let skipDelayFrames: Int64
    private var pendingSkipFrames: Int64 = 0

    /// Apple 的 FLAC 解码器实际可解出的样本数恒小于
    /// kExtAudioFileProperty_FileLengthFrames（STREAMINFO total_samples）
    /// 报出的标称值 — 尾部有一小段（几千~几万帧）Apple 不再产出。
    /// 旧实现 isAtEnd = currentFrame >= totalFrames，于是 currentFrame 永远
    /// 追不上 totalFrames → 结束检测永不触发 → 不自动切歌、尾部下溢。
    /// 与 LibFLAC/FFmpeg 同理，以 ExtAudioFileRead 返回 < 请求数（EOF）为准。
    private var reachedEndOfStream = false

    /// FLAC MD5 校验（仅当源为 FLAC 且 STREAMINFO 含非零 MD5 时启用）
    private var md5Verifier: FLACMD5Verifier?
    private var expectedMD5: [UInt8]?
    public private(set) var md5Result: MD5VerificationResult = .notVerified

    public enum MD5VerificationResult: Sendable, Equatable {
        case notVerified
        case missingExpected
        case match
        case mismatch(expected: [UInt8], actual: [UInt8])
    }

    public var isAtEnd: Bool { reachedEndOfStream || currentFrame >= totalFrames }

    public init(url: URL, verifyFLACMD5: Bool = false) throws {
        var fileRef: ExtAudioFileRef?
        let status = ExtAudioFileOpenURL(url as CFURL, &fileRef)
        guard status == noErr, let ref = fileRef else {
            throw PurePlayError.decodeFailed("ExtAudioFileOpenURL failed: \(status)")
        }
        self.extAudioFile = ref

        // 获取源文件格式
        var fileFormat = AudioStreamBasicDescription()
        var propSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let fmtStatus = ExtAudioFileGetProperty(ref, kExtAudioFileProperty_FileDataFormat,
                                                 &propSize, &fileFormat)
        guard fmtStatus == noErr else {
            ExtAudioFileDispose(ref)
            throw PurePlayError.decodeFailed("Cannot read file format: \(fmtStatus)")
        }

        // 获取总帧数（含编码器 padding — issue #6 在下方修正）
        var frameCount: Int64 = 0
        var frameSize = UInt32(MemoryLayout<Int64>.size)
        ExtAudioFileGetProperty(ref, kExtAudioFileProperty_FileLengthFrames,
                                &frameSize, &frameCount)

        // issue #6：encoder delay/padding 补偿 — gapless 的前提
        var effectiveTotal = frameCount
        var mp3Delay: Int64 = 0
        let ext = url.pathExtension.lowercased()
        if ext == "aac" || ext == "m4a" || ext == "mp4" {
            // AAC：ExtAudioFile 自动补偿开头 priming，但 FileLengthFrames
            // 包含尾部 padding → 用 packet table 的有效帧数作逻辑总帧数，
            // 否则 tryGaplessAdvance 衔接时机偏移，专辑曲目间出现间隙
            var afID: AudioFileID?
            var afSize = UInt32(MemoryLayout<AudioFileID>.size)
            if ExtAudioFileGetProperty(ref, kExtAudioFileProperty_AudioFile,
                                       &afSize, &afID) == noErr,
               let fileID = afID {
                var pt = AudioFilePacketTableInfo()
                var ptSize = UInt32(MemoryLayout<AudioFilePacketTableInfo>.size)
                if AudioFileGetProperty(fileID, kAudioFilePropertyPacketTableInfo,
                                        &ptSize, &pt) == noErr,
                   pt.mNumberValidFrames > 0 {
                    effectiveTotal = Int64(pt.mNumberValidFrames)
                }
            }
        } else if ext == "mp3" {
            // MP3：ExtAudioFile **不**补偿 LAME encoder delay — 解析 Xing/LAME
            // tag：decode 侧丢弃开头 delay 帧，totalFrames 减去 delay+padding
            if let fh = try? FileHandle(forReadingFrom: url),
               let head = try? fh.read(upToCount: 4096) {
                try? fh.close()
                if let dp = Self.parseMP3EncoderDelayPadding(head) {
                    mp3Delay = Int64(dp.delay)
                    let trimmed = frameCount - mp3Delay - Int64(dp.padding)
                    if trimmed > 0 { effectiveTotal = trimmed }
                }
            }
        }
        self.totalFrames = effectiveTotal
        self.skipDelayFrames = mp3Delay
        self.pendingSkipFrames = mp3Delay

        // 探测源样本格式：整数 vs 浮点
        let channels = fileFormat.mChannelsPerFrame
        let sampleRate = fileFormat.mSampleRate
        let srcFlags = fileFormat.mFormatFlags
        let srcIsFloat = (srcFlags & kAudioFormatFlagIsFloat) != 0
        let srcBitDepth = Int(fileFormat.mBitsPerChannel)  // 通常 16 / 24 / 32

        // FLAC：Apple 的 FileDataFormat 把源报成 32-bit float 容器
        // （srcBitDepth=32, srcIsFloat=true），位深/整数判定被浮点化掩盖。
        // 用 STREAMINFO 拿真实位深与采样数，供显示与 EOS 判定使用。
        let isFLAC = url.pathExtension.lowercased() == "flac"
        let flacInfo = isFLAC ? ((try? FLACMetadata.read(from: url)) ?? nil)?.streamInfo : nil

        // issue #14：整数源按**原生位深**容器投递（16→int16 packed、
        // 24→int24 packed 3 字节、其余/未知→int32），不再一律升 int32 —
        // 否则 setPhysicalFormat 把 DAC 设成 32-bit 物理格式，16-bit CD 抓轨
        // 不是原生投递，SignalPath 显示位深也与容器不符。
        // 原生容器请求被拒时回退 int32（低位补 0，数值无损，旧行为）。
        // 浮点源 → float32（无损保留）。
        func makeASBD(_ sf: SampleFormat) -> AudioStreamBasicDescription {
            let bytes = UInt32(sf.bytesPerSample)
            let bits = UInt32(sf.bitDepth)
            return AudioStreamBasicDescription(
                mSampleRate: sampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: sf == .float32
                    ? kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                    : kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: bytes * channels,
                mFramesPerPacket: 1,
                mBytesPerFrame: bytes * channels,
                mChannelsPerFrame: channels,
                mBitsPerChannel: bits,
                mReserved: 0
            )
        }
        var chosenSampleFormat: SampleFormat
        if srcIsFloat {
            chosenSampleFormat = .float32
        } else {
            switch srcBitDepth {
            case 1...16:  chosenSampleFormat = .int16
            case 17...24: chosenSampleFormat = .int24
            default:      chosenSampleFormat = .int32   // 含 srcBitDepth==0（压缩源）
            }
        }
        var clientASBD = makeASBD(chosenSampleFormat)
        var setStatus = ExtAudioFileSetProperty(ref, kExtAudioFileProperty_ClientDataFormat,
                                                 UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                                                 &clientASBD)
        if setStatus != noErr, !srcIsFloat, chosenSampleFormat != .int32 {
            // 原生容器不被接受 → int32 回退（MD5 路径按容器位深自动分流）
            chosenSampleFormat = .int32
            clientASBD = makeASBD(.int32)
            setStatus = ExtAudioFileSetProperty(ref, kExtAudioFileProperty_ClientDataFormat,
                                                 UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                                                 &clientASBD)
        }
        self.clientFormat = clientASBD

        guard setStatus == noErr else {
            ExtAudioFileDispose(ref)
            throw PurePlayError.decodeFailed("Cannot set client format: \(setStatus)")
        }

        // bitDepth 报源原生位深；FLAC 用 STREAMINFO 的真实位深（24-bit
        // 源不会被 Apple 的 32-bit float 容器谎报成 32-bit）；srcBitDepth==0
        // 时回落到容器位深
        let effectiveSrcBits = flacInfo?.bitsPerSample ?? srcBitDepth
        let reportedSrcBits: Int? = effectiveSrcBits > 0 ? effectiveSrcBits : nil
        self.format = AudioFormat(sampleRate: sampleRate,
                                   channels: Int(channels),
                                   sampleFormat: chosenSampleFormat,
                                   sourceBitDepth: reportedSrcBits)

        // FLAC MD5 校验（按需启用）：解析 STREAMINFO，取其内嵌 MD5
        if verifyFLACMD5, isFLAC, let info = flacInfo {
            if info.hasMD5 {
                self.expectedMD5 = info.md5Signature
                self.md5Verifier = FLACMD5Verifier(bitsPerSample: info.bitsPerSample,
                                                    channels: info.channels)
            } else {
                self.md5Result = .missingExpected
            }
        }
    }

    /// 从 AudioSource 初始化（先写到临时文件，再打开）
    /// 这是为了兼容 AudioSource 协议；对于本地文件直接用 URL 更高效
    public convenience init(source: AudioSource, fileExtension: String) throws {
        // 如果是 LocalFileSource，直接获取 URL
        // issue #12：MD5 校验按用户偏好接线（默认开）— 结果经 md5Result 暴露
        if let localSource = source as? LocalFileSource {
            try self.init(url: localSource.url,
                          verifyFLACMD5: AudioPreferences.flacMD5Verify)
            return
        }

        // issue #15c：非本地源（云端流）不再整曲落临时文件 — ExtAudioFile
        // 无法流式解码，整曲缓冲与 CloudPrefetchManager 的流式预取设计相悖，
        // 大文件占双倍磁盘且必须下载完才能出声。CFFmpeg 可用时主动让路，
        // registry 降级链（issue #2）会落到 FFmpegDecoderFactory —
        // FFmpegAVIOAdapter 支持边下边播。
        #if canImport(CFFmpeg)
        throw PurePlayError.unsupportedFormat(
            "CoreAudioDecoder cannot stream; non-local sources route to FFmpeg decoder")
        #endif

        // FFmpeg 不可用：回退整曲临时文件（旧行为，能出声但需完整下载）
        let tmpDir = FileManager.default.temporaryDirectory
        let tmpFile = tmpDir.appendingPathComponent("pureplay_\(UUID().uuidString).\(fileExtension)")
        var data = Data()
        let bufSize = 65536
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 16)
        defer { buf.deallocate() }
        while true {
            let n = try source.read(into: buf, length: bufSize)
            if n <= 0 { break }
            data.append(Data(bytes: buf, count: n))
        }
        try data.write(to: tmpFile)
        // issue #12：临时文件路径同样按偏好启用 MD5 校验
        try self.init(url: tmpFile, verifyFLACMD5: AudioPreferences.flacMD5Verify)
    }

    public func decode(into buffer: UnsafeMutableRawPointer, maxFrames: Int) throws -> Int {
        guard let ref = extAudioFile, maxFrames > 0 else { return 0 }
        let remaining = totalFrames - currentFrame
        guard remaining > 0 else { return 0 }

        // issue #6：丢弃 MP3 encoder delay（文件流开头一次性；seek 后清零）
        if pendingSkipFrames > 0 {
            let bpf = UInt32(format.bytesPerFrame)
            let scratchCap: UInt32 = UInt32(min(Int64(4096), pendingSkipFrames))
            let scratch = UnsafeMutableRawPointer.allocate(
                byteCount: Int(scratchCap) * Int(bpf), alignment: 16)
            defer { scratch.deallocate() }
            while pendingSkipFrames > 0 {
                var want = UInt32(min(Int64(scratchCap), pendingSkipFrames))
                var skipList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: UInt32(format.channels),
                        mDataByteSize: want * bpf,
                        mData: scratch))
                let st = ExtAudioFileRead(ref, &want, &skipList)
                if st != noErr || want == 0 { break }
                pendingSkipFrames -= Int64(want)
            }
        }

        let framesToRead = UInt32(min(Int64(maxFrames), remaining))
        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: UInt32(format.channels),
                mDataByteSize: framesToRead * UInt32(format.bytesPerFrame),
                mData: buffer
            )
        )
        var framesRead = framesToRead
        let status = ExtAudioFileRead(ref, &framesRead, &bufferList)
        guard status == noErr else {
            throw PurePlayError.decodeFailed("ExtAudioFileRead failed: \(status)")
        }
        currentFrame += Int64(framesRead)
        // Apple FLAC 解码器产出的帧数恒少于 FileLengthFrames 标称值 —
        // 当次返回 < 请求数即已到 EOF（issue #5: 否则 currentFrame 追不上
        // totalFrames，isAtEnd 永假，不自动切歌且尾部下溢）。
        if framesToRead > 0 && framesRead < framesToRead {
            reachedEndOfStream = true
        }

        // FLAC MD5 增量更新
        // issue #12：Apple 的 ExtAudioFile FLAC 解码以 float32 容器投递 —
        // 整数分支之外必须补 float 分支（按源位深还原小端整数再喂 MD5），
        // 否则校验器空转、EOF 用空摘要比对出**假 mismatch**。
        if let v = md5Verifier, framesRead > 0 {
            let sampleCount = Int(framesRead) * format.channels
            if clientFormat.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 {
                if format.sampleFormat.bitDepth == v.bitsPerSample {
                    // issue #14：原生位深容器 — FLAC 规范的 MD5 输入正是
                    // 小端原生宽度样本，原始字节直接喂入
                    v.updateRaw(buffer, byteCount: sampleCount * format.sampleFormat.bytesPerSample)
                } else {
                    // int32 回退容器：按源位深移位后喂 MD5（旧路径）
                    buffer.withMemoryRebound(to: Int32.self, capacity: sampleCount) { p in
                        v.updateInt32(p, sampleCount: sampleCount)
                    }
                }
            } else if clientFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
                buffer.withMemoryRebound(to: Float.self, capacity: sampleCount) { p in
                    v.updateFloat(p, sampleCount: sampleCount)
                }
            }
        }

        // 到达 EOF 时一次性比对；hasFed=false（如 32-bit 源走 float 路径
        // 无法还原）→ 保持 notVerified，绝不拿空摘要判 mismatch
        if isAtEnd, md5Result == .notVerified, let v = md5Verifier, let exp = expectedMD5 {
            md5Verifier = nil
            if v.hasFed {
                let actual = v.finalize()
                md5Result = (actual == exp) ? .match : .mismatch(expected: exp, actual: actual)
            }
        }

        return Int(framesRead)
    }

    public func seek(to frame: Int64) throws {
        guard let ref = extAudioFile else { return }
        let clamped = max(0, min(frame, totalFrames))
        // issue #6：逻辑帧 → 文件帧（MP3 encoder delay 偏移）；
        // 落点已越过 delay 区，pendingSkip 清零
        let status = ExtAudioFileSeek(ref, clamped + skipDelayFrames)
        guard status == noErr else {
            throw PurePlayError.decodeFailed("ExtAudioFileSeek failed: \(status)")
        }
        currentFrame = clamped
        pendingSkipFrames = 0
        reachedEndOfStream = false
    }

    public func close() {
        if let ref = extAudioFile {
            ExtAudioFileDispose(ref)
            extAudioFile = nil
        }
    }

    deinit { close() }

    // MARK: - MP3 Xing/LAME tag 解析（issue #6）

    /// 从文件头部字节解析 LAME encoder delay & padding。
    ///
    /// 帧内布局（相对 Xing/Info tag 起点）：
    ///   +0..3   "Xing"（VBR）或 "Info"（CBR）
    ///   +4..7   flags
    ///   +120    LAME 版本串 "LAMEx.xx.x"（存在才信任 delay/padding 字段）
    ///   +213..215  24-bit：高 12 位 = encoder delay，低 12 位 = encoder padding
    ///
    /// tag 位置 = 帧头(4B ± CRC 2B) + side info（MPEG1: stereo 32/mono 17；
    /// MPEG2/2.5: stereo 17/mono 9）。ID3v2 头按 synchsafe size 跳过。
    /// - Returns: (delay, padding) 采样数；无法解析（非 LAME/无 tag）返回 nil
    static func parseMP3EncoderDelayPadding(_ data: Data) -> (delay: Int, padding: Int)? {
        let bytes = [UInt8](data.prefix(8192))
        guard bytes.count > 300 else { return nil }

        // 跳过 ID3v2
        var i = 0
        if bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33, bytes.count > 10 {
            let size = (Int(bytes[6]) << 21) | (Int(bytes[7]) << 14)
                     | (Int(bytes[8]) << 7) | Int(bytes[9])
            i = 10 + size
        }
        // 找第一个帧同步（11 位全 1）
        while i + 4 < bytes.count {
            if bytes[i] == 0xFF, (bytes[i + 1] & 0xE0) == 0xE0 { break }
            i += 1
        }
        guard i + 4 < bytes.count else { return nil }

        let h1 = bytes[i + 1]
        let h2 = bytes[i + 2]
        let h3 = bytes[i + 3]
        let versionBits = (h1 >> 3) & 0x03     // 11 = MPEG1, 10 = MPEG2, 00 = MPEG2.5
        let layerBits = (h1 >> 1) & 0x03       // 01 = Layer III
        guard layerBits == 0x01, versionBits != 0x01 else { return nil }
        let crcAbsent = (h2 & 0x01) != 0
        let mono = ((h3 >> 6) & 0x03) == 0x03
        let mpeg1 = versionBits == 0x03

        let headerSize = 4 + (crcAbsent ? 0 : 2)
        let sideSize: Int
        if mpeg1 { sideSize = mono ? 17 : 32 } else { sideSize = mono ? 9 : 17 }
        let tagPos = i + headerSize + sideSize
        guard tagPos + 216 <= bytes.count else { return nil }

        let isXing = bytes[tagPos] == 0x58 && bytes[tagPos + 1] == 0x69
                  && bytes[tagPos + 2] == 0x6E && bytes[tagPos + 3] == 0x67      // "Xing"
        let isInfo = bytes[tagPos] == 0x49 && bytes[tagPos + 1] == 0x6E
                  && bytes[tagPos + 2] == 0x66 && bytes[tagPos + 3] == 0x6F      // "Info"
        guard isXing || isInfo else { return nil }

        // LAME 魔数（+120）— 非 LAME 编码器（Xing 老 tag）没有 delay/padding 字段
        guard bytes[tagPos + 120] == 0x4C, bytes[tagPos + 121] == 0x41,
              bytes[tagPos + 122] == 0x4D, bytes[tagPos + 123] == 0x45 else { return nil }  // "LAME"

        let b0 = Int(bytes[tagPos + 213])
        let b1 = Int(bytes[tagPos + 214])
        let b2 = Int(bytes[tagPos + 215])
        let delay = ((b0 << 4) | (b1 >> 4)) & 0xFFF
        let padding = (((b1 & 0x0F) << 8) | b2) & 0xFFF
        return (delay, padding)
    }
}

/// ALAC 专用工厂 — 拆出以匹配 Design.md §5.1.2 的 DecoderRegistry 列表
/// 实现仍走 CoreAudio AudioConverter（AAC/ALAC 解码器）；
/// 这层抽象让未来替换为独立 ALAC C 库时无需改外部代码。
public enum ALACDecoderFactory: DecoderFactory {
    public static let supportedExtensions: Set<String> = ["alac", "m4a", "mp4"]
    public static let priority: Int = 95

    public static func canDecode(source: AudioSource, fileExtension: String) -> Bool {
        supportedExtensions.contains(fileExtension.lowercased())
    }

    public static func makeDecoder(source: AudioSource, fileExtension: String) throws -> AudioDecoder {
        try CoreAudioDecoder(source: source, fileExtension: fileExtension)
    }
}

/// CoreAudio 解码器工厂 — 兜底处理 macOS 内置但未拆出专用工厂的格式
public enum CoreAudioDecoderFactory: DecoderFactory {
    public static let supportedExtensions: Set<String> = [
        "flac", "aac", "mp3", "caf", "ogg"
    ]
    public static let priority: Int = 90

    public static func canDecode(source: AudioSource, fileExtension: String) -> Bool {
        supportedExtensions.contains(fileExtension.lowercased())
    }

    public static func makeDecoder(source: AudioSource, fileExtension: String) throws -> AudioDecoder {
        try CoreAudioDecoder(source: source, fileExtension: fileExtension)
    }
}
#endif
