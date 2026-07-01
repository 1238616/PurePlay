import Foundation
import GRDB

public enum DatabaseError: Error {
    case insertFailed
    case notFound
    case invalidData
}

public final class DatabaseManager {
    public static let shared = DatabaseManager()
    
    private let dbQueue: DatabaseQueue
    
    private init() {
        // Create database in Application Support directory
        let fileManager = FileManager.default
        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dbDirectoryURL = appSupportURL.appendingPathComponent("PurePlay", isDirectory: true)
        
        // Create directory if needed
        try? fileManager.createDirectory(at: dbDirectoryURL, withIntermediateDirectories: true)
        
        let dbPath = dbDirectoryURL.appendingPathComponent("Library.sqlite").path
        
        do {
            dbQueue = try DatabaseQueue(path: dbPath)
            try migrator.migrate(dbQueue)
        } catch {
            fatalError("Database initialization failed: \(error)")
        }
    }
    
    // MARK: - Migrations
    
    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif
        
        // v1: Initial schema
        migrator.registerMigration("v1") { db in
            // Track table
            try db.create(table: "track") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("filePath", .text).notNull().unique()
                t.column("fileName", .text).notNull()
                t.column("title", .text).notNull().defaults(to: "")
                t.column("artist", .text).notNull().defaults(to: "")
                t.column("album", .text).notNull().defaults(to: "")
                t.column("albumArtist", .text).notNull().defaults(to: "")
                t.column("genre", .text).notNull().defaults(to: "")
                t.column("year", .integer)
                t.column("trackNumber", .integer)
                t.column("discNumber", .integer)
                t.column("duration", .double).notNull().defaults(to: 0.0)
                t.column("sampleRate", .double).notNull().defaults(to: 44100.0)
                t.column("bitDepth", .integer).notNull().defaults(to: 16)
                t.column("channels", .integer).notNull().defaults(to: 2)
                t.column("fileSize", .integer).notNull().defaults(to: 0)
                t.column("fileModified", .datetime).notNull()
                t.column("dateAdded", .datetime).notNull()
                t.column("lastPlayed", .datetime)
                t.column("playCount", .integer).notNull().defaults(to: 0)
                t.column("isFavorite", .boolean).notNull().defaults(to: false)
                t.column("coverArtPath", .text)
            }
            
            // Album table
            try db.create(table: "album") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("artist", .text).notNull()
                t.column("albumArtist", .text).notNull().defaults(to: "")
                t.column("year", .integer)
                t.column("trackCount", .integer).notNull().defaults(to: 0)
                t.column("duration", .double).notNull().defaults(to: 0.0)
                t.column("coverArtPath", .text)
            }
            
            // Artist table
            try db.create(table: "artist") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique()
                t.column("albumCount", .integer).notNull().defaults(to: 0)
                t.column("trackCount", .integer).notNull().defaults(to: 0)
            }
            
            // Playlist table
            try db.create(table: "playlist") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("isSmart", .boolean).notNull().defaults(to: false)
                t.column("smartRules", .text)
                t.column("dateCreated", .datetime).notNull()
                t.column("dateModified", .datetime).notNull()
            }
            
            // Playlist-Track junction table
            try db.create(table: "playlist_track") { t in
                t.column("playlistId", .integer).notNull().references("playlist", onDelete: .cascade)
                t.column("trackId", .integer).notNull().references("track", onDelete: .cascade)
                t.column("position", .integer).notNull()
                t.primaryKey(["playlistId", "trackId"])
            }
            
            // Play history table
            try db.create(table: "play_history") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("trackId", .integer).notNull().references("track", onDelete: .cascade)
                t.column("playedAt", .datetime).notNull()
                t.column("durationPlayed", .double).notNull()
            }
            
            // Indexes for performance
            try db.create(index: "track_artist", on: "track", columns: ["artist"])
            try db.create(index: "track_album", on: "track", columns: ["album"])
            try db.create(index: "track_genre", on: "track", columns: ["genre"])
            try db.create(index: "track_favorite", on: "track", columns: ["isFavorite"])
            try db.create(index: "track_filepath", on: "track", columns: ["filePath"])
            try db.create(index: "playlist_track_playlist", on: "playlist_track", columns: ["playlistId"])
            try db.create(index: "play_history_track", on: "play_history", columns: ["trackId"])
            try db.create(index: "play_history_date", on: "play_history", columns: ["playedAt"])
        }

        // v2: 对齐 Design.md §6.1 — 增补 source/cloud/format/replayGain 字段
        migrator.registerMigration("v2_extended_track_fields") { db in
            try db.alter(table: "track") { t in
                t.add(column: "source", .text).notNull().defaults(to: "local")
                t.add(column: "cloudFileId", .text)
                t.add(column: "format", .text).notNull().defaults(to: "")
                t.add(column: "replayGainTrack", .double)
                t.add(column: "replayGainAlbum", .double)
            }
            try db.create(index: "track_source", on: "track", columns: ["source"])
            try db.create(index: "track_cloud_fid", on: "track", columns: ["cloudFileId"])
            try db.create(index: "track_format", on: "track", columns: ["format"])
        }

        // v3: FTS5 全文搜索（Design.md §6.1）
        migrator.registerMigration("v3_fts5") { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE track_fts USING fts5(
                    title, artist, album, albumArtist,
                    content='track', content_rowid='id'
                );
                """)

            // 同步触发器：track 表变动 → FTS 索引保持一致
            try db.execute(sql: """
                CREATE TRIGGER track_fts_ai AFTER INSERT ON track BEGIN
                  INSERT INTO track_fts(rowid, title, artist, album, albumArtist)
                    VALUES (new.id, new.title, new.artist, new.album, new.albumArtist);
                END;
                """)
            try db.execute(sql: """
                CREATE TRIGGER track_fts_ad AFTER DELETE ON track BEGIN
                  INSERT INTO track_fts(track_fts, rowid, title, artist, album, albumArtist)
                    VALUES ('delete', old.id, old.title, old.artist, old.album, old.albumArtist);
                END;
                """)
            try db.execute(sql: """
                CREATE TRIGGER track_fts_au AFTER UPDATE ON track BEGIN
                  INSERT INTO track_fts(track_fts, rowid, title, artist, album, albumArtist)
                    VALUES ('delete', old.id, old.title, old.artist, old.album, old.albumArtist);
                  INSERT INTO track_fts(rowid, title, artist, album, albumArtist)
                    VALUES (new.id, new.title, new.artist, new.album, new.albumArtist);
                END;
                """)

            // 回填既有数据
            try db.execute(sql: """
                INSERT INTO track_fts(rowid, title, artist, album, albumArtist)
                  SELECT id, title, artist, album, albumArtist FROM track;
                """)
        }
        
        return migrator
    }
    
    // MARK: - Track CRUD
    
    public func addTrack(_ track: TrackRecord) throws -> Int64 {
        try dbQueue.write { db in
            var insertedTrack = track
            try insertedTrack.insert(db)
            return db.lastInsertedRowID
        }
    }
    
    public func updateTrack(_ track: TrackRecord) throws {
        try dbQueue.write { db in
            try track.update(db)
        }
    }
    
    public func deleteTrack(id: Int64) throws {
        try dbQueue.write { db in
            _ = try TrackRecord.deleteOne(db, id: id)
        }
    }
    
    public func track(byId id: Int64) throws -> TrackRecord? {
        try dbQueue.read { db in
            try TrackRecord.fetchOne(db, id: id)
        }
    }
    
    public func track(byFilePath path: String) throws -> TrackRecord? {
        try dbQueue.read { db in
            try TrackRecord.filter(TrackRecord.Columns.filePath == path).fetchOne(db)
        }
    }
    
    public func allTracks() throws -> [TrackRecord] {
        try dbQueue.read { db in
            try TrackRecord.order(TrackRecord.Columns.title).fetchAll(db)
        }
    }
    
    public func tracks(byArtist artist: String) throws -> [TrackRecord] {
        try dbQueue.read { db in
            try TrackRecord
                .filter(TrackRecord.Columns.artist == artist)
                .order(TrackRecord.Columns.album, TrackRecord.Columns.trackNumber)
                .fetchAll(db)
        }
    }
    
    public func tracks(byAlbum album: String, artist: String? = nil) throws -> [TrackRecord] {
        try dbQueue.read { db in
            var query = TrackRecord.filter(TrackRecord.Columns.album == album)
            if let artist = artist {
                query = query.filter(TrackRecord.Columns.artist == artist)
            }
            return try query.order(TrackRecord.Columns.discNumber, TrackRecord.Columns.trackNumber).fetchAll(db)
        }
    }
    
    public func tracks(byGenre genre: String) throws -> [TrackRecord] {
        try dbQueue.read { db in
            try TrackRecord
                .filter(TrackRecord.Columns.genre == genre)
                .order(TrackRecord.Columns.artist, TrackRecord.Columns.album, TrackRecord.Columns.trackNumber)
                .fetchAll(db)
        }
    }
    
    public func searchTracks(query: String) throws -> [TrackRecord] {
        try dbQueue.read { db in
            let pattern = "%\(query)%"
            return try TrackRecord
                .filter(
                    TrackRecord.Columns.title.like(pattern) ||
                    TrackRecord.Columns.artist.like(pattern) ||
                    TrackRecord.Columns.album.like(pattern)
                )
                .order(TrackRecord.Columns.title)
                .fetchAll(db)
        }
    }

    /// FTS5 全文搜索（按相关度 bm25 排序）
    /// 自动对查询里的特殊字符做转义；空查询返回空列表
    public func searchTracksFTS(query: String) throws -> [TrackRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // 拆词 + 加双引号转义（FTS5 phrase syntax 允许 "any chars"）
        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace })
        let ftsQuery = tokens
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " ")

        return try dbQueue.read { db in
            let sql = """
                SELECT track.* FROM track
                JOIN track_fts ON track.id = track_fts.rowid
                WHERE track_fts MATCH ?
                ORDER BY bm25(track_fts)
                LIMIT 500
                """
            return try TrackRecord.fetchAll(db, sql: sql, arguments: [ftsQuery])
        }
    }

    public func tracks(bySource source: String) throws -> [TrackRecord] {
        try dbQueue.read { db in
            try TrackRecord
                .filter(TrackRecord.Columns.source == source)
                .order(TrackRecord.Columns.title)
                .fetchAll(db)
        }
    }

    public func tracks(byFormat format: String) throws -> [TrackRecord] {
        try dbQueue.read { db in
            try TrackRecord
                .filter(TrackRecord.Columns.format == format)
                .order(TrackRecord.Columns.album, TrackRecord.Columns.trackNumber)
                .fetchAll(db)
        }
    }
    
    public func favoriteTracks() throws -> [TrackRecord] {
        try dbQueue.read { db in
            try TrackRecord
                .filter(TrackRecord.Columns.isFavorite == true)
                .order(TrackRecord.Columns.title)
                .fetchAll(db)
        }
    }
    
    func incrementPlayCount(trackId: Int64) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE track 
                    SET playCount = playCount + 1, lastPlayed = ?
                    WHERE id = ?
                    """,
                arguments: [Date(), trackId]
            )
        }
    }
    
    func toggleFavorite(trackId: Int64) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE track SET isFavorite = NOT isFavorite WHERE id = ?",
                arguments: [trackId]
            )
        }
    }
    
    // MARK: - Album CRUD
    
    public func allAlbums() throws -> [AlbumRecord] {
        try dbQueue.read { db in
            try AlbumRecord.order(AlbumRecord.Columns.title).fetchAll(db)
        }
    }
    
    func albums(byArtist artist: String) throws -> [AlbumRecord] {
        try dbQueue.read { db in
            try AlbumRecord
                .filter(AlbumRecord.Columns.artist == artist)
                .order(AlbumRecord.Columns.year, AlbumRecord.Columns.title)
                .fetchAll(db)
        }
    }
    
    func addAlbum(_ album: AlbumRecord) throws -> Int64 {
        try dbQueue.write { db in
            var insertedAlbum = album
            try insertedAlbum.insert(db)
            return db.lastInsertedRowID
        }
    }
    
    // MARK: - Artist CRUD
    
    func allArtists() throws -> [ArtistRecord] {
        try dbQueue.read { db in
            try ArtistRecord.order(ArtistRecord.Columns.name).fetchAll(db)
        }
    }
    
    func addArtist(_ artist: ArtistRecord) throws -> Int64 {
        try dbQueue.write { db in
            var insertedArtist = artist
            try insertedArtist.insert(db)
            return db.lastInsertedRowID
        }
    }
    
    // MARK: - Playlist CRUD
    
    func allPlaylists() throws -> [PlaylistRecord] {
        try dbQueue.read { db in
            try PlaylistRecord.order(PlaylistRecord.Columns.dateCreated).fetchAll(db)
        }
    }
    
    func addPlaylist(_ playlist: PlaylistRecord) throws -> Int64 {
        try dbQueue.write { db in
            var insertedPlaylist = playlist
            try insertedPlaylist.insert(db)
            return db.lastInsertedRowID
        }
    }
    
    func deletePlaylist(id: Int64) throws {
        try dbQueue.write { db in
            _ = try PlaylistRecord.deleteOne(db, id: id)
        }
    }
    
    public func playlist(byId id: Int64) throws -> PlaylistRecord? {
        try dbQueue.read { db in
            try PlaylistRecord.fetchOne(db, id: id)
        }
    }
    
    public func updatePlaylist(_ playlist: PlaylistRecord) throws {
        try dbQueue.write { db in
            try playlist.update(db)
        }
    }
    
    func addTrackToPlaylist(playlistId: Int64, trackId: Int64, position: Int) throws {
        try dbQueue.write { db in
            let record = PlaylistTrackRecord(
                playlistId: playlistId,
                trackId: trackId,
                position: position
            )
            try record.insert(db)
        }
    }
    
    func removeTrackFromPlaylist(playlistId: Int64, trackId: Int64) throws {
        try dbQueue.write { db in
            _ = try PlaylistTrackRecord
                .filter(PlaylistTrackRecord.Columns.playlistId == playlistId)
                .filter(PlaylistTrackRecord.Columns.trackId == trackId)
                .deleteAll(db)
        }
    }
    
    func playlistTracks(playlistId: Int64) throws -> [TrackRecord] {
        try dbQueue.read { db in
            let sql = """
                SELECT track.* FROM track
                JOIN playlist_track ON track.id = playlist_track.trackId
                WHERE playlist_track.playlistId = ?
                ORDER BY playlist_track.position
                """
            return try TrackRecord.fetchAll(db, sql: sql, arguments: [playlistId])
        }
    }
    
    // MARK: - Play History
    
    func addPlayHistory(trackId: Int64, playedAt: Date, durationPlayed: Double) throws {
        try dbQueue.write { db in
            let record = PlayHistoryRecord(
                trackId: trackId,
                playedAt: playedAt,
                durationPlayed: durationPlayed
            )
            try record.insert(db)
        }
    }
    
    func playHistory(forTrackId trackId: Int64) throws -> [PlayHistoryRecord] {
        try dbQueue.read { db in
            try PlayHistoryRecord
                .filter(PlayHistoryRecord.Columns.trackId == trackId)
                .order(PlayHistoryRecord.Columns.playedAt.desc)
                .fetchAll(db)
        }
    }
    
    func recentPlayHistory(limit: Int = 50) throws -> [PlayHistoryRecord] {
        try dbQueue.read { db in
            try PlayHistoryRecord
                .order(PlayHistoryRecord.Columns.playedAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }
    
    // MARK: - Statistics
    
    func trackCount() throws -> Int {
        try dbQueue.read { db in
            try TrackRecord.fetchCount(db)
        }
    }
    
    func albumCount() throws -> Int {
        try dbQueue.read { db in
            try AlbumRecord.fetchCount(db)
        }
    }
    
    func artistCount() throws -> Int {
        try dbQueue.read { db in
            try ArtistRecord.fetchCount(db)
        }
    }
}
