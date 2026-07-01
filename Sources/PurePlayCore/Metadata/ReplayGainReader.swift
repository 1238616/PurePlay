import Foundation
import AVFoundation

/// 从 FLAC Vorbis Comment / ID3v2 TXXX / iTunes Sound Check (iTunNORM)
/// 三个来源抽取 ReplayGain。失败则字段保持 nil。
enum ReplayGainReader {

    /// 在 MetadataReader 的同步与异步路径末尾调用
    /// 顺序：FLAC streaminfo + vorbis comment → AVAsset (ID3/iTunes) → 不覆盖已填值
    static func augment(metadata: inout TrackMetadata, url: URL, asset: AVAsset) {
        let ext = url.pathExtension.lowercased()

        // 1) FLAC：直接读容器内嵌 Vorbis Comment（最权威）+ STREAMINFO 覆盖音频格式
        if ext == "flac",
           let parsed = (try? FLACMetadata.read(from: url)) ?? nil {
            let info = parsed.streamInfo
            if info.sampleRate > 0 { metadata.sampleRate = Double(info.sampleRate) }
            if info.channels > 0   { metadata.channels   = info.channels }
            if info.bitsPerSample > 0 { metadata.bitDepth = info.bitsPerSample }
            applyVorbisComments(parsed.vorbisComments, into: &metadata)
        }

        // 2) AVAsset 通用元数据中可能携带 ReplayGain（部分 mp3/m4a 经 AVFoundation 反序列化）
        for item in asset.metadata {
            guard let raw = item.identifier?.rawValue ?? item.commonKey?.rawValue else { continue }
            let key = raw.lowercased()
            let value = item.stringValue ?? ""
            ingestKeyValue(key: key, value: value, into: &metadata)
        }

        // 3) iTunNORM（iTunes Sound Check）作为最后兜底
        if metadata.replayGainTrackDB == nil {
            for item in asset.metadata {
                let key = (item.identifier?.rawValue ?? item.commonKey?.rawValue ?? "").lowercased()
                if key.contains("itunnorm"), let v = item.stringValue,
                   let dB = decodeITunNorm(v) {
                    metadata.replayGainTrackDB = dB
                    break
                }
            }
        }
    }

    private static func applyVorbisComments(_ comments: [String: String],
                                             into metadata: inout TrackMetadata) {
        for (rawKey, value) in comments {
            ingestKeyValue(key: rawKey.lowercased(), value: value, into: &metadata)
        }
    }

    private static func ingestKeyValue(key: String, value: String,
                                        into metadata: inout TrackMetadata) {
        switch key {
        case let k where k.contains("replaygain_track_gain"):
            metadata.replayGainTrackDB = parseDBValue(value)
        case let k where k.contains("replaygain_album_gain"):
            metadata.replayGainAlbumDB = parseDBValue(value)
        case let k where k.contains("replaygain_track_peak"):
            metadata.replayGainTrackPeak = Double(value.trimmingCharacters(in: .whitespaces))
        case let k where k.contains("replaygain_album_peak"):
            metadata.replayGainAlbumPeak = Double(value.trimmingCharacters(in: .whitespaces))
        default:
            break
        }
    }

    /// 解析 "-6.42 dB" / "+1.23" / "-1.23dB" 这类字符串
    static func parseDBValue(_ s: String) -> Double? {
        let trimmed = s.replacingOccurrences(of: "dB", with: "",
                                              options: [.caseInsensitive])
                       .trimmingCharacters(in: .whitespaces)
        return Double(trimmed)
    }

    /// iTunNORM 字符串形如 " 00001234 00001234 ..."（10 个 8 位 hex）
    /// 前两个值为左右声道平均能量（1/1000 表示），用 Audirvana / foobar 通用近似：
    ///   gain_dB = -log10(max(L, R) / 1000) * 10
    static func decodeITunNorm(_ s: String) -> Double? {
        let parts = s.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        guard let l = UInt32(parts[0], radix: 16),
              let r = UInt32(parts[1], radix: 16) else { return nil }
        let m = Double(max(l, r))
        guard m > 0 else { return nil }
        return -log10(m / 1000.0) * 10.0
    }
}
