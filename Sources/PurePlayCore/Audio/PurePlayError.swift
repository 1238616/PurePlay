import Foundation

public enum PurePlayError: Error, Equatable, LocalizedError {
    case unsupportedFormat(String)
    case decodeFailed(String)
    case invalidWAVHeader(String)
    case ioError(String)
    case hogModeDenied
    case deviceNotFound
    case sampleRateUnsupported(Double)
    case bufferUnderrun
    case alreadyPlaying
    case notPlaying

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):   return "Unsupported format: \(ext)"
        case .decodeFailed(let detail):     return "Decode failed: \(detail)"
        case .invalidWAVHeader(let detail): return "Invalid file header: \(detail)"
        case .ioError(let detail):          return "I/O error: \(detail)"
        case .hogModeDenied:                return "Hog mode denied"
        case .deviceNotFound:               return "Audio device not found"
        case .sampleRateUnsupported(let r): return "Unsupported sample rate: \(r) Hz"
        case .bufferUnderrun:               return "Buffer underrun"
        case .alreadyPlaying:               return "Already playing"
        case .notPlaying:                   return "Not playing"
        }
    }
}
