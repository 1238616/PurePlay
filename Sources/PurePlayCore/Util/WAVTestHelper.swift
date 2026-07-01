import Foundation

/// WAV 文件生成工具（纯测试辅助）
public enum WAVTestHelper {

    /// 在内存中生成最小 WAV 文件数据（PCM 16-bit 立体声）
    public static func makePCM16Stereo(sampleRate: Int = 44100,
                                        durationFrames: Int = 44100) -> Data {
        let channels = 2
        let bitsPerSample = 16
        let bytesPerSample = bitsPerSample / 8
        let bytesPerFrame = channels * bytesPerSample
        let dataSize = durationFrames * bytesPerFrame
        let fileSize = 36 + dataSize

        var data = Data(capacity: fileSize + 8)

        // RIFF header
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46])  // "RIFF"
        data.appendLE32(UInt32(fileSize))
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45])  // "WAVE"

        // fmt subchunk
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])  // "fmt "
        data.appendLE32(16)                                  // subchunk1 size
        data.appendLE16(1)                                   // PCM
        data.appendLE16(UInt16(channels))
        data.appendLE32(UInt32(sampleRate))
        data.appendLE32(UInt32(sampleRate * bytesPerFrame))  // byte rate
        data.appendLE16(UInt16(bytesPerFrame))               // block align
        data.appendLE16(UInt16(bitsPerSample))

        // data subchunk
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61])  // "data"
        data.appendLE32(UInt32(dataSize))

        // 440 Hz sine wave
        for i in 0..<durationFrames {
            let t = 2.0 * Double.pi * 440.0 * Double(i) / Double(sampleRate)
            let sample = Int16(sin(t) * 16000)
            data.appendLE16(UInt16(bitPattern: sample))  // L
            data.appendLE16(UInt16(bitPattern: sample))  // R
        }

        return data
    }

    /// 24-bit mono WAV
    public static func makePCM24Mono(sampleRate: Int = 96000,
                                      durationFrames: Int = 96000) -> Data {
        let channels = 1
        let bitsPerSample = 24
        let bytesPerSample = 3
        let bytesPerFrame = channels * bytesPerSample
        let dataSize = durationFrames * bytesPerFrame
        let fileSize = 36 + dataSize

        var data = Data(capacity: fileSize + 8)

        // RIFF header
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46])
        data.appendLE32(UInt32(fileSize))
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45])

        // fmt
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])
        data.appendLE32(16)
        data.appendLE16(1)  // PCM
        data.appendLE16(UInt16(channels))
        data.appendLE32(UInt32(sampleRate))
        data.appendLE32(UInt32(sampleRate * bytesPerFrame))
        data.appendLE16(UInt16(bytesPerFrame))
        data.appendLE16(UInt16(bitsPerSample))

        // data
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61])
        data.appendLE32(UInt32(dataSize))

        // 1 kHz sine
        for i in 0..<durationFrames {
            let t = 2.0 * Double.pi * 1000.0 * Double(i) / Double(sampleRate)
            let s32 = Int32(sin(t) * 4_000_000)
            data.append(UInt8(truncatingIfNeeded: s32 & 0xFF))
            data.append(UInt8(truncatingIfNeeded: (s32 >> 8) & 0xFF))
            data.append(UInt8(truncatingIfNeeded: (s32 >> 16) & 0xFF))
        }

        return data
    }
}

extension Data {
    mutating func appendLE16(_ val: UInt16) {
        append(UInt8(val & 0xFF))
        append(UInt8((val >> 8) & 0xFF))
    }
    mutating func appendLE32(_ val: UInt32) {
        append(UInt8(val & 0xFF))
        append(UInt8((val >> 8) & 0xFF))
        append(UInt8((val >> 16) & 0xFF))
        append(UInt8((val >> 24) & 0xFF))
    }
    mutating func appendLE64(_ val: UInt64) {
        for i in 0..<8 { append(UInt8((val >> (8 * i)) & 0xFF)) }
    }
}

/// 最小可解析 DSF 文件生成器（仅供测试）
public enum DSFTestHelper {

    /// blocks 个块对（每声道 4096 字节）。channelByte0 / channelByte1 提供生成函数
    /// 默认 ch0 = 0xAA、ch1 = 0xBB 便于断言。
    public static func makeMinimalDSF(
        sampleFreq: Int = 2_822_400,
        blocks: Int = 1,
        channelPattern: ((_ ch: Int, _ index: Int) -> UInt8)? = nil
    ) -> Data {
        let blockSize = 4096
        let channels = 2
        let dataBytes = blocks * channels * blockSize
        // sampleCountPerChannel = 1-bit 样本数 = blockSize * blocks * 8
        let sampleCount: UInt64 = UInt64(blocks * blockSize * 8)
        let fileSize: UInt64 = UInt64(28 + 52 + 12 + dataBytes)

        var data = Data(capacity: Int(fileSize))

        // === DSD chunk (28B) ===
        data.append(contentsOf: [0x44, 0x53, 0x44, 0x20])   // "DSD "
        data.appendLE64(28)                                 // chunkSize
        data.appendLE64(fileSize)
        data.appendLE64(0)                                  // metaPtr (no ID3)

        // === fmt chunk (52B) ===
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])   // "fmt "
        data.appendLE64(52)
        data.appendLE32(1)                                  // formatVersion
        data.appendLE32(0)                                  // formatID (DSD raw)
        data.appendLE32(2)                                  // channelType (stereo)
        data.appendLE32(UInt32(channels))
        data.appendLE32(UInt32(sampleFreq))
        data.appendLE32(1)                                  // bitsPerSample (LSB-first)
        data.appendLE64(sampleCount)
        data.appendLE32(UInt32(blockSize))
        data.appendLE32(0)                                  // reserved

        // === data chunk header (12B) ===
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61])   // "data"
        data.appendLE64(UInt64(12 + dataBytes))             // chunkSize includes header itself per DSF spec

        // data: per block, ch0 4096 bytes then ch1 4096 bytes
        for b in 0..<blocks {
            for ch in 0..<channels {
                for i in 0..<blockSize {
                    let byte: UInt8
                    if let pattern = channelPattern {
                        byte = pattern(ch, b * blockSize + i)
                    } else {
                        byte = ch == 0 ? 0xAA : 0xBB
                    }
                    data.append(byte)
                }
            }
        }
        return data
    }
}

/// 最小可解析 DFF / DSDIFF 文件生成器（仅供测试）
public enum DFFTestHelper {

    /// 生成最小 DSDIFF：FRM8 + PROP(FS+CHNL) + DSD data
    /// frames = 每声道的 DSD 字节数（每帧 = channels × 1 byte per stream, interleaved）
    /// 默认 ch0 = 0x11, ch1 = 0x22。
    public static func makeMinimalDFF(
        sampleFreq: Int = 2_822_400,
        framesPerChannel: Int = 64,
        channelPattern: ((_ ch: Int, _ idx: Int) -> UInt8)? = nil
    ) -> Data {
        let channels = 2
        let dsdBytes = framesPerChannel * channels   // interleaved

        // 计算各 chunk 大小（不含 chunk header 的 4+8 字节）
        // PROP: 4 "SND " + (12 + 4 "FS  payload") + (12 + 2 + 4 channel ids "CHNL payload")
        //       FS payload = 4 bytes  → with 12 header = 16
        //       CHNL payload = 2 + 2*4 = 10 → padded to even (already 10) → with 12 header = 22
        // PROP size = 4 + 16 + 22 = 42 → odd? Let's pad. 42 even → no pad.
        let fsPayload = 4
        let chnlPayload = 2 + channels * 4  // = 10
        let propSize = 4 + (12 + fsPayload) + (12 + chnlPayload)   // 4 + 16 + 22 = 42

        // DSD chunk payload = dsdBytes
        // FRM8 total payload = 4 ("DSD " formType) + (12 + propSize) + (12 + dsdBytes)
        let frm8Size = 4 + (12 + UInt64(propSize)) + (12 + UInt64(dsdBytes))

        var data = Data()
        // FRM8 header
        data.append(contentsOf: [0x46, 0x52, 0x4D, 0x38])   // "FRM8"
        data.appendBE64(frm8Size)
        data.append(contentsOf: [0x44, 0x53, 0x44, 0x20])   // "DSD "

        // PROP chunk
        data.append(contentsOf: [0x50, 0x52, 0x4F, 0x50])   // "PROP"
        data.appendBE64(UInt64(propSize))
        data.append(contentsOf: [0x53, 0x4E, 0x44, 0x20])   // "SND "

        // FS chunk
        data.append(contentsOf: [0x46, 0x53, 0x20, 0x20])   // "FS  "
        data.appendBE64(UInt64(fsPayload))
        data.appendBE32(UInt32(sampleFreq))

        // CHNL chunk
        data.append(contentsOf: [0x43, 0x48, 0x4E, 0x4C])   // "CHNL"
        data.appendBE64(UInt64(chnlPayload))
        data.appendBE16(UInt16(channels))
        // channel IDs (任意 4 字节代码) — "SLFT", "SRGT"
        data.append(contentsOf: [0x53, 0x4C, 0x46, 0x54])
        data.append(contentsOf: [0x53, 0x52, 0x47, 0x54])

        // DSD data chunk
        data.append(contentsOf: [0x44, 0x53, 0x44, 0x20])   // "DSD "
        data.appendBE64(UInt64(dsdBytes))
        for i in 0..<framesPerChannel {
            for ch in 0..<channels {
                let byte: UInt8
                if let pattern = channelPattern {
                    byte = pattern(ch, i)
                } else {
                    byte = ch == 0 ? 0x11 : 0x22
                }
                data.append(byte)
            }
        }

        return data
    }
}

/// 最小可解析 AIFF 文件生成器（仅供测试）— 大端 PCM
public enum AIFFTestHelper {

    public static func makePCM16Stereo(sampleRate: Int = 44100,
                                       durationFrames: Int = 1024) -> Data {
        let channels = 2
        let bitsPerSample = 16
        let bytesPerSample = bitsPerSample / 8
        let bytesPerFrame = channels * bytesPerSample
        let ssndDataBytes = durationFrames * bytesPerFrame

        // COMM payload = 18 bytes: numChannels(2) + numFrames(4) + sampleSize(2) + sampleRate(10)
        let commPayload = 18
        // SSND payload = 8 (offset + blockSize) + data
        let ssndPayload = 8 + ssndDataBytes

        let formSize = 4 /* "AIFF" */
                     + (8 + commPayload)
                     + (8 + ssndPayload)

        var data = Data()
        // FORM header
        data.append(contentsOf: [0x46, 0x4F, 0x52, 0x4D])   // "FORM"
        data.appendBE32(UInt32(formSize))
        data.append(contentsOf: [0x41, 0x49, 0x46, 0x46])   // "AIFF"

        // COMM chunk
        data.append(contentsOf: [0x43, 0x4F, 0x4D, 0x4D])   // "COMM"
        data.appendBE32(UInt32(commPayload))
        data.appendBE16(UInt16(channels))
        data.appendBE32(UInt32(durationFrames))
        data.appendBE16(UInt16(bitsPerSample))
        data.appendIEEE80(Double(sampleRate))               // 10 bytes

        // SSND chunk
        data.append(contentsOf: [0x53, 0x53, 0x4E, 0x44])   // "SSND"
        data.appendBE32(UInt32(ssndPayload))
        data.appendBE32(0)                                  // offset
        data.appendBE32(0)                                  // blockSize

        // 1 kHz sine, big-endian 16-bit
        for i in 0..<durationFrames {
            let t = 2.0 * Double.pi * 1000.0 * Double(i) / Double(sampleRate)
            let sample = Int16(sin(t) * 16000)
            let u = UInt16(bitPattern: sample)
            for _ in 0..<channels {
                data.append(UInt8((u >> 8) & 0xFF))
                data.append(UInt8(u & 0xFF))
            }
        }
        return data
    }
}

extension Data {
    mutating func appendBE16(_ v: UInt16) {
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8(v & 0xFF))
    }
    mutating func appendBE32(_ v: UInt32) {
        append(UInt8((v >> 24) & 0xFF))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8(v & 0xFF))
    }
    mutating func appendBE64(_ v: UInt64) {
        for i in (0..<8).reversed() { append(UInt8((v >> (8 * i)) & 0xFF)) }
    }
    /// AIFF COMM 用的 80-bit extended precision，仅支持正整数采样率
    mutating func appendIEEE80(_ value: Double) {
        if value == 0 {
            append(contentsOf: [UInt8](repeating: 0, count: 10))
            return
        }
        var v = value
        var exp: UInt16 = 0x3FFF + 31
        while v >= 2_147_483_648 { v /= 2; exp += 1 }
        while v <  1_073_741_824 { v *= 2; exp -= 1 }
        let mantissa = UInt64(v) << 32
        appendBE16(exp)
        appendBE64(mantissa)
    }
}
