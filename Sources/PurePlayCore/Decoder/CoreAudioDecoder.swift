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

    public var isAtEnd: Bool { currentFrame >= totalFrames }

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

        // 获取总帧数
        var frameCount: Int64 = 0
        var frameSize = UInt32(MemoryLayout<Int64>.size)
        ExtAudioFileGetProperty(ref, kExtAudioFileProperty_FileLengthFrames,
                                &frameSize, &frameCount)
        self.totalFrames = frameCount

        // 探测源样本格式：整数 vs 浮点
        let channels = fileFormat.mChannelsPerFrame
        let sampleRate = fileFormat.mSampleRate
        let srcFlags = fileFormat.mFormatFlags
        let srcIsFloat = (srcFlags & kAudioFormatFlagIsFloat) != 0
        let srcBitDepth = Int(fileFormat.mBitsPerChannel)  // 通常 16 / 24 / 32

        // 整数源 → int32 packed 容器（bit-perfect，低位补 0）
        // 浮点源 → float32（无损保留）
        let chosenSampleFormat: SampleFormat = srcIsFloat ? .float32 : .int32
        let containerBytes: UInt32 = 4   // 32-bit container, integer or float
        let containerBits: UInt32 = 32

        var clientASBD = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: srcIsFloat
                ? kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                : kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: containerBytes * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: containerBytes * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: containerBits,
            mReserved: 0
        )
        self.clientFormat = clientASBD

        let setStatus = ExtAudioFileSetProperty(ref, kExtAudioFileProperty_ClientDataFormat,
                                                 UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                                                 &clientASBD)
        guard setStatus == noErr else {
            ExtAudioFileDispose(ref)
            throw PurePlayError.decodeFailed("Cannot set client format: \(setStatus)")
        }

        // bitDepth 报源原生位深；srcBitDepth==0 时回落到容器位深
        let reportedSrcBits: Int? = srcBitDepth > 0 ? srcBitDepth : nil
        self.format = AudioFormat(sampleRate: sampleRate,
                                   channels: Int(channels),
                                   sampleFormat: chosenSampleFormat,
                                   sourceBitDepth: reportedSrcBits)

        // FLAC MD5 校验（按需启用）：解析 STREAMINFO，取其内嵌 MD5
        if verifyFLACMD5, url.pathExtension.lowercased() == "flac",
           let parsed = (try? FLACMetadata.read(from: url)) ?? nil {
            let info = parsed.streamInfo
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
        if let localSource = source as? LocalFileSource {
            try self.init(url: localSource.url)
            return
        }

        // 其他 source 类型：读取全部数据到临时文件
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
        try self.init(url: tmpFile)
    }

    public func decode(into buffer: UnsafeMutableRawPointer, maxFrames: Int) throws -> Int {
        guard let ref = extAudioFile, maxFrames > 0 else { return 0 }
        let remaining = totalFrames - currentFrame
        guard remaining > 0 else { return 0 }

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

        // FLAC MD5 增量更新（仅整数路径）
        if let v = md5Verifier,
           clientFormat.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0,
           framesRead > 0 {
            let sampleCount = Int(framesRead) * format.channels
            buffer.withMemoryRebound(to: Int32.self, capacity: sampleCount) { p in
                v.updateInt32(p, sampleCount: sampleCount)
            }
        }

        // 到达 EOF 时一次性比对
        if isAtEnd, md5Result == .notVerified, let v = md5Verifier, let exp = expectedMD5 {
            let actual = v.finalize()
            md5Verifier = nil
            md5Result = (actual == exp) ? .match : .mismatch(expected: exp, actual: actual)
        }

        return Int(framesRead)
    }

    public func seek(to frame: Int64) throws {
        guard let ref = extAudioFile else { return }
        let clamped = max(0, min(frame, totalFrames))
        let status = ExtAudioFileSeek(ref, clamped)
        guard status == noErr else {
            throw PurePlayError.decodeFailed("ExtAudioFileSeek failed: \(status)")
        }
        currentFrame = clamped
    }

    public func close() {
        if let ref = extAudioFile {
            ExtAudioFileDispose(ref)
            extAudioFile = nil
        }
    }

    deinit { close() }
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
