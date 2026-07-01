import Foundation
import PurePlayCore

/// "Now Playing" 区的元数据快照（独立于 UI 渲染细节）
///
/// 把分散在 VoxContentView 各方法中的 titleLabel/artistLabel/sourceLabel/badgeStack
/// 更新逻辑抽象到一个 value type 上。
///
/// 设计意图：
///   - 单点更新：`applyNowPlaying(_:)` 一次同步所有相关 UI
///   - 便于未来 SwiftUI 迁移：本 ViewModel 已经是 immutable 值语义
///   - 测试友好：可以用 ViewModel 直接验证内容映射逻辑
struct NowPlayingViewModel: Equatable {
    /// 主标题（曲名 / 文件名）
    var title: String
    /// 艺人 + 专辑（一行）
    var artistAlbum: String
    /// 状态文本（"💾 已缓存 · 16/44.1k · WAV" 等）
    var sourceLine: String
    /// 是否显示 DSD 徽章
    var showDSDBadge: Bool
    /// DSD 倍率（64/128/256/512），仅 showDSDBadge=true 时使用
    var dsdMultiplier: Int
    /// 技术 Badge 文本：采样率字符串（"96kHz"）
    var techRate: String?
    /// 技术 Badge 文本：位深字符串（"24bit"）
    var techBits: String?
    /// 技术 Badge 文本：格式字符串（"FLAC"）
    var techFormat: String?

    static let empty = NowPlayingViewModel(
        title: "",
        artistAlbum: "",
        sourceLine: "",
        showDSDBadge: false,
        dsdMultiplier: 0,
        techRate: nil,
        techBits: nil,
        techFormat: nil
    )

    /// 从 PlayerController 当前状态推导 ViewModel
    /// - Parameters:
    ///   - controller: 已设好 queue + currentTrackIndex 的控制器
    ///   - artistHint: DB 元数据查询给出的艺人（可选）
    ///   - albumHint: DB 元数据查询给出的专辑（可选）
    ///   - sourceLine: 调用方提供的"来源行"文本（云盘下载状态等）
    static func derive(from controller: PlayerController,
                       artistHint: String? = nil,
                       albumHint: String? = nil,
                       sourceLine: String = "") -> NowPlayingViewModel {
        guard controller.currentTrackIndex >= 0,
              controller.currentTrackIndex < controller.queue.count
        else { return .empty }

        let track = controller.queue[controller.currentTrackIndex]
        let title = track.displayName
        let artistAlbum: String = {
            switch (artistHint, albumHint) {
            case (let a?, let b?) where !a.isEmpty && !b.isEmpty:
                return "\(a) · \(b)"
            case (let a?, _) where !a.isEmpty:
                return a
            case (_, let b?) where !b.isEmpty:
                return b
            default:
                return ""
            }
        }()

        // 格式 / 采样率 / 位深 derive from active pipeline
        let fmt = controller.currentFormat
        let isDSD = fmt?.isDSD ?? false
        let dsdMult: Int = {
            guard let f = fmt, f.isDSD else { return 0 }
            return max(1, Int(f.dsdRateRaw / 2_822_400.0))
        }()
        let techRate: String? = fmt.map { String(format: "%dkHz", Int($0.sampleRate / 1000)) }
        let techBits: String? = fmt.map { "\($0.bitDepth)bit" }
        let techFormat: String? = {
            switch track {
            case .local(let url):
                let ext = url.pathExtension.uppercased()
                return ext.isEmpty ? nil : ext
            case .cloud(_, let fileName, _):
                let ext = (fileName as NSString).pathExtension.uppercased()
                return ext.isEmpty ? nil : ext
            }
        }()

        return NowPlayingViewModel(
            title: title,
            artistAlbum: artistAlbum,
            sourceLine: sourceLine,
            showDSDBadge: isDSD,
            dsdMultiplier: 64 * dsdMult,
            techRate: techRate,
            techBits: techBits,
            techFormat: techFormat
        )
    }
}
