import Foundation

/// Pure mapping from an FFmpeg codec's reported sample format + bit-depth hints
/// to PurePlay's `SampleFormat` and the target `AVSampleFormat` (as raw `Int32`)
/// to request from swresample.
///
/// Kept free of any CFFmpeg dependency so it can be exercised without a built
/// FFmpeg toolchain. The integer codes match libavutil/samplefmt.h's
/// `AVSampleFormat` enum values; see `AVFmtCode` below.
public enum FFmpegSampleFormatSelector {
    /// Raw values from libavutil's `AVSampleFormat` enum.
    public enum AVFmtCode {
        public static let u8:   Int32 = 0
        public static let s16:  Int32 = 1
        public static let s32:  Int32 = 2
        public static let flt:  Int32 = 3
        public static let dbl:  Int32 = 4
        public static let u8p:  Int32 = 5
        public static let s16p: Int32 = 6
        public static let s32p: Int32 = 7
        public static let fltp: Int32 = 8
        public static let dblp: Int32 = 9
        public static let s64:  Int32 = 10
        public static let s64p: Int32 = 11
    }

    public struct Decision: Equatable {
        public let sampleFormat: SampleFormat
        /// Target `AVSampleFormat` raw value for swresample's packed output.
        public let outAVFormatCode: Int32
    }

    /// Strip planar suffix: map planar codes to their packed equivalents.
    /// Mirrors libavutil's `av_get_packed_sample_fmt`.
    static func packedFormat(_ fmt: Int32) -> Int32 {
        switch fmt {
        case AVFmtCode.u8p:  return AVFmtCode.u8
        case AVFmtCode.s16p: return AVFmtCode.s16
        case AVFmtCode.s32p: return AVFmtCode.s32
        case AVFmtCode.fltp: return AVFmtCode.flt
        case AVFmtCode.dblp: return AVFmtCode.dbl
        case AVFmtCode.s64p: return AVFmtCode.s64
        default:             return fmt
        }
    }

    /// Decide the output `SampleFormat` and the target `AVSampleFormat` for swresample.
    ///
    /// - Parameters:
    ///   - codecSampleFormat: `codec_ctx->sample_fmt` raw value.
    ///   - bitsPerRawSample: `codec_ctx->bits_per_raw_sample` (0 when codec didn't fill it).
    ///   - bitsPerCodedSample: `codecpar->bits_per_coded_sample` (used when raw bits is 0).
    public static func decide(codecSampleFormat: Int32,
                              bitsPerRawSample: Int,
                              bitsPerCodedSample: Int) -> Decision {
        let bits = bitsPerRawSample > 0 ? bitsPerRawSample : bitsPerCodedSample
        switch packedFormat(codecSampleFormat) {
        case AVFmtCode.u8, AVFmtCode.s16:
            return Decision(sampleFormat: .int16, outAVFormatCode: AVFmtCode.s16)
        case AVFmtCode.s32:
            // S32 container is used by 24-bit (APE/FLAC/WMA Lossless 24) and 32-bit
            // codecs. Distinguish via the reported bit depth.
            let format: SampleFormat = (bits > 0 && bits <= 24) ? .int24 : .int32
            return Decision(sampleFormat: format, outAVFormatCode: AVFmtCode.s32)
        case AVFmtCode.flt, AVFmtCode.dbl:
            return Decision(sampleFormat: .int32, outAVFormatCode: AVFmtCode.s32)
        default:
            return Decision(sampleFormat: .int16, outAVFormatCode: AVFmtCode.s16)
        }
    }

    /// Effective bit depth surfaced to consumers (e.g. AudioFormat.sourceBitDepth).
    /// Returns `nil` when neither hint is available.
    public static func effectiveBitDepth(bitsPerRawSample: Int,
                                          bitsPerCodedSample: Int) -> Int? {
        if bitsPerRawSample > 0 { return bitsPerRawSample }
        if bitsPerCodedSample > 0 { return bitsPerCodedSample }
        return nil
    }
}
