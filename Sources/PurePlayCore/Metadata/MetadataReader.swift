import Foundation
import AVFoundation

struct TrackMetadata {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var genre: String?
    var year: Int?
    var trackNumber: Int?
    var discNumber: Int?
    var duration: Double
    var sampleRate: Double?
    var bitDepth: Int?
    var channels: Int?
    var coverArtData: Data?
    var coverArtMimeType: String?
    var replayGainTrackDB: Double?
    var replayGainAlbumDB: Double?
    var replayGainTrackPeak: Double?
    var replayGainAlbumPeak: Double?
}

final class MetadataReader {
    static func readMetadata(from url: URL) -> TrackMetadata? {
        let asset = AVAsset(url: url)
        
        var result = TrackMetadata(duration: 0)
        
        // Read common metadata (synchronous access)
        let metadata = asset.commonMetadata
        for item in metadata {
            guard let key = item.commonKey?.rawValue else { continue }
            
            switch key {
            case "title":
                result.title = item.stringValue
            case "artist":
                result.artist = item.stringValue
            case "albumName":
                result.album = item.stringValue
            case "albumArtist":
                result.albumArtist = item.stringValue
            case "genre":
                result.genre = item.stringValue
            case "creationDate":
                if let date = item.dateValue {
                    result.year = Calendar.current.component(.year, from: date)
                } else if let yearString = item.stringValue, let year = Int(yearString) {
                    result.year = year
                }
            case "trackNumber":
                result.trackNumber = item.numberValue?.intValue
            case "discNumber":
                result.discNumber = item.numberValue?.intValue
            case "artwork":
                result.coverArtData = item.dataValue
                if let mimeType = item.dataType {
                    result.coverArtMimeType = mimeType
                }
            default:
                break
            }
        }
        
        // Duration from asset
        result.duration = CMTimeGetSeconds(asset.duration)
        
        // Read audio format information (synchronous)
        let tracks = asset.tracks(withMediaType: .audio)
        if let audioTrack = tracks.first {
            // Format descriptions
            let descriptions = audioTrack.formatDescriptions as? [CMAudioFormatDescription] ?? []
            if let formatDesc = descriptions.first {
                let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
                if let asbd = asbd?.pointee {
                    result.sampleRate = asbd.mSampleRate
                    result.channels = Int(asbd.mChannelsPerFrame)
                    
                    // Bit depth
                    switch asbd.mFormatID {
                    case kAudioFormatLinearPCM:
                        result.bitDepth = Int(asbd.mBitsPerChannel)
                    default:
                        // For compressed formats, bit depth may not be applicable
                        break
                    }
                }
            }
        }

        ReplayGainReader.augment(metadata: &result, url: url, asset: asset)
        return result
    }
    
    /// Async version for better performance with large libraries
    static func readMetadataAsync(from url: URL) async throws -> TrackMetadata {
        let asset = AVAsset(url: url)
        
        var result = TrackMetadata(duration: 0)
        
        // Load metadata
        let metadata = try await asset.load(.commonMetadata)
        
        for item in metadata {
            let key = item.commonKey?.rawValue
            guard let key = key else { continue }
            
            switch key {
            case "title":
                result.title = item.stringValue
            case "artist":
                result.artist = item.stringValue
            case "albumName":
                result.album = item.stringValue
            case "albumArtist":
                result.albumArtist = item.stringValue
            case "genre":
                result.genre = item.stringValue
            case "creationDate":
                if let date = item.dateValue {
                    result.year = Calendar.current.component(.year, from: date)
                } else if let yearString = item.stringValue, let year = Int(yearString) {
                    result.year = year
                }
            case "trackNumber":
                result.trackNumber = item.numberValue?.intValue
            case "discNumber":
                result.discNumber = item.numberValue?.intValue
            case "artwork":
                result.coverArtData = item.dataValue
                if let mimeType = item.dataType {
                    result.coverArtMimeType = mimeType
                }
            default:
                break
            }
        }
        
        // Read audio format information
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        if let audioTrack = tracks.first {
            // Format descriptions
            let descriptions = try await audioTrack.load(.formatDescriptions)
            if let formatDesc = descriptions.first {
                let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
                if let asbd = asbd?.pointee {
                    result.sampleRate = asbd.mSampleRate
                    result.channels = Int(asbd.mChannelsPerFrame)
                    
                    switch asbd.mFormatID {
                    case kAudioFormatLinearPCM:
                        result.bitDepth = Int(asbd.mBitsPerChannel)
                    default:
                        break
                    }
                }
            }
        }
        
        // Duration from asset
        let duration = try await asset.load(.duration)
        result.duration = CMTimeGetSeconds(duration)

        ReplayGainReader.augment(metadata: &result, url: url, asset: asset)
        return result
    }
}
