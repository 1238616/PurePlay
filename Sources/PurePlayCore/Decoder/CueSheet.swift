import Foundation

/// CUE Sheet 解析与分轨支持
///
/// 标准 CUE Sheet 是文本文件，描述一个或多个 FILE 引用的音频文件中的逻辑轨道：
///
///   PERFORMER "Some Artist"
///   TITLE "Album"
///   FILE "album.flac" WAVE
///     TRACK 01 AUDIO
///       TITLE "Track 1"
///       PERFORMER "Artist 1"
///       INDEX 01 00:00:00
///     TRACK 02 AUDIO
///       TITLE "Track 2"
///       INDEX 01 04:23:45      ; MM:SS:FF where FF = 1/75 of a second
///
/// 单 FILE 多 TRACK 的 CUE：第 N 轨从 INDEX 01 到第 N+1 轨的 INDEX 01；最后一轨到文件末尾。
/// 多 FILE 的 CUE 暂不支持（首版限定单文件）。
public struct CueTrack: Sendable, Equatable {
    public let number: Int
    public let title: String
    public let performer: String
    /// 起始时间（秒）— 来自 INDEX 01
    public let startSeconds: Double
    /// 结束时间（秒）— 下一轨起点；最后一轨为 nil（=直到文件末尾）
    public let endSeconds: Double?

    public var durationSeconds: Double? {
        guard let end = endSeconds else { return nil }
        return end - startSeconds
    }
}

public struct CueSheet: Sendable, Equatable {
    public let albumTitle: String
    public let albumPerformer: String
    /// FILE "xxx" 引用的音频文件路径（相对或绝对，取决于 CUE 内容）
    public let audioFileRef: String
    public let tracks: [CueTrack]

    public static func parse(_ text: String) -> CueSheet? {
        var albumTitle = ""
        var albumPerformer = ""
        var audioFileRef = ""

        struct Pending {
            var number: Int = 0
            var title: String = ""
            var performer: String = ""
            var index01Seconds: Double = -1
        }
        var pendings: [Pending] = []
        var current: Pending?
        var inTrack = false

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            let tokens = tokenize(line)
            guard let cmd = tokens.first?.uppercased() else { continue }

            switch cmd {
            case "FILE":
                // FILE "xxx.flac" WAVE
                if tokens.count >= 2 { audioFileRef = tokens[1] }
            case "TRACK":
                // 把上一个 track 入队
                if let c = current { pendings.append(c) }
                inTrack = true
                let n = tokens.count >= 2 ? Int(tokens[1]) ?? 0 : 0
                current = Pending(number: n, title: "", performer: "", index01Seconds: -1)
            case "TITLE":
                let v = tokens.count >= 2 ? tokens[1] : ""
                if inTrack {
                    current?.title = v
                } else {
                    albumTitle = v
                }
            case "PERFORMER":
                let v = tokens.count >= 2 ? tokens[1] : ""
                if inTrack {
                    current?.performer = v
                } else {
                    albumPerformer = v
                }
            case "INDEX":
                // INDEX 01 MM:SS:FF
                if tokens.count >= 3, tokens[1] == "01" {
                    if let secs = parseTimestamp(tokens[2]) {
                        current?.index01Seconds = secs
                    }
                }
            default:
                break
            }
        }
        if let c = current { pendings.append(c) }

        // 过滤无 INDEX 01 的轨；按 number 排序
        let valid = pendings.filter { $0.index01Seconds >= 0 }
                           .sorted { $0.number < $1.number }
        guard !valid.isEmpty else { return nil }

        var tracks: [CueTrack] = []
        for (i, p) in valid.enumerated() {
            let end = (i + 1 < valid.count) ? valid[i + 1].index01Seconds : nil
            tracks.append(CueTrack(number: p.number,
                                   title: p.title,
                                   performer: p.performer.isEmpty ? albumPerformer : p.performer,
                                   startSeconds: p.index01Seconds,
                                   endSeconds: end))
        }
        return CueSheet(albumTitle: albumTitle,
                        albumPerformer: albumPerformer,
                        audioFileRef: audioFileRef,
                        tracks: tracks)
    }

    /// 解析 "MM:SS:FF"（FF = 1/75 秒）→ 秒
    private static func parseTimestamp(_ s: String) -> Double? {
        let parts = s.split(separator: ":")
        guard parts.count == 3,
              let m = Int(parts[0]), let sec = Int(parts[1]), let f = Int(parts[2])
        else { return nil }
        return Double(m * 60 + sec) + Double(f) / 75.0
    }

    /// 简易分词：识别 "..." 引号块为一个 token
    private static func tokenize(_ line: String) -> [String] {
        var out: [String] = []
        var buf = ""
        var inQuote = false
        for ch in line {
            if ch == "\"" {
                if inQuote {
                    out.append(buf); buf = ""
                    inQuote = false
                } else {
                    if !buf.isEmpty { out.append(buf); buf = "" }
                    inQuote = true
                }
                continue
            }
            if ch == " " || ch == "\t" {
                if inQuote { buf.append(ch) }
                else if !buf.isEmpty {
                    out.append(buf); buf = ""
                }
                continue
            }
            buf.append(ch)
        }
        if !buf.isEmpty { out.append(buf) }
        return out
    }
}

/// 把任意 AudioDecoder 限制到 [startFrame, endFrame) 范围内
///
/// 用于 CUE 分轨：上层根据 CueTrack.startSeconds × sampleRate 推算 startFrame，
/// 用此 wrapper 包住一个底层 decoder，从而对外暴露"独立 track"。
///
/// 实现细节：
/// - 构造时立即 seek 到 startFrame，并把 currentFrame 视作 0
/// - totalFrames = endFrame - startFrame
/// - decode 调用：透传 + 在 currentFrame 触达 totalFrames 时早停
/// - seek(to:) 会 +startFrame 后传给底层
public final class TrimmingDecoder: AudioDecoder {

    private let inner: AudioDecoder
    private let startFrame: Int64
    public let totalFrames: Int64
    public private(set) var currentFrame: Int64 = 0

    public var format: AudioFormat { inner.format }
    public var isAtEnd: Bool { currentFrame >= totalFrames }

    public init(inner: AudioDecoder, startFrame: Int64, endFrame: Int64?) throws {
        self.inner = inner
        self.startFrame = max(0, startFrame)
        let realEnd = endFrame.map { min($0, inner.totalFrames) } ?? inner.totalFrames
        self.totalFrames = max(0, realEnd - self.startFrame)
        try inner.seek(to: self.startFrame)
    }

    public func decode(into buffer: UnsafeMutableRawPointer, maxFrames: Int) throws -> Int {
        let remaining = totalFrames - currentFrame
        guard remaining > 0 else { return 0 }
        let want = min(maxFrames, Int(remaining))
        let got = try inner.decode(into: buffer, maxFrames: want)
        currentFrame += Int64(got)
        return got
    }

    public func seek(to frame: Int64) throws {
        let clamped = max(0, min(frame, totalFrames))
        try inner.seek(to: startFrame + clamped)
        currentFrame = clamped
    }

    public func close() {
        inner.close()
    }
}
