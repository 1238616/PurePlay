import Foundation
import CryptoKit

final class CoverArtManager {
    static let shared = CoverArtManager()
    
    private let cacheDirectory: URL
    
    private init() {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = cachesDir.appendingPathComponent("PurePlay/CoverArt", isDirectory: true)
        
        // Create cache directory if it doesn't exist
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
    
    /// Extract cover art from an audio file
    /// Returns the path to the cached cover art, or nil if no cover art found
    func extractAndCacheCoverArt(for trackURL: URL, trackId: Int64) -> String? {
        // Check if we already have cached cover art for this track
        if let cachedPath = cachedCoverArtPath(for: trackId),
           FileManager.default.fileExists(atPath: cachedPath) {
            return cachedPath
        }
        
        // Try to extract from metadata
        if let metadata = MetadataReader.readMetadata(from: trackURL),
           let coverData = metadata.coverArtData {
            return cacheCoverArt(data: coverData, for: trackId)
        }
        
        // Try to find cover art in the same directory
        let directory = trackURL.deletingLastPathComponent()
        let coverFileNames = ["cover.jpg", "cover.jpeg", "cover.png",
                             "folder.jpg", "folder.jpeg", "folder.png",
                             "album.jpg", "album.jpeg", "album.png",
                             "front.jpg", "front.jpeg", "front.png"]
        
        for fileName in coverFileNames {
            let coverPath = directory.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: coverPath.path),
               let data = try? Data(contentsOf: coverPath) {
                return cacheCoverArt(data: data, for: trackId)
            }
        }
        
        return nil
    }
    
    /// Get the cached cover art path for a track
    func cachedCoverArtPath(for trackId: Int64) -> String? {
        // Try common extensions
        let extensions = ["jpg", "jpeg", "png"]
        for ext in extensions {
            let path = cacheDirectory.appendingPathComponent("\(trackId).\(ext)").path
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }
    
    /// Cache cover art data to disk
    private func cacheCoverArt(data: Data, for trackId: Int64) -> String? {
        // Determine file extension from data
        let ext = fileExtension(for: data)
        let cachePath = cacheDirectory.appendingPathComponent("\(trackId).\(ext)")
        
        do {
            try data.write(to: cachePath)
            return cachePath.path
        } catch {
            print("Failed to cache cover art: \(error)")
            return nil
        }
    }
    
    /// Determine file extension from image data
    private func fileExtension(for data: Data) -> String {
        guard data.count >= 8 else { return "jpg" }
        
        // Check magic bytes
        let bytes = [UInt8](data.prefix(8))
        
        // PNG: 89 50 4E 47
        if bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 {
            return "png"
        }
        
        // JPEG: FF D8 FF
        if bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF {
            return "jpg"
        }
        
        // Default to jpg
        return "jpg"
    }
    
    /// Clear all cached cover art
    func clearCache() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
    
    /// Get total cache size in bytes
    func cacheSize() -> Int64 {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: cacheDirectory,
                                                     includingPropertiesForKeys: [.fileSizeKey],
                                                     options: [.skipsHiddenFiles]) else {
            return 0
        }
        
        var totalSize: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                  let fileSize = resourceValues.fileSize else {
                continue
            }
            totalSize += Int64(fileSize)
        }
        
        return totalSize
    }
}
