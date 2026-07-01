import Foundation

public enum PurePlayError: Error, Equatable {
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
}
