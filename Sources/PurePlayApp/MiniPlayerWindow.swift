import AppKit
import PurePlayCore

/// 悬浮迷你模式（Design.md §9 任务 4.8）
///
/// 紧凑窗口：320×120，始终置顶 + 跨 Space + 半透明深色风格。
/// 内容：曲名 / 艺人 / 微型进度条 / 上一曲 · 播放暂停 · 下一曲。
///
/// 用法：
///   MiniPlayerWindow.shared.show(controller: playerController)
///   MiniPlayerWindow.shared.hide()
final class MiniPlayerWindow: NSWindowController {

    static let shared = MiniPlayerWindow()

    private var playerController: PlayerController?
    private var titleLabel: NSTextField!
    private var artistLabel: NSTextField!
    private var progressBar: NSProgressIndicator!
    private var playButton: NSButton!
    private var refreshTimer: Timer?

    private init() {
        let rect = NSRect(x: 0, y: 0, width: 320, height: 120)
        let window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .fullSizeContentView, .hudWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "PurePlay Mini"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.level = .floating                   // always on top
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 0.97)
        window.hasShadow = true

        super.init(window: window)

        buildContent()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildContent() {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false

        titleLabel = NSTextField(labelWithString: "—")
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        artistLabel = NSTextField(labelWithString: "")
        artistLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        artistLabel.textColor = NSColor(white: 0.7, alpha: 1)
        artistLabel.lineBreakMode = .byTruncatingMiddle
        artistLabel.maximumNumberOfLines = 1
        artistLabel.translatesAutoresizingMaskIntoConstraints = false

        progressBar = NSProgressIndicator()
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        let prev = makeButton(symbol: "backward.fill", action: #selector(prevAction))
        playButton = makeButton(symbol: "play.fill", action: #selector(playPauseAction))
        let next = makeButton(symbol: "forward.fill", action: #selector(nextAction))

        let stack = NSStackView(views: [prev, playButton, next])
        stack.orientation = .horizontal
        stack.spacing = 24
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false

        host.addSubview(titleLabel)
        host.addSubview(artistLabel)
        host.addSubview(progressBar)
        host.addSubview(stack)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: host.topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -16),

            artistLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            artistLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            artistLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            progressBar.topAnchor.constraint(equalTo: artistLabel.bottomAnchor, constant: 10),
            progressBar.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 3),

            stack.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 12),
            stack.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor, constant: -12),
        ])

        window?.contentView = host
    }

    private func makeButton(symbol: String, action: Selector) -> NSButton {
        let btn = NSButton()
        btn.isBordered = false
        btn.bezelStyle = .regularSquare
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        btn.imageScaling = .scaleProportionallyUpOrDown
        btn.contentTintColor = .white
        btn.target = self
        btn.action = action
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.widthAnchor.constraint(equalToConstant: 32).isActive = true
        btn.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return btn
    }

    // MARK: - Public lifecycle

    func show(controller: PlayerController) {
        self.playerController = controller
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        startRefresh()
        refresh()
    }

    func hide() {
        stopRefresh()
        window?.orderOut(nil)
    }

    // MARK: - Periodic refresh

    private func startRefresh() {
        stopRefresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func stopRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func refresh() {
        guard let pc = playerController else { return }
        // Title / artist heuristic: use current source name when no DB metadata wired in
        let path = pc.currentSignalPath()
        titleLabel.stringValue = currentDisplayTitle()
        artistLabel.stringValue = path?.output.deviceName ?? ""

        let total = pc.totalFrames
        let cur = pc.currentFrame
        if total > 0 {
            progressBar.doubleValue = max(0, min(1, Double(cur) / Double(total)))
        } else {
            progressBar.doubleValue = 0
        }

        // Play/pause icon
        let symbol = (pc.state == .playing) ? "pause.fill" : "play.fill"
        playButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    private func currentDisplayTitle() -> String {
        guard let pc = playerController,
              pc.currentTrackIndex >= 0,
              pc.currentTrackIndex < pc.queue.count else {
            return "—"
        }
        let track = pc.queue[pc.currentTrackIndex]
        return track.displayName
    }

    // MARK: - Actions

    @objc private func prevAction() {
        try? playerController?.previous()
    }
    @objc private func nextAction() {
        try? playerController?.next()
    }
    @objc private func playPauseAction() {
        guard let pc = playerController else { return }
        try? pc.togglePlayPause()
    }
}
