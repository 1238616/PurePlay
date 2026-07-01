import Foundation

/// Service that coordinates file watching and scanning
final class ScanService {
    static let shared = ScanService()
    
    private let databaseManager: DatabaseManager
    private let scanner: IncrementalScanner
    private var watchers: [String: FileWatcher] = [:] // path -> watcher
    private let queue = DispatchQueue(label: "com.pureplay.scan", qos: .userInitiated)
    
    private init() {
        self.databaseManager = DatabaseManager.shared
        self.scanner = IncrementalScanner(databaseManager: databaseManager)
    }
    
    /// Start watching a directory for changes
    func watchDirectory(_ url: URL) {
        let path = url.path
        
        // Don't add duplicate watchers
        guard watchers[path] == nil else { return }
        
        let watcher = FileWatcher(paths: [url], latency: 2.0) { [weak self] changedPaths in
            self?.handleFileChanges(changedPaths)
        }
        
        watchers[path] = watcher
        watcher.start()
        
        print("Started watching: \(path)")
    }
    
    /// Stop watching a directory
    func unwatchDirectory(_ url: URL) {
        let path = url.path
        
        guard let watcher = watchers[path] else { return }
        
        watcher.stop()
        watchers.removeValue(forKey: path)
        
        print("Stopped watching: \(path)")
    }
    
    /// Stop all watchers
    func stopAllWatchers() {
        for (_, watcher) in watchers {
            watcher.stop()
        }
        watchers.removeAll()
    }
    
    /// Perform a full scan of a directory
    func fullScan(directory: URL, completion: @escaping (Result<[TrackRecord], Error>) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            do {
                let audioFiles = try self.scanner.fullScan(directory: directory)
                var tracks: [TrackRecord] = []
                
                for fileURL in audioFiles {
                    let track = try self.createTrackRecord(from: fileURL)
                    try self.databaseManager.addTrack(track)
                    tracks.append(track)
                }
                
                DispatchQueue.main.async {
                    completion(.success(tracks))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
    
    /// Perform an incremental scan to detect changes
    func incrementalScan(directory: URL, completion: @escaping (Result<ScanResult, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            do {
                let result = try self.scanner.incrementalScan(directory: directory)
                
                // Process added files
                for fileURL in result.added {
                    let track = try self.createTrackRecord(from: fileURL)
                    try self.databaseManager.addTrack(track)
                }
                
                // Process modified files
                for fileURL in result.modified {
                    guard let track = try self.databaseManager.track(byFilePath: fileURL.path) else { continue }
                    let updatedTrack = try self.createTrackRecord(from: fileURL, existingId: track.id)
                    try self.databaseManager.updateTrack(updatedTrack)
                }
                
                // Process deleted files
                for fileURL in result.deleted {
                    guard let track = try self.databaseManager.track(byFilePath: fileURL.path),
                          let trackId = track.id else { continue }
                    try self.databaseManager.deleteTrack(id: trackId)
                }
                
                DispatchQueue.main.async {
                    completion(.success(result))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
    
    /// Handle file change events from FSEvents
    private func handleFileChanges(_ changedPaths: [String]) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            for path in changedPaths {
                let url = URL(fileURLWithPath: path)
                
                // Only process audio files
                guard self.scanner.isAudioFile(url) else { continue }
                
                let fileManager = FileManager.default
                
                if fileManager.fileExists(atPath: path) {
                    // File was added or modified
                    do {
                        if let existingTrack = try self.databaseManager.track(byFilePath: path) {
                            // Update existing track
                            let updatedTrack = try self.createTrackRecord(from: url, existingId: existingTrack.id)
                            try self.databaseManager.updateTrack(updatedTrack)
                            print("Updated track: \(path)")
                        } else {
                            // Add new track
                            let track = try self.createTrackRecord(from: url)
                            try self.databaseManager.addTrack(track)
                            print("Added track: \(path)")
                        }
                    } catch {
                        print("Error processing file change: \(path) - \(error)")
                    }
                } else {
                    // File was deleted
                    do {
                        if let track = try self.databaseManager.track(byFilePath: path),
                           let trackId = track.id {
                            try self.databaseManager.deleteTrack(id: trackId)
                            print("Deleted track: \(path)")
                        }
                    } catch {
                        print("Error deleting track: \(path) - \(error)")
                    }
                }
            }
        }
    }
    
    /// Create a TrackRecord from a file URL
    private func createTrackRecord(from url: URL, existingId: Int64? = nil) throws -> TrackRecord {
        let fileManager = FileManager.default
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        
        let fileSize = attributes[.size] as? Int64 ?? 0
        let modificationDate = attributes[.modificationDate] as? Date ?? Date()
        
        // Read metadata
        let metadata = MetadataReader.readMetadata(from: url) ?? TrackMetadata(duration: 0)
        
        // Extract cover art (use 0 as temporary ID for new tracks)
        let coverArtPath = CoverArtManager.shared.extractAndCacheCoverArt(for: url, trackId: existingId ?? 0)
        
        var track = TrackRecord(
            id: existingId,
            filePath: url.path,
            fileName: url.lastPathComponent,
            title: metadata.title ?? url.deletingPathExtension().lastPathComponent,
            artist: metadata.artist ?? "Unknown Artist",
            album: metadata.album ?? "Unknown Album",
            albumArtist: metadata.albumArtist ?? metadata.artist ?? "Unknown Artist",
            genre: metadata.genre ?? "Unknown Genre",
            year: metadata.year,
            trackNumber: metadata.trackNumber,
            discNumber: metadata.discNumber,
            duration: metadata.duration,
            sampleRate: metadata.sampleRate ?? 44100.0,
            bitDepth: metadata.bitDepth ?? 16,
            channels: metadata.channels ?? 2,
            fileSize: fileSize,
            fileModified: modificationDate,
            dateAdded: existingId == nil ? Date() : Date(), // Keep original dateAdded for updates
            lastPlayed: nil,
            playCount: 0,
            isFavorite: false,
            coverArtPath: coverArtPath
        )
        
        // Preserve existing stats for updates
        if let existingId = existingId, let existing = try databaseManager.track(byId: existingId) {
            track.dateAdded = existing.dateAdded
            track.lastPlayed = existing.lastPlayed
            track.playCount = existing.playCount
            track.isFavorite = existing.isFavorite
        }
        
        return track
    }
    
    /// Get list of currently watched directories
    var watchedDirectories: [URL] {
        return watchers.keys.map { URL(fileURLWithPath: $0) }
    }
}
