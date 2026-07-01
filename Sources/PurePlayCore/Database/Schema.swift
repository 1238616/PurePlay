import Foundation
import GRDB

// MARK: - Track Record

public struct TrackRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    public var id: Int64?
    public var filePath: String
    public var fileName: String
    public var title: String
    public var artist: String
    public var album: String
    public var albumArtist: String
    public var genre: String
    public var year: Int?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var duration: Double
    public var sampleRate: Double
    public var bitDepth: Int
    public var channels: Int
    public var fileSize: Int64
    public var fileModified: Date
    public var dateAdded: Date
    public var lastPlayed: Date?
    public var playCount: Int
    public var isFavorite: Bool
    public var coverArtPath: String?

    /// 来源：'local' = 本地文件；'quark' = 夸克网盘
    public var source: String
    /// 云盘文件 id（source='quark' 时使用，本地为 nil）
    public var cloudFileId: String?
    /// 格式标识：'flac' / 'wav' / 'dsf' / 'dff' / 'alac' / 'mp3' ...
    public var format: String
    /// ReplayGain（dB），可选；优先读取 album，回退 track
    public var replayGainTrack: Double?
    public var replayGainAlbum: Double?

    public init(id: Int64? = nil,
                filePath: String,
                fileName: String,
                title: String,
                artist: String,
                album: String,
                albumArtist: String = "",
                genre: String = "",
                year: Int? = nil,
                trackNumber: Int? = nil,
                discNumber: Int? = nil,
                duration: Double = 0,
                sampleRate: Double = 44100,
                bitDepth: Int = 16,
                channels: Int = 2,
                fileSize: Int64 = 0,
                fileModified: Date = Date(),
                dateAdded: Date = Date(),
                lastPlayed: Date? = nil,
                playCount: Int = 0,
                isFavorite: Bool = false,
                coverArtPath: String? = nil,
                source: String = "local",
                cloudFileId: String? = nil,
                format: String = "",
                replayGainTrack: Double? = nil,
                replayGainAlbum: Double? = nil) {
        self.id = id
        self.filePath = filePath
        self.fileName = fileName
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.genre = genre
        self.year = year
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.duration = duration
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channels = channels
        self.fileSize = fileSize
        self.fileModified = fileModified
        self.dateAdded = dateAdded
        self.lastPlayed = lastPlayed
        self.playCount = playCount
        self.isFavorite = isFavorite
        self.coverArtPath = coverArtPath
        self.source = source
        self.cloudFileId = cloudFileId
        self.format = format
        self.replayGainTrack = replayGainTrack
        self.replayGainAlbum = replayGainAlbum
    }

    public static let databaseTableName = "track"

    public enum Columns: String, ColumnExpression {
        case id, filePath, fileName, title, artist, album, albumArtist
        case genre, year, trackNumber, discNumber, duration
        case sampleRate, bitDepth, channels, fileSize, fileModified
        case dateAdded, lastPlayed, playCount, isFavorite, coverArtPath
        case source, cloudFileId, format, replayGainTrack, replayGainAlbum
    }
}

// MARK: - Album Record

public struct AlbumRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    public var id: Int64?
    public var title: String
    public var artist: String
    public var albumArtist: String
    public var year: Int?
    public var trackCount: Int
    public var duration: Double
    public var coverArtPath: String?
    
    public init(id: Int64? = nil, title: String, artist: String, albumArtist: String = "", year: Int? = nil, trackCount: Int = 0, duration: Double = 0, coverArtPath: String? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist
        self.year = year
        self.trackCount = trackCount
        self.duration = duration
        self.coverArtPath = coverArtPath
    }
    
    public static let databaseTableName = "album"
    
    public enum Columns: String, ColumnExpression {
        case id, title, artist, albumArtist, year, trackCount, duration, coverArtPath
    }
}

// MARK: - Artist Record

public struct ArtistRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    public var id: Int64?
    public var name: String
    public var albumCount: Int
    public var trackCount: Int
    
    public static let databaseTableName = "artist"
    
    public enum Columns: String, ColumnExpression {
        case id, name, albumCount, trackCount
    }
}

// MARK: - Playlist Record

public struct PlaylistRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    public var id: Int64?
    public var name: String
    public var isSmart: Bool
    public var smartRules: String?  // JSON-encoded rules
    public var dateCreated: Date
    public var dateModified: Date
    
    public static let databaseTableName = "playlist"
    
    public enum Columns: String, ColumnExpression {
        case id, name, isSmart, smartRules, dateCreated, dateModified
    }
}

// MARK: - Playlist Track Record

struct PlaylistTrackRecord: Codable, FetchableRecord, PersistableRecord {
    var playlistId: Int64
    var trackId: Int64
    var position: Int
    
    static let databaseTableName = "playlist_track"
    
    enum Columns: String, ColumnExpression {
        case playlistId, trackId, position
    }
}

// MARK: - Play History Record

struct PlayHistoryRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var trackId: Int64
    var playedAt: Date
    var durationPlayed: Double
    
    static let databaseTableName = "play_history"
    
    enum Columns: String, ColumnExpression {
        case id, trackId, playedAt, durationPlayed
    }
}
