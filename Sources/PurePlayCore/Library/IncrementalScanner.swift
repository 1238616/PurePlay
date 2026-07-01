import Foundation

/// Result of an incremental scan
struct ScanResult {
    let added: [URL]
    let modified: [URL]
    let deleted: [URL]
}

/// Incremental scanner that detects file system changes
final class IncrementalScanner {
    private let audioExtensions: Set<String> = [
        "flac", "wav", "aiff", "aif", "alac", "m4a",
        "mp3", "aac", "ogg", "opus", "wma", "dsf", "dff"
    ]
    
    private let databaseManager: DatabaseManager
    
    init(databaseManager: DatabaseManager) {
        self.databaseManager = databaseManager
    }
    
    /// Perform a full scan of the directory
    func fullScan(directory: URL) throws -> [URL] {
        let fileManager = FileManager.default
        
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw NSError(domain: "IncrementalScanner", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create enumerator"])
        }
        
        var audioFiles: [URL] = []
        
        for case let fileURL as URL in enumerator {
            let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            
            guard resourceValues.isRegularFile == true else { continue }
            guard isAudioFile(fileURL) else { continue }
            
            audioFiles.append(fileURL)
        }
        
        return audioFiles
    }
    
    /// Perform an incremental scan to detect changes since last scan
    func incrementalScan(directory: URL) throws -> ScanResult {
        let currentFiles = try fullScan(directory: directory)
        
        // Get all tracks from database
        let existingTracks = try databaseManager.allTracks()
        let existingPaths = Set(existingTracks.map { $0.filePath })
        let currentPaths = Set(currentFiles.map { $0.path })
        
        // Detect added files
        let addedPaths = currentPaths.subtracting(existingPaths)
        let added = currentFiles.filter { addedPaths.contains($0.path) }
        
        // Detect deleted files
        let deletedPaths = existingPaths.subtracting(currentPaths)
        let deleted = deletedPaths.map { URL(fileURLWithPath: $0) }
        
        // Detect modified files (check modification dates)
        var modified: [URL] = []
        
        for fileURL in currentFiles {
            guard existingPaths.contains(fileURL.path) else { continue }
            
            let resourceValues = try fileURL.resourceValues(forKeys: [.contentModificationDateKey])
            guard let modificationDate = resourceValues.contentModificationDate else { continue }
            
            // Find the track in database
            guard let track = existingTracks.first(where: { $0.filePath == fileURL.path }) else { continue }
            
            // Compare modification dates (allow 1 second tolerance)
            if abs(modificationDate.timeIntervalSince(track.dateAdded)) > 1.0 {
                modified.append(fileURL)
            }
        }
        
        return ScanResult(added: added, modified: modified, deleted: deleted)
    }
    
    /// Check if a file is an audio file based on its extension
    func isAudioFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return audioExtensions.contains(ext)
    }
    
    /// Get the set of supported audio extensions
    var supportedExtensions: Set<String> {
        return audioExtensions
    }
}
