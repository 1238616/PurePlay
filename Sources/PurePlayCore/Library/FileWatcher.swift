import Foundation
import CoreServices

/// File system watcher using FSEvents
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let paths: [URL]
    private let latency: TimeInterval
    private let callback: ([String]) -> Void
    
    init(paths: [URL], latency: TimeInterval = 1.0, callback: @escaping ([String]) -> Void) {
        self.paths = paths
        self.latency = latency
        self.callback = callback
    }
    
    deinit {
        stop()
    }
    
    func start() {
        guard stream == nil else { return }
        
        let pathStrings = paths.map { $0.path } as CFArray
        
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagUseCFTypes
        )
        
        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { (streamRef, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds) in
                guard let clientCallBackInfo = clientCallBackInfo else { return }
                let watcher = Unmanaged<FileWatcher>.fromOpaque(clientCallBackInfo).takeUnretainedValue()
                
                // Extract paths from eventPaths
                let paths = unsafeBitCast(eventPaths, to: CFArray.self) as! [String]
                watcher.callback(paths)
            },
            &context,
            pathStrings,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        )
        
        guard let stream = stream else {
            print("Failed to create FSEventStream")
            return
        }
        
        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        FSEventStreamStart(stream)
    }
    
    func stop() {
        guard let stream = stream else { return }
        
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        
        self.stream = nil
    }
    
    var isRunning: Bool {
        return stream != nil
    }
}
