import Foundation

/// 解码器接口（借鉴 VLC `decoder_t`）
public protocol AudioDecoder: AnyObject {
    var format: AudioFormat { get }
    var totalFrames: Int64 { get }
    var currentFrame: Int64 { get }
    var isAtEnd: Bool { get }

    /// 解码至多 maxFrames 帧到 buffer，返回实际解码帧数
    /// buffer 必须足够大：maxFrames × format.bytesPerFrame
    func decode(into buffer: UnsafeMutableRawPointer, maxFrames: Int) throws -> Int

    func seek(to frame: Int64) throws

    func close()
}

/// 解码器工厂
public protocol DecoderFactory {
    static var supportedExtensions: Set<String> { get }
    static var priority: Int { get }
    static func canDecode(source: AudioSource, fileExtension: String) -> Bool
    static func makeDecoder(source: AudioSource, fileExtension: String) throws -> AudioDecoder
}

/// 解码器注册表（借鉴 VLC `module_need`）
/// 工厂注册顺序 = 优先级，先注册 = 先尝试
public final class DecoderRegistry {
    public static let shared = DecoderRegistry()

    private var factories: [DecoderFactory.Type] = []
    private let lock = NSLock()

    private init() {
        register(WAVDecoderFactory.self)
        register(AIFFDecoderFactory.self)
        register(DSFDecoderFactory.self)
        register(DFFDecoderFactory.self)
        #if canImport(CFLAC)
        register(LibFLACDecoderFactory.self)
        #endif
        #if canImport(AudioToolbox)
        register(ALACDecoderFactory.self)
        register(CoreAudioDecoderFactory.self)
        #endif
        #if canImport(CFFmpeg)
        register(FFmpegDecoderFactory.self)
        #endif
        register(SineDecoderFactory.self)
    }

    public func register(_ factory: DecoderFactory.Type) {
        lock.lock(); defer { lock.unlock() }
        factories.append(factory)
        factories.sort { $0.priority > $1.priority }
    }

    public func makeDecoder(source: AudioSource, fileExtension: String) throws -> AudioDecoder {
        let ext = fileExtension.lowercased()
        var lastError: Error?
        for factory in factories {
            if factory.supportedExtensions.contains(ext) &&
               factory.canDecode(source: source, fileExtension: ext) {
                do {
                    return try factory.makeDecoder(source: source, fileExtension: ext)
                } catch {
                    // 扩展名匹配的工厂不保证能真正解码该文件
                    // （例：.ogg 可能是 Vorbis——ExtAudioFile 解不了，需级联到 FFmpeg）。
                    // 记录错误，把 source 复位后继续尝试下一优先级工厂。
                    lastError = error
                    try? source.seek(to: 0)
                    continue
                }
            }
        }
        if let lastError {
            throw lastError
        }
        throw PurePlayError.unsupportedFormat(ext)
    }

    public var registeredCount: Int {
        lock.lock(); defer { lock.unlock() }
        return factories.count
    }
}
