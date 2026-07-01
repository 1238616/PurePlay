import Foundation

/// 合成正弦波解码器 — 用于无文件场景下的测试与端到端验证
/// 不需要 source；通过 ".sine" 扩展名触发
public final class SineDecoder: AudioDecoder {

    public let format: AudioFormat
    public let totalFrames: Int64
    public private(set) var currentFrame: Int64 = 0

    public var isAtEnd: Bool { currentFrame >= totalFrames }

    private let frequency: Double
    private let amplitude: Float

    public init(sampleRate: Double = 44100,
                channels: Int = 2,
                durationSeconds: Double = 5,
                frequency: Double = 440,
                amplitude: Float = 0.5) {
        self.format = AudioFormat(sampleRate: sampleRate,
                                  channels: channels,
                                  sampleFormat: .float32)
        self.totalFrames = Int64(sampleRate * durationSeconds)
        self.frequency = frequency
        self.amplitude = amplitude
    }

    public func decode(into buffer: UnsafeMutableRawPointer, maxFrames: Int) throws -> Int {
        guard maxFrames > 0 else { return 0 }
        let remaining = totalFrames - currentFrame
        guard remaining > 0 else { return 0 }
        let framesToWrite = min(maxFrames, Int(remaining))

        let fp = buffer.assumingMemoryBound(to: Float.self)
        let twoPiF = 2.0 * .pi * frequency / format.sampleRate
        for i in 0..<framesToWrite {
            let t = Double(currentFrame + Int64(i))
            let s = Float(sin(twoPiF * t)) * amplitude
            for c in 0..<format.channels {
                fp[i * format.channels + c] = s
            }
        }
        currentFrame += Int64(framesToWrite)
        return framesToWrite
    }

    public func seek(to frame: Int64) throws {
        currentFrame = max(0, min(frame, totalFrames))
    }

    public func close() {}
}

public enum SineDecoderFactory: DecoderFactory {
    public static let supportedExtensions: Set<String> = ["sine"]
    public static let priority: Int = 1

    public static func canDecode(source: AudioSource, fileExtension: String) -> Bool {
        fileExtension == "sine"
    }

    public static func makeDecoder(source: AudioSource, fileExtension: String) throws -> AudioDecoder {
        SineDecoder()
    }
}
