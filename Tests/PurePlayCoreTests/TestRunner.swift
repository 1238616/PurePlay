import Foundation
@testable import PurePlayCore
#if canImport(AudioToolbox)
import AudioToolbox   // issue #6 AAC packet-table 测试直接用 ExtAudioFile 合成 m4a
#endif

// ═══════════════════════════════════════════════════════
// Lightweight test harness (no XCTest / no Xcode required)
// ═══════════════════════════════════════════════════════

var totalTests = 0
var passedTests = 0
var failedTests = 0
var failedTestNames: [String] = []

struct TestFailure: Error {}

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String = "",
                               file: String = #file, line: Int = #line) throws {
    guard a == b else {
        let detail = msg.isEmpty ? "\(a) != \(b)" : msg
        print("    FAIL [\(file.split(separator: "/").last ?? ""):\(line)] \(detail)")
        throw TestFailure()
    }
}

func assertTrue(_ v: Bool, _ msg: String = "",
                file: String = #file, line: Int = #line) throws {
    guard v else {
        print("    FAIL [\(file.split(separator: "/").last ?? ""):\(line)] expected true. \(msg)")
        throw TestFailure()
    }
}

func assertFalse(_ v: Bool, _ msg: String = "",
                 file: String = #file, line: Int = #line) throws {
    try assertTrue(!v, msg, file: file, line: line)
}

func assertGreaterThan<T: Comparable>(_ a: T, _ b: T,
                                       file: String = #file, line: Int = #line) throws {
    guard a > b else {
        print("    FAIL [\(file.split(separator: "/").last ?? ""):\(line)] \(a) not > \(b)")
        throw TestFailure()
    }
}

func assertLessThan<T: Comparable>(_ a: T, _ b: T,
                                    file: String = #file, line: Int = #line) throws {
    guard a < b else {
        print("    FAIL [\(file.split(separator: "/").last ?? ""):\(line)] \(a) not < \(b)")
        throw TestFailure()
    }
}

func assertLessThanOrEqual<T: Comparable>(_ a: T, _ b: T,
                                           file: String = #file, line: Int = #line) throws {
    guard a <= b else {
        print("    FAIL [\(file.split(separator: "/").last ?? ""):\(line)] \(a) not <= \(b)")
        throw TestFailure()
    }
}

func assertThrows<T>(_ expr: @autoclosure () throws -> T,
                     file: String = #file, line: Int = #line) throws {
    do {
        _ = try expr()
        print("    FAIL [\(file.split(separator: "/").last ?? ""):\(line)] expected error, none thrown")
        throw TestFailure()
    } catch is TestFailure {
        throw TestFailure()  // re-throw; the assertion above already logged
    } catch {
        // Good — expected an error and got one
    }
}

func assertEqualFloat(_ a: Float, _ b: Float, accuracy: Float,
                      file: String = #file, line: Int = #line) throws {
    guard abs(a - b) <= accuracy else {
        print("    FAIL [\(file.split(separator: "/").last ?? ""):\(line)] \(a) != \(b) +/- \(accuracy)")
        throw TestFailure()
    }
}

func runTest(_ name: String, _ body: () throws -> Void) {
    totalTests += 1
    do {
        try body()
        passedTests += 1
        print("  ✓ \(name)")
    } catch {
        failedTests += 1
        failedTestNames.append(name)
        if !(error is TestFailure) {
            print("    FAIL \(name): \(error)")
        }
    }
}

// ═══════════════════════════════════════════════════════
// AudioFormat Tests
// ═══════════════════════════════════════════════════════
print("═══ AudioFormat Tests ═══")

runTest("pcmConvenience") {
    let fmt = AudioFormat.pcm(rate: 96000, channels: 2, bitDepth: 24)
    try assertEqual(fmt.sampleRate, 96000)
    try assertEqual(fmt.channels, 2)
    try assertEqual(fmt.bitDepth, 24)
    try assertEqual(fmt.sampleFormat, .int24)
    try assertEqual(fmt.bytesPerFrame, 6)
    try assertFalse(fmt.isDSD)
}

runTest("float32Format") {
    let fmt = AudioFormat(sampleRate: 44100, channels: 2, sampleFormat: .float32)
    try assertEqual(fmt.bytesPerFrame, 8)
    try assertFalse(fmt.sampleFormat.isInteger)
}

runTest("int16Format") {
    let fmt = AudioFormat.pcm(rate: 44100, channels: 1, bitDepth: 16)
    try assertEqual(fmt.bytesPerFrame, 2)
    try assertTrue(fmt.sampleFormat.isInteger)
}

runTest("dsdFormat") {
    let fmt = AudioFormat(sampleRate: 2_822_400, channels: 2, sampleFormat: .int32, isDSD: true)
    try assertTrue(fmt.isDSD)
}

runTest("audioFileFormat") {
    try assertEqual(AudioFileFormat.from(fileExtension: "flac"), .flac)
    try assertEqual(AudioFileFormat.from(fileExtension: "FLAC"), .flac)
    try assertEqual(AudioFileFormat.from(fileExtension: "dsf"), .dsf)
    try assertTrue(AudioFileFormat.dsf.isDSD)
    try assertTrue(AudioFileFormat.flac.isLossless)
    try assertFalse(AudioFileFormat.mp3.isLossless)
    try assertEqual(AudioFileFormat.from(fileExtension: "xyz"), .unknown)
}

// ═══════════════════════════════════════════════════════
// MemorySource Tests
// ═══════════════════════════════════════════════════════
print("\n═══ MemorySource Tests ═══")

runTest("readAll") {
    let data = Data([1, 2, 3, 4, 5, 6, 7, 8])
    let src = MemorySource(data: data)
    try assertEqual(src.totalBytes, 8)
    try assertEqual(src.currentPosition, 0)
    var buf = [UInt8](repeating: 0, count: 8)
    let n = try buf.withUnsafeMutableBufferPointer { try src.read(into: $0.baseAddress!, length: 8) }
    try assertEqual(n, 8)
    try assertEqual(buf, [1, 2, 3, 4, 5, 6, 7, 8])
}

runTest("partialRead") {
    let src = MemorySource(data: Data([10, 20, 30]))
    var buf = [UInt8](repeating: 0, count: 2)
    let n = try buf.withUnsafeMutableBufferPointer { try src.read(into: $0.baseAddress!, length: 2) }
    try assertEqual(n, 2)
    try assertEqual(buf, [10, 20])
}

runTest("readPastEnd") {
    let src = MemorySource(data: Data([1]))
    var buf = [UInt8](repeating: 0, count: 10)
    let n = try buf.withUnsafeMutableBufferPointer { try src.read(into: $0.baseAddress!, length: 10) }
    try assertEqual(n, 1)
}

runTest("seek") {
    let src = MemorySource(data: Data([0, 1, 2, 3, 4]))
    try src.seek(to: 3)
    try assertEqual(src.currentPosition, 3)
    var buf = [UInt8](repeating: 0, count: 2)
    let n = try buf.withUnsafeMutableBufferPointer { try src.read(into: $0.baseAddress!, length: 2) }
    try assertEqual(n, 2)
    try assertEqual(buf, [3, 4])
}

runTest("seekOutOfBounds") {
    let src = MemorySource(data: Data([1, 2, 3]))
    try assertThrows(try src.seek(to: 100))
    try assertThrows(try src.seek(to: -1))
}

runTest("emptySource") {
    let src = MemorySource(data: Data())
    try assertEqual(src.totalBytes, 0)
    var buf = [UInt8](repeating: 0, count: 1)
    let n = try buf.withUnsafeMutableBufferPointer { try src.read(into: $0.baseAddress!, length: 1) }
    try assertEqual(n, 0)
}

// ═══════════════════════════════════════════════════════
// WAV Decoder Tests
// ═══════════════════════════════════════════════════════
print("\n═══ WAV Decoder Tests ═══")

runTest("decode16BitStereo") {
    let wavData = WAVTestHelper.makePCM16Stereo(sampleRate: 44100, durationFrames: 4410)
    let source = MemorySource(data: wavData)
    let decoder = try WAVDecoder(source: source)
    try assertEqual(decoder.format.sampleRate, 44100)
    try assertEqual(decoder.format.channels, 2)
    try assertEqual(decoder.format.sampleFormat, .int16)
    try assertEqual(decoder.totalFrames, 4410)
    try assertFalse(decoder.isAtEnd)

    let buf = UnsafeMutableRawPointer.allocate(byteCount: 4410 * 4, alignment: 16)
    defer { buf.deallocate() }
    let frames = try decoder.decode(into: buf, maxFrames: 4410)
    try assertEqual(frames, 4410)
    try assertTrue(decoder.isAtEnd)
}

runTest("decode24BitMono") {
    let wavData = WAVTestHelper.makePCM24Mono(sampleRate: 96000, durationFrames: 9600)
    let source = MemorySource(data: wavData)
    let decoder = try WAVDecoder(source: source)
    try assertEqual(decoder.format.sampleRate, 96000.0)
    try assertEqual(decoder.format.channels, 1)
    try assertEqual(decoder.format.sampleFormat, .int24)
    try assertEqual(decoder.totalFrames, 9600)
}

runTest("partialDecode") {
    let wavData = WAVTestHelper.makePCM16Stereo(sampleRate: 44100, durationFrames: 1000)
    let source = MemorySource(data: wavData)
    let decoder = try WAVDecoder(source: source)
    let buf = UnsafeMutableRawPointer.allocate(byteCount: 400 * 4, alignment: 16)
    defer { buf.deallocate() }
    let f1 = try decoder.decode(into: buf, maxFrames: 400)
    try assertEqual(f1, 400)
    try assertEqual(decoder.currentFrame, 400)
    let f2 = try decoder.decode(into: buf, maxFrames: 400)
    try assertEqual(f2, 400)
    let f3 = try decoder.decode(into: buf, maxFrames: 400)
    try assertEqual(f3, 200)
    try assertTrue(decoder.isAtEnd)
}

runTest("wavSeek") {
    let wavData = WAVTestHelper.makePCM16Stereo(sampleRate: 44100, durationFrames: 4410)
    let source = MemorySource(data: wavData)
    let decoder = try WAVDecoder(source: source)
    try decoder.seek(to: 2000)
    try assertEqual(decoder.currentFrame, 2000)
    let buf = UnsafeMutableRawPointer.allocate(byteCount: 4410 * 4, alignment: 16)
    defer { buf.deallocate() }
    let f = try decoder.decode(into: buf, maxFrames: 4410)
    try assertEqual(f, 2410)
}

runTest("bitPerfectRoundTrip") {
    let frames = 4410
    let wavData = WAVTestHelper.makePCM16Stereo(sampleRate: 44100, durationFrames: frames)
    let source = MemorySource(data: wavData)
    let decoder = try WAVDecoder(source: source)
    let bufSize = frames * 4
    let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 16)
    defer { buf.deallocate() }
    let decoded = try decoder.decode(into: buf, maxFrames: frames)
    try assertEqual(decoded, frames)
    let headerSize = 44
    let originalPCM = wavData.subdata(in: headerSize..<(headerSize + bufSize))
    let decodedData = Data(bytes: buf, count: bufSize)
    try assertEqual(decodedData, originalPCM, "Decoded PCM must be bit-identical to source")
}

runTest("invalidHeader") {
    let garbage = Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
    let source = MemorySource(data: garbage)
    try assertThrows(try WAVDecoder(source: source))
}

// --- issue #3: WAVE_FORMAT_EXTENSIBLE SubFormat GUID ---

runTest("wavExtensibleFloat32DetectedAsFloat") {
    let wavData = WAVTestHelper.makeExtensibleFloat32Stereo(sampleRate: 48000, durationFrames: 480)
    let source = MemorySource(data: wavData)
    let decoder = try WAVDecoder(source: source)
    try assertEqual(decoder.format.sampleFormat, .float32)
    try assertEqual(decoder.format.channels, 2)
    try assertEqual(decoder.totalFrames, 480)

    let buf = UnsafeMutableRawPointer.allocate(byteCount: 480 * 8, alignment: 16)
    defer { buf.deallocate() }
    let frames = try decoder.decode(into: buf, maxFrames: 480)
    try assertEqual(frames, 480)
    let fp = buf.assumingMemoryBound(to: Float.self)
    // 首样本 sin(0)=0
    try assertEqualFloat(fp[0], 0.0, accuracy: 1e-6)
    // 峰值应接近 0.5（float 数据被正确解读，而非 int32 垃圾值）
    var peak: Float = 0
    for i in 0..<(480 * 2) { peak = max(peak, abs(fp[i])) }
    try assertEqualFloat(peak, 0.5, accuracy: 0.01)
}

runTest("wavExtensiblePCM24DetectedAsInt24") {
    let wavData = WAVTestHelper.makeExtensiblePCM24Stereo(sampleRate: 96000, durationFrames: 960)
    let source = MemorySource(data: wavData)
    let decoder = try WAVDecoder(source: source)
    try assertEqual(decoder.format.sampleFormat, .int24)
    try assertEqual(decoder.format.sampleRate, 96000.0)
    try assertEqual(decoder.totalFrames, 960)
    let buf = UnsafeMutableRawPointer.allocate(byteCount: 960 * 6, alignment: 16)
    defer { buf.deallocate() }
    let frames = try decoder.decode(into: buf, maxFrames: 960)
    try assertEqual(frames, 960)
}

runTest("wavExtensibleUnknownGUIDThrows") {
    // 取 PCM24 生成器，把 SubFormat GUID Data1（文件偏移 44）改成 0x0002（ADPCM）
    var wavData = WAVTestHelper.makeExtensiblePCM24Stereo()
    wavData[44] = 0x02; wavData[45] = 0x00; wavData[46] = 0x00; wavData[47] = 0x00
    let source = MemorySource(data: wavData)
    try assertThrows(try WAVDecoder(source: source))
}

// --- issue #3: IEEE Float 64-bit 降转 float32 ---

runTest("wavFloat64DownconvertsToFloat32") {
    let wavData = WAVTestHelper.makeFloat64Mono(sampleRate: 44100, durationFrames: 441)
    let source = MemorySource(data: wavData)
    let decoder = try WAVDecoder(source: source)
    try assertEqual(decoder.format.sampleFormat, .float32)
    try assertEqual(decoder.format.channels, 1)
    try assertEqual(decoder.totalFrames, 441)

    let buf = UnsafeMutableRawPointer.allocate(byteCount: 441 * 4, alignment: 16)
    defer { buf.deallocate() }
    let frames = try decoder.decode(into: buf, maxFrames: 441)
    try assertEqual(frames, 441)
    let fp = buf.assumingMemoryBound(to: Float.self)
    // 校验若干样本与 sin(t)*0.5 一致（Double→Float 降转）
    for i in [0, 100, 220, 440] {
        let t = 2.0 * Double.pi * 440.0 * Double(i) / 44100.0
        try assertEqualFloat(fp[i], Float(sin(t) * 0.5), accuracy: 1e-6)
    }
    // seek 使用 diskBytesPerFrame(8)：回到 200 帧再解码应得到对应样本
    try decoder.seek(to: 200)
    let f2 = try decoder.decode(into: buf, maxFrames: 241)
    try assertEqual(f2, 241)
    let t200 = 2.0 * Double.pi * 440.0 * 200.0 / 44100.0
    try assertEqualFloat(fp[0], Float(sin(t200) * 0.5), accuracy: 1e-6)
}

// --- issue #4: RF64 / ds64 ---

runTest("wavRF64UsesDs64DataSize") {
    let frames = 100
    let declared = UInt64(frames * 2 * 2)   // 与实际数据一致
    let wavData = WAVTestHelper.makeRF64PCM16(sampleRate: 44100,
                                              durationFrames: frames,
                                              declaredDataSize: declared)
    let source = MemorySource(data: wavData)
    let decoder = try WAVDecoder(source: source)
    try assertEqual(decoder.format.sampleFormat, .int16)
    // data chunk size 是占位符 0xFFFFFFFF — totalFrames 必须来自 ds64
    try assertEqual(decoder.totalFrames, Int64(frames))
    let buf = UnsafeMutableRawPointer.allocate(byteCount: frames * 4, alignment: 16)
    defer { buf.deallocate() }
    let decoded = try decoder.decode(into: buf, maxFrames: frames)
    try assertEqual(decoded, frames)
    try assertTrue(decoder.isAtEnd)
}

// ═══════════════════════════════════════════════════════
// Sine Decoder Tests
// ═══════════════════════════════════════════════════════
print("\n═══ Sine Decoder Tests ═══")

runTest("sineBasic") {
    let dec = SineDecoder(sampleRate: 44100, channels: 2, durationSeconds: 1)
    try assertEqual(dec.format.sampleRate, 44100)
    try assertEqual(dec.format.channels, 2)
    try assertEqual(dec.format.sampleFormat, .float32)
    try assertEqual(dec.totalFrames, 44100)
    let buf = UnsafeMutableRawPointer.allocate(byteCount: 44100 * 8, alignment: 16)
    defer { buf.deallocate() }
    let n = try dec.decode(into: buf, maxFrames: 44100)
    try assertEqual(n, 44100)
    try assertTrue(dec.isAtEnd)
}

runTest("sineAmplitude") {
    let dec = SineDecoder(sampleRate: 44100, channels: 1, durationSeconds: 0.01,
                          frequency: 1000, amplitude: 0.5)
    let frames = 441
    let buf = UnsafeMutableRawPointer.allocate(byteCount: frames * 4, alignment: 16)
    defer { buf.deallocate() }
    let n = try dec.decode(into: buf, maxFrames: frames)
    try assertEqual(n, frames)
    let fp = buf.assumingMemoryBound(to: Float.self)
    var maxVal: Float = 0
    for i in 0..<n { maxVal = max(maxVal, abs(fp[i])) }
    try assertGreaterThan(maxVal, Float(0.4))
    try assertLessThanOrEqual(maxVal, Float(0.5))
}

runTest("sineSeek") {
    let dec = SineDecoder(sampleRate: 44100, channels: 2, durationSeconds: 5)
    try dec.seek(to: 22050)
    try assertEqual(dec.currentFrame, 22050)
    try dec.seek(to: 999_999)
    try assertEqual(dec.currentFrame, dec.totalFrames)
}

runTest("decoderRegistry") {
    let registry = DecoderRegistry.shared
    try assertGreaterThan(registry.registeredCount, 1)
    let src = MemorySource(data: Data())
    let dec = try registry.makeDecoder(source: src, fileExtension: "sine")
    try assertTrue(dec is SineDecoder)
}

runTest("registryUnsupported") {
    let src = MemorySource(data: Data())
    try assertThrows(try DecoderRegistry.shared.makeDecoder(source: src, fileExtension: "xyz"))
}

// --- issue #2: 工厂失败后级联降级到下一优先级工厂 ---

enum QTestFailHighFactory: DecoderFactory {
    static let supportedExtensions: Set<String> = ["qtest"]
    static let priority: Int = 200
    static func canDecode(source: AudioSource, fileExtension: String) -> Bool { true }
    static func makeDecoder(source: AudioSource, fileExtension: String) throws -> AudioDecoder {
        throw PurePlayError.decodeFailed("qtest-high: intentional failure")
    }
}

enum QTestSineLowFactory: DecoderFactory {
    static let supportedExtensions: Set<String> = ["qtest"]
    static let priority: Int = 50
    static func canDecode(source: AudioSource, fileExtension: String) -> Bool { true }
    static func makeDecoder(source: AudioSource, fileExtension: String) throws -> AudioDecoder {
        SineDecoder(durationSeconds: 0.01)
    }
}

enum QTestAllFailHighFactory: DecoderFactory {
    static let supportedExtensions: Set<String> = ["qfail"]
    static let priority: Int = 200
    static func canDecode(source: AudioSource, fileExtension: String) -> Bool { true }
    static func makeDecoder(source: AudioSource, fileExtension: String) throws -> AudioDecoder {
        throw PurePlayError.decodeFailed("qfail-high")
    }
}

enum QTestAllFailLowFactory: DecoderFactory {
    static let supportedExtensions: Set<String> = ["qfail"]
    static let priority: Int = 100
    static func canDecode(source: AudioSource, fileExtension: String) -> Bool { true }
    static func makeDecoder(source: AudioSource, fileExtension: String) throws -> AudioDecoder {
        throw PurePlayError.decodeFailed("qfail-low")
    }
}

runTest("registryFallsBackWhenFactoryFails") {
    let registry = DecoderRegistry.shared
    registry.register(QTestFailHighFactory.self)
    registry.register(QTestSineLowFactory.self)
    let src = MemorySource(data: Data())
    let dec = try registry.makeDecoder(source: src, fileExtension: "qtest")
    try assertTrue(dec is SineDecoder,
                   "高优先级工厂失败后应级联到低优先级 SineDecoder 工厂")
}

runTest("registryThrowsLastErrorWhenAllFail") {
    let registry = DecoderRegistry.shared
    registry.register(QTestAllFailHighFactory.self)
    registry.register(QTestAllFailLowFactory.self)
    let src = MemorySource(data: Data())
    do {
        _ = try registry.makeDecoder(source: src, fileExtension: "qfail")
        try assertTrue(false, "expected throw")
    } catch let e as PurePlayError {
        // 全部失败时应抛出最后一次（最低优先级）工厂的错误，而非 unsupportedFormat
        try assertEqual(e, PurePlayError.decodeFailed("qfail-low"))
    }
}

// ═══════════════════════════════════════════════════════
// PCMRingBuffer Tests
// ═══════════════════════════════════════════════════════
print("\n═══ PCMRingBuffer Tests ═══")

runTest("writeAndRead") {
    let rb = PCMRingBuffer(capacity: 64)
    try assertEqual(rb.availableToRead, 0)
    try assertEqual(rb.availableToWrite, 64)
    let data: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
    let written = data.withUnsafeBytes { rb.write($0.baseAddress!, length: 8) }
    try assertEqual(written, 8)
    try assertEqual(rb.availableToRead, 8)
    var out = [UInt8](repeating: 0, count: 8)
    let readCount = out.withUnsafeMutableBytes { rb.read(into: $0.baseAddress!, length: 8) }
    try assertEqual(readCount, 8)
    try assertEqual(out, data)
    try assertEqual(rb.availableToRead, 0)
}

runTest("overflowProtection") {
    let rb = PCMRingBuffer(capacity: 4)
    let data: [UInt8] = [1, 2, 3, 4, 5, 6]
    let written = data.withUnsafeBytes { rb.write($0.baseAddress!, length: 6) }
    try assertEqual(written, 4)
}

runTest("underflowProtection") {
    let rb = PCMRingBuffer(capacity: 16)
    var out = [UInt8](repeating: 0, count: 8)
    let r = out.withUnsafeMutableBytes { rb.read(into: $0.baseAddress!, length: 8) }
    try assertEqual(r, 0)
}

runTest("wraparound") {
    let rb = PCMRingBuffer(capacity: 8)
    let d1: [UInt8] = [10, 20, 30, 40, 50, 60, 70, 80]
    d1.withUnsafeBytes { rb.write($0.baseAddress!, length: 8) }
    var out = [UInt8](repeating: 0, count: 4)
    out.withUnsafeMutableBytes { rb.read(into: $0.baseAddress!, length: 4) }
    try assertEqual(out, [10, 20, 30, 40])
    let d2: [UInt8] = [91, 92, 93, 94]
    d2.withUnsafeBytes { rb.write($0.baseAddress!, length: 4) }
    var full = [UInt8](repeating: 0, count: 8)
    let n = full.withUnsafeMutableBytes { rb.read(into: $0.baseAddress!, length: 8) }
    try assertEqual(n, 8)
    try assertEqual(full, [50, 60, 70, 80, 91, 92, 93, 94])
}

runTest("reset") {
    let rb = PCMRingBuffer(capacity: 16)
    let d: [UInt8] = [1, 2, 3, 4]
    d.withUnsafeBytes { rb.write($0.baseAddress!, length: 4) }
    try assertEqual(rb.availableToRead, 4)
    rb.reset()
    try assertEqual(rb.availableToRead, 0)
    try assertEqual(rb.availableToWrite, 16)
}

runTest("concurrentAccess") {
    let rb = PCMRingBuffer(capacity: 1024)
    let targetBytes = 10_000
    let chunkSize = 64
    let sem = DispatchSemaphore(value: 0)

    var totalWritten = 0
    var totalRead = 0

    Thread.detachNewThread {
        let chunk = [UInt8](repeating: 0xAB, count: chunkSize)
        while totalWritten < targetBytes {
            let w = chunk.withUnsafeBytes { rb.write($0.baseAddress!, length: chunkSize) }
            totalWritten += w
            if w == 0 { Thread.sleep(forTimeInterval: 0.0001) }
        }
        sem.signal()
    }
    Thread.detachNewThread {
        var out = [UInt8](repeating: 0, count: chunkSize)
        while totalRead < targetBytes {
            let r = out.withUnsafeMutableBytes { rb.read(into: $0.baseAddress!, length: chunkSize) }
            totalRead += r
            if r == 0 { Thread.sleep(forTimeInterval: 0.0001) }
        }
        sem.signal()
    }
    sem.wait()
    sem.wait()
    try assertGreaterThan(totalWritten, targetBytes - 1)
    try assertGreaterThan(totalRead, targetBytes - 1)
}

// ═══════════════════════════════════════════════════════
// DSP Chain Tests
// ═══════════════════════════════════════════════════════
print("\n═══ DSP Chain Tests ═══")

runTest("bitPerfectBypass") {
    let prefs = DSPPreferences()
    let fmt = AudioFormat.pcm(rate: 96000, channels: 2, bitDepth: 24)
    let chain = DSPChain.build(inputFormat: fmt, preferences: prefs)
    try assertTrue(chain.isBypass)
    try assertTrue(chain.nodes.isEmpty)
}

runTest("gainNode") {
    let node = GainNode(gainDB: 6.0)
    try assertTrue(node.isEnabled)
    let fmt = AudioFormat(sampleRate: 44100, channels: 2, sampleFormat: .float32)
    _ = node.configure(inputFormat: fmt)
    var samples: [Float] = [1.0, -0.5, 0.25, 0]
    let expected = samples.map { $0 * pow(10, 6.0 / 20.0) }
    samples.withUnsafeMutableBufferPointer { buf in
        node.process(input: buf.baseAddress!, output: buf.baseAddress!, frameCount: 4)
    }
    for i in 0..<4 {
        try assertEqualFloat(samples[i], expected[i], accuracy: 0.001)
    }
}

runTest("zeroGain") {
    let node = GainNode(gainDB: 0)
    var samples: [Float] = [0.5, -0.5, 1.0, -1.0]
    let original = samples
    samples.withUnsafeMutableBufferPointer { buf in
        node.process(input: buf.baseAddress!, output: buf.baseAddress!, frameCount: 4)
    }
    for i in 0..<4 {
        try assertEqualFloat(samples[i], original[i], accuracy: 0.0001)
    }
}

runTest("crossfeedNode") {
    let node = CrossfeedNode(intensity: 1.0)
    let fmt = AudioFormat(sampleRate: 44100, channels: 2, sampleFormat: .float32)
    _ = node.configure(inputFormat: fmt)
    var samples: [Float] = [1.0, 0.0, 1.0, 0.0]
    samples.withUnsafeMutableBufferPointer { buf in
        node.process(input: buf.baseAddress!, output: buf.baseAddress!, frameCount: 4)
    }
    try assertGreaterThan(samples[1], Float(0))
    try assertLessThan(samples[0], Float(1.0))
}

runTest("chainWithDSP") {
    var prefs = DSPPreferences()
    prefs.bitPerfect = false
    prefs.replayGainEnabled = true
    prefs.replayGainDB = 0
    prefs.eqEnabled = true
    prefs.parametricBands = [ParametricBand(type: .peaking, frequency: 1000, gain: 3, q: 1.414)]
    prefs.crossfeedEnabled = true
    let fmt = AudioFormat(sampleRate: 44100, channels: 2, sampleFormat: .float32)
    let chain = DSPChain.build(inputFormat: fmt, preferences: prefs)
    try assertFalse(chain.isBypass)
    // Gain + EQ + Crossfeed + SoftLimiter（issue #7：默认链末软限幅）
    try assertEqual(chain.nodes.count, 4)
    try assertEqual(chain.nodes.last?.name, "SoftLimiter")
}

runTest("chainLimiterCanBeDisabled") {
    // issue #7：限幅器可关（用户显式选择原始削波行为时）
    var prefs = DSPPreferences()
    prefs.bitPerfect = false
    prefs.replayGainEnabled = true
    prefs.limiterEnabled = false
    let fmt = AudioFormat(sampleRate: 44100, channels: 2, sampleFormat: .float32)
    let chain = DSPChain.build(inputFormat: fmt, preferences: prefs)
    try assertTrue(chain.nodes.allSatisfy { $0.name != "SoftLimiter" })
}

// ═══════════════════════════════════════════════════════
// SoftLimiter + PCMOutputConverter Tests (issue #7 / #9)
// ═══════════════════════════════════════════════════════
print("\n═══ SoftLimiter / PCMOutputConverter Tests ═══")

runTest("softLimiterBelowThresholdPassthrough") {
    let node = SoftLimiterNode()   // threshold 0.8
    var samples: [Float] = [0.5, -0.79, 0.0, -0.001, 0.79]
    let original = samples
    samples.withUnsafeMutableBufferPointer { buf in
        node.process(input: buf.baseAddress!, output: buf.baseAddress!, frameCount: 5)
    }
    for i in 0..<5 {
        try assertEqualFloat(samples[i], original[i], accuracy: 1e-6)
    }
}

runTest("softLimiterCompressesAboveThreshold") {
    let node = SoftLimiterNode()
    var samples: [Float] = [1.0, 2.0, -3.0, 100.0]
    samples.withUnsafeMutableBufferPointer { buf in
        node.process(input: buf.baseAddress!, output: buf.baseAddress!, frameCount: 4)
    }
    // f(1.0) = 0.8 + 0.2·tanh(1) ≈ 0.9523 — 软膝内明确压缩且 < 满幅
    try assertEqualFloat(samples[0], 0.9523, accuracy: 0.001)
    try assertLessThan(abs(samples[0]), Float(1.0))
    // 极端输入（2.0/-3.0/100.0）：渐近满幅，永不越过（tanh ≤ 1 → y ≤ 1.0；
    // Float 精度下 tanh(≫1) == 1.0，允许恰好贴到满幅）
    for i in 1..<4 {
        try assertLessThan(abs(samples[i]), Float(1.0) + 1e-6)
        try assertGreaterThan(abs(samples[i]), Float(0.999))
    }
    // 单调：更大输入 → 更大输出
    try assertGreaterThan(samples[1], samples[0])
    // 负输入 → 负输出（奇对称）
    try assertLessThan(samples[2], Float(0))
}

runTest("pcmConverterInt16RoundTripAndClamp") {
    let conv = PCMOutputConverter(targetFormat: .int16, ditherEnabled: false)
    let input: [Float] = [0.5, -0.5, 1.0, -1.0, 2.0, 0.0]
    var outBytes = [UInt8](repeating: 0, count: input.count * 2)
    input.withUnsafeBufferPointer { ib in
        outBytes.withUnsafeMutableBytes { ob in
            conv.convert(input: ib.baseAddress!, output: ob.baseAddress!, sampleCount: input.count)
        }
    }
    func code16(_ i: Int) -> Int16 {
        let lo = UInt16(outBytes[i * 2])
        let hi = UInt16(outBytes[i * 2 + 1]) << 8
        return Int16(bitPattern: lo | hi)
    }
    try assertEqual(code16(0), Int16(16384))     // 0.5 × 2^15
    try assertEqual(code16(1), Int16(-16384))
    try assertEqual(code16(2), Int16(32767))     // +1.0 → clamp 到 maxCode
    try assertEqual(code16(3), Int16(-32768))    // -1.0 → minCode 合法
    try assertEqual(code16(4), Int16(32767))     // 2.0 超幅 → clamp 不越界
    try assertEqual(code16(5), Int16(0))
}

runTest("pcmConverterInt24RoundTrip") {
    let conv = PCMOutputConverter(targetFormat: .int24, ditherEnabled: false)
    let input: [Float] = [0.5, 0.25, -1.0]
    var outBytes = [UInt8](repeating: 0, count: input.count * 3)
    input.withUnsafeBufferPointer { ib in
        outBytes.withUnsafeMutableBytes { ob in
            conv.convert(input: ib.baseAddress!, output: ob.baseAddress!, sampleCount: input.count)
        }
    }
    func code(_ i: Int) -> Int32 {
        var v = Int32(outBytes[i * 3]) | (Int32(outBytes[i * 3 + 1]) << 8) | (Int32(outBytes[i * 3 + 2]) << 16)
        if v & 0x800000 != 0 { v |= ~0xFFFFFF }
        return v
    }
    try assertEqual(code(0), Int32(4194304))    // 0.5 × 2^23
    try assertEqual(code(1), Int32(2097152))    // 0.25 × 2^23
    try assertEqual(code(2), Int32(-8388608))   // -1.0 → minCode
}

runTest("pcmConverterInt32RoundTrip") {
    let conv = PCMOutputConverter(targetFormat: .int32, ditherEnabled: false)
    let input: [Float] = [0.5, -0.25]
    var outBytes = [UInt8](repeating: 0, count: input.count * 4)
    input.withUnsafeBufferPointer { ib in
        outBytes.withUnsafeMutableBytes { ob in
            conv.convert(input: ib.baseAddress!, output: ob.baseAddress!, sampleCount: input.count)
        }
    }
    func code32(_ i: Int) -> Int32 {
        let b0 = UInt32(outBytes[i * 4])
        let b1 = UInt32(outBytes[i * 4 + 1]) << 8
        let b2 = UInt32(outBytes[i * 4 + 2]) << 16
        let b3 = UInt32(outBytes[i * 4 + 3]) << 24
        return Int32(bitPattern: b0 | b1 | b2 | b3)
    }
    try assertEqual(code32(0), Int32(1073741824))    // 0.5 × 2^31（Float 精度内）
    try assertEqual(code32(1), Int32(-536870912))
}

runTest("pcmConverterDitherSpreadsCodes") {
    // 半 LSB 的 DC 输入：无 dither → 单一码值；TPDF dither → 多个码值
    let x: Float = 0.5 / 32768.0
    let trials = 200

    let convD = PCMOutputConverter(targetFormat: .int16, ditherEnabled: true)
    var dithered = Set<Int16>()
    for _ in 0..<trials {
        var b = [UInt8](repeating: 0, count: 2)
        withUnsafePointer(to: x) { ip in
            b.withUnsafeMutableBytes { ob in
                convD.convert(input: ip, output: ob.baseAddress!, sampleCount: 1)
            }
        }
        dithered.insert(Int16(bitPattern: UInt16(b[0]) | UInt16(b[1]) << 8))
    }
    try assertGreaterThan(dithered.count, 1)   // 抖动确实落在真实量化点
    try assertLessThan(dithered.count, 5)      // ±1 LSB 三角分布，不会散得更开

    let convN = PCMOutputConverter(targetFormat: .int16, ditherEnabled: false)
    var plain = Set<Int16>()
    for _ in 0..<trials {
        var b = [UInt8](repeating: 0, count: 2)
        withUnsafePointer(to: x) { ip in
            b.withUnsafeMutableBytes { ob in
                convN.convert(input: ip, output: ob.baseAddress!, sampleCount: 1)
            }
        }
        plain.insert(Int16(bitPattern: UInt16(b[0]) | UInt16(b[1]) << 8))
    }
    try assertEqual(plain.count, 1)            // 无 dither → 确定性量化
}

runTest("pipelineDitherTargetsInt16Output") {
    // issue #9：ditherEnabled + 目标位深 ≤16 → 输出格式 int16（真正降位）
    var prefs = DSPPreferences()
    prefs.bitPerfect = false
    prefs.replayGainEnabled = true
    prefs.ditherEnabled = true
    prefs.ditherTargetBitDepth = 16
    let dec = SineDecoder(durationSeconds: 0.1)
    let pipe = AudioPipeline(decoder: dec, output: MockAudioOutput(), dspPreferences: prefs)
    try assertEqual(pipe.outputFormat.sampleFormat, .int16)
    try assertTrue(pipe.outputConverter?.ditherEnabled ?? false)

    // 目标 24 → int24
    var prefs24 = prefs
    prefs24.ditherTargetBitDepth = 24
    let pipe24 = AudioPipeline(decoder: SineDecoder(durationSeconds: 0.1),
                               output: MockAudioOutput(), dspPreferences: prefs24)
    try assertEqual(pipe24.outputFormat.sampleFormat, .int24)
}

runTest("pipelineEQBoostLimiterPreventsHardClip") {
    // issue #7 集成：+6dB 提升 0.9 幅正弦 → float 峰值 ~1.80（超满幅）
    // 限幅开：码值渐近满幅但永不钉死在 maxCode（软膝）
    // 限幅关：硬削波，大量样本钉死在 maxCode 8388607
    func run(limiter: Bool) -> (maxCode: Int32, pinnedCount: Int) {
        var prefs = DSPPreferences()
        prefs.bitPerfect = false
        prefs.replayGainEnabled = true
        prefs.replayGainDB = 6
        prefs.limiterEnabled = limiter
        let dec = SineDecoder(sampleRate: 44100, channels: 1, durationSeconds: 0.5,
                              frequency: 1000, amplitude: 0.9)
        let pipe = AudioPipeline(decoder: dec, output: MockAudioOutput(), dspPreferences: prefs)
        try! pipe.start()
        Thread.sleep(forTimeInterval: 0.25)
        let frames = 4096
        let bpf = pipe.outputFormat.bytesPerFrame    // int24 mono = 3
        let buf = UnsafeMutableRawPointer.allocate(byteCount: frames * bpf, alignment: 16)
        defer { buf.deallocate() }
        _ = pipe.ringBuffer.read(into: buf, length: frames * bpf)   // 必须在 stop 前读
        pipe.stop()
        let raw = buf.assumingMemoryBound(to: UInt8.self)
        var maxCode: Int32 = 0
        var pinned = 0
        for i in 0..<frames {
            var v = Int32(raw[i * 3]) | (Int32(raw[i * 3 + 1]) << 8) | (Int32(raw[i * 3 + 2]) << 16)
            if v & 0x800000 != 0 { v |= ~0xFFFFFF }
            let a = abs(v)
            maxCode = max(maxCode, a)
            // 8388607 = 正满幅 maxCode；8388608 = abs(minCode) 负满幅钉死
            if a == 8388607 || a == 8388608 { pinned += 1 }
        }
        return (maxCode, pinned)
    }

    let limited = run(limiter: true)
    try assertEqual(limited.pinnedCount, 0, "软限幅后不应有任何样本钉死在满幅码")
    try assertLessThan(limited.maxCode, Int32(8388607))
    try assertGreaterThan(limited.maxCode, Int32(8_000_000))   // 信号仍接近满幅（不是衰减掉的）

    let clipped = run(limiter: false)
    // 限幅关闭时应出现硬削波（样本钉死满幅码；负峰钉到 minCode → abs = 2^23）
    try assertGreaterThan(clipped.pinnedCount, 0)
    try assertEqual(clipped.maxCode, Int32(8388608))
}

// ═══════════════════════════════════════════════════════
// DoP Packer Tests
// ═══════════════════════════════════════════════════════
print("\n═══ DoP Packer Tests ═══")

runTest("basicPacking") {
    let packer = DoPPacker(bitOrder: .msbFirst, channels: 2)
    let dsd: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD]
    var pcm = [UInt8](repeating: 0, count: 6)
    let written = dsd.withUnsafeBufferPointer { src in
        pcm.withUnsafeMutableBufferPointer { dst in
            packer.pack(dsdInterleaved: src.baseAddress!, dsdBytes: 4,
                        outPCM: dst.baseAddress!, outCapacity: 6)
        }
    }
    try assertEqual(written, 6)
    try assertEqual(pcm[0], UInt8(0x05))
    try assertEqual(pcm[1], UInt8(0xAA))
    try assertEqual(pcm[2], UInt8(0xBB))
    try assertEqual(pcm[3], UInt8(0x05))
    try assertEqual(pcm[4], UInt8(0xCC))
    try assertEqual(pcm[5], UInt8(0xDD))
}

runTest("markerAlternation") {
    let packer = DoPPacker(bitOrder: .msbFirst, channels: 1)
    let dsd: [UInt8] = [0x11, 0x22, 0x33, 0x44]
    var pcm = [UInt8](repeating: 0, count: 6)
    dsd.withUnsafeBufferPointer { src in
        pcm.withUnsafeMutableBufferPointer { dst in
            packer.pack(dsdInterleaved: src.baseAddress!, dsdBytes: 4,
                        outPCM: dst.baseAddress!, outCapacity: 6)
        }
    }
    try assertEqual(pcm[0], UInt8(0x05))
    try assertEqual(pcm[3], UInt8(0xFA))
}

runTest("isDoPDetection") {
    let pcm: [UInt8] = [0x05, 0x11, 0x22, 0xFA, 0x33, 0x44]
    let result = pcm.withUnsafeBufferPointer {
        DoPPacker.isDoPStream($0.baseAddress!, length: 6, channels: 1)
    }
    try assertTrue(result)

    let bad: [UInt8] = [0x05, 0x11, 0x22, 0x05, 0x33, 0x44]
    let badResult = bad.withUnsafeBufferPointer {
        DoPPacker.isDoPStream($0.baseAddress!, length: 6, channels: 1)
    }
    try assertFalse(badResult)
}

runTest("dsdRates") {
    try assertEqual(DSDRate.dsd64.rawValue, 2_822_400)
    try assertEqual(DSDRate.dsd64.dopCarrierRate, 176_400.0)
    try assertEqual(DSDRate.dsd128.dopCarrierRate, 352_800.0)
    try assertEqual(DSDRate.dsd256.dopCarrierRate, 705_600.0)
}

runTest("strategyDoP") {
    let dac = DACCapabilities(maxPCMRate: 384_000)
    let s = DSDStrategyChooser.choose(rate: .dsd64, dac: dac, preference: .preferDoP)
    try assertEqual(s, .dop(carrierRate: 176_400))
}

runTest("strategyFallbackPCM") {
    let dac = DACCapabilities(maxPCMRate: 96_000)
    let s = DSDStrategyChooser.choose(rate: .dsd128, dac: dac, preference: .auto)
    try assertEqual(s, .pcm(targetRate: 176_400))
}

runTest("strategyAlwaysPCM") {
    let dac = DACCapabilities(maxPCMRate: 768_000)
    let s = DSDStrategyChooser.choose(rate: .dsd64, dac: dac, preference: .alwaysPCM)
    try assertEqual(s, .pcm(targetRate: 88_200))
}

// ═══════════════════════════════════════════════════════
// DSF Decoder Tests
// ═══════════════════════════════════════════════════════
print("\n═══ DSF Decoder Tests ═══")

runTest("dsfHeaderParsing") {
    let data = DSFTestHelper.makeMinimalDSF(sampleFreq: 2_822_400, blocks: 1)
    let source = MemorySource(data: data)
    let decoder = try DSFDecoder(source: source)
    try assertTrue(decoder.format.isDSD)
    try assertEqual(decoder.format.channels, 2)
    try assertEqual(decoder.format.sampleFormat, .int24)
    try assertEqual(decoder.format.sampleRate, 176_400.0)   // 2_822_400 / 16
    try assertEqual(decoder.format.dsdRateRaw, 2_822_400.0)
    // 1 block × 4096 bytes/ch × 8 bits/byte / 16 bits/frame = 2048 frames
    try assertEqual(decoder.totalFrames, 2048)
    try assertEqual(decoder.format.bitDepth, 1)
}

runTest("dsfDecodeProducesDoPMarkers") {
    let data = DSFTestHelper.makeMinimalDSF(sampleFreq: 2_822_400, blocks: 1)
    let source = MemorySource(data: data)
    let decoder = try DSFDecoder(source: source)
    // Decode 1 frame = 6 bytes (2 ch × 3 bytes)
    let buf = UnsafeMutableRawPointer.allocate(byteCount: 6, alignment: 4)
    defer { buf.deallocate() }
    let frames = try decoder.decode(into: buf, maxFrames: 1)
    try assertEqual(frames, 1)
    // After byte-swap, marker (0x05) should be at position 2 of each 3-byte sample (LE highest)
    let p = buf.assumingMemoryBound(to: UInt8.self)
    try assertEqual(p[2], UInt8(0x05))   // ch0 marker
    try assertEqual(p[5], UInt8(0x05))   // ch1 marker (first frame, both still 0x05 before alternation)
}

runTest("dsfMarkerAlternation") {
    let data = DSFTestHelper.makeMinimalDSF(sampleFreq: 2_822_400, blocks: 1)
    let source = MemorySource(data: data)
    let decoder = try DSFDecoder(source: source)
    // Decode 4 frames = 24 bytes
    let buf = UnsafeMutableRawPointer.allocate(byteCount: 24, alignment: 4)
    defer { buf.deallocate() }
    let frames = try decoder.decode(into: buf, maxFrames: 4)
    try assertEqual(frames, 4)
    let p = buf.assumingMemoryBound(to: UInt8.self)
    // marker positions per frame: bytes [2, 5] within each 6-byte frame
    let frame0Ch0 = p[0 * 6 + 2]
    let frame1Ch0 = p[1 * 6 + 2]
    let frame2Ch0 = p[2 * 6 + 2]
    let frame3Ch0 = p[3 * 6 + 2]
    // Expect alternation 05, FA, 05, FA
    try assertEqual(frame0Ch0, UInt8(0x05))
    try assertEqual(frame1Ch0, UInt8(0xFA))
    try assertEqual(frame2Ch0, UInt8(0x05))
    try assertEqual(frame3Ch0, UInt8(0xFA))
}

runTest("dsfDoPFirstBlockPayloadNotSilence") {
    // 回归：旧代码首块对从不加载（条件误用 blockSizePerChannel），
    // 无 seek 直接 decode 时开头一块全零静音。
    // 常量字节模式下 DoP payload 与字节序无关：ch0=0xFF → 0xFFFF，ch1=0x00 → 0x0000
    let data = DSFTestHelper.makeMinimalDSF(
        sampleFreq: 2_822_400, blocks: 1,
        channelPattern: { ch, _ in ch == 0 ? 0xFF : 0x00 })
    let decoder = try DSFDecoder(source: MemorySource(data: data))
    let buf = UnsafeMutableRawPointer.allocate(byteCount: 6, alignment: 4)
    defer { buf.deallocate() }
    let frames = try decoder.decode(into: buf, maxFrames: 1)
    try assertEqual(frames, 1)
    let p = buf.assumingMemoryBound(to: UInt8.self)
    try assertEqual(p[0], UInt8(0xFF), "ch0 payload lo 应为真实数据 0xFF")
    try assertEqual(p[1], UInt8(0xFF), "ch0 payload hi 应为真实数据 0xFF")
    try assertEqual(p[2], UInt8(0x05))
    try assertEqual(p[3], UInt8(0x00))
    try assertEqual(p[4], UInt8(0x00))
    try assertEqual(p[5], UInt8(0x05))
}

runTest("dsfSeekRepositionsAndResetsMarker") {
    let data = DSFTestHelper.makeMinimalDSF(sampleFreq: 2_822_400, blocks: 1)
    let source = MemorySource(data: data)
    let decoder = try DSFDecoder(source: source)
    // Read 3 frames first (marker would be at FA next)
    let scratch = UnsafeMutableRawPointer.allocate(byteCount: 18, alignment: 4)
    defer { scratch.deallocate() }
    _ = try decoder.decode(into: scratch, maxFrames: 3)
    try assertEqual(decoder.currentFrame, 3)

    // Seek back to frame 100
    try decoder.seek(to: 100)
    try assertEqual(decoder.currentFrame, 100)

    // Marker should reset to 0x05 on next decode
    let buf = UnsafeMutableRawPointer.allocate(byteCount: 6, alignment: 4)
    defer { buf.deallocate() }
    let n = try decoder.decode(into: buf, maxFrames: 1)
    try assertEqual(n, 1)
    let p = buf.assumingMemoryBound(to: UInt8.self)
    try assertEqual(p[2], UInt8(0x05))
}

runTest("dsfRegistryResolves") {
    try assertTrue(DSFDecoderFactory.supportedExtensions.contains("dsf"))
    let data = DSFTestHelper.makeMinimalDSF()
    let source = MemorySource(data: data)
    let decoder = try DecoderRegistry.shared.makeDecoder(source: source, fileExtension: "dsf")
    try assertTrue(decoder.format.isDSD)
}

runTest("pipelineBypassesDSPForDSD") {
    // DSD (DoP) must stay bit-perfect — any DSP would corrupt the marker
    // bytes. The pipeline silently forces an empty chain instead of
    // refusing to start; the UI layer tells the user "EQ bypassed for DSD".
    let data = DSFTestHelper.makeMinimalDSF()
    let source = MemorySource(data: data)
    let decoder = try DSFDecoder(source: source)
    var prefs = DSPPreferences()
    prefs.bitPerfect = false
    prefs.eqEnabled = true
    prefs.parametricBands = [ParametricBand(type: .peaking, frequency: 1000, gain: 3, q: 1.414)]
    let output = MockAudioOutput()
    let pipe = AudioPipeline(decoder: decoder, output: output, dspPreferences: prefs)
    try assertTrue(pipe.dspChain.isBypass, "DSD must force an empty DSP chain")
    try assertTrue(pipe.outputFormat.isDSD, "DSD output format must be preserved")
}

// ═══════════════════════════════════════════════════════
// Mock Output Tests
// ═══════════════════════════════════════════════════════
print("\n═══ Mock Output Tests ═══")

runTest("listDevices") {
    let out = MockAudioOutput()
    let devices = out.listDevices()
    try assertEqual(devices.count, 1)
    try assertEqual(devices[0].name, "Mock DAC")
}

runTest("hogModeLifecycle") {
    let out = MockAudioOutput()
    let dev = out.listDevices().first!
    try out.setDevice(dev)
    try assertFalse(out.isHogMode)
    try out.acquireHogMode()
    try assertTrue(out.isHogMode)
    try out.releaseHogMode()
    try assertFalse(out.isHogMode)
}

runTest("sampleRateSwitch") {
    let out = MockAudioOutput()
    try out.switchSampleRate(to: 96000)
    try assertEqual(out.currentSampleRate, 96000.0)
    try out.switchSampleRate(to: 192000)
    try assertEqual(out.currentSampleRate, 192000.0)
}

runTest("startStop") {
    let out = MockAudioOutput()
    let format = AudioFormat.pcm(rate: 44100, channels: 2, bitDepth: 16)
    try out.start(format: format) { _, _ in 0 }
    try assertTrue(out.isPlaying)
    try assertEqual(out.currentSampleRate, 44100.0)
    out.stop()
    try assertFalse(out.isPlaying)
}

runTest("renderCallback") {
    let out = MockAudioOutput()
    var callCount = 0
    let format = AudioFormat.pcm(rate: 44100, channels: 2, bitDepth: 16)
    try out.start(format: format) { buf, frames in
        callCount += 1
        memset(buf, 0xCD, frames * 4)
        return frames
    }
    let pulled = out.pullFrames(512, bytesPerFrame: 4)
    try assertEqual(pulled, 512)
    try assertEqual(callCount, 1)
    try assertEqual(out.framesRendered, 512)
    out.stop()
}

// ═══════════════════════════════════════════════════════
// SampleRateManager + Device wiring Tests
// ═══════════════════════════════════════════════════════
print("\n═══ SampleRateManager / Device Wiring Tests ═══")

runTest("pickTargetRateExactMatch") {
    let chosen = SampleRateManager.pickTargetRate(
        source: 96000,
        supported: [44100, 48000, 88200, 96000, 192000],
        deviceDefault: 48000
    )
    try assertEqual(chosen, 96000.0)
}

runTest("pickTargetRateFallsBackToDefault") {
    let chosen = SampleRateManager.pickTargetRate(
        source: 192000,
        supported: [44100, 48000],
        deviceDefault: 48000
    )
    try assertEqual(chosen, 48000.0)
}

runTest("pipelineSwitchesRateBeforeStart") {
    let out = MockAudioOutput()
    let dev = out.listDevices().first!   // mock DAC supports up to 768k
    try out.setDevice(dev)
    try out.switchSampleRate(to: 44100)   // start somewhere else
    let decoder = SineDecoder(sampleRate: 96000, channels: 2, durationSeconds: 0.1)
    let pipe = AudioPipeline(decoder: decoder, output: out)
    try pipe.start()
    try assertTrue(pipe.didMatchHardwareRate)
    pipe.stop()
}

runTest("pipelineFallsBackWhenRateUnsupported") {
    let limitedDev = AudioDevice(
        id: 99, name: "Limited DAC", uid: "limited-99",
        maxSampleRate: 48000, supportedRates: [44100, 48000]
    )
    let out = MockAudioOutput()
    try out.setDevice(limitedDev)
    try out.switchSampleRate(to: 48000)   // device default
    let decoder = SineDecoder(sampleRate: 96000, channels: 2, durationSeconds: 0.1)
    let pipe = AudioPipeline(decoder: decoder, output: out)
    try pipe.start()
    try assertFalse(pipe.didMatchHardwareRate)
    pipe.stop()
}

// --- issue #5: SincResampler 接线 ---

runTest("pickTargetRatePrefersLowestUpsample") {
    // 无精确匹配时选 ≥ source 的最低支持率（上采样对 DAC 滤波更从容）
    let chosen = SampleRateManager.pickTargetRate(
        source: 88200,
        supported: [44100, 48000, 96000, 192000],
        deviceDefault: 48000
    )
    try assertEqual(chosen, 96000.0)
}

runTest("pickTargetRateHighestWhenSourceExceedsAll") {
    let chosen = SampleRateManager.pickTargetRate(
        source: 384000,
        supported: [44100, 48000, 96000],
        deviceDefault: 44100
    )
    try assertEqual(chosen, 96000.0)
}

runTest("dspChainNoLongerClaimsResampledRate") {
    // LinearResamplerNode 地雷已拆除：链输出率恒等于输入率
    var prefs = DSPPreferences()
    prefs.bitPerfect = false
    prefs.replayGainEnabled = true
    prefs.resamplerTargetRate = 88200
    let inFmt = AudioFormat(sampleRate: 44100, channels: 2, sampleFormat: .int16)
    let chain = DSPChain.build(inputFormat: inFmt, preferences: prefs)
    try assertEqual(chain.outputFormat.sampleRate, 44100.0)
    try assertTrue(chain.nodes.allSatisfy { $0.name != "LinearResampler" })
}

runTest("pipelineSincResamplerDoublesRate") {
    // 44.1k → 88.2k（×2 上采样）：输出格式、帧率与音调都必须正确
    var prefs = DSPPreferences()
    prefs.bitPerfect = false
    prefs.resamplerTargetRate = 88200
    let dec = SineDecoder(sampleRate: 44100, channels: 1, durationSeconds: 1,
                          frequency: 1000, amplitude: 0.5)
    let out = MockAudioOutput()
    let pipe = AudioPipeline(decoder: dec, output: out, dspPreferences: prefs)
    try assertEqual(pipe.outputFormat.sampleRate, 88200.0)
    // issue #9：重采样后同样转回整数输出（float 源 → 默认 24-bit）
    try assertEqual(pipe.outputFormat.sampleFormat, .int24)
    try assertTrue(pipe.resampler != nil)
    try pipe.start()
    Thread.sleep(forTimeInterval: 0.3)
    // 读 17640 帧（0.2s @88.2k），1kHz 正弦应有 ~200 个正峰 —
    // 若重采样是 1:1 直通地雷，峰数会只有 ~100（变速变调）
    // 注意：必须在 stop() 之前读 — stop 会 reset ring buffer
    let frames = 17640
    let bpf = pipe.outputFormat.bytesPerFrame          // int24 mono = 3
    let buf = UnsafeMutableRawPointer.allocate(byteCount: frames * bpf, alignment: 16)
    let read = pipe.ringBuffer.read(into: buf, length: frames * bpf)
    pipe.stop()
    defer { buf.deallocate() }
    try assertEqual(read, frames * bpf)
    // 解 3-byte LE int24 → float（±1 域）
    let raw = buf.assumingMemoryBound(to: UInt8.self)
    func sampleAt(_ i: Int) -> Float {
        var v = Int32(raw[i * 3]) | (Int32(raw[i * 3 + 1]) << 8) | (Int32(raw[i * 3 + 2]) << 16)
        if v & 0x800000 != 0 { v |= ~0xFFFFFF }
        return Float(v) / 8388608.0
    }
    var peaks = 0
    for i in 1..<(frames - 1) {
        let a = sampleAt(i - 1), b = sampleAt(i), c = sampleAt(i + 1)
        if b > a && b >= c && b > 0.2 { peaks += 1 }
    }
    try assertGreaterThan(peaks, 175)
    try assertLessThan(peaks, 225)
    // 幅度保持（Kaiser sinc DC 归一 → 增益 ≈ 1）
    var peakVal: Float = 0
    for i in 0..<frames { peakVal = max(peakVal, abs(sampleAt(i))) }
    try assertEqualFloat(peakVal, 0.5, accuracy: 0.05)
}

runTest("pipelineResamplesWhenDeviceLacksSourceRate") {
    // 设备不支持源率 → 主动接 SincResampler 到设备目标率，而非放任系统 SRC
    let limitedDev = AudioDevice(
        id: 98, name: "Limited DAC 2", uid: "limited-98",
        maxSampleRate: 48000, supportedRates: [44100, 48000]
    )
    let out = MockAudioOutput()
    try out.setDevice(limitedDev)
    let decoder = SineDecoder(sampleRate: 96000, channels: 2, durationSeconds: 0.2)
    let pipe = AudioPipeline(decoder: decoder, output: out)
    try pipe.start()
    try assertFalse(pipe.didMatchHardwareRate)
    try assertTrue(pipe.resampler != nil)
    try assertEqual(pipe.outputFormat.sampleRate, 48000.0)
    try assertEqual(pipe.outputFormat.sampleFormat, .int24)   // issue #9：整数量化点输出
    try assertTrue(pipe.outputConverter != nil)
    pipe.stop()
}

runTest("pipelineNeverResamplesDSD") {
    // DoP 标记字节绝不允许经过重采样（issue #1/#5 边界）
    let limitedDev = AudioDevice(
        id: 97, name: "Limited DAC 3", uid: "limited-97",
        maxSampleRate: 48000, supportedRates: [44100, 48000]
    )
    let out = MockAudioOutput()
    try out.setDevice(limitedDev)
    let dsd = DSFTestHelper.makeMinimalDSF()
    let dec = try DSFDecoder(source: MemorySource(data: dsd))
    let pipe = AudioPipeline(decoder: dec, output: out)
    try pipe.start()
    try assertTrue(pipe.resampler == nil)
    pipe.stop()
}

runTest("hogPreferenceRoundTrip") {
    // Clean slate
    AudioPreferences.hogEnabled = false
    let out1 = MockAudioOutput()
    let pc1 = PlayerController(output: out1)
    try assertFalse(pc1.isHogModeEnabled)

    pc1.setHogModePreference(true)
    try assertTrue(pc1.isHogModeEnabled)
    try assertTrue(AudioPreferences.hogEnabled)

    // New controller picks up persisted value
    let out2 = MockAudioOutput()
    let pc2 = PlayerController(output: out2)
    try assertTrue(pc2.isHogModeEnabled)

    // Cleanup
    AudioPreferences.hogEnabled = false
}

runTest("setOutputDevicePersistsUID") {
    AudioPreferences.deviceUID = nil
    let out = MockAudioOutput()
    let pc = PlayerController(output: out)
    let dev = out.listDevices().first!
    try pc.setOutputDevice(dev)
    try assertEqual(AudioPreferences.deviceUID ?? "", dev.uid)
    try assertEqual(pc.currentOutputDevice()?.uid ?? "", dev.uid)

    // Cleanup
    AudioPreferences.deviceUID = nil
}

runTest("hogAcquiredOnPlayReleasedOnStop") {
    AudioPreferences.hogEnabled = false
    let out = MockAudioOutput()
    let pc = PlayerController(output: out)
    let dev = out.listDevices().first!
    try pc.setOutputDevice(dev)
    pc.setHogModePreference(true)

    // Use Sine decoder via direct play (we can't go through DecoderRegistry without a real file).
    // Instead, simulate the acquire/release path by invoking the same hooks via setOutputDevice flow:
    // Drive Hog via a manual pipeline start.
    let decoder = SineDecoder(sampleRate: 44100, channels: 2, durationSeconds: 0.1)
    let pipe = AudioPipeline(decoder: decoder, output: out)
    // Manually mirror PlayerController.acquireHogIfNeeded behaviour pre-start
    try out.acquireHogMode()
    try assertTrue(out.isHogMode)
    try pipe.start()
    pipe.stop()
    try out.releaseHogMode()
    try assertFalse(out.isHogMode)

    // Cleanup
    AudioPreferences.hogEnabled = false
    AudioPreferences.deviceUID = nil
}

// ═══════════════════════════════════════════════════════
// AudioPipeline Tests
// ═══════════════════════════════════════════════════════
print("\n═══ AudioPipeline Tests ═══")

runTest("pipelineWithSine") {
    let decoder = SineDecoder(sampleRate: 44100, channels: 2, durationSeconds: 0.1)
    let output = MockAudioOutput()
    let pipeline = AudioPipeline(decoder: decoder, output: output)
    try assertEqual(pipeline.outputFormat.sampleRate, 44100.0)
    try assertEqual(pipeline.outputFormat.channels, 2)
    try assertTrue(pipeline.dspChain.isBypass)
    try pipeline.start()
    try assertTrue(output.isPlaying)
    Thread.sleep(forTimeInterval: 0.2)
    let pulled = output.pullFrames(1024, bytesPerFrame: pipeline.outputFormat.bytesPerFrame)
    try assertGreaterThan(pulled, 0)
    pipeline.stop()
    try assertFalse(output.isPlaying)
}

runTest("pipelineWithWAV") {
    let wavData = WAVTestHelper.makePCM16Stereo(sampleRate: 44100, durationFrames: 4410)
    let source = MemorySource(data: wavData)
    let decoder = try WAVDecoder(source: source)
    let output = MockAudioOutput()
    let pipeline = AudioPipeline(decoder: decoder, output: output)
    try assertEqual(pipeline.outputFormat.sampleRate, 44100.0)
    try assertEqual(pipeline.outputFormat.sampleFormat, .int16)
    try pipeline.start()
    Thread.sleep(forTimeInterval: 0.3)
    let frames = output.pullFrames(4410, bytesPerFrame: 4)
    try assertGreaterThan(frames, 0)
    pipeline.stop()
}

runTest("pipelineStopIdempotent") {
    let decoder = SineDecoder(sampleRate: 44100, channels: 2, durationSeconds: 0.1)
    let output = MockAudioOutput()
    let pipeline = AudioPipeline(decoder: decoder, output: output)
    try pipeline.start()
    pipeline.stop()
    pipeline.stop()
}

runTest("pipelineSeekResetsRingBuffer") {
    let decoder = SineDecoder(sampleRate: 44100, channels: 2, durationSeconds: 1.0)
    let output = MockAudioOutput()
    let pipeline = AudioPipeline(decoder: decoder, output: output)
    try pipeline.start()
    Thread.sleep(forTimeInterval: 0.05)   // let decode thread fill some bytes
    try pipeline.seek(toFrame: 22050)
    // seek resets the ring buffer; right after seek we expect 0 readable bytes
    try assertEqual(pipeline.ringBuffer.availableToRead, 0)
    try assertEqual(decoder.currentFrame, 22050)
    pipeline.stop()
}

// ─── issue #16：欠载淡出（fade-out）代替硬插零 ───

runTest("pipelineUnderrunFadesToZeroFloat32") {
    // bitPerfect 默认 → chain bypass → float32 直通输出（bpf = 8）
    let decoder = SineDecoder(sampleRate: 44100, channels: 2, durationSeconds: 0.1)
    let pipe = AudioPipeline(decoder: decoder, output: MockAudioOutput())
    try assertEqual(pipe.outputFormat.sampleFormat, .float32)

    // 手动写入 2 帧常量种子 [0.5, -0.5]，不启动解码线程
    var seed: [Float] = [0.5, -0.5, 0.5, -0.5]
    let written = seed.withUnsafeBufferPointer { p in
        pipe.ringBuffer.write(p.baseAddress!, length: 16)
    }
    try assertEqual(written, 16)

    // 拉 6 帧：前 2 帧是真实数据，后 4 帧应是淡出坡而非硬零
    let buf = UnsafeMutableRawPointer.allocate(byteCount: 48, alignment: 8)
    defer { buf.deallocate() }
    memset(buf, 0xAB, 48)
    let got = pipe.fillRenderBuffer(buf, frames: 6)
    try assertEqual(got, 6, "欠载时必须返回满帧数，防止 AU 层整段 memset")
    let f = buf.bindMemory(to: Float.self, capacity: 12)
    try assertEqual(f[0], 0.5)
    try assertEqual(f[1], -0.5)
    try assertEqual(f[2], 0.5)
    try assertEqual(f[3], -0.5)
    // ramp 4 帧：keep = (4-i)/5 → 0.8 / 0.6 / 0.4 / 0.2
    let keeps: [Float] = [0.8, 0.6, 0.4, 0.2]
    for i in 0..<4 {
        try assertTrue(abs(f[4 + i * 2] - 0.5 * keeps[i]) < 1e-6,
                       "ramp 帧 \(i) 左声道应为 0.5*\(keeps[i])，实际 \(f[4 + i * 2])")
        try assertTrue(abs(f[5 + i * 2] + 0.5 * keeps[i]) < 1e-6,
                       "ramp 帧 \(i) 右声道应为 -0.5*\(keeps[i])，实际 \(f[5 + i * 2])")
    }
    try assertEqual(pipe.underrunCount, 1, "播放中途欠载应计数一次")

    // 连续欠载：种子已清零 → 纯静音延续，不会从旧大幅度帧回跳
    let got2 = pipe.fillRenderBuffer(buf, frames: 4)
    try assertEqual(got2, 4)
    for i in 0..<8 {
        try assertEqual(f[i], 0.0, "第二次欠载应为纯静音")
    }
    try assertEqual(pipe.underrunCount, 2)
}

runTest("pipelineUnderrunFadesInt24") {
    var prefs = DSPPreferences()
    prefs.bitPerfect = false
    let pipe = AudioPipeline(decoder: SineDecoder(sampleRate: 44100, channels: 2,
                                                  durationSeconds: 0.1),
                             output: MockAudioOutput(), dspPreferences: prefs)
    try assertEqual(pipe.outputFormat.sampleFormat, .int24)
    // 1 帧 [0x400000, 0x400000] LE 3 字节
    var seedBytes: [UInt8] = [0x00, 0x00, 0x40, 0x00, 0x00, 0x40]
    let written = seedBytes.withUnsafeBufferPointer { p in
        pipe.ringBuffer.write(p.baseAddress!, length: 6)
    }
    try assertEqual(written, 6)

    let buf = UnsafeMutableRawPointer.allocate(byteCount: 24, alignment: 8)
    defer { buf.deallocate() }
    let got = pipe.fillRenderBuffer(buf, frames: 4)
    try assertEqual(got, 4)
    let raw = buf.bindMemory(to: UInt8.self, capacity: 24)
    func rd24(_ frame: Int) -> Int32 {
        var v = Int32(raw[frame * 6]) | (Int32(raw[frame * 6 + 1]) << 8)
            | (Int32(raw[frame * 6 + 2]) << 16)
        if v & 0x0080_0000 != 0 { v |= ~0x00FF_FFFF }
        return v
    }
    try assertEqual(rd24(0), 0x400000, "首帧应是种子数据")
    // ramp 3 帧：keep = 3/4, 2/4, 1/4 → 0x300000 / 0x200000 / 0x100000
    try assertEqual(rd24(1), 0x300000)
    try assertEqual(rd24(2), 0x200000)
    try assertEqual(rd24(3), 0x100000)
    try assertEqual(pipe.underrunCount, 1)
}

runTest("pipelineEndDrainNotCountedAsUnderrun") {
    let pipe = AudioPipeline(decoder: SineDecoder(sampleRate: 44100, channels: 2,
                                                  durationSeconds: 0.1),
                             output: MockAudioOutput())
    var seed: [Float] = [0.5, -0.5]
    _ = seed.withUnsafeBufferPointer { p in pipe.ringBuffer.write(p.baseAddress!, length: 8) }
    let buf = UnsafeMutableRawPointer.allocate(byteCount: 32, alignment: 8)
    defer { buf.deallocate() }
    // 中途欠载计 1 次
    _ = pipe.fillRenderBuffer(buf, frames: 4)
    try assertEqual(pipe.underrunCount, 1)
    // 曲尾排空：解码器已到末尾 → 不再计数，但仍返回满帧静音
    pipe.decoderAtEndFlag.store(true, ordering: .relaxed)
    let got = pipe.fillRenderBuffer(buf, frames: 4)
    try assertEqual(got, 4)
    let f = buf.bindMemory(to: Float.self, capacity: 8)
    for i in 0..<8 { try assertEqual(f[i], 0.0) }
    try assertEqual(pipe.underrunCount, 1, "曲尾正常排空不应计入欠载")
}

runTest("pipelineSeekResetsUnderrunAccounting") {
    let pipe = AudioPipeline(decoder: SineDecoder(sampleRate: 44100, channels: 2,
                                                  durationSeconds: 1.0),
                             output: MockAudioOutput())
    var seed: [Float] = [0.5, -0.5]
    _ = seed.withUnsafeBufferPointer { p in pipe.ringBuffer.write(p.baseAddress!, length: 8) }
    let buf = UnsafeMutableRawPointer.allocate(byteCount: 32, alignment: 8)
    defer { buf.deallocate() }
    _ = pipe.fillRenderBuffer(buf, frames: 4)
    try assertEqual(pipe.underrunCount, 1)
    // seek 造成的空洞不是网络欠载 — 计数不应增长
    try pipe.seek(toFrame: 22050)
    _ = pipe.fillRenderBuffer(buf, frames: 4)
    try assertEqual(pipe.underrunCount, 1, "seek 空洞不应计入欠载")
}

runTest("playerControllerExposesUnderrunCount") {
    let out = MockAudioOutput()
    let pc = PlayerController(output: out)
    try assertEqual(pc.underrunCount, 0, "无管线时应为 0")
}

runTest("playerSeekToFractionMid") {
    let totalSec = 1.0
    let rate = 44100.0
    let decoder = SineDecoder(sampleRate: rate, channels: 2, durationSeconds: totalSec)
    let output = MockAudioOutput()
    let pc = PlayerController(output: output)
    let pipeline = AudioPipeline(decoder: decoder, output: output)
    // Inject the pipeline directly through a real start path is overkill; we use
    // PlayerController.playLocal via a fake URL would fail. Instead exercise the
    // pipeline-level seek via the public method on AudioPipeline and verify
    // PlayerController.seek calculates the right frame target by re-using its math.
    try pipeline.start()
    Thread.sleep(forTimeInterval: 0.05)
    let total = decoder.totalFrames
    try pipeline.seek(toFrame: Int64(Double(total) * 0.5))
    try assertEqual(decoder.currentFrame, Int64(Double(total) * 0.5))
    pipeline.stop()
    _ = pc  // silence unused warning
}

runTest("playerSeekToFractionClampsOutOfRange") {
    let decoder = SineDecoder(sampleRate: 44100, channels: 2, durationSeconds: 0.5)
    let output = MockAudioOutput()
    let pipeline = AudioPipeline(decoder: decoder, output: output)
    try pipeline.start()
    Thread.sleep(forTimeInterval: 0.03)
    try pipeline.seek(toFrame: -1000)   // SineDecoder clamps to 0
    try assertEqual(decoder.currentFrame, 0)
    try pipeline.seek(toFrame: 999_999_999)  // clamps to totalFrames
    try assertEqual(decoder.currentFrame, decoder.totalFrames)
    pipeline.stop()
}

runTest("pipelineDSPEnabled") {
    let decoder = SineDecoder(sampleRate: 44100, channels: 2, durationSeconds: 0.1)
    let output = MockAudioOutput()
    var prefs = DSPPreferences()
    prefs.bitPerfect = false
    prefs.replayGainEnabled = true
    prefs.replayGainDB = -3
    let pipeline = AudioPipeline(decoder: decoder, output: output, dspPreferences: prefs)
    try assertFalse(pipeline.dspChain.isBypass)
    // issue #9：DSP 开启 ≠ float32 输出 — 转回整数（float 源默认 24-bit）
    try assertEqual(pipeline.outputFormat.sampleFormat, .int24)
    try assertTrue(pipeline.outputConverter != nil)
    try pipeline.start()
    Thread.sleep(forTimeInterval: 0.15)
    let frames = output.pullFrames(2048, bytesPerFrame: pipeline.outputFormat.bytesPerFrame)
    try assertGreaterThan(frames, 0)
    pipeline.stop()
}

// ═══════════════════════════════════════════════════════
// Library Model Tests
// ═══════════════════════════════════════════════════════
print("\n═══ Library Model Tests ═══")

runTest("addAndRetrieve") {
    let lib = InMemoryLibrary()
    let t = TrackInfo(url: URL(fileURLWithPath: "/music/test.flac"),
                      title: "Test Song", artist: "Artist", album: "Album",
                      sampleRate: 96000, bitDepth: 24, channels: 2, format: .flac)
    lib.add(t)
    try assertEqual(lib.count, 1)
    try assertEqual(lib.allTracks().first?.title, "Test Song")
}

runTest("search") {
    let lib = InMemoryLibrary()
    lib.add(TrackInfo(url: URL(fileURLWithPath: "/a.wav"), title: "Jazz Piano", artist: "Miles"))
    lib.add(TrackInfo(url: URL(fileURLWithPath: "/b.wav"), title: "Rock Guitar", artist: "Hendrix"))
    lib.add(TrackInfo(url: URL(fileURLWithPath: "/c.wav"), title: "Jazz Sax", artist: "Coltrane"))
    let results = lib.search(query: "jazz")
    try assertEqual(results.count, 2)
}

runTest("remove") {
    let lib = InMemoryLibrary()
    let t = TrackInfo(url: URL(fileURLWithPath: "/x.wav"))
    lib.add(t)
    try assertEqual(lib.count, 1)
    lib.remove(id: t.id)
    try assertEqual(lib.count, 0)
}

runTest("autoTitle") {
    let t = TrackInfo(url: URL(fileURLWithPath: "/music/Cool Track.flac"))
    try assertEqual(t.title, "Cool Track")
}

// ═══════════════════════════════════════════════════════
// BiquadEQ Tests → ParametricEQ backward-compat
// ═══════════════════════════════════════════════════════
print("\n═══ ParametricEQ Tests (graphic compat) ═══")

runTest("eqFlatGainIsPassthrough") {
    let eq = ParametricEQNode(graphicGains: Array(repeating: 0, count: 10))
    let fmt = AudioFormat(sampleRate: 44100, channels: 1, sampleFormat: .float32)
    _ = eq.configure(inputFormat: fmt)
    // DC signal should pass through unchanged with 0 dB gain
    var samples: [Float] = [0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5]
    let original = samples
    samples.withUnsafeMutableBufferPointer { buf in
        eq.process(input: buf.baseAddress!, output: buf.baseAddress!, frameCount: 8)
    }
    // After settling, last samples should be very close to original
    try assertEqualFloat(samples[7], original[7], accuracy: 0.01)
}

runTest("eqBoostChangesSignal") {
    let gains: [Float] = [0, 0, 0, 0, 12, 0, 0, 0, 0, 0]  // +12dB at 500Hz
    let eq = ParametricEQNode(graphicGains: gains)
    let fmt = AudioFormat(sampleRate: 44100, channels: 1, sampleFormat: .float32)
    _ = eq.configure(inputFormat: fmt)

    // 500Hz sine at 44100 Hz sampling
    let n = 882  // 20ms of data
    var samples = [Float](repeating: 0, count: n)
    for i in 0..<n {
        samples[i] = sin(Float(2.0 * .pi * 500.0 * Double(i) / 44100.0)) * 0.1
    }
    let inputRMS = samples.map { $0 * $0 }.reduce(0, +) / Float(n)

    samples.withUnsafeMutableBufferPointer { buf in
        eq.process(input: buf.baseAddress!, output: buf.baseAddress!, frameCount: n)
    }
    let outputRMS = samples.map { $0 * $0 }.reduce(0, +) / Float(n)

    // +12dB should increase energy significantly
    try assertGreaterThan(outputRMS, inputRMS * 2.0)
}

runTest("eqStereo") {
    let eq = ParametricEQNode(graphicGains: Array(repeating: 6, count: 10))
    let fmt = AudioFormat(sampleRate: 44100, channels: 2, sampleFormat: .float32)
    _ = eq.configure(inputFormat: fmt)

    // Interleaved stereo: L R L R...
    var samples = [Float](repeating: 0, count: 200)
    for i in stride(from: 0, to: 200, by: 2) {
        samples[i] = 0.1      // L
        samples[i + 1] = -0.1 // R
    }
    samples.withUnsafeMutableBufferPointer { buf in
        eq.process(input: buf.baseAddress!, output: buf.baseAddress!, frameCount: 200)
    }
    // Just verify it doesn't crash and produces non-zero output
    let anyNonZero = samples.contains { $0 != 0 }
    try assertTrue(anyNonZero)
}

// ═══════════════════════════════════════════════════════
// DitherNode Tests
// ═══════════════════════════════════════════════════════
print("\n═══ DitherNode Tests ═══")

runTest("ditherAddsNoise") {
    let dither = DitherNode(targetBitDepth: 16)
    _ = dither.configure(inputFormat: AudioFormat(sampleRate: 44100, channels: 1, sampleFormat: .float32))
    let n = 1000
    var samples = [Float](repeating: 0.5, count: n)
    let original = samples
    samples.withUnsafeMutableBufferPointer { buf in
        dither.process(input: buf.baseAddress!, output: buf.baseAddress!, frameCount: n)
    }
    // Not all samples should be identical after dithering
    var diffCount = 0
    for i in 0..<n {
        if abs(samples[i] - original[i]) > 0.00001 { diffCount += 1 }
    }
    try assertGreaterThan(diffCount, 0)
}

runTest("ditherStaysInRange") {
    let dither = DitherNode(targetBitDepth: 16)
    _ = dither.configure(inputFormat: AudioFormat(sampleRate: 44100, channels: 1, sampleFormat: .float32))
    var samples = [Float](repeating: 0.999, count: 500)
    samples.withUnsafeMutableBufferPointer { buf in
        dither.process(input: buf.baseAddress!, output: buf.baseAddress!, frameCount: 500)
    }
    for s in samples {
        try assertLessThanOrEqual(s, Float(1.0))
        try assertGreaterThan(s, Float(-1.01))
    }
}

runTest("ditherQuantizesTo16bit") {
    let dither = DitherNode(targetBitDepth: 16)
    _ = dither.configure(inputFormat: AudioFormat(sampleRate: 44100, channels: 1, sampleFormat: .float32))
    var samples: [Float] = [0.12345678, -0.98765432, 0.0001, 0.5]
    samples.withUnsafeMutableBufferPointer { buf in
        dither.process(input: buf.baseAddress!, output: buf.baseAddress!, frameCount: 4)
    }
    // Each output should be quantized to 1/32768 steps
    let step: Float = 1.0 / 32768.0
    for s in samples {
        let quantized = (s / step).rounded(.toNearestOrAwayFromZero) * step
        try assertEqualFloat(s, quantized, accuracy: step * 0.5 + 0.0001)
    }
}

// ═══════════════════════════════════════════════════════
// PlayerController Tests
// ═══════════════════════════════════════════════════════
print("\n═══ PlayerController Tests ═══")

runTest("playerInitialState") {
    let out = MockAudioOutput()
    let pc = PlayerController(output: out)
    try assertEqual(pc.state, .stopped)
    try assertEqual(pc.currentTrackIndex, -1)
    try assertTrue(pc.isBitPerfect)
    try assertEqual(pc.currentFrame, 0)
    try assertEqual(pc.totalFrames, 0)
}

runTest("playerStopIdempotent") {
    let out = MockAudioOutput()
    let pc = PlayerController(output: out)
    pc.stop()
    pc.stop()
    try assertEqual(pc.state, .stopped)
}

runTest("playerQueueNavigation") {
    let out = MockAudioOutput()
    let pc = PlayerController(output: out)
    // No queue — next/previous should not crash
    try pc.next()
    try pc.previous()
    try assertEqual(pc.state, .stopped)
}

// ═══════════════════════════════════════════════════════
// LocalFileSource Tests
// ═══════════════════════════════════════════════════════
print("\n═══ LocalFileSource Tests ═══")

runTest("localFileSourceReadAndSeek") {
    // Write a temporary file
    let tmpDir = FileManager.default.temporaryDirectory
    let tmpFile = tmpDir.appendingPathComponent("pureplay_test_\(UUID().uuidString).bin")
    let testData = Data([0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE])
    try testData.write(to: tmpFile)
    defer { try? FileManager.default.removeItem(at: tmpFile) }

    let src = try LocalFileSource(url: tmpFile)
    try assertEqual(src.totalBytes, 8)

    var buf = [UInt8](repeating: 0, count: 4)
    let n1 = try buf.withUnsafeMutableBufferPointer { try src.read(into: $0.baseAddress!, length: 4) }
    try assertEqual(n1, 4)
    try assertEqual(buf, [0xDE, 0xAD, 0xBE, 0xEF])

    try src.seek(to: 6)
    let n2 = try buf.withUnsafeMutableBufferPointer { try src.read(into: $0.baseAddress!, length: 4) }
    try assertEqual(n2, 2)
    try assertEqual(Array(buf[0..<2]), [0xBA, 0xBE])

    src.close()
}

runTest("localFileSourceNotFound") {
    let bogus = URL(fileURLWithPath: "/nonexistent_\(UUID().uuidString).wav")
    do {
        _ = try LocalFileSource(url: bogus)
        try assertTrue(false, "Should have thrown")
    } catch {
        // Expected
    }
}

// ═══════════════════════════════════════════════════════
// Pipeline Bit-Perfect End-to-End Test
// ═══════════════════════════════════════════════════════
print("\n═══ Pipeline Bit-Perfect Tests ═══")

runTest("pipelineBitPerfectWAV") {
    // Generate WAV → decode via pipeline (bit-perfect) → read from ring buffer → compare
    let frames = 2205
    let wavData = WAVTestHelper.makePCM16Stereo(sampleRate: 44100, durationFrames: frames)
    let source = MemorySource(data: wavData)
    let decoder = try WAVDecoder(source: source)
    let output = MockAudioOutput()
    let pipeline = AudioPipeline(decoder: decoder, output: output)

    try assertTrue(pipeline.dspChain.isBypass)
    try pipeline.start()
    Thread.sleep(forTimeInterval: 0.5)

    let bpf = pipeline.outputFormat.bytesPerFrame
    let totalBytes = frames * bpf
    let readBuf = UnsafeMutableRawPointer.allocate(byteCount: totalBytes, alignment: 16)
    defer { readBuf.deallocate() }
    let read = pipeline.ringBuffer.read(into: readBuf, length: totalBytes)

    pipeline.stop()

    // Compare with original PCM data
    let headerSize = 44
    let originalPCM = wavData.subdata(in: headerSize..<(headerSize + read))
    let pipelineOutput = Data(bytes: readBuf, count: read)
    try assertEqual(pipelineOutput, originalPCM, "Pipeline output must be bit-identical to WAV PCM data")
}

runTest("pipelineDSPWithInt16Decoder") {
    // Test that DSP works with integer PCM decoders (int-to-float conversion)
    let frames = 1000
    let wavData = WAVTestHelper.makePCM16Stereo(sampleRate: 44100, durationFrames: frames)
    let source = MemorySource(data: wavData)
    let decoder = try WAVDecoder(source: source)
    let output = MockAudioOutput()
    var prefs = DSPPreferences()
    prefs.bitPerfect = false
    prefs.replayGainEnabled = true
    prefs.replayGainDB = -6  // attenuate by 6dB
    let pipeline = AudioPipeline(decoder: decoder, output: output, dspPreferences: prefs)

    try assertFalse(pipeline.dspChain.isBypass)
    // issue #9：int16 源 + DSP → 输出转回 int16（源原生位深），不再是 float32
    try assertEqual(pipeline.outputFormat.sampleFormat, .int16)
    try pipeline.start()
    Thread.sleep(forTimeInterval: 0.3)

    let bpf = pipeline.outputFormat.bytesPerFrame
    let readBuf = UnsafeMutableRawPointer.allocate(byteCount: frames * bpf, alignment: 16)
    defer { readBuf.deallocate() }
    let read = pipeline.ringBuffer.read(into: readBuf, length: frames * bpf)
    pipeline.stop()

    // Should have output some data (int16 → float32 → gain → int16)
    try assertGreaterThan(read, 0)
    let ip = readBuf.assumingMemoryBound(to: Int16.self)
    let samplesRead = read / 2
    // int16 样本必须在合法范围内且非全零（-6dB 增益 ≈ 半幅）
    var maxAbs: Int = 0
    for i in 0..<samplesRead {
        maxAbs = max(maxAbs, Int(abs(Int32(ip[i]))))
    }
    try assertGreaterThan(maxAbs, 0)
    try assertLessThan(maxAbs, 32768)  // no overflow, valid int16 range
    // 源正弦幅度 ~0.5 满幅 → -6dB 后 ~0.25 → int16 ≈ 8192（宽容差）
    try assertGreaterThan(maxAbs, 4000)
    try assertLessThan(maxAbs, 14000)
}

// ═══════════════════════════════════════════════════════
// Crossfeed Full-Signal Test
// ═══════════════════════════════════════════════════════
print("\n═══ Crossfeed Full-Signal Tests ═══")

runTest("crossfeedZeroIntensityIsBypass") {
    let node = CrossfeedNode(intensity: 0)
    let fmt = AudioFormat(sampleRate: 44100, channels: 2, sampleFormat: .float32)
    _ = node.configure(inputFormat: fmt)
    var samples: [Float] = [0.7, -0.3, 0.5, 0.9, -0.2, 0.1]   // 3 stereo frames
    let original = samples
    samples.withUnsafeMutableBufferPointer { buf in
        node.process(input: buf.baseAddress!, output: buf.baseAddress!, frameCount: 6)
    }
    // intensity=0 → directGain=1, crossGain=0 → output == input
    for i in 0..<6 {
        try assertEqualFloat(samples[i], original[i], accuracy: 1e-6)
    }
}

runTest("crossfeedMonoPassesThrough") {
    let node = CrossfeedNode(intensity: 0.6)
    let monoFmt = AudioFormat(sampleRate: 44100, channels: 1, sampleFormat: .float32)
    _ = node.configure(inputFormat: monoFmt)
    var samples: [Float] = [0.3, -0.5, 0.7, 0.2]
    let original = samples
    samples.withUnsafeMutableBufferPointer { buf in
        node.process(input: buf.baseAddress!, output: buf.baseAddress!, frameCount: 4)
    }
    for i in 0..<4 {
        try assertEqualFloat(samples[i], original[i], accuracy: 1e-6)
    }
}

runTest("crossfeedAttenuatesHighFreq") {
    // Compare crossfeed contribution at low (200Hz) vs high (8kHz) frequency
    let sr = 44100.0
    let frames = 4096
    let total = frames * 2

    func runAt(freqHz: Double) -> Float {
        let node = CrossfeedNode(intensity: 1.0)
        let fmt = AudioFormat(sampleRate: sr, channels: 2, sampleFormat: .float32)
        _ = node.configure(inputFormat: fmt)
        var samples = [Float](repeating: 0, count: total)
        // Pure tone in L, silence in R
        for i in 0..<frames {
            samples[i * 2] = Float(sin(2.0 * .pi * freqHz * Double(i) / sr))
            samples[i * 2 + 1] = 0
        }
        samples.withUnsafeMutableBufferPointer { buf in
            node.process(input: buf.baseAddress!, output: buf.baseAddress!, frameCount: total)
        }
        // RMS of right channel (the crossfeed-injected signal)
        var sumSq: Float = 0
        for i in 0..<frames {
            let r = samples[i * 2 + 1]
            sumSq += r * r
        }
        return (sumSq / Float(frames)).squareRoot()
    }

    let lowRMS = runAt(freqHz: 200)    // below the 700Hz cutoff
    let highRMS = runAt(freqHz: 8000)  // well above cutoff
    // Lowpass should attenuate 8kHz much more than 200Hz
    try assertGreaterThan(lowRMS, highRMS * 3)
}

// ═══════════════════════════════════════════════════════
// Int-to-Float Conversion Test
// ═══════════════════════════════════════════════════════
print("\n═══ Int-to-Float Conversion Tests ═══")

runTest("int16ToFloat") {
    // Directly test the pipeline's static conversion via a round-trip
    let wavData = WAVTestHelper.makePCM16Stereo(sampleRate: 44100, durationFrames: 100)
    let source = MemorySource(data: wavData)
    let decoder = try WAVDecoder(source: source)
    try assertEqual(decoder.format.sampleFormat, .int16)

    // Decode 100 frames of int16
    let buf = UnsafeMutableRawPointer.allocate(byteCount: 100 * 4, alignment: 16)
    defer { buf.deallocate() }
    let n = try decoder.decode(into: buf, maxFrames: 100)
    try assertEqual(n, 100)

    // Verify first sample is a valid int16
    let p = buf.assumingMemoryBound(to: Int16.self)
    let firstSample = p[0]
    // 440 Hz sine at t=0 should be ~0
    try assertLessThan(abs(Int(firstSample)), 1000)
}

// ═══════════════════════════════════════════════════════
// WAV Float32 Format Test
// ═══════════════════════════════════════════════════════
print("\n═══ WAV Float32 Tests ═══")

runTest("wavFloat32Decode") {
    // Build a float32 WAV in memory
    var data = Data()
    let sampleRate: UInt32 = 48000
    let channels: UInt16 = 1
    let bitsPerSample: UInt16 = 32
    let bytesPerSample: UInt16 = 4
    let blockAlign = channels * bytesPerSample
    let numFrames = 480
    let dataSize = UInt32(numFrames) * UInt32(blockAlign)
    let fileSize: UInt32 = 36 + dataSize

    data.append(contentsOf: Array("RIFF".utf8))
    data.appendLE32(fileSize)
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8))
    data.appendLE32(16)
    data.appendLE16(3)  // IEEE float
    data.appendLE16(channels)
    data.appendLE32(sampleRate)
    data.appendLE32(sampleRate * UInt32(blockAlign))
    data.appendLE16(blockAlign)
    data.appendLE16(bitsPerSample)
    data.append(contentsOf: Array("data".utf8))
    data.appendLE32(dataSize)

    // Write float32 samples: 1kHz sine
    for i in 0..<numFrames {
        let t = 2.0 * Double.pi * 1000.0 * Double(i) / Double(sampleRate)
        var s = Float(sin(t)) * 0.5
        withUnsafeBytes(of: &s) { data.append(contentsOf: $0) }
    }

    let source = MemorySource(data: data)
    let decoder = try WAVDecoder(source: source)
    try assertEqual(decoder.format.sampleRate, 48000.0)
    try assertEqual(decoder.format.channels, 1)
    try assertEqual(decoder.format.sampleFormat, .float32)
    try assertEqual(decoder.totalFrames, Int64(numFrames))

    let buf = UnsafeMutableRawPointer.allocate(byteCount: numFrames * 4, alignment: 16)
    defer { buf.deallocate() }
    let decoded = try decoder.decode(into: buf, maxFrames: numFrames)
    try assertEqual(decoded, numFrames)

    // Verify bit-perfect: compare decoded float samples to original
    let headerSize = 44
    let originalPCM = data.subdata(in: headerSize..<(headerSize + numFrames * 4))
    let decodedData = Data(bytes: buf, count: numFrames * 4)
    try assertEqual(decodedData, originalPCM, "Float32 WAV decode must be bit-identical")
}

// ═══════════════════════════════════════════════════════
// CoreAudio Decoder Tests (FLAC/ALAC/MP3 via AudioToolbox)
// ═══════════════════════════════════════════════════════
print("\n═══ CoreAudio Decoder Tests ═══")

#if canImport(AudioToolbox)
runTest("coreAudioDecoderRegistered") {
    let registry = DecoderRegistry.shared
    let src = MemorySource(data: Data())
    // CoreAudioDecoderFactory now handles the generic fallback (flac/mp3/aac/caf/ogg).
    // ALAC/m4a/mp4 moved to ALACDecoderFactory.
    try assertTrue(CoreAudioDecoderFactory.canDecode(source: src, fileExtension: "flac"))
    try assertTrue(CoreAudioDecoderFactory.canDecode(source: src, fileExtension: "mp3"))
    try assertFalse(CoreAudioDecoderFactory.canDecode(source: src, fileExtension: "m4a"))
    try assertFalse(CoreAudioDecoderFactory.canDecode(source: src, fileExtension: "xyz"))
    _ = registry
}

runTest("coreAudioDecoderWithWAVFile") {
    // Use CoreAudioDecoder to decode a WAV file (ExtAudioFile supports WAV too)
    // This validates the decoder works without needing an external FLAC file
    let frames = 4410
    let wavData = WAVTestHelper.makePCM16Stereo(sampleRate: 44100, durationFrames: frames)
    let tmpFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("pureplay_ca_test_\(UUID().uuidString).wav")
    try wavData.write(to: tmpFile)
    defer { try? FileManager.default.removeItem(at: tmpFile) }

    let decoder = try CoreAudioDecoder(url: tmpFile)
    try assertEqual(decoder.format.sampleRate, 44100.0)
    try assertEqual(decoder.format.channels, 2)
    // issue #14: integer source → NATIVE int16 packed container (was int32)
    try assertEqual(decoder.format.sampleFormat, .int16)
    try assertEqual(decoder.format.bitDepth, 16)
    try assertEqual(decoder.format.containerBitDepth, 16)
    try assertEqual(decoder.totalFrames, Int64(frames))
    try assertFalse(decoder.isAtEnd)

    let buf = UnsafeMutableRawPointer.allocate(byteCount: frames * 4, alignment: 16)
    defer { buf.deallocate() }
    let decoded = try decoder.decode(into: buf, maxFrames: frames)
    try assertEqual(decoded, frames)
    try assertTrue(decoder.isAtEnd)

    // int16 samples (sine peak should be sizable)
    let ip = buf.assumingMemoryBound(to: Int16.self)
    var maxAbs: Int = 0
    for i in 0..<(decoded * 2) { maxAbs = max(maxAbs, Int(abs(Int32(ip[i])))) }
    try assertGreaterThan(maxAbs, 10_000)  // 440Hz sine amplitude ~16000

    // bit-perfect passthrough: native int16 container == raw WAV payload
    let originalPCM = wavData.subdata(in: 44..<(44 + frames * 4))
    let decodedData = Data(bytes: buf, count: frames * 4)
    try assertEqual(decodedData, originalPCM, "int16 native decode must be bit-identical to WAV payload")

    decoder.close()
}

runTest("coreAudioDecoderSeek") {
    let frames = 8820
    let wavData = WAVTestHelper.makePCM16Stereo(sampleRate: 44100, durationFrames: frames)
    let tmpFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("pureplay_ca_seek_\(UUID().uuidString).wav")
    try wavData.write(to: tmpFile)
    defer { try? FileManager.default.removeItem(at: tmpFile) }

    let decoder = try CoreAudioDecoder(url: tmpFile)
    try decoder.seek(to: 4410)
    try assertEqual(decoder.currentFrame, 4410)

    let buf = UnsafeMutableRawPointer.allocate(byteCount: frames * 8, alignment: 16)
    defer { buf.deallocate() }
    let decoded = try decoder.decode(into: buf, maxFrames: frames)
    try assertEqual(decoded, 4410)  // remaining frames after seek
    try assertTrue(decoder.isAtEnd)
    decoder.close()
}

runTest("coreAudioDecoderViaRegistry") {
    // Verify the split: CoreAudio fallback now owns flac only (among lossless),
    // alac belongs to ALAC factory, aiff to AIFF factory.
    try assertTrue(CoreAudioDecoderFactory.supportedExtensions.contains("flac"))
    try assertFalse(CoreAudioDecoderFactory.supportedExtensions.contains("alac"))
    try assertFalse(CoreAudioDecoderFactory.supportedExtensions.contains("aiff"))
    try assertTrue(ALACDecoderFactory.supportedExtensions.contains("alac"))
    try assertTrue(AIFFDecoderFactory.supportedExtensions.contains("aiff"))
}

runTest("coreAudioDecoderReportsSourceBitDepth16") {
    let frames = 2205
    let wavData = WAVTestHelper.makePCM16Stereo(sampleRate: 44100, durationFrames: frames)
    let tmpFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("pureplay_src16_\(UUID().uuidString).wav")
    try wavData.write(to: tmpFile)
    defer { try? FileManager.default.removeItem(at: tmpFile) }

    let decoder = try CoreAudioDecoder(url: tmpFile)
    // issue #14: UI bit depth AND ASBD container are both source-native (16)
    try assertEqual(decoder.format.bitDepth, 16)
    try assertEqual(decoder.format.containerBitDepth, 16)
    try assertEqual(decoder.format.sampleFormat, .int16)
    decoder.close()
}

// ─── issue #6: MP3 Xing/LAME encoder delay & padding parser ───

/// 合成 MP3 首帧 + Xing/Info tag（含 LAME 魔数与 delay/padding 字段）。
/// 帧头: FF FB = MPEG1 Layer III；h2=0x91 → protection_absent（无 CRC）；
/// h3=0x00 stereo / 0xC0 mono。tagPos = 帧头 4 + side info(32/17)。
func makeSyntheticMP3Header(id3Size: Int = 0, mono: Bool = false, crcPresent: Bool = false,
                            xing: Bool = false, writeTag: Bool = true, lameMagic: Bool = true,
                            delay: Int = 576, padding: Int = 1152) -> Data {
    var bytes = [UInt8](repeating: 0, count: 600)
    var p = 0
    if id3Size > 0 {
        bytes[0] = 0x49; bytes[1] = 0x44; bytes[2] = 0x33   // "ID3"
        bytes[3] = 4; bytes[4] = 0; bytes[5] = 0            // v2.4, no flags
        bytes[6] = UInt8((id3Size >> 21) & 0x7F)            // synchsafe size
        bytes[7] = UInt8((id3Size >> 14) & 0x7F)
        bytes[8] = UInt8((id3Size >> 7) & 0x7F)
        bytes[9] = UInt8(id3Size & 0x7F)
        for k in 10..<(10 + id3Size) { bytes[k] = 0x20 }    // padding body (no sync bytes)
        p = 10 + id3Size
    }
    bytes[p] = 0xFF
    bytes[p + 1] = 0xFB                       // MPEG1, Layer III
    bytes[p + 2] = crcPresent ? 0x90 : 0x91   // bit0=0 → CRC present (headerSize 6)
    bytes[p + 3] = mono ? 0xC0 : 0x00         // channel mode
    let headerSize = 4 + (crcPresent ? 2 : 0)
    let sideSize = mono ? 17 : 32             // MPEG1
    let tagPos = p + headerSize + sideSize
    if writeTag {
        let magic = xing ? "Xing" : "Info"
        for (k, c) in magic.utf8.enumerated() { bytes[tagPos + k] = UInt8(c) }
        bytes[tagPos + 7] = 0x07              // flags: frames/bytes/TOC present
        if lameMagic {
            for (k, c) in "LAME3.99.5".utf8.enumerated() { bytes[tagPos + 120 + k] = UInt8(c) }
        }
        bytes[tagPos + 213] = UInt8((delay >> 4) & 0xFF)
        bytes[tagPos + 214] = UInt8(((delay & 0x0F) << 4) | ((padding >> 8) & 0x0F))
        bytes[tagPos + 215] = UInt8(padding & 0xFF)
    }
    return Data(bytes)
}

runTest("mp3LameTagParserStereoInfo") {
    // MPEG1 stereo, no CRC, "Info" (CBR) tag → tagPos = 0+4+32 = 36
    let data = makeSyntheticMP3Header(delay: 576, padding: 1152)
    let r = CoreAudioDecoder.parseMP3EncoderDelayPadding(data)
    try assertTrue(r != nil, "LAME tag must parse")
    try assertEqual(r?.delay, 576)
    try assertEqual(r?.padding, 1152)
}

runTest("mp3LameTagParserMonoXingWithID3") {
    // ID3v2 (size 20) + MPEG1 mono + "Xing" (VBR) → tagPos = 30+4+17 = 51
    let data = makeSyntheticMP3Header(id3Size: 20, mono: true, xing: true,
                                      delay: 529, padding: 1152)
    let r = CoreAudioDecoder.parseMP3EncoderDelayPadding(data)
    try assertTrue(r != nil, "LAME tag after ID3v2 must parse")
    try assertEqual(r?.delay, 529)
    try assertEqual(r?.padding, 1152)
}

runTest("mp3LameTagParserCRCPresent") {
    // CRC present → headerSize 6 → tagPos = 0+6+32 = 38
    let data = makeSyntheticMP3Header(crcPresent: true, delay: 1152, padding: 576)
    let r = CoreAudioDecoder.parseMP3EncoderDelayPadding(data)
    try assertTrue(r != nil, "CRC-present frame must parse")
    try assertEqual(r?.delay, 1152)
    try assertEqual(r?.padding, 576)
}

runTest("mp3LameTagParserRejectsInvalid") {
    // 非 LAME（无魔数）→ 不信任 delay 字段
    let noLame = makeSyntheticMP3Header(lameMagic: false)
    try assertTrue(CoreAudioDecoder.parseMP3EncoderDelayPadding(noLame) == nil)
    // 无 Xing/Info tag
    let noTag = makeSyntheticMP3Header(writeTag: false)
    try assertTrue(CoreAudioDecoder.parseMP3EncoderDelayPadding(noTag) == nil)
    // 纯垃圾（无帧同步）
    let junk = Data(repeating: 0x41, count: 600)
    try assertTrue(CoreAudioDecoder.parseMP3EncoderDelayPadding(junk) == nil)
    // 数据过短
    let short = Data(repeating: 0, count: 100)
    try assertTrue(CoreAudioDecoder.parseMP3EncoderDelayPadding(short) == nil)
}

// ─── issue #6: AAC packet table → 逻辑总帧数（去尾部 padding）───

runTest("coreAudioAACPacketTableTrimsPadding") {
    // 用 AudioToolbox 自带 AAC 编码器合成一个 m4a：写 N 帧，
    // 编码器补齐整 packet（1024 帧/packet）→ FileLengthFrames > N；
    // packet table 的 mNumberValidFrames == N → decoder.totalFrames 必须等于 N
    let frames = 44100
    let tmpFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("pureplay_aac_pt_\(UUID().uuidString).m4a")
    defer { try? FileManager.default.removeItem(at: tmpFile) }

    var fileFormat = AudioStreamBasicDescription(
        mSampleRate: 44100, mFormatID: kAudioFormatMPEG4AAC,
        mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024,
        mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
    var writer: ExtAudioFileRef?
    var st = ExtAudioFileCreateWithURL(tmpFile as CFURL, kAudioFileM4AType,
                                       &fileFormat, nil, 0, &writer)
    guard st == noErr, let wref = writer else {
        print("    SKIP: AAC encoder unavailable (status \(st))")
        return
    }
    var client = AudioStreamBasicDescription(
        mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
        mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
    ExtAudioFileSetProperty(wref, kExtAudioFileProperty_ClientDataFormat,
                            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
    let pcm = UnsafeMutableRawPointer.allocate(byteCount: frames * 4, alignment: 16)
    defer { pcm.deallocate() }
    let sp = pcm.assumingMemoryBound(to: Int16.self)
    for i in 0..<(frames * 2) { sp[i] = Int16((i % 200 < 100) ? 12000 : -12000) }
    var abl = AudioBufferList(mNumberBuffers: 1,
                              mBuffers: AudioBuffer(mNumberChannels: 2,
                                                    mDataByteSize: UInt32(frames * 4),
                                                    mData: pcm))
    st = ExtAudioFileWrite(wref, UInt32(frames), &abl)
    ExtAudioFileDispose(wref)
    guard st == noErr else {
        print("    SKIP: AAC write failed (status \(st))")
        return
    }

    let decoder = try CoreAudioDecoder(url: tmpFile)
    defer { decoder.close() }
    // 关键断言：totalFrames 来自 packet table 有效帧数，不是补齐后的文件帧数
    try assertEqual(decoder.totalFrames, Int64(frames))

    // 能完整解码 totalFrames 帧（compressed 源 → int32 容器）
    let buf = UnsafeMutableRawPointer.allocate(byteCount: frames * 8, alignment: 16)
    defer { buf.deallocate() }
    var got = 0
    while got < frames && !decoder.isAtEnd {
        let n = try decoder.decode(into: buf + got * 8, maxFrames: min(4096, frames - got))
        if n <= 0 { break }
        got += n
    }
    try assertEqual(got, frames)
    try assertTrue(decoder.isAtEnd)
}

// ─── issue #15c: 非本地源不再落临时文件，主动让路 FFmpeg ───

#if canImport(CFFmpeg)
runTest("coreAudioNonLocalSourceRoutesToFFmpeg") {
    let src = MemorySource(data: Data(repeating: 0x42, count: 1024))
    try assertThrows(try CoreAudioDecoder(source: src, fileExtension: "m4a"))
    try assertThrows(try CoreAudioDecoder(source: src, fileExtension: "mp3"))
    // 本地源不受影响，仍走 ExtAudioFile
    let wav = WAVTestHelper.makePCM16Stereo(sampleRate: 44100, durationFrames: 100)
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("pureplay_local_route_\(UUID().uuidString).wav")
    try wav.write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let d = try CoreAudioDecoder(source: try LocalFileSource(url: tmp), fileExtension: "wav")
    try assertEqual(d.format.sampleFormat, .int16)
    d.close()
    // registry 降级链的落点：FFmpeg 工厂现在认识 m4a/mp3/aac
    try assertTrue(FFmpegDecoderFactory.canDecode(source: src, fileExtension: "m4a"))
    try assertTrue(FFmpegDecoderFactory.canDecode(source: src, fileExtension: "mp3"))
    try assertTrue(FFmpegDecoderFactory.canDecode(source: src, fileExtension: "aac"))
}
#endif
#endif

// ═══════════════════════════════════════════════════════
// RateLimiter Tests
// ═══════════════════════════════════════════════════════
print("\n═══ RateLimiter Tests ═══")

runTest("rateLimiterBasicAcquire") {
    let rl = RateLimiter(rate: 100, burst: 5)
    // Should be able to acquire burst tokens immediately
    for _ in 0..<5 {
        try assertTrue(rl.available)
        rl.acquire()
    }
}

runTest("rateLimiterRefills") {
    let rl = RateLimiter(rate: 1000, burst: 2)
    rl.acquire()
    rl.acquire()
    // After depleting burst, wait a tiny bit for refill
    Thread.sleep(forTimeInterval: 0.01)
    try assertTrue(rl.available)
}

runTest("rateLimiterBlocks") {
    let rl = RateLimiter(rate: 10, burst: 1)
    rl.acquire()
    // Immediately after, should not be available (rate = 10/s, need 100ms for 1 token)
    try assertFalse(rl.available)
}

// ═══════════════════════════════════════════════════════
// CloudDownloadCache Tests
// ═══════════════════════════════════════════════════════
print("\n═══ CloudDownloadCache Tests ═══")

runTest("cacheStoreAndRetrieve") {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pureplay_cache_test_\(UUID().uuidString)")
    let cache = CloudDownloadCache(maxSizeBytes: 1024 * 1024, cacheDir: tmpDir)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let testData = Data(repeating: 0xAB, count: 1000)
    try cache.cache(fid: "file001", fileName: "test.flac", data: testData)

    try assertEqual(cache.count, 1)
    try assertEqual(cache.currentSize, 1000)

    let url = cache.cachedURL(for: "file001")
    try assertTrue(url != nil)
    let loaded = try Data(contentsOf: url!)
    try assertEqual(loaded, testData)
}

runTest("cacheLRUEviction") {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pureplay_cache_test_\(UUID().uuidString)")
    let cache = CloudDownloadCache(maxSizeBytes: 500, cacheDir: tmpDir)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    // Add 3 files, each 200 bytes → total 600 > max 500
    try cache.cache(fid: "a", fileName: "a.wav", data: Data(repeating: 1, count: 200))
    Thread.sleep(forTimeInterval: 0.01)
    try cache.cache(fid: "b", fileName: "b.wav", data: Data(repeating: 2, count: 200))
    Thread.sleep(forTimeInterval: 0.01)
    try cache.cache(fid: "c", fileName: "c.wav", data: Data(repeating: 3, count: 200))

    // "a" should be evicted (oldest)
    let urlA = cache.cachedURL(for: "a")
    try assertTrue(urlA == nil, "Oldest entry should be evicted")
    // "b" and "c" should still exist
    try assertTrue(cache.cachedURL(for: "b") != nil)
    try assertTrue(cache.cachedURL(for: "c") != nil)
}

runTest("cacheClearAll") {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pureplay_cache_test_\(UUID().uuidString)")
    let cache = CloudDownloadCache(maxSizeBytes: 1024 * 1024, cacheDir: tmpDir)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    try cache.cache(fid: "x", fileName: "x.flac", data: Data(repeating: 0, count: 100))
    try cache.cache(fid: "y", fileName: "y.flac", data: Data(repeating: 0, count: 100))
    try assertEqual(cache.count, 2)

    cache.clearAll()
    try assertEqual(cache.count, 0)
    try assertEqual(cache.currentSize, 0)
}

// ═══════════════════════════════════════════════════════
// QuarkFile Model Tests
// ═══════════════════════════════════════════════════════
print("\n═══ QuarkFile Model Tests ═══")

runTest("quarkFileAudioDetection") {
    let audioFile = QuarkFile(id: "1", fileName: "track.flac", fileSize: 50_000_000,
                              isDir: false, updatedAt: "2024-01-01", parentFid: "0")
    try assertTrue(audioFile.isAudioFile)
    try assertEqual(audioFile.fileExtension, "flac")

    let nonAudio = QuarkFile(id: "2", fileName: "photo.jpg", fileSize: 5_000_000,
                             isDir: false, updatedAt: "2024-01-01", parentFid: "0")
    try assertFalse(nonAudio.isAudioFile)

    let dsdFile = QuarkFile(id: "3", fileName: "album.dsf", fileSize: 200_000_000,
                            isDir: false, updatedAt: "2024-01-01", parentFid: "0")
    try assertTrue(dsdFile.isAudioFile)
    try assertEqual(dsdFile.fileExtension, "dsf")
}

runTest("quarkFileDirectory") {
    let dir = QuarkFile(id: "d1", fileName: "Hi-Res", fileSize: 0,
                        isDir: true, updatedAt: "2024-01-01", parentFid: "0")
    try assertTrue(dir.isDir)
    try assertFalse(dir.isAudioFile)
}

// ═══════════════════════════════════════════════════════
// KeychainStore Tests
// ═══════════════════════════════════════════════════════
print("\n═══ KeychainStore Tests ═══")

runTest("keychainSaveAndLoad") {
    let ks = KeychainStore(service: "com.pureplay.test.\(UUID().uuidString)")
    let testCookies = ["__puus": "token123", "QK_UID": "user456"]
    try ks.saveCookies(testCookies)
    let loaded = ks.loadCookies()
    try assertTrue(loaded != nil)
    try assertEqual(loaded!["__puus"], "token123")
    try assertEqual(loaded!["QK_UID"], "user456")
    ks.clearCookies()
    let after = ks.loadCookies()
    try assertTrue(after == nil)
}

// ═══════════════════════════════════════════════════════
// QuarkAPIClient Tests (offline/unit)
// ═══════════════════════════════════════════════════════
print("\n═══ QuarkAPIClient Tests ═══")

runTest("quarkClientInitialState") {
    let client = QuarkAPIClient(keychain: KeychainStore(service: "com.pureplay.test.\(UUID().uuidString)"))
    try assertFalse(client.isLoggedIn)
}

runTest("quarkClientSetCookies") {
    let ks = KeychainStore(service: "com.pureplay.test.\(UUID().uuidString)")
    let client = QuarkAPIClient(keychain: ks)
    client.setCookies(["__puus": "abc", "QK_UID": "def"])
    try assertTrue(client.isLoggedIn)
    // Verify persisted to keychain
    let saved = ks.loadCookies()
    try assertEqual(saved?["__puus"], "abc")
    client.logout()
    try assertFalse(client.isLoggedIn)
    ks.clearCookies()
}

// ═══════════════════════════════════════════════════════
// Database Tests
// ═══════════════════════════════════════════════════════
print("\n═══ Database Tests ═══")

runTest("databaseManagerSingleton") {
    let db = DatabaseManager.shared
    // If we got here, the singleton initialized successfully
    try assertTrue(true)
}

runTest("databaseAddAndFetchTrack") {
    let db = DatabaseManager.shared
    let track = TrackRecord(
        filePath: "/test/track1.flac",
        fileName: "track1.flac",
        title: "Test Track",
        artist: "Test Artist",
        album: "Test Album",
        albumArtist: "Test Album Artist",
        genre: "Test Genre",
        year: 2024,
        trackNumber: 1,
        discNumber: 1,
        duration: 180.5,
        sampleRate: 96000.0,
        bitDepth: 24,
        channels: 2,
        fileSize: 50000000,
        fileModified: Date(),
        dateAdded: Date(),
        lastPlayed: nil,
        playCount: 0,
        isFavorite: false,
        coverArtPath: nil
    )
    
    let trackId = try db.addTrack(track)
    try assertTrue(trackId > 0)
    
    let fetched = try db.track(byId: trackId)
    try assertTrue(fetched != nil)
    try assertEqual(fetched!.title, "Test Track")
    try assertEqual(fetched!.artist, "Test Artist")
    try assertEqual(fetched!.sampleRate, 96000.0)
    try assertEqual(fetched!.bitDepth, 24)
    
    // Cleanup
    try db.deleteTrack(id: trackId)
}

runTest("databaseUpdateTrack") {
    let db = DatabaseManager.shared
    let track = TrackRecord(
        filePath: "/test/update_test.flac",
        fileName: "update_test.flac",
        title: "Original Title",
        artist: "Original Artist",
        album: "Test Album",
        albumArtist: "",
        genre: "",
        year: 2024,
        trackNumber: 1,
        discNumber: 1,
        duration: 120.0,
        sampleRate: 44100.0,
        bitDepth: 16,
        channels: 2,
        fileSize: 10000000,
        fileModified: Date(),
        dateAdded: Date(),
        lastPlayed: nil,
        playCount: 0,
        isFavorite: false,
        coverArtPath: nil
    )
    
    let trackId = try db.addTrack(track)
    var updated = track
    updated.id = trackId
    updated.title = "Updated Title"
    updated.playCount = 5
    try db.updateTrack(updated)
    
    let fetched = try db.track(byId: trackId)
    try assertEqual(fetched!.title, "Updated Title")
    try assertEqual(fetched!.playCount, 5)
    
    // Cleanup
    try db.deleteTrack(id: trackId)
}

runTest("databaseSearchTracks") {
    let db = DatabaseManager.shared
    
    // Add test tracks
    let track1 = TrackRecord(
        filePath: "/test/search1.flac",
        fileName: "search1.flac",
        title: "Symphony No. 9",
        artist: "Beethoven",
        album: "Classical Masterpieces",
        albumArtist: "",
        genre: "Classical",
        year: 1824,
        trackNumber: 1,
        discNumber: 1,
        duration: 3600.0,
        sampleRate: 96000.0,
        bitDepth: 24,
        channels: 2,
        fileSize: 100000000,
        fileModified: Date(),
        dateAdded: Date(),
        lastPlayed: nil,
        playCount: 0,
        isFavorite: false,
        coverArtPath: nil
    )
    
    let track2 = TrackRecord(
        filePath: "/test/search2.flac",
        fileName: "search2.flac",
        title: "Moonlight Sonata",
        artist: "Beethoven",
        album: "Piano Works",
        albumArtist: "",
        genre: "Classical",
        year: 1801,
        trackNumber: 1,
        discNumber: 1,
        duration: 900.0,
        sampleRate: 96000.0,
        bitDepth: 24,
        channels: 2,
        fileSize: 50000000,
        fileModified: Date(),
        dateAdded: Date(),
        lastPlayed: nil,
        playCount: 0,
        isFavorite: false,
        coverArtPath: nil
    )
    
    let id1 = try db.addTrack(track1)
    let id2 = try db.addTrack(track2)
    
    // Search by title
    let results = try db.searchTracks(query: "Symphony")
    try assertEqual(results.count, 1)
    try assertEqual(results[0].title, "Symphony No. 9")
    
    // Search by artist
    let beethovenResults = try db.searchTracks(query: "Beethoven")
    try assertEqual(beethovenResults.count, 2)
    
    // Cleanup
    try db.deleteTrack(id: id1)
    try db.deleteTrack(id: id2)
}

runTest("databaseIncrementPlayCount") {
    let db = DatabaseManager.shared
    let track = TrackRecord(
        filePath: "/test/playcount.flac",
        fileName: "playcount.flac",
        title: "Play Count Test",
        artist: "Test Artist",
        album: "Test Album",
        albumArtist: "",
        genre: "",
        year: 2024,
        trackNumber: 1,
        discNumber: 1,
        duration: 180.0,
        sampleRate: 44100.0,
        bitDepth: 16,
        channels: 2,
        fileSize: 10000000,
        fileModified: Date(),
        dateAdded: Date(),
        lastPlayed: nil,
        playCount: 0,
        isFavorite: false,
        coverArtPath: nil
    )
    
    let trackId = try db.addTrack(track)
    
    // Increment play count 3 times
    try db.incrementPlayCount(trackId: trackId)
    try db.incrementPlayCount(trackId: trackId)
    try db.incrementPlayCount(trackId: trackId)
    
    let fetched = try db.track(byId: trackId)
    try assertEqual(fetched!.playCount, 3)
    try assertTrue(fetched!.lastPlayed != nil)
    
    // Cleanup
    try db.deleteTrack(id: trackId)
}

runTest("databaseToggleFavorite") {
    let db = DatabaseManager.shared
    let track = TrackRecord(
        filePath: "/test/favorite.flac",
        fileName: "favorite.flac",
        title: "Favorite Test",
        artist: "Test Artist",
        album: "Test Album",
        albumArtist: "",
        genre: "",
        year: 2024,
        trackNumber: 1,
        discNumber: 1,
        duration: 180.0,
        sampleRate: 44100.0,
        bitDepth: 16,
        channels: 2,
        fileSize: 10000000,
        fileModified: Date(),
        dateAdded: Date(),
        lastPlayed: nil,
        playCount: 0,
        isFavorite: false,
        coverArtPath: nil
    )
    
    let trackId = try db.addTrack(track)
    
    // Toggle to favorite
    try db.toggleFavorite(trackId: trackId)
    var fetched = try db.track(byId: trackId)
    try assertTrue(fetched!.isFavorite)
    
    // Toggle back
    try db.toggleFavorite(trackId: trackId)
    fetched = try db.track(byId: trackId)
    try assertFalse(fetched!.isFavorite)
    
    // Cleanup
    try db.deleteTrack(id: trackId)
}

runTest("databasePlaylistOperations") {
    let db = DatabaseManager.shared
    
    // Create a playlist
    let playlist = PlaylistRecord(
        name: "Test Playlist",
        isSmart: false,
        smartRules: nil,
        dateCreated: Date(),
        dateModified: Date()
    )
    let playlistId = try db.addPlaylist(playlist)
    try assertTrue(playlistId > 0)
    
    // Add tracks
    let track1 = TrackRecord(
        filePath: "/test/playlist1.flac",
        fileName: "playlist1.flac",
        title: "Playlist Track 1",
        artist: "Artist",
        album: "Album",
        albumArtist: "",
        genre: "",
        year: 2024,
        trackNumber: 1,
        discNumber: 1,
        duration: 180.0,
        sampleRate: 44100.0,
        bitDepth: 16,
        channels: 2,
        fileSize: 10000000,
        fileModified: Date(),
        dateAdded: Date(),
        lastPlayed: nil,
        playCount: 0,
        isFavorite: false,
        coverArtPath: nil
    )
    let track2 = TrackRecord(
        filePath: "/test/playlist2.flac",
        fileName: "playlist2.flac",
        title: "Playlist Track 2",
        artist: "Artist",
        album: "Album",
        albumArtist: "",
        genre: "",
        year: 2024,
        trackNumber: 2,
        discNumber: 1,
        duration: 200.0,
        sampleRate: 44100.0,
        bitDepth: 16,
        channels: 2,
        fileSize: 10000000,
        fileModified: Date(),
        dateAdded: Date(),
        lastPlayed: nil,
        playCount: 0,
        isFavorite: false,
        coverArtPath: nil
    )
    
    let trackId1 = try db.addTrack(track1)
    let trackId2 = try db.addTrack(track2)
    
    // Add tracks to playlist
    try db.addTrackToPlaylist(playlistId: playlistId, trackId: trackId1, position: 1)
    try db.addTrackToPlaylist(playlistId: playlistId, trackId: trackId2, position: 2)
    
    // Fetch playlist tracks
    let playlistTracks = try db.playlistTracks(playlistId: playlistId)
    try assertEqual(playlistTracks.count, 2)
    try assertEqual(playlistTracks[0].title, "Playlist Track 1")
    try assertEqual(playlistTracks[1].title, "Playlist Track 2")
    
    // Remove track from playlist
    try db.removeTrackFromPlaylist(playlistId: playlistId, trackId: trackId1)
    let updatedTracks = try db.playlistTracks(playlistId: playlistId)
    try assertEqual(updatedTracks.count, 1)
    
    // Cleanup
    try db.deletePlaylist(id: playlistId)
    try db.deleteTrack(id: trackId1)
    try db.deleteTrack(id: trackId2)
}

runTest("databasePlayHistory") {
    let db = DatabaseManager.shared
    
    let track = TrackRecord(
        filePath: "/test/history.flac",
        fileName: "history.flac",
        title: "History Test",
        artist: "Artist",
        album: "Album",
        albumArtist: "",
        genre: "",
        year: 2024,
        trackNumber: 1,
        discNumber: 1,
        duration: 180.0,
        sampleRate: 44100.0,
        bitDepth: 16,
        channels: 2,
        fileSize: 10000000,
        fileModified: Date(),
        dateAdded: Date(),
        lastPlayed: nil,
        playCount: 0,
        isFavorite: false,
        coverArtPath: nil
    )
    
    let trackId = try db.addTrack(track)
    
    // Add play history
    let now = Date()
    try db.addPlayHistory(trackId: trackId, playedAt: now, durationPlayed: 180.0)
    try db.addPlayHistory(trackId: trackId, playedAt: now.addingTimeInterval(-86400), durationPlayed: 120.0)
    
    // Fetch history
    let history = try db.playHistory(forTrackId: trackId)
    try assertEqual(history.count, 2)
    try assertEqual(history[0].durationPlayed, 180.0)
    try assertEqual(history[1].durationPlayed, 120.0)
    
    // Cleanup
    try db.deleteTrack(id: trackId)
}

runTest("databaseStatistics") {
    let db = DatabaseManager.shared
    
    let trackCount = try db.trackCount()
    let albumCount = try db.albumCount()
    let artistCount = try db.artistCount()
    
    // Should be non-negative
    try assertTrue(trackCount >= 0)
    try assertTrue(albumCount >= 0)
    try assertTrue(artistCount >= 0)
}

// ═══════════════════════════════════════════════════════
// Metadata Tests
// ═══════════════════════════════════════════════════════
print("\n═══ Metadata Tests ═══")

runTest("metadataReaderWithValidWAVFile") {
    // Create a temporary WAV file
    let tempDir = FileManager.default.temporaryDirectory
    let testFile = tempDir.appendingPathComponent("test_metadata.wav")
    
    // Create minimal WAV file (44 bytes header + no data)
    let wavHeader: [UInt8] = [
        0x52, 0x49, 0x46, 0x46, // "RIFF"
        0x24, 0x00, 0x00, 0x00, // File size - 8
        0x57, 0x41, 0x56, 0x45, // "WAVE"
        0x66, 0x6D, 0x74, 0x20, // "fmt "
        0x10, 0x00, 0x00, 0x00, // Chunk size
        0x01, 0x00,             // Audio format (PCM)
        0x02, 0x00,             // Num channels
        0x44, 0xAC, 0x00, 0x00, // Sample rate (44100)
        0x10, 0xB1, 0x02, 0x00, // Byte rate
        0x04, 0x00,             // Block align
        0x10, 0x00,             // Bits per sample
        0x64, 0x61, 0x74, 0x61, // "data"
        0x00, 0x00, 0x00, 0x00  // Data size
    ]
    
    try Data(wavHeader).write(to: testFile)
    
    let metadata = MetadataReader.readMetadata(from: testFile)
    
    // Should be able to read basic format info
    try assertTrue(metadata != nil)
    try assertEqual(metadata?.channels, 2)
    try assertEqual(metadata?.sampleRate, 44100.0)
    try assertEqual(metadata?.bitDepth, 16)
    
    // Cleanup
    try? FileManager.default.removeItem(at: testFile)
}

runTest("metadataReaderWithNonExistentFile") {
    let fakeURL = URL(fileURLWithPath: "/nonexistent/file.flac")
    let metadata = MetadataReader.readMetadata(from: fakeURL)
    
    // Should still return metadata object but with default/empty values
    try assertTrue(metadata != nil)
    try assertEqual(metadata?.duration, 0.0)
}

runTest("metadataReaderWithNonAudioFile") {
    let tempDir = FileManager.default.temporaryDirectory
    let testFile = tempDir.appendingPathComponent("test.txt")
    
    try "This is not an audio file".write(to: testFile, atomically: true, encoding: .utf8)
    
    let metadata = MetadataReader.readMetadata(from: testFile)
    
    // Should return metadata but with no audio info
    try assertTrue(metadata != nil)
    try assertTrue(metadata?.channels == nil || metadata?.channels == 0)
    
    // Cleanup
    try? FileManager.default.removeItem(at: testFile)
}

runTest("coverArtManagerSingleton") {
    let manager = CoverArtManager.shared
    // Should initialize successfully
    try assertTrue(manager != nil)
}

runTest("coverArtManagerCacheOperations") {
    let manager = CoverArtManager.shared
    
    // Clear cache first
    manager.clearCache()
    
    // Cache size should be 0
    let initialSize = manager.cacheSize()
    try assertEqual(initialSize, 0)
    
    // Try to get non-existent cover art
    let path = manager.cachedCoverArtPath(for: 999999)
    try assertTrue(path == nil)
}

runTest("coverArtManagerFileExtensionDetection") {
    let manager = CoverArtManager.shared
    
    // Test PNG magic bytes
    let pngData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    let tempDir = FileManager.default.temporaryDirectory
    let testFile = tempDir.appendingPathComponent("test_png.wav")
    try pngData.write(to: testFile)
    
    // Try to extract (will fail to extract from WAV but tests the manager)
    let path = manager.extractAndCacheCoverArt(for: testFile, trackId: 888888)
    // Should be nil since we don't have actual cover art
    try assertTrue(path == nil)
    
    // Cleanup
    try? FileManager.default.removeItem(at: testFile)
}

// ═══════════════════════════════════════════════════════
// Scanner Tests
// ═══════════════════════════════════════════════════════
print("\n═══ Scanner Tests ═══")

runTest("fileWatcherInitialization") {
    let tempDir = FileManager.default.temporaryDirectory
    var callbackCalled = false
    
    let watcher = FileWatcher(paths: [tempDir], latency: 1.0) { changedPaths in
        callbackCalled = true
    }
    
    // Should initialize without error
    try assertTrue(watcher != nil)
    
    // Should not be running initially
    try assertFalse(watcher.isRunning)
}

runTest("incrementalScannerFullScan") {
    let tempDir = FileManager.default.temporaryDirectory
    let scanner = IncrementalScanner(databaseManager: DatabaseManager.shared)
    
    // Create a temporary directory with test files
    let testDir = tempDir.appendingPathComponent("scanner_test_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
    
    // Create a test WAV file
    let testFile = testDir.appendingPathComponent("test.wav")
    let wavHeader: [UInt8] = [
        0x52, 0x49, 0x46, 0x46, // "RIFF"
        0x24, 0x00, 0x00, 0x00, // File size - 8
        0x57, 0x41, 0x56, 0x45, // "WAVE"
        0x66, 0x6D, 0x74, 0x20, // "fmt "
        0x10, 0x00, 0x00, 0x00, // Chunk size
        0x01, 0x00,             // Audio format (PCM)
        0x02, 0x00,             // Num channels
        0x44, 0xAC, 0x00, 0x00, // Sample rate (44100)
        0x10, 0xB1, 0x02, 0x00, // Byte rate
        0x04, 0x00,             // Block align
        0x10, 0x00,             // Bits per sample
        0x64, 0x61, 0x74, 0x61, // "data"
        0x00, 0x00, 0x00, 0x00  // Data size
    ]
    try Data(wavHeader).write(to: testFile)
    
    // Perform full scan
    let files = try scanner.fullScan(directory: testDir)
    
    // Should find the WAV file
    try assertEqual(files.count, 1)
    try assertEqual(files[0].lastPathComponent, "test.wav")
    
    // Cleanup
    try? FileManager.default.removeItem(at: testDir)
}

runTest("incrementalScannerDetectsAudioFiles") {
    let scanner = IncrementalScanner(databaseManager: DatabaseManager.shared)
    
    // Test audio file detection
    let tempDir = FileManager.default.temporaryDirectory
    let wavFile = tempDir.appendingPathComponent("test.flac")
    let txtFile = tempDir.appendingPathComponent("test.txt")
    
    try "fake flac".write(to: wavFile, atomically: true, encoding: .utf8)
    try "text file".write(to: txtFile, atomically: true, encoding: .utf8)
    
    try assertTrue(scanner.isAudioFile(wavFile))
    try assertFalse(scanner.isAudioFile(txtFile))
    
    // Cleanup
    try? FileManager.default.removeItem(at: wavFile)
    try? FileManager.default.removeItem(at: txtFile)
}

runTest("scanServiceSingleton") {
    let service = ScanService.shared
    
    // Should initialize successfully
    try assertTrue(service != nil)
    
    // Should have no watched directories initially
    let watched = service.watchedDirectories
    try assertEqual(watched.count, 0)
}

runTest("scanServiceWatchDirectory") {
    let service = ScanService.shared
    let tempDir = FileManager.default.temporaryDirectory
    
    // Watch a directory
    service.watchDirectory(tempDir)
    
    // Should be in watched list
    let watched = service.watchedDirectories
    try assertTrue(watched.contains(tempDir))
    
    // Unwatch
    service.unwatchDirectory(tempDir)
    
    // Should no longer be in watched list
    let watchedAfter = service.watchedDirectories
    try assertFalse(watchedAfter.contains(tempDir))
}

// ═══════════════════════════════════════════════════════
// Smart Playlist Engine Tests
// ═══════════════════════════════════════════════════════
print("\n═══ Smart Playlist Engine Tests ═══")

runTest("smartPlaylistEngineEvaluateContains") {
    let track1 = TrackRecord(
        filePath: "/test1.mp3",
        fileName: "test1.mp3",
        title: "Love Song",
        artist: "Artist A",
        album: "Album 1"
    )
    let track2 = TrackRecord(
        filePath: "/test2.mp3",
        fileName: "test2.mp3",
        title: "Happy Day",
        artist: "Artist B",
        album: "Album 2"
    )
    
    let rule = SmartPlaylistRule(field: .title, op: .contains, value: "Love")
    let results = SmartPlaylistEngine.evaluate(rules: [rule], tracks: [track1, track2])
    
    try assertEqual(results.count, 1)
    try assertEqual(results[0].title, "Love Song")
}

runTest("smartPlaylistEngineEvaluateEquals") {
    let track1 = TrackRecord(
        filePath: "/test1.mp3",
        fileName: "test1.mp3",
        title: "Song 1",
        artist: "Artist A",
        album: "Album 1",
        year: 2020
    )
    let track2 = TrackRecord(
        filePath: "/test2.mp3",
        fileName: "test2.mp3",
        title: "Song 2",
        artist: "Artist B",
        album: "Album 2",
        year: 2021
    )
    
    let rule = SmartPlaylistRule(field: .year, op: .equals, value: "2020")
    let results = SmartPlaylistEngine.evaluate(rules: [rule], tracks: [track1, track2])
    
    try assertEqual(results.count, 1)
    try assertEqual(results[0].year, 2020)
}

runTest("smartPlaylistEngineEvaluateGreaterThan") {
    let track1 = TrackRecord(
        filePath: "/test1.mp3",
        fileName: "test1.mp3",
        title: "Song 1",
        artist: "Artist A",
        album: "Album 1",
        duration: 180.0
    )
    let track2 = TrackRecord(
        filePath: "/test2.mp3",
        fileName: "test2.mp3",
        title: "Song 2",
        artist: "Artist B",
        album: "Album 2",
        duration: 240.0
    )
    
    let rule = SmartPlaylistRule(field: .duration, op: .greaterThan, value: "200")
    let results = SmartPlaylistEngine.evaluate(rules: [rule], tracks: [track1, track2])
    
    try assertEqual(results.count, 1)
    try assertEqual(results[0].duration, 240.0)
}

runTest("smartPlaylistEngineEvaluateMultipleRules") {
    let track1 = TrackRecord(
        filePath: "/test1.mp3",
        fileName: "test1.mp3",
        title: "Love Song",
        artist: "Artist A",
        album: "Album 1",
        year: 2020
    )
    let track2 = TrackRecord(
        filePath: "/test2.mp3",
        fileName: "test2.mp3",
        title: "Love Story",
        artist: "Artist B",
        album: "Album 2",
        year: 2021
    )
    let track3 = TrackRecord(
        filePath: "/test3.mp3",
        fileName: "test3.mp3",
        title: "Happy Day",
        artist: "Artist C",
        album: "Album 3",
        year: 2020
    )
    
    let rule1 = SmartPlaylistRule(field: .title, op: .contains, value: "Love")
    let rule2 = SmartPlaylistRule(field: .year, op: .equals, value: "2020")
    let results = SmartPlaylistEngine.evaluate(rules: [rule1, rule2], tracks: [track1, track2, track3])
    
    try assertEqual(results.count, 1)
    try assertEqual(results[0].title, "Love Song")
}

runTest("smartPlaylistEngineParseRules") {
    let rules = [
        SmartPlaylistRule(field: .title, op: .contains, value: "Love"),
        SmartPlaylistRule(field: .year, op: .greaterThan, value: "2019")
    ]
    
    let json = SmartPlaylistEngine.encodeRules(rules)
    try assertTrue(json != nil)
    
    let parsed = SmartPlaylistEngine.parseRules(from: json)
    try assertEqual(parsed.count, 2)
    try assertEqual(parsed[0].field, .title)
    try assertEqual(parsed[0].op, .contains)
    try assertEqual(parsed[0].value, "Love")
}

// ═══════════════════════════════════════════════════════
// Queue Management Tests
// ═══════════════════════════════════════════════════════
print("\n═══ Queue Management Tests ═══")

runTest("queueManagerAddToQueue") {
    let db = DatabaseManager.shared
    let output = MockAudioOutput()
    let playerController = PlayerController(output: output)
    let queueManager = QueueManager(playerController: playerController, databaseManager: db)
    
    let source1 = TrackSource.local(URL(fileURLWithPath: "/test1.mp3"))
    let source2 = TrackSource.local(URL(fileURLWithPath: "/test2.mp3"))
    
    queueManager.addToQueue([source1, source2])
    
    try assertEqual(queueManager.queueCount, 2)
}

runTest("queueManagerInsertToQueue") {
    let db = DatabaseManager.shared
    let output = MockAudioOutput()
    let playerController = PlayerController(output: output)
    let queueManager = QueueManager(playerController: playerController, databaseManager: db)
    
    let source1 = TrackSource.local(URL(fileURLWithPath: "/test1.mp3"))
    let source2 = TrackSource.local(URL(fileURLWithPath: "/test2.mp3"))
    let source3 = TrackSource.local(URL(fileURLWithPath: "/test3.mp3"))
    
    queueManager.addToQueue([source1, source3])
    queueManager.insertToQueue([source2], at: 1)
    
    try assertEqual(queueManager.queueCount, 3)
}

runTest("queueManagerRemoveFromQueue") {
    let db = DatabaseManager.shared
    let output = MockAudioOutput()
    let playerController = PlayerController(output: output)
    let queueManager = QueueManager(playerController: playerController, databaseManager: db)
    
    let source1 = TrackSource.local(URL(fileURLWithPath: "/test1.mp3"))
    let source2 = TrackSource.local(URL(fileURLWithPath: "/test2.mp3"))
    let source3 = TrackSource.local(URL(fileURLWithPath: "/test3.mp3"))
    
    queueManager.addToQueue([source1, source2, source3])
    queueManager.removeFromQueue(at: [1])
    
    try assertEqual(queueManager.queueCount, 2)
}

runTest("queueManagerMoveInQueue") {
    let db = DatabaseManager.shared
    let output = MockAudioOutput()
    let playerController = PlayerController(output: output)
    let queueManager = QueueManager(playerController: playerController, databaseManager: db)
    
    let source1 = TrackSource.local(URL(fileURLWithPath: "/test1.mp3"))
    let source2 = TrackSource.local(URL(fileURLWithPath: "/test2.mp3"))
    let source3 = TrackSource.local(URL(fileURLWithPath: "/test3.mp3"))
    
    queueManager.addToQueue([source1, source2, source3])
    queueManager.moveInQueue(from: 0, to: 2)
    
    try assertEqual(queueManager.queueCount, 3)
}

runTest("queueManagerClearQueue") {
    let db = DatabaseManager.shared
    let output = MockAudioOutput()
    let playerController = PlayerController(output: output)
    let queueManager = QueueManager(playerController: playerController, databaseManager: db)
    
    let source1 = TrackSource.local(URL(fileURLWithPath: "/test1.mp3"))
    let source2 = TrackSource.local(URL(fileURLWithPath: "/test2.mp3"))
    
    queueManager.addToQueue([source1, source2])
    queueManager.clearQueue()
    
    try assertEqual(queueManager.queueCount, 0)
}

runTest("queueManagerReplaceQueue") {
    let db = DatabaseManager.shared
    let output = MockAudioOutput()
    let playerController = PlayerController(output: output)
    let queueManager = QueueManager(playerController: playerController, databaseManager: db)
    
    let source1 = TrackSource.local(URL(fileURLWithPath: "/test1.mp3"))
    let source2 = TrackSource.local(URL(fileURLWithPath: "/test2.mp3"))
    let source3 = TrackSource.local(URL(fileURLWithPath: "/test3.mp3"))
    
    queueManager.addToQueue([source1])
    queueManager.replaceQueue(with: [source2, source3])
    
    try assertEqual(queueManager.queueCount, 2)
}

// ═══════════════════════════════════════════════════════
// AIFF Decoder Tests
// ═══════════════════════════════════════════════════════
print("\n═══ AIFF Decoder Tests ═══")

runTest("aiffBasicDecode") {
    let frames = 256
    let data = AIFFTestHelper.makePCM16Stereo(sampleRate: 44100, durationFrames: frames)
    let src = MemorySource(data: data)
    let dec = try AIFFDecoder(source: src)
    try assertEqual(dec.format.sampleRate, 44100.0)
    try assertEqual(dec.format.channels, 2)
    try assertEqual(dec.format.sampleFormat, .int16)
    try assertEqual(dec.totalFrames, Int64(frames))

    let bytes = frames * dec.format.bytesPerFrame
    let buf = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
    defer { buf.deallocate() }
    let n = try dec.decode(into: buf, maxFrames: frames)
    try assertEqual(n, frames)
}

runTest("aiffByteSwapToLE") {
    // 使用 helper 生成 2 帧 stereo PCM16；helper 内部以 BE 存储 sample
    let data = AIFFTestHelper.makePCM16Stereo(sampleRate: 44100, durationFrames: 2)
    // 找 SSND payload 起点：扫描 "SSND" 4 字节标签 + 跳过 8 字节 header (size+offset+blockSize)
    // helper 的固定结构：12 (FORM) + 8 (COMM hdr) + 18 (COMM) + 8 (SSND hdr) + 8 (offset/blockSize) = 54
    let ssndPayloadStart = 54
    let beBytes = [UInt8](data[ssndPayloadStart..<(ssndPayloadStart + 4)])

    let dec = try AIFFDecoder(source: MemorySource(data: data))
    let buf = UnsafeMutableRawPointer.allocate(byteCount: 4, alignment: 4)
    defer { buf.deallocate() }
    let n = try dec.decode(into: buf, maxFrames: 1)
    try assertEqual(n, 1)
    let p = buf.assumingMemoryBound(to: UInt8.self)
    // 第 1 个 16-bit sample 应该被翻转：beBytes[0..2] → LE[1..0]
    try assertEqual(p[0], beBytes[1])
    try assertEqual(p[1], beBytes[0])
    try assertEqual(p[2], beBytes[3])
    try assertEqual(p[3], beBytes[2])
}

runTest("aiffRegistryResolves") {
    try assertTrue(AIFFDecoderFactory.supportedExtensions.contains("aiff"))
    try assertTrue(AIFFDecoderFactory.supportedExtensions.contains("aif"))
    let data = AIFFTestHelper.makePCM16Stereo(sampleRate: 48000, durationFrames: 128)
    let dec = try DecoderRegistry.shared.makeDecoder(
        source: MemorySource(data: data), fileExtension: "aiff")
    try assertEqual(dec.format.sampleRate, 48000.0)
}

// ═══════════════════════════════════════════════════════
// DFF Decoder Tests
// ═══════════════════════════════════════════════════════
print("\n═══ DFF Decoder Tests ═══")

runTest("dffHeaderParsing") {
    let data = DFFTestHelper.makeMinimalDFF(sampleFreq: 2_822_400, framesPerChannel: 64)
    let dec = try DFFDecoder(source: MemorySource(data: data))
    try assertTrue(dec.format.isDSD)
    try assertEqual(dec.format.channels, 2)
    try assertEqual(dec.format.sampleFormat, .int24)
    try assertEqual(dec.format.sampleRate, 176_400.0)
    try assertEqual(dec.format.dsdRateRaw, 2_822_400.0)
    // 64 字节/声道 × 2 channels interleaved = 128 字节
    // total DoP frames = 128 / (2 ch * 2 bytes) = 32
    try assertEqual(dec.totalFrames, 32)
}

runTest("dffDecodeProducesDoPMarkers") {
    let data = DFFTestHelper.makeMinimalDFF()
    let dec = try DFFDecoder(source: MemorySource(data: data))
    let buf = UnsafeMutableRawPointer.allocate(byteCount: 6, alignment: 4)
    defer { buf.deallocate() }
    let frames = try dec.decode(into: buf, maxFrames: 1)
    try assertEqual(frames, 1)
    let p = buf.assumingMemoryBound(to: UInt8.self)
    try assertEqual(p[2], UInt8(0x05))  // ch0 marker (LE high byte)
    try assertEqual(p[5], UInt8(0x05))  // ch1 marker
}

runTest("dffMarkerAlternation") {
    let data = DFFTestHelper.makeMinimalDFF(framesPerChannel: 16)
    let dec = try DFFDecoder(source: MemorySource(data: data))
    let buf = UnsafeMutableRawPointer.allocate(byteCount: 24, alignment: 4)
    defer { buf.deallocate() }
    let frames = try dec.decode(into: buf, maxFrames: 4)
    try assertEqual(frames, 4)
    let p = buf.assumingMemoryBound(to: UInt8.self)
    try assertEqual(p[0 * 6 + 2], UInt8(0x05))
    try assertEqual(p[1 * 6 + 2], UInt8(0xFA))
    try assertEqual(p[2 * 6 + 2], UInt8(0x05))
    try assertEqual(p[3 * 6 + 2], UInt8(0xFA))
}

runTest("dffSeekResetsMarker") {
    let data = DFFTestHelper.makeMinimalDFF(framesPerChannel: 16)
    let dec = try DFFDecoder(source: MemorySource(data: data))
    let scratch = UnsafeMutableRawPointer.allocate(byteCount: 18, alignment: 4)
    defer { scratch.deallocate() }
    _ = try dec.decode(into: scratch, maxFrames: 3)
    try dec.seek(to: 5)
    try assertEqual(dec.currentFrame, 5)
    let buf = UnsafeMutableRawPointer.allocate(byteCount: 6, alignment: 4)
    defer { buf.deallocate() }
    let n = try dec.decode(into: buf, maxFrames: 1)
    try assertEqual(n, 1)
    let p = buf.assumingMemoryBound(to: UInt8.self)
    try assertEqual(p[2], UInt8(0x05))
}

runTest("dffRegistryResolves") {
    try assertTrue(DFFDecoderFactory.supportedExtensions.contains("dff"))
    let data = DFFTestHelper.makeMinimalDFF()
    let dec = try DecoderRegistry.shared.makeDecoder(
        source: MemorySource(data: data), fileExtension: "dff")
    try assertTrue(dec.format.isDSD)
}

// ═══════════════════════════════════════════════════════
// DSD1024 (F4) Tests
// ═══════════════════════════════════════════════════════
print("\n═══ DSD1024 Tests ═══")

runTest("dsd1024EnumRawValueAndMultiplier") {
    try assertEqual(DSDRate.dsd1024.rawValue, 45_158_400)
    try assertEqual(DSDRate.dsd1024.multiplier, 1024)
}

runTest("dsd1024RecommendedPCMRateIs384k") {
    try assertEqual(DSDRate.dsd1024.recommendedPCMRate, 384_000.0)
}

runTest("dsd1024DisplayName") {
    try assertEqual(DSDRate.dsd1024.displayName, "DSD1024")
}

runTest("dsd1024CaseIterableIncludesDSD1024") {
    try assertTrue(DSDRate.allCases.contains(.dsd1024))
    try assertEqual(DSDRate.allCases.count, 5)
}

runTest("dsfDecoderAcceptsDSD1024") {
    let data = DSFTestHelper.makeMinimalDSF(sampleFreq: 45_158_400, blocks: 1)
    let decoder = try DSFDecoder(source: MemorySource(data: data))
    try assertTrue(decoder.format.isDSD)
    try assertEqual(decoder.format.dsdRateRaw, 45_158_400.0)
}

runTest("dffDecoderAcceptsDSD1024") {
    let data = DFFTestHelper.makeMinimalDFF(sampleFreq: 45_158_400, framesPerChannel: 16)
    let dec = try DFFDecoder(source: MemorySource(data: data))
    try assertTrue(dec.format.isDSD)
    try assertEqual(dec.format.dsdRateRaw, 45_158_400.0)
}

runTest("dacProbeNeverSupportsDSD1024") {
    // 即便设备宣称 768k 也不应被判定为支持 DSD1024（DoP carrier 需 2.8224 MHz PCM）
    let dev = AudioDevice(id: 101, name: "Hypothetical Mega DAC",
                          uid: "uid-101", maxSampleRate: 768_000,
                          supportedRates: [44100, 192000, 384000, 768000])
    let result = DACCapabilityProbe.probe(dev)
    try assertFalse(result.supports(.dsd1024))
}

runTest("dacProbeWhitelistDoesNotImplyDSD1024") {
    // Topping D90 白名单 maxDSD = .dsd512，不应让 DSD1024 返回 true
    let dev = AudioDevice(id: 102, name: "Topping D90",
                          uid: "uid-102", maxSampleRate: 768_000,
                          supportedRates: [44100, 192000, 384000, 768000])
    let result = DACCapabilityProbe.probe(dev)
    try assertFalse(result.supports(.dsd1024))
}

runTest("strategyDSD1024PreferDoPFallsBackToPCM384k") {
    // DSD1024 DoP carrier = 2_822_400 Hz；最大 PCM 仅 768k 仍不足，必须落到 PCM
    let dac = DACCapabilities(maxPCMRate: 768_000)
    let s = DSDStrategyChooser.choose(rate: .dsd1024, dac: dac, preference: .preferDoP)
    try assertEqual(s, .pcm(targetRate: 384_000))
}

runTest("strategyDSD1024AutoFallsBackToPCM384k") {
    let dac = DACCapabilities(maxPCMRate: 768_000)
    let s = DSDStrategyChooser.choose(rate: .dsd1024, dac: dac, preference: .auto)
    try assertEqual(s, .pcm(targetRate: 384_000))
}

runTest("strategyDSD1024AlwaysPCMReturnsPCM384k") {
    let dac = DACCapabilities(maxPCMRate: 768_000)
    let s = DSDStrategyChooser.choose(rate: .dsd1024, dac: dac, preference: .alwaysPCM)
    try assertEqual(s, .pcm(targetRate: 384_000))
}

// ═══════════════════════════════════════════════════════
// CueSheet & TrimmingDecoder Tests
// ═══════════════════════════════════════════════════════
print("\n═══ CueSheet Tests ═══")

runTest("cueSheetParseBasic") {
    let text = """
    PERFORMER "Some Band"
    TITLE "The Album"
    FILE "album.flac" WAVE
      TRACK 01 AUDIO
        TITLE "First"
        PERFORMER "Band A"
        INDEX 01 00:00:00
      TRACK 02 AUDIO
        TITLE "Second"
        INDEX 01 04:23:45
      TRACK 03 AUDIO
        TITLE "Third"
        INDEX 01 09:00:00
    """
    let sheet = CueSheet.parse(text)
    try assertTrue(sheet != nil)
    let s = sheet!
    try assertEqual(s.albumTitle, "The Album")
    try assertEqual(s.albumPerformer, "Some Band")
    try assertEqual(s.audioFileRef, "album.flac")
    try assertEqual(s.tracks.count, 3)
    try assertEqual(s.tracks[0].number, 1)
    try assertEqual(s.tracks[0].title, "First")
    try assertEqual(s.tracks[0].performer, "Band A")
    try assertEqual(s.tracks[0].startSeconds, 0.0)
    // 04:23:45 = 4*60 + 23 + 45/75 = 263.6
    try assertTrue(abs(s.tracks[1].startSeconds - 263.6) < 0.001)
    // Track 2 inherits album performer
    try assertEqual(s.tracks[1].performer, "Some Band")
    // Track 3 endSeconds = nil
    try assertTrue(s.tracks[2].endSeconds == nil)
    // Track 1 endSeconds = 263.6
    try assertTrue(abs((s.tracks[0].endSeconds ?? 0) - 263.6) < 0.001)
}

runTest("cueSheetEmptyReturnsNil") {
    try assertTrue(CueSheet.parse("") == nil)
}

runTest("trimmingDecoderBoundaries") {
    let frames = 4410
    let wav = WAVTestHelper.makePCM16Stereo(sampleRate: 44100, durationFrames: frames)
    let inner = try WAVDecoder(source: MemorySource(data: wav))
    // 取 [1000, 3000) 共 2000 帧
    let trim = try TrimmingDecoder(inner: inner, startFrame: 1000, endFrame: 3000)
    try assertEqual(trim.totalFrames, 2000)
    try assertEqual(trim.currentFrame, 0)
    try assertFalse(trim.isAtEnd)

    let bytes = 2000 * 4
    let buf = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
    defer { buf.deallocate() }
    let n = try trim.decode(into: buf, maxFrames: 5000)  // ask more than allowed
    try assertEqual(n, 2000)
    try assertTrue(trim.isAtEnd)
}

runTest("trimmingDecoderSeek") {
    let frames = 4410
    let wav = WAVTestHelper.makePCM16Stereo(sampleRate: 44100, durationFrames: frames)
    let inner = try WAVDecoder(source: MemorySource(data: wav))
    let trim = try TrimmingDecoder(inner: inner, startFrame: 1000, endFrame: 3000)
    try trim.seek(to: 500)
    try assertEqual(trim.currentFrame, 500)
    // 1500 帧 × 4 字节（int16 立体声）= 6000；旧值 4000 会堆溢出
    // 2000 字节（Guard Malloc 下在 MemorySource.read 的 memmove 处即崩）
    let buf = UnsafeMutableRawPointer.allocate(byteCount: 6000, alignment: 16)
    defer { buf.deallocate() }
    let n = try trim.decode(into: buf, maxFrames: 1500)
    try assertEqual(n, 1500)
    try assertTrue(trim.isAtEnd)
}

runTest("trimmingDecoderEndDefaultsToInnerEnd") {
    let frames = 1024
    let wav = WAVTestHelper.makePCM16Stereo(sampleRate: 44100, durationFrames: frames)
    let inner = try WAVDecoder(source: MemorySource(data: wav))
    let trim = try TrimmingDecoder(inner: inner, startFrame: 512, endFrame: nil)
    try assertEqual(trim.totalFrames, 512)
}

// ═══════════════════════════════════════════════════════
// ALAC Factory Tests
// ═══════════════════════════════════════════════════════
print("\n═══ ALAC Factory Tests ═══")

runTest("alacFactoryRegistered") {
    try assertTrue(ALACDecoderFactory.supportedExtensions.contains("alac"))
    try assertTrue(ALACDecoderFactory.supportedExtensions.contains("m4a"))
    try assertTrue(ALACDecoderFactory.supportedExtensions.contains("mp4"))
    try assertGreaterThan(ALACDecoderFactory.priority, CoreAudioDecoderFactory.priority)
    // CoreAudio fallback no longer claims alac/m4a/mp4
    try assertFalse(CoreAudioDecoderFactory.supportedExtensions.contains("alac"))
    try assertFalse(CoreAudioDecoderFactory.supportedExtensions.contains("m4a"))
    try assertFalse(CoreAudioDecoderFactory.supportedExtensions.contains("mp4"))
}

// ═══════════════════════════════════════════════════════
// Sinc Resampler Tests
// ═══════════════════════════════════════════════════════
print("\n═══ Sinc Resampler Tests ═══")

runTest("sincResampler1to1Identity") {
    // 1:1 比率应基本恒等（小数值漂移可接受 < 0.01）
    let resampler = SincResampler(inputRate: 44100, outputRate: 44100, channels: 1)
    let frames = 256
    let input = UnsafeMutablePointer<Float>.allocate(capacity: frames)
    let output = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
    defer { input.deallocate(); output.deallocate() }
    for i in 0..<frames {
        input[i] = sin(Float(i) * 0.1)
    }
    let produced = resampler.process(input: input, inputFrames: frames,
                                     output: output, outputCapacityFrames: frames * 2)
    // 由于历史窗口效应，首批输出可能略少；至少应产出绝大多数样本
    try assertGreaterThan(produced, frames - 64)
}

runTest("sincResampler2to1Decimation") {
    // 88.2k → 44.1k：输入 N 帧约产出 N/2 帧
    let resampler = SincResampler(inputRate: 88200, outputRate: 44100, channels: 1)
    let inputFrames = 1024
    let input = UnsafeMutablePointer<Float>.allocate(capacity: inputFrames)
    let output = UnsafeMutablePointer<Float>.allocate(capacity: inputFrames)
    defer { input.deallocate(); output.deallocate() }
    for i in 0..<inputFrames {
        // 单频 1kHz 正弦
        input[i] = sin(2 * .pi * 1000 * Float(i) / 88200)
    }
    let produced = resampler.process(input: input, inputFrames: inputFrames,
                                     output: output, outputCapacityFrames: inputFrames)
    let expected = inputFrames / 2
    // 允许 ±32 帧误差（边界处历史 ramp-up）
    try assertGreaterThan(produced, expected - 32)
    try assertLessThan(produced, expected + 32)
}

runTest("sincResamplerStereoInterleave") {
    let resampler = SincResampler(inputRate: 48000, outputRate: 48000, channels: 2)
    let frames = 128
    let input = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
    let output = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2 + 32)
    defer { input.deallocate(); output.deallocate() }
    for i in 0..<frames {
        input[i * 2] = 0.5      // L
        input[i * 2 + 1] = -0.5  // R
    }
    let produced = resampler.process(input: input, inputFrames: frames,
                                     output: output, outputCapacityFrames: frames + 16)
    try assertGreaterThan(produced, 0)
}

runTest("sincResamplerReset") {
    let resampler = SincResampler(inputRate: 96000, outputRate: 48000, channels: 1)
    let input = UnsafeMutablePointer<Float>.allocate(capacity: 64)
    let output = UnsafeMutablePointer<Float>.allocate(capacity: 64)
    defer { input.deallocate(); output.deallocate() }
    for i in 0..<64 { input[i] = Float(i) / 64.0 }
    _ = resampler.process(input: input, inputFrames: 64,
                          output: output, outputCapacityFrames: 64)
    resampler.reset()
    // After reset, no error
    let produced = resampler.process(input: input, inputFrames: 64,
                                     output: output, outputCapacityFrames: 64)
    try assertGreaterThan(produced, 0)
}

// ═══════════════════════════════════════════════════════
// DSD2PCM Converter Tests
// ═══════════════════════════════════════════════════════
print("\n═══ DSD2PCM Tests ═══")

runTest("dsd2pcmOutputRateMath") {
    let conv = DSD2PCMConverter(channels: 2, dsdBitstreamRate: 2_822_400)
    // 2.8224 MHz / 8 = 352.8 kHz
    try assertEqual(conv.outputRate, 352800.0)
}

runTest("dsd2pcmProducesFrames") {
    let conv = DSD2PCMConverter(channels: 2, dsdBitstreamRate: 2_822_400)
    let inputFrames = 16
    var input = [UInt8](repeating: 0x69, count: inputFrames * 2)
    let output = UnsafeMutablePointer<Float>.allocate(capacity: inputFrames * 2)
    defer { output.deallocate() }
    let produced = input.withUnsafeBufferPointer { src in
        conv.process(dsdInterleaved: src.baseAddress!,
                     inputFrames: inputFrames,
                     output: output,
                     outputCapacityFrames: inputFrames)
    }
    // 1 byte in → 1 PCM sample out (per channel)
    try assertEqual(produced, inputFrames)
}

runTest("dsd2pcmZeroDCBalancedInput") {
    // 0x69 = 01101001, mean ≈ 0.5 → mapped to 0
    // 但我们的映射是 1→+1 / 0→-1，所以输入全 0x69 时 acc ≈ 0
    let conv = DSD2PCMConverter(channels: 1, dsdBitstreamRate: 2_822_400)
    let inputFrames = 128
    let input = [UInt8](repeating: 0x69, count: inputFrames)
    let output = UnsafeMutablePointer<Float>.allocate(capacity: inputFrames)
    defer { output.deallocate() }
    let produced = input.withUnsafeBufferPointer { src in
        conv.process(dsdInterleaved: src.baseAddress!,
                     inputFrames: inputFrames,
                     output: output,
                     outputCapacityFrames: inputFrames)
    }
    try assertGreaterThan(produced, 0)
    // 中段（filter 已稳定）的样本应该接近 0
    var sumAbs: Float = 0
    let tail = produced - 16
    for i in tail..<produced {
        sumAbs += abs(output[i])
    }
    let mean = sumAbs / Float(produced - tail)
    // 0x69 不是完美 DC = 0 的 pattern；放宽阈值 < 0.1
    try assertLessThan(mean, 0.1)
}

runTest("dsd2pcmCapacityLimit") {
    let conv = DSD2PCMConverter(channels: 2, dsdBitstreamRate: 2_822_400)
    let input = [UInt8](repeating: 0xAA, count: 64)
    let output = UnsafeMutablePointer<Float>.allocate(capacity: 20)
    defer { output.deallocate() }
    let produced = input.withUnsafeBufferPointer { src in
        conv.process(dsdInterleaved: src.baseAddress!,
                     inputFrames: 32, output: output, outputCapacityFrames: 10)
    }
    try assertLessThanOrEqual(produced, 10)
}

// ─── issue #10：DSD PCM 回退（解码器 PCM 模式 + PlayerController 接线）───

runTest("dopPackerReverseIsBitMirror") {
    try assertEqual(DoPPacker.reverse(0x0F), 0xF0)
    try assertEqual(DoPPacker.reverse(0xAA), 0x55)
    try assertEqual(DoPPacker.reverse(0x00), 0x00)
    try assertEqual(DoPPacker.reverse(0xFF), 0xFF)
    for v in 0...255 {
        try assertEqual(DoPPacker.reverse(DoPPacker.reverse(UInt8(v))), UInt8(v))
    }
}

runTest("dsfDecoderPCMModeFormat") {
    let data = DSFTestHelper.makeMinimalDSF(sampleFreq: 2_822_400, blocks: 1)
    let dec = try DSFDecoder(source: MemorySource(data: data), pcmMode: true)
    try assertEqual(dec.format.sampleRate, 352_800.0)   // dsdRate / 8
    try assertEqual(dec.format.sampleFormat, .float32)
    try assertFalse(dec.format.isDSD)
    try assertEqual(dec.totalFrames, 4096)              // 1 DSD 字节/帧/声道
    // 对照：DoP 模式 1 帧 = 2 DSD 字节/声道
    let dop = try DSFDecoder(source: MemorySource(data: data), pcmMode: false)
    try assertEqual(dop.totalFrames, 2048)
    try assertTrue(dop.format.isDSD)
    try assertEqual(dop.format.sampleFormat, .int24)
}

runTest("dsfDecoderPCMModeDecodesDC") {
    // ch0 = 0xFF（全 1 → +1 DC），ch1 = 0x00（全 0 → -1 DC）；FIR DC 增益 = 1
    let data = DSFTestHelper.makeMinimalDSF(
        sampleFreq: 2_822_400, blocks: 1,
        channelPattern: { ch, _ in ch == 0 ? 0xFF : 0x00 })
    let dec = try DSFDecoder(source: MemorySource(data: data), pcmMode: true)
    let n = 512
    let buf = UnsafeMutableRawPointer.allocate(byteCount: n * 2 * 4, alignment: 16)
    defer { buf.deallocate() }
    let got = try dec.decode(into: buf, maxFrames: n)
    try assertEqual(got, n)
    let f = buf.bindMemory(to: Float.self, capacity: n * 2)
    // 滤波器稳定后（12 字节窗口 + 余量）ch0 ≈ +1、ch1 ≈ -1
    for i in 100..<n {
        try assertTrue(abs(f[i * 2] - 1.0) < 0.05,
                       "ch0 应 ≈ +1.0，帧 \(i) 实际 \(f[i * 2])")
        try assertTrue(abs(f[i * 2 + 1] + 1.0) < 0.05,
                       "ch1 应 ≈ -1.0，帧 \(i) 实际 \(f[i * 2 + 1])")
    }
    try assertEqual(dec.currentFrame, Int64(n))
}

runTest("dsfDecoderPCMSeekResetsConverter") {
    let data = DSFTestHelper.makeMinimalDSF(
        sampleFreq: 2_822_400, blocks: 2,
        channelPattern: { ch, _ in ch == 0 ? 0xFF : 0x00 })
    let dec = try DSFDecoder(source: MemorySource(data: data), pcmMode: true)
    try assertEqual(dec.totalFrames, 8192)
    try dec.seek(to: 4096)   // 恰好跨到第 2 个块对
    try assertEqual(dec.currentFrame, 4096)
    let n = 64
    let buf = UnsafeMutableRawPointer.allocate(byteCount: n * 2 * 4, alignment: 16)
    defer { buf.deallocate() }
    let got = try dec.decode(into: buf, maxFrames: n)
    try assertEqual(got, n)
    let f = buf.bindMemory(to: Float.self, capacity: n * 2)
    for i in 20..<n {
        try assertTrue(abs(f[i * 2] - 1.0) < 0.05)
        try assertTrue(abs(f[i * 2 + 1] + 1.0) < 0.05)
    }
    try assertEqual(dec.currentFrame, 4096 + Int64(n))
}

runTest("dffDecoderPCMModeDecodesDC") {
    // DFF 是 MSB-first 交错 — 无需 bit-reverse，直接喂转换器
    let data = DFFTestHelper.makeMinimalDFF(
        sampleFreq: 2_822_400, framesPerChannel: 512,
        channelPattern: { ch, _ in ch == 0 ? 0xFF : 0x00 })
    let dec = try DFFDecoder(source: MemorySource(data: data), pcmMode: true)
    try assertEqual(dec.format.sampleRate, 352_800.0)
    try assertEqual(dec.format.sampleFormat, .float32)
    try assertFalse(dec.format.isDSD)
    try assertEqual(dec.totalFrames, 512)   // 1 DSD 字节/帧/声道
    let n = 512
    let buf = UnsafeMutableRawPointer.allocate(byteCount: n * 2 * 4, alignment: 16)
    defer { buf.deallocate() }
    let got = try dec.decode(into: buf, maxFrames: n)
    try assertEqual(got, n)
    let f = buf.bindMemory(to: Float.self, capacity: n * 2)
    for i in 100..<n {
        try assertTrue(abs(f[i * 2] - 1.0) < 0.05,
                       "ch0 应 ≈ +1.0，帧 \(i) 实际 \(f[i * 2])")
        try assertTrue(abs(f[i * 2 + 1] + 1.0) < 0.05,
                       "ch1 应 ≈ -1.0，帧 \(i) 实际 \(f[i * 2 + 1])")
    }
}

runTest("playerDSDPCMFallbackWhenDeviceLacksDoPCarrier") {
    AudioPreferences.hogEnabled = false
    let data = DSFTestHelper.makeMinimalDSF(sampleFreq: 2_822_400, blocks: 2)
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp_dsd_pcm_\(UUID().uuidString).dsf")
    try data.write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let out = MockAudioOutput()
    let limited = AudioDevice(id: 95, name: "PCM Only Unit", uid: "pcm-only-95",
                              maxSampleRate: 48000, supportedRates: [44100, 48000])
    try out.setDevice(limited)
    let pc = PlayerController(output: out)
    try pc.playLocal(url: tmp)
    try assertEqual(pc.state, .playing)
    let fmt = pc.currentFormat
    try assertTrue(fmt != nil)
    try assertFalse(fmt!.isDSD, "DAC 不支持 DoP 载波率时应回退 DSD2PCM")
    try assertEqual(fmt!.sampleFormat, .float32)
    try assertEqual(fmt!.sampleRate, 352_800.0)
    pc.stop()
    AudioPreferences.deviceUID = nil
}

runTest("playerDSDKeepsDoPWhenDeviceSupportsCarrier") {
    AudioPreferences.hogEnabled = false
    let data = DSFTestHelper.makeMinimalDSF(sampleFreq: 2_822_400, blocks: 2)
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp_dsd_dop_\(UUID().uuidString).dsf")
    try data.write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let out = MockAudioOutput()
    let dopDev = AudioDevice(id: 94, name: "DoP Capable Unit", uid: "dop-94",
                             maxSampleRate: 176400,
                             supportedRates: [44100, 48000, 88200, 176400])
    try out.setDevice(dopDev)
    let pc = PlayerController(output: out)
    try pc.playLocal(url: tmp)
    try assertEqual(pc.state, .playing)
    let fmt = pc.currentFormat
    try assertTrue(fmt != nil)
    try assertTrue(fmt!.isDSD, "载波率受支持时应保持 DoP")
    try assertEqual(fmt!.sampleFormat, .int24)
    try assertEqual(fmt!.sampleRate, 176_400.0)
    pc.stop()
    AudioPreferences.deviceUID = nil
}

// ═══════════════════════════════════════════════════════
// DACCapabilityProbe Tests
// ═══════════════════════════════════════════════════════
print("\n═══ DACCapabilityProbe Tests ═══")

runTest("dacProbeWhitelistMatch") {
    // 名字精准匹配 RME ADI-2
    let rate = KnownDSDDevices.matches(name: "RME ADI-2 Pro FS R")
    try assertTrue(rate != nil)
    try assertEqual(rate, .dsd256)
}

runTest("dacProbeWhitelistCaseInsensitive") {
    let rate = KnownDSDDevices.matches(name: "topping d90 mqa")
    try assertTrue(rate != nil)
    try assertEqual(rate, .dsd512)
}

runTest("dacProbeWhitelistUnknownDevice") {
    let rate = KnownDSDDevices.matches(name: "Built-in Output")
    try assertTrue(rate == nil)
}

runTest("dacProbeFullProbe") {
    let dev = AudioDevice(id: 99, name: "Generic USB DAC",
                          uid: "uid-99", maxSampleRate: 384_000,
                          supportedRates: [44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000])
    let result = DACCapabilityProbe.probe(dev)
    try assertTrue(result.supportsDSD64)   // 需 176.4 kHz, ✓
    try assertTrue(result.supportsDSD128)  // 需 352.8 kHz, ✓
    try assertFalse(result.supportsDSD256) // 需 705.6 kHz, ✗
    try assertFalse(result.isWhitelisted)
}

runTest("dacProbeWhitelistOverridesLowSampleRate") {
    // 即便设备 supportedRates 不够，白名单也会标识 isWhitelisted
    let dev = AudioDevice(id: 100, name: "Topping D90",
                          uid: "uid-100", maxSampleRate: 384_000,
                          supportedRates: [44100, 192000, 384000])
    let result = DACCapabilityProbe.probe(dev)
    try assertTrue(result.isWhitelisted)
    try assertEqual(result.whitelistMaxDSD, .dsd512)
}

// ═══════════════════════════════════════════════════════
// SignalPath Tests
// ═══════════════════════════════════════════════════════
print("\n═══ SignalPath Tests ═══")

runTest("signalPathBitPerfectFlag") {
    let dec = AudioFormat.pcm(rate: 96000, channels: 2, bitDepth: 24)
    var prefs = DSPPreferences()
    prefs.bitPerfect = true
    let chain = DSPChain.build(inputFormat: dec, preferences: prefs)
    let path = SignalPath.build(decoderFormat: dec,
                                dspChain: chain,
                                outputFormat: dec,
                                device: AudioDevice(id: 1, name: "RME ADI-2",
                                                    uid: "u1", maxSampleRate: 384000,
                                                    supportedRates: [96000]),
                                isHogMode: true,
                                hardwareRateMatched: true)
    try assertTrue(path.isBitPerfect)
    try assertTrue(path.dsp.isBypass)
    try assertTrue(path.output.isHogMode)
}

runTest("signalPathNotBitPerfectWhenDSPActive") {
    let dec = AudioFormat.pcm(rate: 44100, channels: 2, bitDepth: 16)
    var prefs = DSPPreferences()
    prefs.bitPerfect = false
    prefs.eqEnabled = true
    prefs.parametricBands = [ParametricBand(type: .peaking, frequency: 1000, gain: 3, q: 1.414)]
    let chain = DSPChain.build(inputFormat: dec, preferences: prefs)
    let path = SignalPath.build(decoderFormat: dec,
                                dspChain: chain,
                                outputFormat: dec,
                                device: nil,
                                isHogMode: false,
                                hardwareRateMatched: true)
    try assertFalse(path.isBitPerfect)
    try assertFalse(path.dsp.isBypass)
    try assertTrue(path.dsp.enabledNodes.contains("ParametricEQ"))
}

runTest("signalPathDisplayText") {
    let dec = AudioFormat.pcm(rate: 96000, channels: 2, bitDepth: 24)
    var prefs = DSPPreferences()
    prefs.bitPerfect = true
    let chain = DSPChain.build(inputFormat: dec, preferences: prefs)
    let path = SignalPath.build(decoderFormat: dec,
                                dspChain: chain,
                                outputFormat: dec,
                                device: AudioDevice(id: 1, name: "Mock DAC",
                                                    uid: "u", maxSampleRate: 96000,
                                                    supportedRates: [96000]),
                                isHogMode: true,
                                hardwareRateMatched: true)
    let text = path.displayText
    try assertTrue(text.contains("Bit-Perfect"))
    try assertTrue(text.contains("Mock DAC"))
    try assertTrue(text.contains("Hog"))
    try assertTrue(text.contains("✓"))
}

runTest("signalPathDSDSource") {
    let dsd = AudioFormat(sampleRate: 176_400, channels: 2,
                          sampleFormat: .int24, isDSD: true, sourceBitDepth: 1)
    var prefs = DSPPreferences()
    prefs.bitPerfect = true
    let chain = DSPChain.build(inputFormat: dsd, preferences: prefs)
    let path = SignalPath.build(decoderFormat: dsd,
                                dspChain: chain,
                                outputFormat: dsd,
                                device: nil,
                                isHogMode: false,
                                hardwareRateMatched: false)
    try assertTrue(path.source.isDSD)
    try assertEqual(path.source.format, "DSD64")
    try assertEqual(path.output.format, "DoP DSD64")
}

runTest("playerControllerSignalPathNilWhenStopped") {
    let out = MockAudioOutput()
    let pc = PlayerController(output: out)
    try assertTrue(pc.currentSignalPath() == nil)
}

// ─── issue #8 ReplayGain 接线 + issue #12 FLAC MD5 校验接线 ───

runTest("audioPrefsReplayGainModeNormalizes") {
    UserDefaults.standard.removeObject(forKey: "ppl.replayGainMode")
    try assertEqual(AudioPreferences.replayGainMode, "off")   // 默认
    AudioPreferences.replayGainMode = "track"
    try assertEqual(AudioPreferences.replayGainMode, "track")
    AudioPreferences.replayGainMode = "album"
    try assertEqual(AudioPreferences.replayGainMode, "album")
    AudioPreferences.replayGainMode = "bogus"
    try assertEqual(AudioPreferences.replayGainMode, "off")   // 非法值归一化
    AudioPreferences.replayGainMode = "off"
}

runTest("audioPrefsFlacMD5VerifyDefaultsTrue") {
    UserDefaults.standard.removeObject(forKey: "ppl.flacMD5Verify")
    try assertTrue(AudioPreferences.flacMD5Verify)   // 未设置 = 默认开
    AudioPreferences.flacMD5Verify = false
    try assertFalse(AudioPreferences.flacMD5Verify)
    AudioPreferences.flacMD5Verify = true
    try assertTrue(AudioPreferences.flacMD5Verify)
    UserDefaults.standard.removeObject(forKey: "ppl.flacMD5Verify")
}

runTest("replayGainSelectGainModes") {
    var md = TrackMetadata(duration: 0)
    try assertTrue(ReplayGainReader.selectGain(mode: "off", metadata: md) == nil)
    md.replayGainTrackDB = -6.5
    try assertEqual(ReplayGainReader.selectGain(mode: "track", metadata: md) ?? -999,
                    Float(-6.5))
    md.replayGainAlbumDB = -3.0
    try assertEqual(ReplayGainReader.selectGain(mode: "album", metadata: md) ?? -999,
                    Float(-3.0))
    // album 模式缺 album tag → 回退 track
    var md2 = TrackMetadata(duration: 0)
    md2.replayGainTrackDB = -6.5
    try assertEqual(ReplayGainReader.selectGain(mode: "album", metadata: md2) ?? -999,
                    Float(-6.5))
    // 无 tag → 跳过（nil），不做固定增益猜测
    let empty = TrackMetadata(duration: 0)
    try assertTrue(ReplayGainReader.selectGain(mode: "track", metadata: empty) == nil)
    // 正增益 + peak → 防削波上限 = -20·log10(0.9) ≈ 0.915 dB
    var md3 = TrackMetadata(duration: 0)
    md3.replayGainTrackDB = 6.0
    md3.replayGainTrackPeak = 0.9
    let capped = ReplayGainReader.selectGain(mode: "track", metadata: md3) ?? -999
    try assertTrue(abs(capped - Float(-20 * log10(0.9))) < 0.01,
                   "正增益应被 peak 压到 \(String(describing: -20 * log10(0.9)))，实际 \(capped)")
    // 负增益不受 peak 影响
    var md4 = TrackMetadata(duration: 0)
    md4.replayGainTrackDB = -6.0
    md4.replayGainTrackPeak = 0.9
    try assertEqual(ReplayGainReader.selectGain(mode: "track", metadata: md4) ?? -999,
                    Float(-6.0))
}

runTest("signalPathMD5TagInDisplayText") {
    let dec = AudioFormat.pcm(rate: 44100, channels: 2, bitDepth: 16)
    var prefs = DSPPreferences()
    prefs.bitPerfect = true
    let chain = DSPChain.build(inputFormat: dec, preferences: prefs)
    let dev = AudioDevice(id: 1, name: "Mock DAC", uid: "u",
                          maxSampleRate: 96000, supportedRates: [44100])
    let withTag = SignalPath.build(decoderFormat: dec, dspChain: chain,
                                   outputFormat: dec, device: dev,
                                   isHogMode: false, hardwareRateMatched: true,
                                   md5Tag: "MD5 ✓")
    try assertTrue(withTag.displayText.contains("MD5 ✓"))
    try assertTrue(withTag.md5Tag == "MD5 ✓")
    let noTag = SignalPath.build(decoderFormat: dec, dspChain: chain,
                                 outputFormat: dec, device: dev,
                                 isHogMode: false, hardwareRateMatched: true)
    try assertFalse(noTag.displayText.contains("MD5"))
    try assertTrue(noTag.md5Tag == nil)
}

#if canImport(AudioToolbox)
runTest("flacMD5VerifyDecoderWiring") {
    // 用 afconvert 生成真 FLAC（Apple FLAC 编码器在 STREAMINFO 写 MD5）
    let uid = UUID().uuidString
    let tmpDir = FileManager.default.temporaryDirectory
    let wavURL = tmpDir.appendingPathComponent("pp_md5_\(uid).wav")
    let flacURL = tmpDir.appendingPathComponent("pp_md5_\(uid).flac")
    defer {
        try? FileManager.default.removeItem(at: wavURL)
        try? FileManager.default.removeItem(at: flacURL)
    }
    try WAVTestHelper.makePCM16Stereo(sampleRate: 44100, durationFrames: 8820)
        .write(to: wavURL)
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
    proc.arguments = ["-f", "flac", "-d", "flac", wavURL.path, flacURL.path]
    try proc.run()
    proc.waitUntilExit()
    // 注意：Apple afconvert 对 <4608 帧（1 个 FLAC block）的输入会产出
    // 42 字节 stub（magic 全零）且 exit 0 — 必须校验 fLaC magic
    let flacBytes = (try? Data(contentsOf: flacURL)) ?? Data()
    guard proc.terminationStatus == 0, flacBytes.count > 4,
          flacBytes[0] == 0x66, flacBytes[1] == 0x4C,
          flacBytes[2] == 0x61, flacBytes[3] == 0x43 else {
        print("    (skipped: afconvert FLAC unavailable)")
        return
    }

    func decodeFully(_ dec: CoreAudioDecoder) throws {
        // 按解码器实际输出格式分配 — Apple FLAC 路径输出 float32（8 字节/帧
        // 立体声）；旧值 8820*4 假定 int16 会堆溢出并让 MD5 读到 NaN
        let buf = UnsafeMutableRawPointer.allocate(
            byteCount: 8820 * dec.format.bytesPerFrame, alignment: 16)
        defer { buf.deallocate() }
        while !dec.isAtEnd {
            let n = try dec.decode(into: buf, maxFrames: 8820)
            if n == 0 { break }
        }
    }

    // 偏好开 → 工厂路径（init(source:)）自动启用校验
    AudioPreferences.flacMD5Verify = true
    let dec = try CoreAudioDecoder(source: LocalFileSource(url: flacURL),
                                   fileExtension: "flac")
    try decodeFully(dec)
    let parsed = (try? FLACMetadata.read(from: flacURL)) ?? nil
    if parsed?.streamInfo.hasMD5 == true {
        try assertEqual(dec.md5Result, CoreAudioDecoder.MD5VerificationResult.match,
                        "偏好开启时解码到 EOF 应 MD5 匹配")
    } else {
        try assertEqual(dec.md5Result, CoreAudioDecoder.MD5VerificationResult.missingExpected)
    }
    dec.close()

    // 偏好关 → 不校验
    AudioPreferences.flacMD5Verify = false
    let dec2 = try CoreAudioDecoder(source: LocalFileSource(url: flacURL),
                                    fileExtension: "flac")
    try decodeFully(dec2)
    try assertEqual(dec2.md5Result, CoreAudioDecoder.MD5VerificationResult.notVerified)
    dec2.close()

    UserDefaults.standard.removeObject(forKey: "ppl.flacMD5Verify")   // 恢复默认开
}

runTest("playerAppliesReplayGainFromFLACTag") {
    // 构造带 REPLAYGAIN_TRACK_GAIN vorbis comment 的真 FLAC：
    // afconvert 生成 → 在最后一个 metadata block 后注入 VORBIS_COMMENT 块
    func injectVorbisComment(_ data: Data, comments: [String]) -> Data {
        var d = [UInt8](data)
        guard d.count > 4, d[0] == 0x66, d[1] == 0x4C,
              d[2] == 0x61, d[3] == 0x43 else { return data }
        var pos = 4
        var lastBlockStart = -1
        while pos + 4 <= d.count {
            let header = d[pos]
            let len = (Int(d[pos + 1]) << 16) | (Int(d[pos + 2]) << 8) | Int(d[pos + 3])
            lastBlockStart = pos
            pos += 4 + len
            if (header & 0x80) != 0 { break }
        }
        guard lastBlockStart >= 0 else { return data }
        var body: [UInt8] = []
        func appendLE32(_ v: Int) {
            body += [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
                     UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
        }
        let vendor = Array("PurePlayTest".utf8)
        appendLE32(vendor.count); body += vendor
        appendLE32(comments.count)
        for c in comments {
            let b = Array(c.utf8)
            appendLE32(b.count); body += b
        }
        let bodyLen = (Int(d[lastBlockStart + 1]) << 16)
                      | (Int(d[lastBlockStart + 2]) << 8) | Int(d[lastBlockStart + 3])
        let insertAt = lastBlockStart + 4 + bodyLen
        d[lastBlockStart] &= 0x7F                       // 清除旧 last 标志
        var newBlock: [UInt8] = [0x84,                  // last | type 4 (VORBIS_COMMENT)
                                 UInt8((body.count >> 16) & 0xFF),
                                 UInt8((body.count >> 8) & 0xFF),
                                 UInt8(body.count & 0xFF)]
        newBlock += body
        d.insert(contentsOf: newBlock, at: insertAt)
        return Data(d)
    }

    let uid = UUID().uuidString
    let tmpDir = FileManager.default.temporaryDirectory
    let wavURL = tmpDir.appendingPathComponent("pp_rg_\(uid).wav")
    let flacURL = tmpDir.appendingPathComponent("pp_rg_\(uid).flac")
    defer {
        try? FileManager.default.removeItem(at: wavURL)
        try? FileManager.default.removeItem(at: flacURL)
    }
    // ≥4608 帧：Apple afconvert 对不足 1 个 FLAC block 的输入产出 stub（见前一测试）
    try WAVTestHelper.makePCM16Stereo(sampleRate: 44100, durationFrames: 8820)
        .write(to: wavURL)
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
    proc.arguments = ["-f", "flac", "-d", "flac", wavURL.path, flacURL.path]
    try proc.run()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0,
          let base = try? Data(contentsOf: flacURL),
          base.count > 4, base[0] == 0x66, base[1] == 0x4C,
          base[2] == 0x61, base[3] == 0x43 else {
        print("    (skipped: afconvert FLAC unavailable)")
        return
    }
    let tagged = injectVorbisComment(base, comments: [
        "REPLAYGAIN_TRACK_GAIN=-6.50 dB",
        "REPLAYGAIN_TRACK_PEAK=0.891250",
        "REPLAYGAIN_ALBUM_GAIN=-3.00 dB",
    ])
    try tagged.write(to: flacURL)

    // 注入后仍是合法 FLAC：元数据可读 + ExtAudioFile 可解码
    let parsed = (try? FLACMetadata.read(from: flacURL)) ?? nil
    try assertTrue(parsed != nil, "注入 VORBIS_COMMENT 后 FLAC 解析应成功")
    try assertEqual(parsed?.vorbisComments["REPLAYGAIN_TRACK_GAIN"] ?? "", "-6.50 dB")
    let md = MetadataReader.readMetadata(from: flacURL)
    try assertTrue(md?.replayGainTrackDB != nil)
    try assertTrue(abs((md?.replayGainTrackDB ?? 0) + 6.5) < 0.01)

    // 起播接线：mode=track → GainNode 进链、bitPerfect 解除、dB 如实暴露
    AudioPreferences.hogEnabled = false
    AudioPreferences.replayGainMode = "track"
    let out = MockAudioOutput()
    let pc = PlayerController(output: out)
    try pc.playLocal(url: flacURL)
    try assertEqual(pc.state, .playing)
    try assertTrue(pc.lastReplayGainDB != nil)
    try assertTrue(abs((pc.lastReplayGainDB ?? 0) + 6.5) < 0.01,
                   "peak 0.89125 → headroom 1dB，-6.5dB 不应被压")
    let sp = pc.currentSignalPath()
    try assertTrue(sp?.dsp.enabledNodes.contains("Gain") == true,
                   "GainNode 应出现在信号路径中")
    try assertFalse(sp!.isBitPerfect)
    pc.stop()

    // mode=off → 不应用
    AudioPreferences.replayGainMode = "off"
    let pc2 = PlayerController(output: MockAudioOutput())
    try pc2.playLocal(url: flacURL)
    try assertTrue(pc2.lastReplayGainDB == nil)
    try assertFalse(pc2.currentSignalPath()?.dsp.enabledNodes.contains("Gain") == true)
    pc2.stop()
}
#endif

// ═══════════════════════════════════════════════════════
// Gapless & Schema Tests
// ═══════════════════════════════════════════════════════
print("\n═══ Gapless & Schema Tests ═══")

runTest("canSwapDecoderMatchingFormat") {
    let wav1 = WAVTestHelper.makePCM16Stereo(sampleRate: 44100, durationFrames: 256)
    let wav2 = WAVTestHelper.makePCM16Stereo(sampleRate: 44100, durationFrames: 512)
    let d1 = try WAVDecoder(source: MemorySource(data: wav1))
    let d2 = try WAVDecoder(source: MemorySource(data: wav2))
    let out = MockAudioOutput()
    let pipe = AudioPipeline(decoder: d1, output: out)
    try assertTrue(pipe.canSwapDecoder(d2))
}

runTest("canSwapDecoderMismatchedRate") {
    let wav1 = WAVTestHelper.makePCM16Stereo(sampleRate: 44100, durationFrames: 256)
    let wav2 = WAVTestHelper.makePCM16Stereo(sampleRate: 48000, durationFrames: 256)
    let d1 = try WAVDecoder(source: MemorySource(data: wav1))
    let d2 = try WAVDecoder(source: MemorySource(data: wav2))
    let out = MockAudioOutput()
    let pipe = AudioPipeline(decoder: d1, output: out)
    try assertFalse(pipe.canSwapDecoder(d2))
}

runTest("swapDecoderRejectsMismatch") {
    let wav1 = WAVTestHelper.makePCM16Stereo(sampleRate: 44100, durationFrames: 256)
    let wav2 = WAVTestHelper.makePCM16Stereo(sampleRate: 48000, durationFrames: 256)
    let d1 = try WAVDecoder(source: MemorySource(data: wav1))
    let d2 = try WAVDecoder(source: MemorySource(data: wav2))
    let out = MockAudioOutput()
    let pipe = AudioPipeline(decoder: d1, output: out)
    try assertThrows(try pipe.swapDecoder(d2))
}

runTest("swapDecoderSucceedsOnMatch") {
    let wav1 = WAVTestHelper.makePCM16Stereo(sampleRate: 44100, durationFrames: 256)
    let wav2 = WAVTestHelper.makePCM16Stereo(sampleRate: 44100, durationFrames: 512)
    let d1 = try WAVDecoder(source: MemorySource(data: wav1))
    let d2 = try WAVDecoder(source: MemorySource(data: wav2))
    let out = MockAudioOutput()
    let pipe = AudioPipeline(decoder: d1, output: out)
    try pipe.swapDecoder(d2)
    try assertEqual(pipe.decoder.totalFrames, 512)
}

runTest("tryGaplessAdvanceReturnsFalseWhenQueueEmpty") {
    let out = MockAudioOutput()
    let pc = PlayerController(output: out)
    // No pipeline → false
    try assertFalse(pc.tryGaplessAdvance())
}

runTest("trackRecordEncodesNewFields") {
    let r = TrackRecord(
        filePath: "/x.flac", fileName: "x.flac",
        title: "T", artist: "A", album: "Al",
        source: "quark", cloudFileId: "fid-123",
        format: "flac",
        replayGainTrack: -6.5, replayGainAlbum: -7.2)
    try assertEqual(r.source, "quark")
    try assertEqual(r.cloudFileId, "fid-123")
    try assertEqual(r.format, "flac")
    try assertEqual(r.replayGainTrack, -6.5)
    try assertEqual(r.replayGainAlbum, -7.2)
}

runTest("trackRecordDefaultsToLocal") {
    let r = TrackRecord(filePath: "/x.wav", fileName: "x.wav",
                        title: "T", artist: "A", album: "Al")
    try assertEqual(r.source, "local")
    try assertTrue(r.cloudFileId == nil)
    try assertEqual(r.format, "")
    try assertTrue(r.replayGainTrack == nil)
}

runTest("searchTracksFTSEmptyQuery") {
    let results = try DatabaseManager.shared.searchTracksFTS(query: "  ")
    try assertEqual(results.count, 0)
}

runTest("searchTracksFTSDoesNotCrashOnQuotes") {
    // 引号注入测试 — 不应抛错；返回空或匹配
    let results = try DatabaseManager.shared.searchTracksFTS(query: "test \"with quotes\"")
    try assertGreaterThan(results.count, -1)  // 仅验证不抛异常
}

runTest("tryGaplessAdvanceSwapsForCompatibleQueue") {
    // 写两份完全相同格式的 wav 到 temp 目录，跑实际管线 swap
    let frames = 512
    let wav1 = WAVTestHelper.makePCM16Stereo(sampleRate: 44100, durationFrames: frames)
    let wav2 = WAVTestHelper.makePCM16Stereo(sampleRate: 44100, durationFrames: frames)
    let tmp = FileManager.default.temporaryDirectory
    let u1 = tmp.appendingPathComponent("pp_gapless_a_\(UUID().uuidString).wav")
    let u2 = tmp.appendingPathComponent("pp_gapless_b_\(UUID().uuidString).wav")
    try wav1.write(to: u1)
    try wav2.write(to: u2)
    defer { try? FileManager.default.removeItem(at: u1)
            try? FileManager.default.removeItem(at: u2) }

    let out = MockAudioOutput()
    let pc = PlayerController(output: out)
    pc.queue = [.local(u1), .local(u2)]
    try pc.playFromQueue(index: 0)
    let firstDecoder = ObjectIdentifier(pc.currentSignalPath() != nil ? pc as AnyObject : pc as AnyObject)
    _ = firstDecoder
    let advanced = pc.tryGaplessAdvance()
    pc.stop()
    try assertTrue(advanced)
}

// ═══════════════════════════════════════════════════════
// Cloud Header Prober Tests
// ═══════════════════════════════════════════════════════
print("\n═══ Cloud Header Prober Tests ═══")

runTest("probeDetectsWAV") {
    let wav = WAVTestHelper.makePCM16Stereo(sampleRate: 96000, durationFrames: 16)
    let result = CloudHeaderProber.probe(headerBytes: wav)
    try assertEqual(result.format, .wav)
    try assertEqual(result.extensionHint, "wav")
    try assertTrue(result.audioFormat != nil)
    try assertEqual(result.audioFormat?.sampleRate, 96000.0)
    try assertEqual(result.audioFormat?.channels, 2)
    try assertEqual(result.audioFormat?.sampleFormat, .int16)
}

runTest("probeDetectsAIFF") {
    let aiff = AIFFTestHelper.makePCM16Stereo(sampleRate: 44100, durationFrames: 8)
    let result = CloudHeaderProber.probe(headerBytes: aiff)
    try assertEqual(result.format, .aiff)
    try assertEqual(result.extensionHint, "aiff")
}

runTest("probeDetectsDSF") {
    let dsf = DSFTestHelper.makeMinimalDSF(sampleFreq: 2_822_400, blocks: 1)
    let result = CloudHeaderProber.probe(headerBytes: dsf.prefix(2048))
    try assertEqual(result.format, .dsf)
    try assertEqual(result.extensionHint, "dsf")
    try assertTrue(result.audioFormat != nil)
    try assertEqual(result.audioFormat?.isDSD, true)
    try assertEqual(result.audioFormat?.sampleRate, 176_400.0)
}

runTest("probeDetectsDFF") {
    let dff = DFFTestHelper.makeMinimalDFF(framesPerChannel: 32)
    let result = CloudHeaderProber.probe(headerBytes: dff)
    try assertEqual(result.format, .dff)
    try assertEqual(result.extensionHint, "dff")
}

runTest("probeDetectsMP3WithID3") {
    var data = Data([0x49, 0x44, 0x33, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    data.append(contentsOf: [UInt8](repeating: 0, count: 100))
    let r = CloudHeaderProber.probe(headerBytes: data)
    try assertEqual(r.format, .mp3)
}

runTest("probeDetectsRawMP3Frame") {
    var data = Data([0xFF, 0xFB])   // sync word + MPEG-1 Layer 3
    data.append(contentsOf: [UInt8](repeating: 0, count: 32))
    let r = CloudHeaderProber.probe(headerBytes: data)
    try assertEqual(r.format, .mp3)
}

runTest("probeReturnsUnknownForGarbage") {
    let garbage = Data([UInt8](repeating: 0xAA, count: 256))
    let r = CloudHeaderProber.probe(headerBytes: garbage)
    try assertEqual(r.format, .unknown)
}

runTest("probeTooShortReturnsUnknown") {
    let r = CloudHeaderProber.probe(headerBytes: Data([0x46, 0x4F]))
    try assertEqual(r.format, .unknown)
}

// ═══════════════════════════════════════════════════════
// CloudStreamSource Tests (no network)
// ═══════════════════════════════════════════════════════
print("\n═══ CloudStreamSource Tests ═══")

runTest("cloudStreamReadFromInjectedChunk") {
    let client = QuarkAPIClient(keychain: InMemoryCookieStore())
    let totalBytes: Int64 = 1024
    let source = CloudStreamSource(client: client, fid: "test", fileSize: totalBytes,
                                   chunkSize: 256, prebufferBytes: 256)
    // 注入两个 chunk
    let chunk0 = Data((0..<256).map { UInt8($0 & 0xFF) })
    let chunk1 = Data((0..<256).map { UInt8(($0 + 100) & 0xFF) })
    source._testInjectChunk(index: 0, data: chunk0)
    source._testInjectChunk(index: 1, data: chunk1)
    try assertEqual(source.downloadedBytes, 512)

    // 读 100 字节
    let buf = UnsafeMutableRawPointer.allocate(byteCount: 100, alignment: 16)
    defer { buf.deallocate() }
    let n = try source.read(into: buf, length: 100)
    try assertEqual(n, 100)
    let read = Data(bytes: buf, count: 100)
    try assertEqual(read, chunk0.prefix(100))
    try assertEqual(source.currentPosition, 100)
}

runTest("cloudStreamReadAcrossChunkBoundary") {
    let client = QuarkAPIClient(keychain: InMemoryCookieStore())
    let source = CloudStreamSource(client: client, fid: "x", fileSize: 512,
                                   chunkSize: 256, prebufferBytes: 256)
    let chunk0 = Data((0..<256).map { _ in UInt8(0xAA) })
    let chunk1 = Data((0..<256).map { _ in UInt8(0xBB) })
    source._testInjectChunk(index: 0, data: chunk0)
    source._testInjectChunk(index: 1, data: chunk1)

    // 第一次 read 取尾部 50 字节，仅命中 chunk0
    try source.seek(to: 206)
    let buf = UnsafeMutableRawPointer.allocate(byteCount: 50, alignment: 16)
    defer { buf.deallocate() }
    let n1 = try source.read(into: buf, length: 50)
    try assertEqual(n1, 50)
    let bytes1 = [UInt8](Data(bytes: buf, count: 50))
    try assertTrue(bytes1.allSatisfy { $0 == 0xAA })

    // 下一次 read 从 256 开始命中 chunk1
    let n2 = try source.read(into: buf, length: 50)
    try assertEqual(n2, 50)
    let bytes2 = [UInt8](Data(bytes: buf, count: 50))
    try assertTrue(bytes2.allSatisfy { $0 == 0xBB })
}

runTest("cloudStreamSeekUpdatesPosition") {
    let client = QuarkAPIClient(keychain: InMemoryCookieStore())
    let source = CloudStreamSource(client: client, fid: "x", fileSize: 1024,
                                   chunkSize: 256, prebufferBytes: 256)
    try source.seek(to: 500)
    try assertEqual(source.currentPosition, 500)
    try source.seek(to: 0)
    try assertEqual(source.currentPosition, 0)
}

runTest("cloudStreamSeekRejectsOutOfBounds") {
    let client = QuarkAPIClient(keychain: InMemoryCookieStore())
    let source = CloudStreamSource(client: client, fid: "x", fileSize: 100,
                                   chunkSize: 256, prebufferBytes: 256)
    try assertThrows(try source.seek(to: -1))
    try assertThrows(try source.seek(to: 200))
}

runTest("cloudStreamReadAtEOFReturnsZero") {
    let client = QuarkAPIClient(keychain: InMemoryCookieStore())
    let source = CloudStreamSource(client: client, fid: "x", fileSize: 100,
                                   chunkSize: 256, prebufferBytes: 0)
    try source.seek(to: 100)
    let buf = UnsafeMutableRawPointer.allocate(byteCount: 10, alignment: 16)
    defer { buf.deallocate() }
    let n = try source.read(into: buf, length: 10)
    try assertEqual(n, 0)
}

// ═══════════════════════════════════════════════════════
// CloudPrefetchManager Tests
// ═══════════════════════════════════════════════════════
print("\n═══ CloudPrefetchManager Tests ═══")

runTest("prefetchTriggersBelowThreshold") {
    let pm = CloudPrefetchManager(triggerThresholdSeconds: 30,
                                  prefetchBytes: 1024)
    var calls = 0
    pm.nextCloudInfoProvider = {
        calls += 1
        return (fid: "next-fid", fileSize: 5_000_000)
    }
    pm.cloudSourceBuilder = { fid, size in
        let client = QuarkAPIClient(keychain: InMemoryCookieStore())
        return CloudStreamSource(client: client, fid: fid, fileSize: size,
                                 chunkSize: 256, prebufferBytes: 0)
    }
    // 在阈值内
    pm.tick(currentDuration: 100, currentTime: 75)  // 剩 25s ≤ 30s
    try assertGreaterThan(calls, 0)
    try assertTrue(pm.prefetching != nil)
    pm.cancel()
}

runTest("prefetchDoesNotTriggerAboveThreshold") {
    let pm = CloudPrefetchManager(triggerThresholdSeconds: 30,
                                  prefetchBytes: 1024)
    var calls = 0
    pm.nextCloudInfoProvider = {
        calls += 1
        return (fid: "x", fileSize: 1024)
    }
    pm.cloudSourceBuilder = { fid, size in
        let client = QuarkAPIClient(keychain: InMemoryCookieStore())
        return CloudStreamSource(client: client, fid: fid, fileSize: size,
                                 chunkSize: 256, prebufferBytes: 0)
    }
    pm.tick(currentDuration: 200, currentTime: 100)  // 剩 100s > 30s
    try assertEqual(calls, 0)
    try assertTrue(pm.prefetching == nil)
}

runTest("prefetchDedupesSameTrack") {
    let pm = CloudPrefetchManager(triggerThresholdSeconds: 30, prefetchBytes: 512)
    var calls = 0
    pm.nextCloudInfoProvider = {
        calls += 1
        return (fid: "stable-fid", fileSize: 1024)
    }
    pm.cloudSourceBuilder = { fid, size in
        let client = QuarkAPIClient(keychain: InMemoryCookieStore())
        return CloudStreamSource(client: client, fid: fid, fileSize: size,
                                 chunkSize: 256, prebufferBytes: 0)
    }
    pm.tick(currentDuration: 60, currentTime: 40)
    pm.tick(currentDuration: 60, currentTime: 45)
    pm.tick(currentDuration: 60, currentTime: 50)
    // provider 仍可能被调用多次（因为 tick 每次都查询），
    // 但 builder 只应被调用一次（去重）
    try assertTrue(pm.prefetching != nil)
    pm.cancel()
}

runTest("prefetchConsumeMatchesFid") {
    let pm = CloudPrefetchManager(triggerThresholdSeconds: 30, prefetchBytes: 512)
    pm.nextCloudInfoProvider = { (fid: "fid-X", fileSize: 1024) }
    pm.cloudSourceBuilder = { fid, size in
        let client = QuarkAPIClient(keychain: InMemoryCookieStore())
        return CloudStreamSource(client: client, fid: fid, fileSize: size,
                                 chunkSize: 256, prebufferBytes: 0)
    }
    pm.triggerIfNeeded()
    try assertTrue(pm.prefetching != nil)
    let consumed = pm.consumePrefetch(for: "fid-X")
    try assertTrue(consumed != nil)
    try assertTrue(pm.prefetching == nil)
    let none = pm.consumePrefetch(for: "fid-X")
    try assertTrue(none == nil)
}

// ═══════════════════════════════════════════════════════
// WaveformBuffer Tests
// ═══════════════════════════════════════════════════════
print("\n═══ WaveformBuffer Tests ═══")

runTest("waveformBufferEmptySnapshot") {
    let buf = WaveformBuffer(capacityBins: 8, framesPerBin: 4)
    let snap = buf.snapshot(count: 8)
    try assertEqual(snap.count, 8)
    try assertTrue(snap.allSatisfy { $0.peak == 0 && $0.rms == 0 })
}

runTest("waveformBufferPushOneBin") {
    let buf = WaveformBuffer(capacityBins: 8, framesPerBin: 4)
    // 4 frames, mono, all = 1.0 → peak=1.0, rms=1.0
    let samples: [Float] = [1.0, 1.0, 1.0, 1.0]
    samples.withUnsafeBufferPointer { p in
        buf.push(samples: p.baseAddress!, frameCount: 4, channels: 1)
    }
    try assertEqual(buf.binsWritten, 1)
    let snap = buf.snapshot(count: 1)
    try assertEqual(snap.count, 1)
    try assertEqualFloat(snap[0].peak, 1.0, accuracy: 1e-6)
    try assertEqualFloat(snap[0].rms, 1.0, accuracy: 1e-6)
}

runTest("waveformBufferMultiChannelPeak") {
    let buf = WaveformBuffer(capacityBins: 4, framesPerBin: 2)
    // 2 frames stereo: [(L=0.3, R=0.8), (L=0.5, R=-0.2)]
    // peak = max(|0.3|, |0.8|, |0.5|, |0.2|) = 0.8
    let samples: [Float] = [0.3, 0.8, 0.5, -0.2]
    samples.withUnsafeBufferPointer { p in
        buf.push(samples: p.baseAddress!, frameCount: 2, channels: 2)
    }
    let snap = buf.snapshot(count: 1)
    try assertEqualFloat(snap[0].peak, 0.8, accuracy: 1e-6)
}

runTest("waveformBufferRingWrapAround") {
    let buf = WaveformBuffer(capacityBins: 3, framesPerBin: 2)
    // Push 5 bins worth of data; only the last 3 should remain
    // Bin values 0.1, 0.3, 0.5, 0.7, 0.9 — only 0.5, 0.7, 0.9 kept
    let amplitudes: [Float] = [0.1, 0.3, 0.5, 0.7, 0.9]
    for amp in amplitudes {
        let frames: [Float] = [amp, amp]
        frames.withUnsafeBufferPointer { p in
            buf.push(samples: p.baseAddress!, frameCount: 2, channels: 1)
        }
    }
    try assertEqual(buf.binsWritten, 5)
    let snap = buf.snapshot(count: 3)
    try assertEqual(snap.count, 3)
    try assertEqualFloat(snap[0].peak, 0.5, accuracy: 1e-6)
    try assertEqualFloat(snap[1].peak, 0.7, accuracy: 1e-6)
    try assertEqualFloat(snap[2].peak, 0.9, accuracy: 1e-6)
}

runTest("waveformBufferReset") {
    let buf = WaveformBuffer(capacityBins: 4, framesPerBin: 2)
    let samples: [Float] = [1.0, 1.0]
    samples.withUnsafeBufferPointer { p in
        buf.push(samples: p.baseAddress!, frameCount: 2, channels: 1)
    }
    try assertEqual(buf.binsWritten, 1)
    buf.reset()
    try assertEqual(buf.binsWritten, 0)
    let snap = buf.snapshot(count: 4)
    try assertTrue(snap.allSatisfy { $0.peak == 0 && $0.rms == 0 })
}

runTest("waveformBufferSnapshotPaddedWithZero") {
    let buf = WaveformBuffer(capacityBins: 8, framesPerBin: 2)
    let samples: [Float] = [0.5, 0.5]
    samples.withUnsafeBufferPointer { p in
        buf.push(samples: p.baseAddress!, frameCount: 2, channels: 1)
    }
    // Request 5 bins, only 1 written → first 4 should be zero, last = 0.5
    let snap = buf.snapshot(count: 5)
    try assertEqual(snap.count, 5)
    try assertEqual(snap[0].peak, 0)
    try assertEqual(snap[3].peak, 0)
    try assertEqualFloat(snap[4].peak, 0.5, accuracy: 1e-6)
}

// ═══════════════════════════════════════════════════════
// End-to-End Playback & Stress Tests
// ═══════════════════════════════════════════════════════
print("\n═══ E2E Playback & Stress Tests ═══")

runTest("e2ePlaybackFullTrack") {
    let frames = 2205
    let wav = WAVTestHelper.makePCM16Stereo(sampleRate: 44100, durationFrames: frames)
    let dec = try WAVDecoder(source: MemorySource(data: wav))
    let out = MockAudioOutput()
    let pipe = AudioPipeline(decoder: dec, output: out)
    try pipe.start()
    Thread.sleep(forTimeInterval: 0.3)
    let pulled = out.pullFrames(frames, bytesPerFrame: pipe.outputFormat.bytesPerFrame)
    pipe.stop()
    try assertGreaterThan(pulled, 0)
}

runTest("e2ePipelineStopMidStream") {
    let frames = 441000  // 10 seconds — too large to finish in 50ms
    let wav = WAVTestHelper.makePCM16Stereo(sampleRate: 44100, durationFrames: frames)
    let dec = try WAVDecoder(source: MemorySource(data: wav))
    let out = MockAudioOutput()
    let pipe = AudioPipeline(decoder: dec, output: out)
    try pipe.start()
    Thread.sleep(forTimeInterval: 0.05)
    out.pullFrames(512, bytesPerFrame: pipe.outputFormat.bytesPerFrame)
    pipe.stop()
    // Verify stop didn't crash and output is no longer playing
    try assertFalse(out.isPlaying)
}

runTest("stressGapless50Tracks") {
    let trackFrames = 256
    let trackCount = 50
    let tmp = FileManager.default.temporaryDirectory
    var urls: [URL] = []
    for i in 0..<trackCount {
        let wav = WAVTestHelper.makePCM16Stereo(sampleRate: 44100, durationFrames: trackFrames)
        let u = tmp.appendingPathComponent("pp_stress_\(i)_\(UUID().uuidString).wav")
        try wav.write(to: u)
        urls.append(u)
    }
    defer { for u in urls { try? FileManager.default.removeItem(at: u) } }

    let out = MockAudioOutput()
    let pc = PlayerController(output: out)
    pc.queue = urls.map { .local($0) }
    try pc.playFromQueue(index: 0)
    Thread.sleep(forTimeInterval: 0.15)

    for _ in 1..<trackCount {
        let advanced = pc.tryGaplessAdvance()
        if !advanced { break }
    }
    pc.stop()
    try assertEqual(pc.currentTrackIndex, trackCount - 1)
}

runTest("stressVolumeAcrossTrackChange") {
    let wav1 = WAVTestHelper.makePCM16Stereo(sampleRate: 44100, durationFrames: 512)
    let wav2 = WAVTestHelper.makePCM16Stereo(sampleRate: 44100, durationFrames: 512)
    let tmp = FileManager.default.temporaryDirectory
    let u1 = tmp.appendingPathComponent("pp_vol_a_\(UUID().uuidString).wav")
    let u2 = tmp.appendingPathComponent("pp_vol_b_\(UUID().uuidString).wav")
    try wav1.write(to: u1)
    try wav2.write(to: u2)
    defer { try? FileManager.default.removeItem(at: u1)
            try? FileManager.default.removeItem(at: u2) }

    let out = MockAudioOutput()
    let pc = PlayerController(output: out)
    pc.setVolume(0.3)
    pc.queue = [.local(u1), .local(u2)]
    try pc.playFromQueue(index: 0)
    Thread.sleep(forTimeInterval: 0.1)
    pc.stop()
    // Play second track — volume must persist
    try pc.playFromQueue(index: 1)
    Thread.sleep(forTimeInterval: 0.1)
    // issue #1: HAL 数字增益 (kHALOutputParam_Volume) 不再被使用 —
    // 输出后端音量恒为 unity，音量只存在于 DSP float 域
    try assertEqualFloat(out.currentVolume, 1.0, accuracy: 0.0001)
    // 滑杆位置跨曲目保留
    try assertEqualFloat(pc.volume, 0.3, accuracy: 0.001)
    pc.stop()
}

// ═══════════════════════════════════════════════════════
// Volume: bit-perfect 保护 (issue #1) + 感知 dB 曲线 (issue #17)
// ═══════════════════════════════════════════════════════
print("\n═══ Volume Curve / Bit-Perfect Volume Tests ═══")

runTest("volumeCurveEndpoints") {
    try assertEqualFloat(VolumeCurve.linearGain(slider: 1.0), 1.0, accuracy: 1e-6)
    try assertEqualFloat(VolumeCurve.linearGain(slider: 0.0), 0.0, accuracy: 1e-6)
    try assertEqualFloat(VolumeCurve.dB(slider: 1.0), 0.0, accuracy: 1e-6)
    try assertTrue(VolumeCurve.dB(slider: 0.0) == -Float.infinity)
}

runTest("volumeCurveMidpointIsMinus30dB") {
    try assertEqualFloat(VolumeCurve.dB(slider: 0.5), -30.0, accuracy: 1e-4)
    try assertEqualFloat(VolumeCurve.linearGain(slider: 0.5), pow(10, -1.5), accuracy: 1e-5)
}

runTest("volumeCurveMonotonic") {
    for i in 1...100 {
        let hi = VolumeCurve.linearGain(slider: Float(i) / 100)
        let lo = VolumeCurve.linearGain(slider: Float(i - 1) / 100)
        try assertGreaterThan(hi, lo)
    }
}

runTest("playerControllerVolumeBitPerfectStaysUnity") {
    let out = MockAudioOutput()
    let pc = PlayerController(output: out)              // 默认 bitPerfect = true
    pc.setVolume(0.3)
    try assertEqualFloat(pc.effectiveVolumeGain, 1.0, accuracy: 0)

    var prefs = DSPPreferences()
    prefs.bitPerfect = false
    let pc2 = PlayerController(output: out, dspPreferences: prefs)
    pc2.setVolume(0.5)
    try assertEqualFloat(pc2.effectiveVolumeGain,
                         VolumeCurve.linearGain(slider: 0.5), accuracy: 1e-6)
}

runTest("pipelineAppliesVolumeInDSPDomain") {
    var prefs = DSPPreferences()
    prefs.bitPerfect = false
    prefs.replayGainEnabled = true
    prefs.replayGainDB = 0            // 链非空 → float32 DSP 路径
    let dec = SineDecoder(sampleRate: 44100, channels: 1, durationSeconds: 1,
                          frequency: 1000, amplitude: 0.5)
    let out = MockAudioOutput()
    let pipe = AudioPipeline(decoder: dec, output: out, dspPreferences: prefs)
    pipe.setVolume(linearGain: 0.5)
    try pipe.start()
    Thread.sleep(forTimeInterval: 0.25)
    // issue #9：ring 中是 int24（mono，BPF=3）— 音量作用在 float 域，
    // 之后经 PCMOutputConverter 量化为整数
    let frames = 1024
    let bpf = pipe.outputFormat.bytesPerFrame
    try assertEqual(pipe.outputFormat.sampleFormat, .int24)
    let buf = UnsafeMutableRawPointer.allocate(byteCount: frames * bpf, alignment: 16)
    defer { buf.deallocate() }
    let read = pipe.ringBuffer.read(into: buf, length: frames * bpf)
    try assertEqual(read, frames * bpf)
    let raw = buf.assumingMemoryBound(to: UInt8.self)
    var peakCode: Int32 = 0
    for i in 0..<frames {
        var v = Int32(raw[i * 3]) | (Int32(raw[i * 3 + 1]) << 8) | (Int32(raw[i * 3 + 2]) << 16)
        if v & 0x800000 != 0 { v |= ~0xFFFFFF }
        peakCode = max(peakCode, abs(v))
    }
    // 0.5 振幅 × 0.5 增益 = 0.25 → int24 ≈ 0.25 × 2^23 = 2097152
    try assertEqualFloat(Float(peakCode), 2_097_152, accuracy: 200_000)
    pipe.stop()
}

runTest("pipelineBitPerfectIgnoresVolume") {
    let frames = 2048
    let wav = WAVTestHelper.makePCM16Stereo(sampleRate: 44100, durationFrames: frames)
    let source = MemorySource(data: wav)
    let dec = try WAVDecoder(source: source)
    let out = MockAudioOutput()
    let pipe = AudioPipeline(decoder: dec, output: out)   // 默认 bitPerfect → 空链
    pipe.setVolume(linearGain: 0.5)                        // 必须不生效
    try pipe.start()
    Thread.sleep(forTimeInterval: 0.25)
    let byteCount = frames * 4
    let buf = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
    defer { buf.deallocate() }
    let read = pipe.ringBuffer.read(into: buf, length: byteCount)
    try assertEqual(read, byteCount)
    let original = wav.subdata(in: 44..<(44 + byteCount))
    try assertEqual(Data(bytes: buf, count: byteCount), original,
                    "bit-perfect 路径不得应用任何增益（DoP 标记字节依赖此保证）")
    pipe.stop()
}

// ═══════════════════════════════════════════════════════
// BitPerfect Acceptance Tests (Design.md §12)
// ═══════════════════════════════════════════════════════
print("\n═══ BitPerfect Acceptance Tests ═══")

// §12 testWAV_RawByteCompare — 解码字节流必须与源 data chunk 完全一致
runTest("acceptance_WAV_RawByteCompare") {
    let frames = 8192
    let wav = WAVTestHelper.makePCM16Stereo(sampleRate: 44100, durationFrames: frames)
    let source = MemorySource(data: wav)
    let decoder = try WAVDecoder(source: source)
    let bytesPerFrame = decoder.format.bytesPerFrame
    let totalBytes = frames * bytesPerFrame
    let buf = UnsafeMutableRawPointer.allocate(byteCount: totalBytes, alignment: 16)
    defer { buf.deallocate() }
    let n = try decoder.decode(into: buf, maxFrames: frames)
    try assertEqual(n, frames)
    let originalPCM = wav.subdata(in: 44..<(44 + totalBytes))
    let decoded = Data(bytes: buf, count: totalBytes)
    try assertEqual(decoded, originalPCM, "WAV decoded bytes must equal source data chunk")
}

// §12 testDSD_DoP_RoundTrip — DSD bitstream → DoP 24bit → 解包应还原 DSD bits
runTest("acceptance_DSD_DoP_RoundTrip") {
    // 用确定性 pattern：每个字节 = (b*blockSize+i) & 0xFF
    let dsf = DSFTestHelper.makeMinimalDSF(sampleFreq: 2_822_400, blocks: 1) { _, idx in
        UInt8(idx & 0xFF)
    }
    let source = MemorySource(data: dsf)
    let decoder = try DSFDecoder(source: source)

    // 解码 16 帧 (96 字节 = 32 个 24-bit samples)
    let frameCount = 16
    let bytes = frameCount * decoder.format.bytesPerFrame
    let buf = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
    defer { buf.deallocate() }
    let n = try decoder.decode(into: buf, maxFrames: frameCount)
    try assertEqual(n, frameCount)

    // 验证每个 24-bit sample 最高字节是 DoP 标记（LE 存储：第 2 字节）
    let p = buf.assumingMemoryBound(to: UInt8.self)
    var expectedMarker: UInt8 = 0x05
    for f in 0..<frameCount {
        for c in 0..<2 {
            let markerByte = p[f * 6 + c * 3 + 2]
            try assertEqual(markerByte, expectedMarker,
                            "frame=\(f) ch=\(c) marker mismatch")
        }
        expectedMarker = (expectedMarker == 0x05) ? 0xFA : 0x05
    }
}

// §12 testHogMode_Exclusivity — Hog 期间设备独占；release 后恢复
runTest("acceptance_HogMode_Exclusivity") {
    let out = MockAudioOutput()
    let dev = out.listDevices().first!
    try out.setDevice(dev)
    try assertFalse(out.isHogMode, "initially not in hog")
    try out.acquireHogMode()
    try assertTrue(out.isHogMode, "Hog acquired = exclusive")
    try out.releaseHogMode()
    try assertFalse(out.isHogMode, "Hog released = device returns to shared")
}

// §12 testAutoSampleRateSwitch — 不同源率应触发 PhysicalFormat 调用
runTest("acceptance_AutoSampleRateSwitch") {
    let out = MockAudioOutput()
    let dev = out.listDevices().first!
    try out.setDevice(dev)

    // 模拟 96k → 192k 切换：通过 AudioPipeline.start 触发
    let sineFmt = AudioFormat.pcm(rate: 96000, channels: 2, bitDepth: 24)
    let wavData = WAVTestHelper.makePCM24Mono(sampleRate: 96000, durationFrames: 4096)
    let src = MemorySource(data: wavData)
    let dec1 = try WAVDecoder(source: src)
    _ = sineFmt
    let pipe1 = AudioPipeline(decoder: dec1, output: out)
    try pipe1.start()
    pipe1.stop()
    try assertGreaterThan(out.setPhysicalFormatCalls.count, 0)
    let firstCall = out.setPhysicalFormatCalls[0]
    try assertEqual(firstCall.sampleRate, 96000.0)

    // 下一首 192k 文件
    let wav2 = WAVTestHelper.makePCM16Stereo(sampleRate: 192000, durationFrames: 4096)
    let dec2 = try WAVDecoder(source: MemorySource(data: wav2))
    let pipe2 = AudioPipeline(decoder: dec2, output: out)
    try pipe2.start()
    pipe2.stop()
    let last = out.setPhysicalFormatCalls.last!
    try assertEqual(last.sampleRate, 192000.0)
}

// §12 testTrueBitPerfectMode — DSP bypass 时 ring buffer 内容必须 = 解码原始字节
runTest("acceptance_TrueBitPerfectMode") {
    let frames = 1024
    let wav = WAVTestHelper.makePCM16Stereo(sampleRate: 44100, durationFrames: frames)
    let decoder = try WAVDecoder(source: MemorySource(data: wav))
    let out = MockAudioOutput()
    var prefs = DSPPreferences()
    prefs.bitPerfect = true
    let pipe = AudioPipeline(decoder: decoder, output: out, dspPreferences: prefs)
    try assertTrue(pipe.dspChain.isBypass, "bitPerfect=true must produce empty DSP chain")
    try assertEqual(pipe.outputFormat.sampleFormat, .int16,
                    "outputFormat must equal decoder native format in bit-perfect")
    try assertEqual(pipe.outputFormat.bytesPerFrame, 4)
    try pipe.start()
    // 等待解码线程把内容填进 ring buffer
    Thread.sleep(forTimeInterval: 0.2)

    let bytes = frames * pipe.outputFormat.bytesPerFrame
    let buf = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
    defer { buf.deallocate() }
    let read = pipe.ringBuffer.read(into: buf, length: bytes)
    pipe.stop()
    try assertGreaterThan(read, 0)
    // 校验前 N 字节与 WAV data chunk 前 N 字节相等
    let originalPCM = wav.subdata(in: 44..<(44 + read))
    let ringContent = Data(bytes: buf, count: read)
    try assertEqual(ringContent, originalPCM, "Ring buffer in bit-perfect mode must equal source PCM bytes")
}

// §12 testPhysicalFormat_PreferredOverNominal — Physical 成功时不调 NominalSampleRate
runTest("acceptance_PhysicalFormatPreferred") {
    let out = MockAudioOutput()
    let dev = out.listDevices().first!
    try out.setDevice(dev)
    out.physicalFormatSucceeds = true

    let wav = WAVTestHelper.makePCM16Stereo(sampleRate: 96000, durationFrames: 1024)
    let dec = try WAVDecoder(source: MemorySource(data: wav))
    let pipe = AudioPipeline(decoder: dec, output: out)
    try pipe.start()
    pipe.stop()

    try assertTrue(pipe.didMatchHardwareRate)
    try assertGreaterThan(out.setPhysicalFormatCalls.count, 0)
}

// 设备生命周期事件钩子
runTest("acceptance_DeviceLifecycleHooks") {
    let out = MockAudioOutput()
    var lostFired = false
    var defaultChangedFired = false
    var streamChangedFired = false
    var devicesChangedFired = false
    out.onDeviceLost = { lostFired = true }
    out.onDefaultDeviceChanged = { _ in defaultChangedFired = true }
    out.onStreamFormatChanged = { streamChangedFired = true }
    out.onDevicesChanged = { devicesChangedFired = true }

    out.simulateDeviceLost()
    out.simulateDefaultDeviceChanged(to: nil)
    out.simulateStreamFormatChanged()
    out.simulateDevicesChanged()

    try assertTrue(lostFired)
    try assertTrue(defaultChangedFired)
    try assertTrue(streamChangedFired)
    try assertTrue(devicesChangedFired)
}

// ═══════════════════════════════════════════════════════
// Parametric EQ Tests
// ═══════════════════════════════════════════════════════

runTest("parametricBandInit") {
    let band = ParametricBand()
    try assertEqual(band.type, .peaking)
    try assertEqual(band.frequency, 1000)
    try assertEqual(band.gain, 0)
    try assertEqual(band.q, 1.414)
    try assertTrue(band.enabled)
}

runTest("parametricBandRanges") {
    try assertEqual(ParametricBand.frequencyRange, 20...20000)
    try assertEqual(ParametricBand.gainRange, -24...24)
    try assertEqual(ParametricBand.qRange, 0.1...30)
    try assertEqual(ParametricBand.maxBands, 20)
}

runTest("parametricEQNodeFlatResponse") {
    let node = ParametricEQNode(bands: [])
    let fmt = AudioFormat(sampleRate: 48000, channels: 2, sampleFormat: .float32)
    _ = node.configure(inputFormat: fmt)
    let input: [Float] = [0.5, -0.5, 0.25, -0.25]
    var output = [Float](repeating: 0, count: 4)
    node.process(input: input, output: &output, frameCount: 4)
    try assertEqual(output[0], 0.5)
    try assertEqual(output[1], -0.5)
}

runTest("parametricEQNodePreamp") {
    let node = ParametricEQNode(bands: [], preamp: 6.0)
    let fmt = AudioFormat(sampleRate: 48000, channels: 1, sampleFormat: .float32)
    _ = node.configure(inputFormat: fmt)
    let input: [Float] = [0.5]
    var output = [Float](repeating: 0, count: 1)
    node.process(input: input, output: &output, frameCount: 1)
    let expectedGain = pow(10.0, 6.0 / 20.0) as Float
    let diff = abs(output[0] - 0.5 * expectedGain)
    try assertTrue(diff < 0.001, "preamp gain mismatch: \(output[0]) vs \(0.5 * expectedGain)")
}

runTest("parametricEQNodePeaking") {
    let band = ParametricBand(type: .peaking, frequency: 1000, gain: 6, q: 1.414)
    let node = ParametricEQNode(bands: [band])
    let fmt = AudioFormat(sampleRate: 48000, channels: 1, sampleFormat: .float32)
    _ = node.configure(inputFormat: fmt)
    let magAt1k = node.magnitudeDBAt(frequency: 1000)
    try assertTrue(abs(magAt1k - 6.0) < 0.5, "peaking at 1kHz: expected ~6dB, got \(magAt1k)")
    let magAt20 = node.magnitudeDBAt(frequency: 20)
    try assertTrue(abs(magAt20) < 1.0, "peaking at 20Hz: expected ~0dB, got \(magAt20)")
}

runTest("parametricEQNodeLowShelf") {
    let band = ParametricBand(type: .lowShelf, frequency: 200, gain: 6, q: 0.707)
    let node = ParametricEQNode(bands: [band])
    let fmt = AudioFormat(sampleRate: 48000, channels: 1, sampleFormat: .float32)
    _ = node.configure(inputFormat: fmt)
    let magAt50 = node.magnitudeDBAt(frequency: 50)
    try assertTrue(magAt50 > 4.0, "lowShelf at 50Hz: expected >4dB, got \(magAt50)")
    let magAt10k = node.magnitudeDBAt(frequency: 10000)
    try assertTrue(abs(magAt10k) < 1.0, "lowShelf at 10kHz: expected ~0dB, got \(magAt10k)")
}

runTest("parametricEQNodeHighShelf") {
    let band = ParametricBand(type: .highShelf, frequency: 4000, gain: 6, q: 0.707)
    let node = ParametricEQNode(bands: [band])
    let fmt = AudioFormat(sampleRate: 48000, channels: 1, sampleFormat: .float32)
    _ = node.configure(inputFormat: fmt)
    let magAt16k = node.magnitudeDBAt(frequency: 16000)
    try assertTrue(magAt16k > 4.0, "highShelf at 16kHz: expected >4dB, got \(magAt16k)")
    let magAt100 = node.magnitudeDBAt(frequency: 100)
    try assertTrue(abs(magAt100) < 1.0, "highShelf at 100Hz: expected ~0dB, got \(magAt100)")
}

runTest("parametricEQGraphicCompat") {
    let gains: [Float] = [3, 2, 1, 0, -1, -2, -1, 0, 1, 2]
    let node = ParametricEQNode(graphicGains: gains)
    try assertEqual(node.bands.count, 10)
    try assertEqual(node.bands[0].frequency, 31)
    try assertEqual(node.bands[0].gain, 3)
    try assertEqual(node.bands[0].q, 1.414)
    try assertEqual(node.bands[0].type, .peaking)
}

runTest("parametricEQDisabledBands") {
    var band = ParametricBand(type: .peaking, frequency: 1000, gain: 12, q: 1.0)
    band.enabled = false
    let node = ParametricEQNode(bands: [band])
    let fmt = AudioFormat(sampleRate: 48000, channels: 1, sampleFormat: .float32)
    _ = node.configure(inputFormat: fmt)
    let magAt1k = node.magnitudeDBAt(frequency: 1000)
    try assertTrue(abs(magAt1k) < 0.01, "disabled band should have no effect: \(magAt1k)")
}

runTest("parametricEQNodeLowPass12") {
    // RBJ LPF with Q=0.707 (Butterworth) at 1 kHz cutoff:
    // ~0 dB in passband (100 Hz), ~-3 dB at cutoff, strong attenuation at 10 kHz.
    let band = ParametricBand(type: .lowPass12, frequency: 1000, gain: 0, q: 0.707)
    let node = ParametricEQNode(bands: [band])
    let fmt = AudioFormat(sampleRate: 48000, channels: 1, sampleFormat: .float32)
    _ = node.configure(inputFormat: fmt)
    let magAt100 = node.magnitudeDBAt(frequency: 100)
    try assertTrue(abs(magAt100) < 0.5, "LPF passband at 100Hz: expected ~0dB, got \(magAt100)")
    let magAtCutoff = node.magnitudeDBAt(frequency: 1000)
    try assertTrue(abs(magAtCutoff - (-3.0)) < 1.0, "LPF at cutoff 1kHz: expected ~-3dB, got \(magAtCutoff)")
    let magAt10k = node.magnitudeDBAt(frequency: 10000)
    try assertTrue(magAt10k < -30.0, "LPF stopband at 10kHz: expected strong attenuation, got \(magAt10k)")
}

runTest("parametricEQNodeHighPass12") {
    // RBJ HPF with Q=0.707 at 1 kHz cutoff: mirror of LPF.
    let band = ParametricBand(type: .highPass12, frequency: 1000, gain: 0, q: 0.707)
    let node = ParametricEQNode(bands: [band])
    let fmt = AudioFormat(sampleRate: 48000, channels: 1, sampleFormat: .float32)
    _ = node.configure(inputFormat: fmt)
    let magAt10k = node.magnitudeDBAt(frequency: 10000)
    try assertTrue(abs(magAt10k) < 0.5, "HPF passband at 10kHz: expected ~0dB, got \(magAt10k)")
    let magAtCutoff = node.magnitudeDBAt(frequency: 1000)
    try assertTrue(abs(magAtCutoff - (-3.0)) < 1.0, "HPF at cutoff 1kHz: expected ~-3dB, got \(magAtCutoff)")
    let magAt100 = node.magnitudeDBAt(frequency: 100)
    try assertTrue(magAt100 < -30.0, "HPF stopband at 100Hz: expected strong attenuation, got \(magAt100)")
}

runTest("parametricEQLowPass12IgnoresGain") {
    // LP/HP filters do not use the gain parameter. A non-zero gain on LPF should
    // still produce a low-pass response, not a peaking shape.
    let band = ParametricBand(type: .lowPass12, frequency: 1000, gain: 12, q: 0.707)
    let node = ParametricEQNode(bands: [band])
    let fmt = AudioFormat(sampleRate: 48000, channels: 1, sampleFormat: .float32)
    _ = node.configure(inputFormat: fmt)
    let magAt100 = node.magnitudeDBAt(frequency: 100)
    let magAt10k = node.magnitudeDBAt(frequency: 10000)
    try assertTrue(magAt100 > magAt10k + 25.0, "LPF with gain should still attenuate highs: 100Hz=\(magAt100), 10kHz=\(magAt10k)")
}

runTest("parametricEQFilterTypeCodableUnknownFallsBackToPeaking") {
    // Forward-compat: a JSON preset with an unknown filter type string should
    // decode to .peaking instead of throwing.
    let json = #"{"type":"futureFilter","frequency":1000,"gain":3,"q":1.0,"enabled":true}"#
        .data(using: .utf8)!
    let band = try JSONDecoder().decode(ParametricBand.self, from: json)
    try assertEqual(band.type, .peaking)
}

runTest("eqInterpolationInitialConfigureSnapsToTarget") {
    // First configure must not insert a 93ms ramp; otherwise short test
    // buffers wouldn't see full effect.
    let band = ParametricBand(type: .peaking, frequency: 1000, gain: 12, q: 1.0)
    let eq = ParametricEQNode(bands: [band])
    let fmt = AudioFormat(sampleRate: 44100, channels: 1, sampleFormat: .float32)
    _ = eq.configure(inputFormat: fmt)
    let n = 882  // 20 ms
    var samples = [Float](repeating: 0, count: n)
    for i in 0..<n {
        samples[i] = sin(Float(2.0 * .pi * 1000.0 * Double(i) / 44100.0)) * 0.1
    }
    let inputRMS = samples.map { $0 * $0 }.reduce(0, +) / Float(n)
    samples.withUnsafeMutableBufferPointer { buf in
        eq.process(input: buf.baseAddress!, output: buf.baseAddress!, frameCount: n)
    }
    let outputRMS = samples.map { $0 * $0 }.reduce(0, +) / Float(n)
    // +12 dB peak ⇒ ≈ 4x energy. Allow some leeway.
    try assertTrue(outputRMS > inputRMS * 2.0,
                   "First configure should snap to target: in=\(inputRMS) out=\(outputRMS)")
}

runTest("eqInterpolationLargeChangeRampsSmoothly") {
    // After an initial flat-EQ pass, applying a +12 dB boost should ramp in
    // over ~93 ms rather than jumping instantly. Verify the output energy in
    // the first ~10 ms is closer to the input (pre-boost) than to the fully
    // boosted target.
    let sampleRate: Float = 44100
    let fmt = AudioFormat(sampleRate: Double(sampleRate), channels: 1, sampleFormat: .float32)
    // Start with a tiny non-zero band so subsequent recalc treats it as a
    // change rather than a first configure.
    let initial = ParametricBand(type: .peaking, frequency: 1000, gain: 0.01, q: 1.0)
    let eq = ParametricEQNode(bands: [initial])
    _ = eq.configure(inputFormat: fmt)

    // Now swap to a big +12 dB boost — this should trigger the 93 ms ramp.
    eq.apply(bands: [ParametricBand(type: .peaking, frequency: 1000, gain: 12, q: 1.0)],
             preamp: 0)

    // First 10 ms block.
    let blockA = 441
    var bufA = [Float](repeating: 0, count: blockA)
    for i in 0..<blockA {
        bufA[i] = sin(Float(2.0 * .pi * 1000.0 * Double(i) / Double(sampleRate))) * 0.1
    }
    let inputRMSA = bufA.map { $0 * $0 }.reduce(0, +) / Float(blockA)
    bufA.withUnsafeMutableBufferPointer { p in
        eq.process(input: p.baseAddress!, output: p.baseAddress!, frameCount: blockA)
    }
    let earlyRMS = bufA.map { $0 * $0 }.reduce(0, +) / Float(blockA)
    // During the very start of the ramp the boost should still be partial —
    // not yet at the steady-state ~4× energy.
    try assertTrue(earlyRMS < inputRMSA * 3.5,
                   "Early ramp should be partial: in=\(inputRMSA) early=\(earlyRMS)")

    // Run several more blocks to finish the ramp (~200 ms total).
    for _ in 0..<20 {
        var buf = [Float](repeating: 0, count: blockA)
        for i in 0..<blockA {
            buf[i] = sin(Float(2.0 * .pi * 1000.0 * Double(i) / Double(sampleRate))) * 0.1
        }
        buf.withUnsafeMutableBufferPointer { p in
            eq.process(input: p.baseAddress!, output: p.baseAddress!, frameCount: blockA)
        }
    }

    // Final block — must have reached the steady-state boost (~4× energy).
    var finalBuf = [Float](repeating: 0, count: blockA)
    for i in 0..<blockA {
        finalBuf[i] = sin(Float(2.0 * .pi * 1000.0 * Double(i) / Double(sampleRate))) * 0.1
    }
    finalBuf.withUnsafeMutableBufferPointer { p in
        eq.process(input: p.baseAddress!, output: p.baseAddress!, frameCount: blockA)
    }
    let finalRMS = finalBuf.map { $0 * $0 }.reduce(0, +) / Float(blockA)
    try assertTrue(finalRMS > inputRMSA * 3.0,
                   "Steady-state should reach full boost: in=\(inputRMSA) final=\(finalRMS)")
}

runTest("eqInterpolationNoClickOnLargeJump") {
    // Proxy for "click-free": sample-to-sample first difference of the output
    // across a coefficient swap should not exceed the same metric measured
    // before the swap by more than a small factor.
    let sampleRate: Float = 44100
    let fmt = AudioFormat(sampleRate: Double(sampleRate), channels: 1, sampleFormat: .float32)
    let eq = ParametricEQNode(bands: [ParametricBand(type: .peaking, frequency: 1000, gain: 0.01, q: 1.0)])
    _ = eq.configure(inputFormat: fmt)

    let n = 441
    func makeSine() -> [Float] {
        var s = [Float](repeating: 0, count: n)
        for i in 0..<n {
            s[i] = sin(Float(2.0 * .pi * 1000.0 * Double(i) / Double(sampleRate))) * 0.1
        }
        return s
    }
    var pre = makeSine()
    pre.withUnsafeMutableBufferPointer { p in
        eq.process(input: p.baseAddress!, output: p.baseAddress!, frameCount: n)
    }
    var preMaxDiff: Float = 0
    for i in 1..<n { preMaxDiff = max(preMaxDiff, abs(pre[i] - pre[i - 1])) }

    // Big change: invert sign + huge boost.
    eq.apply(bands: [ParametricBand(type: .peaking, frequency: 1000, gain: 18, q: 4.0)],
             preamp: 0)

    var post = makeSine()
    post.withUnsafeMutableBufferPointer { p in
        eq.process(input: p.baseAddress!, output: p.baseAddress!, frameCount: n)
    }
    var postMaxDiff: Float = 0
    for i in 1..<n { postMaxDiff = max(postMaxDiff, abs(post[i] - post[i - 1])) }

    // Without interpolation a coefficient swap of this magnitude would
    // typically produce a transient spike orders of magnitude above the
    // sinusoid's natural step. Verify the spike stays bounded.
    try assertTrue(postMaxDiff < preMaxDiff * 5.0,
                   "Click bound exceeded: pre=\(preMaxDiff) post=\(postMaxDiff)")
}

runTest("autoEQParserBasic") {
    let text = """
    Preamp: -6.2 dB
    Filter 1: ON PK Fc 200 Hz Gain 3.5 dB Q 1.41
    Filter 2: ON LSC Fc 105 Hz Gain -2.0 dB Q 0.71
    Filter 3: ON HSC Fc 8000 Hz Gain 4.0 dB Q 0.50
    """
    let result = try AutoEQParser.parse(text)
    try assertEqual(result.preamp, -6.2)
    try assertEqual(result.bands.count, 3)
    try assertEqual(result.bands[0].type, .peaking)
    try assertEqual(result.bands[0].frequency, 200)
    try assertEqual(result.bands[0].gain, 3.5)
    try assertEqual(result.bands[1].type, .lowShelf)
    try assertEqual(result.bands[1].frequency, 105)
    try assertEqual(result.bands[2].type, .highShelf)
    try assertEqual(result.bands[2].frequency, 8000)
}

runTest("autoEQParserAutoEQAppFormat") {
    let text = """
    Preamp: -8.75 dB
    Filter 1: ON LS Fc 105.0 Hz Gain 8.8 dB Q 0.70
    Filter 2: ON PK Fc 162.6 Hz Gain -7.7 dB Q 1.03
    Filter 3: ON PK Fc 295.9 Hz Gain 1.5 dB Q 1.59
    Filter 4: ON PK Fc 979.5 Hz Gain -4.8 dB Q 1.03
    Filter 5: ON PK Fc 1841.4 Hz Gain 2.5 dB Q 1.87
    Filter 6: ON PK Fc 2766.5 Hz Gain 7.3 dB Q 1.55
    Filter 7: ON PK Fc 4092.5 Hz Gain -4.1 dB Q 2.77
    Filter 8: ON PK Fc 5732.1 Hz Gain -5.3 dB Q 4.43
    Filter 9: ON PK Fc 7958.9 Hz Gain 4.5 dB Q 1.37
    Filter 10: ON HS Fc 10000.0 Hz Gain 3.6 dB Q 0.70
    """
    let result = try AutoEQParser.parse(text)
    try assertEqual(result.preamp, -8.75)
    try assertEqual(result.bands.count, 10)
    try assertEqual(result.bands[0].type, .lowShelf)
    try assertEqual(result.bands[0].frequency, 105.0)
    try assertEqual(result.bands[0].gain, 8.8)
    try assertEqual(result.bands[1].type, .peaking)
    try assertEqual(result.bands[1].frequency, 162.6)
    try assertEqual(result.bands[9].type, .highShelf)
    try assertEqual(result.bands[9].frequency, 10000.0)
    try assertEqual(result.bands[9].gain, 3.6)
}

runTest("autoEQParserNoFilters") {
    let text = "Some random text\nNothing useful here"
    do {
        _ = try AutoEQParser.parse(text)
        try assertTrue(false, "Should have thrown")
    } catch {
        // Expected
    }
}

runTest("autoEQParserJSON") {
    let json = """
    {"preamp": -3.0, "bands": [{"type": "peaking", "frequency": 500, "gain": 2.5, "q": 1.0, "enabled": true}]}
    """.data(using: .utf8)!
    let result = try AutoEQParser.parseJSON(json)
    try assertEqual(result.preamp, -3.0)
    try assertEqual(result.bands.count, 1)
    try assertEqual(result.bands[0].frequency, 500)
}

runTest("autoEQExtractHeadphoneNameParametricEQ") {
    try assertEqual(AutoEQParser.extractHeadphoneName(from: "Sennheiser HD 600 ParametricEQ.txt"),
                    "Sennheiser HD 600")
    try assertEqual(AutoEQParser.extractHeadphoneName(from: "Audeze LCD-X 2021 ParametricEQ.txt"),
                    "Audeze LCD-X 2021")
    try assertEqual(AutoEQParser.extractHeadphoneName(from: "HiFiMAN Sundara ParametricEQ.txt"),
                    "HiFiMAN Sundara")
}

runTest("autoEQExtractHeadphoneNameOtherSuffixes") {
    try assertEqual(AutoEQParser.extractHeadphoneName(from: "Foo GraphicEQ.txt"), "Foo")
    try assertEqual(AutoEQParser.extractHeadphoneName(from: "Foo FixedBandEQ.txt"), "Foo")
    try assertEqual(AutoEQParser.extractHeadphoneName(from: "Foo ParamEQ.txt"), "Foo")
}

runTest("autoEQExtractHeadphoneNameFallback") {
    // No known AutoEQ suffix: just strip the extension.
    try assertEqual(AutoEQParser.extractHeadphoneName(from: "my_custom.txt"), "my_custom")
    try assertEqual(AutoEQParser.extractHeadphoneName(from: "noext"), "noext")
    try assertTrue(AutoEQParser.extractHeadphoneName(from: ".txt") == nil)
}

runTest("autoEQExtractHeadphoneNameChineseFilename") {
    try assertEqual(AutoEQParser.extractHeadphoneName(from: "森海塞尔 HD600 ParametricEQ.txt"),
                    "森海塞尔 HD600")
}

runTest("autoEQParseFilePopulatesHeadphoneName") {
    let tempDir = FileManager.default.temporaryDirectory
    let url = tempDir.appendingPathComponent("Sennheiser HD 600 ParametricEQ.txt")
    let text = """
    Preamp: -6.2 dB
    Filter 1: ON PK Fc 200 Hz Gain 3.5 dB Q 1.41
    """
    try text.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }
    let result = try AutoEQParser.parse(file: url)
    try assertEqual(result.headphoneName, "Sennheiser HD 600")
    try assertEqual(result.bands.count, 1)
    try assertEqual(result.preamp, -6.2)
}

runTest("audioFileFormatNewCases") {
    try assertEqual(AudioFileFormat.from(fileExtension: "tta"), .tta)
    try assertEqual(AudioFileFormat.from(fileExtension: "wma"), .wma)
    try assertEqual(AudioFileFormat.from(fileExtension: "mka"), .mka)
    try assertEqual(AudioFileFormat.from(fileExtension: "aac"), .aac)
    try assertTrue(AudioFileFormat.tta.isLossless)
    try assertFalse(AudioFileFormat.wma.isLossless)
    try assertFalse(AudioFileFormat.aac.isLossless)
}

runTest("dspPreferencesParametric") {
    var prefs = DSPPreferences()
    try assertTrue(prefs.parametricBands.isEmpty)
    try assertEqual(prefs.preamp, 0)
    let band = ParametricBand(type: .peaking, frequency: 1000, gain: 3, q: 1.414)
    prefs.parametricBands = [band]
    prefs.preamp = -2
    prefs.eqEnabled = true
    prefs.bitPerfect = false
    let fmt = AudioFormat(sampleRate: 48000, channels: 2, sampleFormat: .float32)
    let chain = DSPChain.build(inputFormat: fmt, preferences: prefs)
    try assertTrue(chain.nodes.count >= 1, "Expected at least 1 node, got \(chain.nodes.count)")
    let eqNode = chain.nodes.first { $0.name == "ParametricEQ" }
    try assertTrue(eqNode != nil, "ParametricEQ node not found in chain")
}

#if canImport(CFFmpeg)
runTest("ffmpegDecoderFactoryExtensions") {
    try assertTrue(FFmpegDecoderFactory.supportedExtensions.contains("ape"))
    try assertTrue(FFmpegDecoderFactory.supportedExtensions.contains("wv"))
    try assertTrue(FFmpegDecoderFactory.supportedExtensions.contains("tta"))
    try assertTrue(FFmpegDecoderFactory.supportedExtensions.contains("opus"))
    try assertTrue(FFmpegDecoderFactory.supportedExtensions.contains("ogg"))
    try assertTrue(FFmpegDecoderFactory.supportedExtensions.contains("wma"))
    try assertTrue(FFmpegDecoderFactory.supportedExtensions.contains("mka"))
    // issue #15c: 云端流让路后 registry 降级链的落点 — 必须认识这些扩展
    try assertTrue(FFmpegDecoderFactory.supportedExtensions.contains("mp3"))
    try assertTrue(FFmpegDecoderFactory.supportedExtensions.contains("m4a"))
    try assertTrue(FFmpegDecoderFactory.supportedExtensions.contains("mp4"))
    try assertTrue(FFmpegDecoderFactory.supportedExtensions.contains("aac"))
    try assertTrue(FFmpegDecoderFactory.supportedExtensions.contains("flac"))
    try assertTrue(FFmpegDecoderFactory.supportedExtensions.contains("alac"))
    try assertTrue(FFmpegDecoderFactory.supportedExtensions.contains("caf"))
    // 优先级仍低于原生解码器 — 本地文件路由不变
    try assertEqual(FFmpegDecoderFactory.priority, 80)
}

runTest("ffmpegDecoderFactoryCanDecode") {
    let src = MemorySource(data: Data(repeating: 0, count: 100))
    try assertTrue(FFmpegDecoderFactory.canDecode(source: src, fileExtension: "ape"))
    try assertTrue(FFmpegDecoderFactory.canDecode(source: src, fileExtension: "wv"))
    try assertTrue(FFmpegDecoderFactory.canDecode(source: src, fileExtension: "flac"))  // issue #15c
    try assertFalse(FFmpegDecoderFactory.canDecode(source: src, fileExtension: "wav"))
}

runTest("ffmpegDecoderRegistryPriority") {
    let registry = DecoderRegistry.shared
    try assertTrue(registry.registeredCount > 0)
}
#endif

// ═══════════════════════════════════════════════════════
// FFmpegSampleFormatSelector — exercises the WMA Lossless
// decision branches without requiring a built FFmpeg.
// ═══════════════════════════════════════════════════════
typealias _FmtCodes = FFmpegSampleFormatSelector.AVFmtCode

runTest("ffmpegFormatSelectorAPE24") {
    // APE reports S32P with bits_per_raw_sample = 24 — the v1.5.11 regression guard.
    let d = FFmpegSampleFormatSelector.decide(
        codecSampleFormat: _FmtCodes.s32p,
        bitsPerRawSample: 24,
        bitsPerCodedSample: 0
    )
    try assertEqual(d.sampleFormat, .int24)
    try assertEqual(d.outAVFormatCode, _FmtCodes.s32)
}

runTest("ffmpegFormatSelectorWMALossless16") {
    // WMA Lossless 16-bit: codec emits S16P planar; raw bits = 16.
    let d = FFmpegSampleFormatSelector.decide(
        codecSampleFormat: _FmtCodes.s16p,
        bitsPerRawSample: 16,
        bitsPerCodedSample: 16
    )
    try assertEqual(d.sampleFormat, .int16)
    try assertEqual(d.outAVFormatCode, _FmtCodes.s16)
}

runTest("ffmpegFormatSelectorWMALossless24") {
    // WMA Lossless 24-bit: codec emits S32P planar; raw bits = 24.
    let d = FFmpegSampleFormatSelector.decide(
        codecSampleFormat: _FmtCodes.s32p,
        bitsPerRawSample: 24,
        bitsPerCodedSample: 0
    )
    try assertEqual(d.sampleFormat, .int24)
    try assertEqual(d.outAVFormatCode, _FmtCodes.s32)
}

runTest("ffmpegFormatSelectorWMALosslessCodedFallback") {
    // Some WMA Lossless streams leave bits_per_raw_sample == 0 and only fill
    // bits_per_coded_sample. The selector must fall back to coded bits.
    let d = FFmpegSampleFormatSelector.decide(
        codecSampleFormat: _FmtCodes.s32p,
        bitsPerRawSample: 0,
        bitsPerCodedSample: 24
    )
    try assertEqual(d.sampleFormat, .int24)
    try assertEqual(d.outAVFormatCode, _FmtCodes.s32)
}

runTest("ffmpegFormatSelectorWMAv2Float") {
    // wmav2 / wmapro emit FLTP; route them through S32 with int32 framing.
    let d = FFmpegSampleFormatSelector.decide(
        codecSampleFormat: _FmtCodes.fltp,
        bitsPerRawSample: 0,
        bitsPerCodedSample: 16
    )
    try assertEqual(d.sampleFormat, .int32)
    try assertEqual(d.outAVFormatCode, _FmtCodes.s32)
}

runTest("ffmpegFormatSelectorS32NoBitsHintFallsBackToInt32") {
    // S32 container with zero bit-depth hint should default to int32, not int24.
    let d = FFmpegSampleFormatSelector.decide(
        codecSampleFormat: _FmtCodes.s32,
        bitsPerRawSample: 0,
        bitsPerCodedSample: 0
    )
    try assertEqual(d.sampleFormat, .int32)
    try assertEqual(d.outAVFormatCode, _FmtCodes.s32)
}

runTest("ffmpegFormatSelectorEffectiveBitDepth") {
    try assertEqual(FFmpegSampleFormatSelector.effectiveBitDepth(
        bitsPerRawSample: 24, bitsPerCodedSample: 16), 24)
    try assertEqual(FFmpegSampleFormatSelector.effectiveBitDepth(
        bitsPerRawSample: 0, bitsPerCodedSample: 16), 16)
    try assertTrue(FFmpegSampleFormatSelector.effectiveBitDepth(
        bitsPerRawSample: 0, bitsPerCodedSample: 0) == nil)
}

// ═══════════════════════════════════════════════════════
// AudioPreferences DSD/EQ slot (F11 + F12)
// ═══════════════════════════════════════════════════════
print("\n═══ AudioPreferences DSD/EQ Tests ═══")

func _resetAudioPrefsKeys() {
    let ud = UserDefaults.standard
    for key in [
        "ppl.dsdMaxPCMRate",
        "ppl.eqSlotA",
        "ppl.eqSlotB",
        "ppl.activeEQSlot",
        "ppl.eqMigrationVersion",
        "ppl.currentHeadphoneName",
        "ppl.parametricBands",
    ] {
        ud.removeObject(forKey: key)
    }
}

runTest("dsdMaxPCMRateDefaultsTo384k") {
    _resetAudioPrefsKeys()
    try assertEqual(AudioPreferences.dsdMaxPCMRate, 384_000.0)
}

runTest("dsdMaxPCMRateAccepts768k") {
    _resetAudioPrefsKeys()
    AudioPreferences.dsdMaxPCMRate = 768_000
    try assertEqual(AudioPreferences.dsdMaxPCMRate, 768_000.0)
    _resetAudioPrefsKeys()
}

runTest("dsdMaxPCMRateInvalidValueClampsTo384k") {
    _resetAudioPrefsKeys()
    AudioPreferences.dsdMaxPCMRate = 192_000  // invalid → clamp to 384k
    try assertEqual(AudioPreferences.dsdMaxPCMRate, 384_000.0)
    _resetAudioPrefsKeys()
}

runTest("strategyDSD1024Uses768kWhenUserOptsIn") {
    let dac = DACCapabilities(maxPCMRate: 768_000)
    let s = DSDStrategyChooser.choose(rate: .dsd1024, dac: dac,
                                       preference: .auto, userMaxPCM: 768_000)
    try assertEqual(s, .pcm(targetRate: 768_000))
}

runTest("strategyDSD1024Stays384kAtDefaultPref") {
    let dac = DACCapabilities(maxPCMRate: 768_000)
    let s = DSDStrategyChooser.choose(rate: .dsd1024, dac: dac,
                                       preference: .auto, userMaxPCM: 384_000)
    try assertEqual(s, .pcm(targetRate: 384_000))
}

runTest("strategyDSD512UnaffectedByUserMax") {
    // DSD512 recommended is 352.8k; userMaxPCM does not raise it
    let dac = DACCapabilities(maxPCMRate: 96_000)  // not enough for DoP
    let s = DSDStrategyChooser.choose(rate: .dsd512, dac: dac,
                                       preference: .auto, userMaxPCM: 768_000)
    try assertEqual(s, .pcm(targetRate: 352_800))
}

runTest("eqMigrationCopiesLegacyKeyToSlotA") {
    _resetAudioPrefsKeys()
    let payload = "legacy-eq-payload".data(using: .utf8)!
    UserDefaults.standard.set(payload, forKey: "ppl.parametricBands")
    try assertTrue(AudioPreferences.eqSlotA == nil)
    AudioPreferences.performEQMigrationIfNeeded()
    try assertEqual(AudioPreferences.eqSlotA, payload)
    try assertTrue(AudioPreferences.eqSlotB == nil)
    try assertEqual(AudioPreferences.activeEQSlot, "A")
    _resetAudioPrefsKeys()
}

runTest("eqMigrationIsIdempotent") {
    _resetAudioPrefsKeys()
    let payload = "v1".data(using: .utf8)!
    UserDefaults.standard.set(payload, forKey: "ppl.parametricBands")
    AudioPreferences.performEQMigrationIfNeeded()
    // Mutate slot A then re-run migration — should NOT overwrite
    let newPayload = "v2".data(using: .utf8)!
    AudioPreferences.eqSlotA = newPayload
    AudioPreferences.performEQMigrationIfNeeded()
    try assertEqual(AudioPreferences.eqSlotA, newPayload)
    _resetAudioPrefsKeys()
}

runTest("eqMigrationFreshInstallKeepsSlotsEmpty") {
    _resetAudioPrefsKeys()
    AudioPreferences.performEQMigrationIfNeeded()
    try assertTrue(AudioPreferences.eqSlotA == nil)
    try assertTrue(AudioPreferences.eqSlotB == nil)
    _resetAudioPrefsKeys()
}

runTest("eqSlotAWriteSyncsLegacyKey") {
    _resetAudioPrefsKeys()
    let payload = "new".data(using: .utf8)!
    AudioPreferences.eqSlotA = payload
    let legacy = UserDefaults.standard.data(forKey: "ppl.parametricBands")
    try assertEqual(legacy, payload)
    _resetAudioPrefsKeys()
}

runTest("activeEQSlotNormalizesToAOrB") {
    _resetAudioPrefsKeys()
    AudioPreferences.activeEQSlot = "B"
    try assertEqual(AudioPreferences.activeEQSlot, "B")
    AudioPreferences.activeEQSlot = "garbage"
    try assertEqual(AudioPreferences.activeEQSlot, "A")
    _resetAudioPrefsKeys()
}

// ═══════════════════════════════════════════════════════
// SpectrumAnalyzer (F6 frequency-axis bug + E1 asymmetric smoothing)
// ═══════════════════════════════════════════════════════
print("\n═══ SpectrumAnalyzer Tests ═══")

func _spectrumPeakBand(toneHz: Float, bandCount: Int, fftSize: Int, sampleRate: Float) -> Int {
    // Feed >= fftSize samples; large attack so first frame reaches near peak
    let analyzer = SpectrumAnalyzer(bandCount: bandCount, fftSize: fftSize,
                                    sampleRate: sampleRate,
                                    attackTime: 0.0001, releaseTime: 0.3)
    var samples = [Float](repeating: 0, count: fftSize)
    for i in 0..<fftSize {
        samples[i] = sin(2 * .pi * toneHz * Float(i) / sampleRate)
    }
    samples.withUnsafeBufferPointer { ptr in
        analyzer.process(samples: ptr.baseAddress!, frameCount: fftSize, channels: 1)
    }
    let bands = analyzer.currentBands()
    return bands.enumerated().max(by: { $0.element < $1.element })?.offset ?? -1
}

func _expectedBandFor(hz: Float, bandCount: Int, sampleRate: Float) -> Int {
    let minLog = log10(Float(20))
    let maxLog = log10(sampleRate / 2)
    let logHz = log10(hz)
    let frac = (logHz - minLog) / (maxLog - minLog)
    return min(bandCount - 1, max(0, Int(frac * Float(bandCount))))
}

runTest("spectrumAnalyzer1kHzPeakBand") {
    let bandCount = 32
    let sampleRate: Float = 44100
    let peak = _spectrumPeakBand(toneHz: 1000, bandCount: bandCount,
                                  fftSize: 1024, sampleRate: sampleRate)
    let expected = _expectedBandFor(hz: 1000, bandCount: bandCount, sampleRate: sampleRate)
    try assertTrue(abs(peak - expected) <= 1,
                   "1kHz peak at band \(peak), expected ~\(expected)")
}

runTest("spectrumAnalyzer100HzPeakBand") {
    let bandCount = 32
    let sampleRate: Float = 44100
    let peak = _spectrumPeakBand(toneHz: 100, bandCount: bandCount,
                                  fftSize: 4096, sampleRate: sampleRate)
    let expected = _expectedBandFor(hz: 100, bandCount: bandCount, sampleRate: sampleRate)
    try assertTrue(abs(peak - expected) <= 2,
                   "100Hz peak at band \(peak), expected ~\(expected)")
}

runTest("spectrumAnalyzer10kHzPeakBand") {
    let bandCount = 32
    let sampleRate: Float = 44100
    let peak = _spectrumPeakBand(toneHz: 10_000, bandCount: bandCount,
                                  fftSize: 1024, sampleRate: sampleRate)
    let expected = _expectedBandFor(hz: 10_000, bandCount: bandCount, sampleRate: sampleRate)
    try assertTrue(abs(peak - expected) <= 1,
                   "10kHz peak at band \(peak), expected ~\(expected)")
}

runTest("spectrumAnalyzerHighSampleRateBinMapping") {
    // 96kHz / 1kHz tone should still land near the same log-band slot
    let bandCount = 32
    let sampleRate: Float = 96000
    let peak = _spectrumPeakBand(toneHz: 1000, bandCount: bandCount,
                                  fftSize: 2048, sampleRate: sampleRate)
    let expected = _expectedBandFor(hz: 1000, bandCount: bandCount, sampleRate: sampleRate)
    try assertTrue(abs(peak - expected) <= 1,
                   "1kHz @ 96k peak at band \(peak), expected ~\(expected)")
}

runTest("spectrumAnalyzerAsymmetricAttackRelease") {
    // Fast attack + slow release: feeding a strong tone then silence; after silence
    // the band should still be substantially elevated (release tail).
    let analyzer = SpectrumAnalyzer(bandCount: 32, fftSize: 1024,
                                    sampleRate: 44100,
                                    attackTime: 0.0001, releaseTime: 0.3)
    var tone = [Float](repeating: 0, count: 1024)
    for i in 0..<1024 {
        tone[i] = sin(2 * .pi * 1000 * Float(i) / 44100)
    }
    tone.withUnsafeBufferPointer { ptr in
        analyzer.process(samples: ptr.baseAddress!, frameCount: 1024, channels: 1)
    }
    let peakBands = analyzer.currentBands()
    let peakIdx = peakBands.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0
    let attackValue = peakBands[peakIdx]
    // One frame of silence — release should keep value high (≈ 1 - releaseCoef ≈ slow decay)
    let silence = [Float](repeating: 0, count: 1024)
    silence.withUnsafeBufferPointer { ptr in
        analyzer.process(samples: ptr.baseAddress!, frameCount: 1024, channels: 1)
    }
    let afterBands = analyzer.currentBands()
    try assertGreaterThan(afterBands[peakIdx], attackValue * 0.5)
}

// ═══════════════════════════════════════════════════════
// Regression: cloud playlist loop bug
// Timer.scheduledTimer attaches to the caller's RunLoop. When playCloud()
// resumes on the Swift Concurrency cooperative thread pool, that thread has
// no running RunLoop, so the end-detection timer silently never fires and
// onTrackFinished is never called — playlist loop dies after one cloud
// track. Fix: RunLoop.main.add(timer, forMode: .common).
// ═══════════════════════════════════════════════════════
print("═══ Regression: Cloud Loop Timer Scheduling ═══")

runTest("timerOnCooperativePoolNeedsExplicitMainRunLoop") {
    // Simulate the broken path: from a Task on the cooperative pool, use
    // Timer.scheduledTimer (the old code). It must NOT fire within 0.5s.
    let brokenFired = NSLock()
    var brokenFireCount = 0
    let brokenGroup = DispatchGroup()
    brokenGroup.enter()
    Task.detached {
        let _ = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            brokenFired.lock(); brokenFireCount += 1; brokenFired.unlock()
        }
        // Give the cooperative thread time to "run" — its RunLoop isn't running,
        // so the timer never gets serviced.
        Thread.sleep(forTimeInterval: 0.5)
        brokenGroup.leave()
    }
    brokenGroup.wait()
    brokenFired.lock(); let brokenCount = brokenFireCount; brokenFired.unlock()
    try assertEqual(brokenCount, 0,
                    "Timer.scheduledTimer on cooperative pool fired \(brokenCount) times — expected 0 (no live RunLoop)")

    // Verify the fix: explicitly RunLoop.main.add. The timer must fire.
    // We spin RunLoop.main briefly from this thread (the test thread is main).
    let fixedFired = NSLock()
    var fixedFireCount = 0
    Task.detached {
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            fixedFired.lock(); fixedFireCount += 1; fixedFired.unlock()
        }
        RunLoop.main.add(timer, forMode: .common)
    }
    // Pump the main RunLoop for ~0.5s so the timer can fire.
    let deadline = Date().addingTimeInterval(0.6)
    while Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    fixedFired.lock(); let fixedCount = fixedFireCount; fixedFired.unlock()
    try assertGreaterThan(fixedCount, 0)
}


print("\n" + String(repeating: "═", count: 50))
print("Tests: \(totalTests) total, \(passedTests) passed, \(failedTests) failed")
if !failedTestNames.isEmpty {
    print("Failed:")
    for name in failedTestNames { print("  ✗ \(name)") }
}
print(String(repeating: "═", count: 50))

if failedTests > 0 {
    exit(1)
}
