import Foundation

/// 播放队列管理器
/// 提供高级队列管理功能：添加、删除、重排、保存、加载
public final class QueueManager: @unchecked Sendable {
    
    private let playerController: PlayerController
    private let databaseManager: DatabaseManager
    
    /// 队列变更回调
    public var onQueueChanged: (() -> Void)?
    
    public init(playerController: PlayerController, databaseManager: DatabaseManager) {
        self.playerController = playerController
        self.databaseManager = databaseManager
    }
    
    // MARK: - 队列操作
    
    /// 添加曲目到队列末尾
    public func addToQueue(_ sources: [TrackSource]) {
        playerController.queue.append(contentsOf: sources)
        onQueueChanged?()
    }
    
    /// 添加曲目到队列指定位置
    public func insertToQueue(_ sources: [TrackSource], at index: Int) {
        let insertIndex = max(0, min(index, playerController.queue.count))
        playerController.queue.insert(contentsOf: sources, at: insertIndex)
        onQueueChanged?()
    }
    
    /// 添加曲目为下一首播放
    public func playNext(_ sources: [TrackSource]) {
        let insertIndex = playerController.currentTrackIndex + 1
        insertToQueue(sources, at: insertIndex)
    }
    
    /// 从队列移除曲目
    public func removeFromQueue(at indices: [Int]) {
        let sortedIndices = indices.sorted().reversed()
        for index in sortedIndices {
            guard index >= 0 && index < playerController.queue.count else { continue }
            
            // Adjust current track index if needed
            if index < playerController.currentTrackIndex {
                playerController.currentTrackIndex -= 1
            } else if index == playerController.currentTrackIndex {
                // If removing current track, stop playback
                if playerController.state == .playing {
                    try? playerController.stop()
                }
                playerController.currentTrackIndex = -1
            }
            
            playerController.queue.remove(at: index)
        }
        onQueueChanged?()
    }
    
    /// 移动队列中的曲目
    public func moveInQueue(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex >= 0 && sourceIndex < playerController.queue.count else { return }
        guard destinationIndex >= 0 && destinationIndex <= playerController.queue.count else { return }
        
        let track = playerController.queue.remove(at: sourceIndex)
        
        // Adjust destination index if needed
        let adjustedDest = sourceIndex < destinationIndex ? destinationIndex - 1 : destinationIndex
        playerController.queue.insert(track, at: adjustedDest)
        
        // Adjust current track index
        if playerController.currentTrackIndex == sourceIndex {
            playerController.currentTrackIndex = adjustedDest
        } else if sourceIndex < playerController.currentTrackIndex && adjustedDest >= playerController.currentTrackIndex {
            playerController.currentTrackIndex -= 1
        } else if sourceIndex > playerController.currentTrackIndex && adjustedDest <= playerController.currentTrackIndex {
            playerController.currentTrackIndex += 1
        }
        
        onQueueChanged?()
    }
    
    /// 清空队列
    public func clearQueue() {
        playerController.queue.removeAll()
        playerController.currentTrackIndex = -1
        if playerController.state == .playing {
            try? playerController.stop()
        }
        onQueueChanged?()
    }
    
    /// 替换队列内容
    public func replaceQueue(with sources: [TrackSource], startIndex: Int = 0) {
        playerController.queue = sources
        playerController.currentTrackIndex = startIndex
        onQueueChanged?()
    }
    
    // MARK: - 队列持久化
    
    /// 保存当前队列为播放列表
    public func saveQueueAsPlaylist(name: String) throws -> Int64 {
        let playlist = PlaylistRecord(
            name: name,
            isSmart: false,
            smartRules: nil,
            dateCreated: Date(),
            dateModified: Date()
        )
        
        let playlistId = try databaseManager.addPlaylist(playlist)
        
        // Add tracks to playlist
        for (index, source) in playerController.queue.enumerated() {
            switch source {
            case .local(let url):
                // Find or create track record
                if let track = try databaseManager.track(byFilePath: url.path) {
                    try databaseManager.addTrackToPlaylist(playlistId: playlistId, trackId: track.id!, position: index)
                }
            case .cloud:
                // Cloud tracks are not persisted to playlists in this implementation
                break
            }
        }
        
        return playlistId
    }
    
    /// 从播放列表加载队列
    public func loadQueueFromPlaylist(playlistId: Int64) throws {
        let tracks = try databaseManager.playlistTracks(playlistId: playlistId)
        
        let sources: [TrackSource] = tracks.map { track in
            TrackSource.local(URL(fileURLWithPath: track.filePath))
        }
        
        replaceQueue(with: sources)
    }
    
    // MARK: - 队列信息
    
    /// 获取当前队列
    public var currentQueue: [TrackSource] {
        playerController.queue
    }
    
    /// 获取队列长度
    public var queueCount: Int {
        playerController.queue.count
    }
    
    /// 获取当前播放索引
    public var currentIndex: Int {
        playerController.currentTrackIndex
    }
    
    /// 获取队列总时长（估算）
    public var estimatedDuration: Double {
        // This would require loading metadata for all tracks
        // For now, return 0 as a placeholder
        return 0
    }
}
