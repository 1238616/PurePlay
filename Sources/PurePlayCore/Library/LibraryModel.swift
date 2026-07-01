import Foundation

/// 简化的音乐库模型（in-memory，用于 Phase 1）
/// 产品版应替换为 GRDB.swift + SQLite
public struct TrackInfo: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let url: URL
    public let title: String
    public let artist: String
    public let album: String
    public let sampleRate: Double
    public let bitDepth: Int
    public let channels: Int
    public let format: AudioFileFormat
    public let durationSeconds: Double
    public let fileSize: Int64

    public init(url: URL, title: String = "", artist: String = "",
                album: String = "", sampleRate: Double = 44100,
                bitDepth: Int = 16, channels: Int = 2,
                format: AudioFileFormat = .wav, durationSeconds: Double = 0,
                fileSize: Int64 = 0) {
        self.id = UUID()
        self.url = url
        self.title = title.isEmpty ? url.deletingPathExtension().lastPathComponent : title
        self.artist = artist
        self.album = album
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channels = channels
        self.format = format
        self.durationSeconds = durationSeconds
        self.fileSize = fileSize
    }
}

/// In-memory 音乐库（开发 + 测试用）
public final class InMemoryLibrary: @unchecked Sendable {
    private var tracks: [TrackInfo] = []
    private let lock = NSLock()

    public init() {}

    public func add(_ track: TrackInfo) {
        lock.lock(); defer { lock.unlock() }
        tracks.append(track)
    }

    public func allTracks() -> [TrackInfo] {
        lock.lock(); defer { lock.unlock() }
        return tracks
    }

    public func search(query: String) -> [TrackInfo] {
        lock.lock(); defer { lock.unlock() }
        let q = query.lowercased()
        return tracks.filter {
            $0.title.lowercased().contains(q) ||
            $0.artist.lowercased().contains(q) ||
            $0.album.lowercased().contains(q)
        }
    }

    public func remove(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        tracks.removeAll { $0.id == id }
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return tracks.count
    }
}
