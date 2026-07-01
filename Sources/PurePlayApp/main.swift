import Foundation
import AppKit
import Carbon.HIToolbox
import PurePlayCore

// App entry point (main.swift allows top-level code)

let appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.3.2"

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var window: NSWindow!
    private var playerController: PlayerController!
    private var statusItem: NSStatusItem!
    private var contentView: VoxContentView!
    private var quarkClient: QuarkAPIClient!
    private var cloudCache: CloudDownloadCache!
    private var loginPanel: QuarkLoginPanel?
    private var fileBrowser: QuarkFileBrowser?
    private var mediaKeyHandler: MediaKeyHandler!
    private var audioMenu: NSMenu!
    private var coreAudioOutput: CoreAudioHALOutput!
    private var globalHotKey: GlobalHotKey?
    private var prefetchManager: CloudPrefetchManager!
    private var prefetchTickTimer: Timer?
    private var waveformBuffer: WaveformBuffer!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // v1.5 → v1.6 EQ slot migration (F12). Safe to call repeatedly (idempotent).
        AudioPreferences.performEQMigrationIfNeeded()

        let output = CoreAudioHALOutput()
        coreAudioOutput = output
        playerController = PlayerController(output: output)
        // 波形采集：1024 bins × 256 frames/bin ≈ 6 秒 @ 44.1k
        waveformBuffer = WaveformBuffer(capacityBins: 1024, framesPerBin: 256)
        playerController.waveformBuffer = waveformBuffer
        quarkClient = QuarkAPIClient()
        quarkClient.onAuthExpired = { [weak self] in
            self?.handleAuthExpired()
        }
        cloudCache = CloudDownloadCache(maxSizeBytes: 2 * 1024 * 1024 * 1024)  // 2GB
        mediaKeyHandler = MediaKeyHandler(playerController: playerController)
        mediaKeyHandler.onPlayPause = { [weak self] in self?.contentView.handleMediaPlayPause() }
        mediaKeyHandler.onNext = { [weak self] in self?.contentView.handleMediaNext() }
        mediaKeyHandler.onPrevious = { [weak self] in self?.contentView.handleMediaPrevious() }
        mediaKeyHandler.onStop = { [weak self] in self?.contentView.handleMediaStop() }
        mediaKeyHandler.register()

        // CoreAudio 设备生命周期事件 — Design.md §5.4.2 第 6 项 listener
        output.onDeviceLost = { [weak self] in
            guard let self = self else { return }
            // 设备拔出 → 暂停播放并刷新菜单
            if self.playerController.state == .playing {
                self.playerController.pause()
            }
            self.contentView?.refreshSignalPath()
            self.rebuildAudioMenu()
        }
        output.onDefaultDeviceChanged = { [weak self] _ in
            self?.rebuildAudioMenu()
        }
        output.onStreamFormatChanged = { [weak self] in
            self?.contentView?.refreshSignalPath()
        }
        output.onDevicesChanged = { [weak self] in
            self?.rebuildAudioMenu()
        }

        // 全局热键（Carbon RegisterEventHotKey）
        // ⌃⌥F8 = play/pause；⌃⌥→ = next；⌃⌥← = prev
        let hk = GlobalHotKey()
        hk.register(action: .playPause, keyCode: kVK_F8,
                    modifiers: [.control, .option]) { [weak self] in
            self?.contentView.handleMediaPlayPause()
        }
        hk.register(action: .nextTrack, keyCode: kVK_RightArrow,
                    modifiers: [.control, .option]) { [weak self] in
            self?.contentView.handleMediaNext()
        }
        hk.register(action: .previousTrack, keyCode: kVK_LeftArrow,
                    modifiers: [.control, .option]) { [weak self] in
            self?.contentView.handleMediaPrevious()
        }
        self.globalHotKey = hk

        // 云盘预下载管理器：在曲尾倒数 30s 时为下一首云盘启动 prebuffer
        let pm = CloudPrefetchManager()
        pm.nextCloudInfoProvider = { [weak self] in
            guard let self = self else { return nil }
            guard let nextIdx = self.playerController.nextTrackIndex() else { return nil }
            let track = self.playerController.queue[nextIdx]
            if case .cloud(let fid, _, let size) = track {
                return (fid: fid, fileSize: size)
            }
            return nil
        }
        pm.cloudSourceBuilder = { [weak self] fid, size in
            guard let self = self else {
                return CloudStreamSource(client: QuarkAPIClient(), fid: fid, fileSize: size)
            }
            return CloudStreamSource(client: self.quarkClient, fid: fid, fileSize: size)
        }
        self.prefetchManager = pm

        // 1Hz tick：把当前播放进度送给 prefetch manager
        prefetchTickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self,
                  let fmt = self.playerController.currentFormat,
                  fmt.sampleRate > 0 else { return }
            let total = Double(self.playerController.totalFrames) / fmt.sampleRate
            let cur = Double(self.playerController.currentFrame) / fmt.sampleRate
            self.prefetchManager.tick(currentDuration: total, currentTime: cur)
        }

        // Set app icon from bundle resources
        if let iconPath = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let icon = NSImage(contentsOfFile: iconPath) {
            NSApp.applicationIconImage = icon
        } else if let iconPath = Bundle.main.path(forResource: "AppIcon", ofType: "png"),
                  let icon = NSImage(contentsOfFile: iconPath) {
            NSApp.applicationIconImage = icon
        }

        setupWindow()
        setupStatusItem()
        setupMainMenu()
        restoreAudioPreferences()
        contentView.refreshSignalPath()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func restoreAudioPreferences() {
        if let uid = AudioPreferences.deviceUID, !uid.isEmpty {
            let devices = playerController.listOutputDevices()
            if let match = devices.first(where: { $0.uid == uid }) {
                try? playerController.setOutputDevice(match)
            }
        }
        // Restore EQ
        if AudioPreferences.eqEnabled {
            playerController.dspPreferences.eqEnabled = true
            playerController.dspPreferences.bitPerfect = false
        }
        if let bands = AudioPreferences.parametricBands {
            playerController.dspPreferences.parametricBands = bands
        }
        playerController.dspPreferences.preamp = AudioPreferences.preamp
    }

    private func setupWindow() {
        let contentRect = NSRect(x: 0, y: 0, width: 420, height: 820)
        window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "PurePlay v\(appVersion)"
        window.minSize = NSSize(width: 320, height: 480)
        window.center()
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.118, alpha: 1.0)
        window.appearance = NSAppearance(named: .darkAqua)

        contentView = VoxContentView(playerController: playerController, window: window)
        contentView.onCloudTapped = { [weak self] in self?.openCloud() }
        contentView.onPlayCloudTrack = { [weak self] index in self?.playCloudTrackAtIndex(index) }

        // Auto-advance when a track finishes (loop / sequential / shuffle / repeatOne).
        playerController.onTrackFinished = { [weak self] in
            DispatchQueue.main.async { self?.advanceToNextTrack() }
        }

        // Gapless decoder swap: refresh now-playing UI without restarting playback.
        playerController.onTrackChanged = { [weak self] index in
            self?.contentView.updateUIForCurrentTrack(index)
        }

        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
    }

    private func advanceToNextTrack() {
        guard let next = playerController.nextTrackIndex() else {
            playerController.stop()
            return
        }
        let track = playerController.queue[next]
        switch track {
        case .local:
            contentView.playTrackAtIndexFromCallback(next)
        case .cloud:
            playCloudTrackAtIndex(next)
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "PurePlay")
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open PurePlay", action: #selector(showWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About PurePlay", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit PurePlay", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(title: "Open...", action: #selector(openFile), keyEquivalent: "o"))
        fileMenu.addItem(NSMenuItem(title: "Cloud (夸克网盘)...", action: #selector(openCloud), keyEquivalent: "k"))
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(NSMenuItem(title: "New Smart Playlist...", action: #selector(newSmartPlaylist), keyEquivalent: "n"))
        let fileMenuItem = NSMenuItem()
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Audio menu — dynamic device list + Hog toggle
        audioMenu = NSMenu(title: "Audio")
        audioMenu.delegate = self
        audioMenu.autoenablesItems = false
        let audioMenuItem = NSMenuItem(title: "Audio", action: nil, keyEquivalent: "")
        audioMenuItem.submenu = audioMenu
        mainMenu.addItem(audioMenuItem)

        // View menu — mini player toggle
        let viewMenu = NSMenu(title: "View")
        let miniItem = NSMenuItem(title: "Mini Player",
                                  action: #selector(toggleMiniPlayer),
                                  keyEquivalent: "m")
        miniItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(miniItem)
        viewMenu.addItem(NSMenuItem.separator())
        let eqItem = NSMenuItem(title: "Equalizer...",
                                action: #selector(openEqualizer),
                                keyEquivalent: "e")
        eqItem.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(eqItem)
        let viewMenuItem = NSMenuItem()
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func toggleMiniPlayer() {
        let mini = MiniPlayerWindow.shared
        if let w = mini.window, w.isVisible {
            mini.hide()
        } else {
            mini.show(controller: playerController)
        }
    }

    @objc private func openEqualizer() {
        let panel = EQPanel.shared
        panel.onChanged = { [weak self] enabled, bands, preamp in
            guard let self = self else { return }
            self.playerController.dspPreferences.eqEnabled = enabled
            self.playerController.dspPreferences.parametricBands = bands
            self.playerController.dspPreferences.preamp = preamp
            if enabled {
                self.playerController.dspPreferences.bitPerfect = false
            }
            AudioPreferences.eqEnabled = enabled
            AudioPreferences.parametricBands = bands
            AudioPreferences.preamp = preamp
        }
        panel.sync(enabled: playerController.dspPreferences.eqEnabled,
                   bands: playerController.dspPreferences.parametricBands,
                   preamp: playerController.dspPreferences.preamp)
        panel.show()
    }

    // MARK: - NSMenuDelegate (Audio menu)

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === audioMenu else { return }
        rebuildAudioMenu()
    }

    private func rebuildAudioMenu() {
        audioMenu.removeAllItems()

        let header = NSMenuItem(title: "Output Device", action: nil, keyEquivalent: "")
        header.isEnabled = false
        audioMenu.addItem(header)

        let devices = playerController.listOutputDevices()
        let currentUID = playerController.currentOutputDevice()?.uid
        if devices.isEmpty {
            let none = NSMenuItem(title: "  (no output devices)", action: nil, keyEquivalent: "")
            none.isEnabled = false
            audioMenu.addItem(none)
        } else {
            for (idx, dev) in devices.enumerated() {
                let item = NSMenuItem(
                    title: "  \(dev.name)",
                    action: #selector(selectAudioDevice(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.tag = idx
                item.representedObject = dev.uid
                item.state = (dev.uid == currentUID) ? .on : .off
                audioMenu.addItem(item)
            }
        }

        audioMenu.addItem(NSMenuItem.separator())

        let hogItem = NSMenuItem(
            title: "Exclusive Mode (Hog)",
            action: #selector(toggleHogMode),
            keyEquivalent: ""
        )
        hogItem.target = self
        hogItem.state = playerController.isHogModeEnabled ? .on : .off
        audioMenu.addItem(hogItem)

        audioMenu.addItem(NSMenuItem.separator())

        let statusText = audioStatusLine()
        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        audioMenu.addItem(status)
    }

    private func audioStatusLine() -> String {
        var parts: [String] = []
        if let dev = playerController.currentOutputDevice() {
            parts.append(dev.name)
        } else {
            parts.append("System Default")
        }
        if let fmt = playerController.currentFormat {
            parts.append("\(Int(fmt.sampleRate))Hz")
        }
        if playerController.isHogModeActive { parts.append("Hog ✓") }
        return "Current: " + parts.joined(separator: " · ")
    }

    @objc private func selectAudioDevice(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        let devices = playerController.listOutputDevices()
        guard let dev = devices.first(where: { $0.uid == uid }) else { return }
        do {
            try playerController.setOutputDevice(dev)
            contentView.refreshSignalPath()
        } catch {
            NSSound.beep()
        }
    }

    @objc private func toggleHogMode() {
        playerController.setHogModePreference(!playerController.isHogModeEnabled)
        contentView.refreshSignalPath()
    }

    @objc private func showWindow() {
        guard window != nil else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openFile() {
        contentView.openFile()
    }

    @objc private func openCloud() {
        // Ensure main window is visible so app doesn't quit when panels close
        if let win = window, !win.isVisible {
            win.makeKeyAndOrderFront(nil)
        }

        if quarkClient.isLoggedIn {
            showFileBrowser()
        } else {
            showLoginPanel()
        }
    }

    @objc private func newSmartPlaylist() {
        contentView.showSmartPlaylistEditor()
    }

    private func handleAuthExpired() {
        // 关闭已打开的 Cloud 浏览器，避免空数据闪烁
        fileBrowser?.close()
        fileBrowser = nil

        if let win = window, !win.isVisible {
            win.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "夸克账号登录已失效"
        alert.informativeText = "你的登录会话已过期或被风控。点击「重新登录」以恢复云盘功能。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "重新登录")
        alert.addButton(withTitle: "稍后")
        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            showLoginPanel()
        }
    }

    private func showLoginPanel() {
        let panel = QuarkLoginPanel(client: quarkClient) { [weak self] in
            self?.showFileBrowser()
        }
        self.loginPanel = panel
        panel.showModal()
    }

    private func showFileBrowser() {
        let browser = QuarkFileBrowser(
            client: quarkClient,
            onFileSelected: { [weak self] file in
                self?.handleCloudFilePlay(file)
            },
            onAddToPlaylist: { [weak self] files in
                self?.handleCloudFilesAddToPlaylist(files)
            }
        )
        self.fileBrowser = browser
        browser.showModal()
    }

    private func handleCloudFilePlay(_ file: QuarkFile) {
        // Add to playlist and play immediately
        contentView.playlistPanel.addCloudFile(file)
        let index = contentView.playlistPanel.entries.count - 1
        playCloudTrackAtIndex(index)
    }

    private func handleCloudFilesAddToPlaylist(_ files: [QuarkFile]) {
        contentView.playlistPanel.addCloudFiles(files)
    }

    private func playCloudTrackAtIndex(_ index: Int) {
        guard index >= 0 && index < playerController.queue.count else { return }
        let track = playerController.queue[index]
        guard case .cloud(let fid, let fileName, let fileSize) = track else { return }

        playerController.currentTrackIndex = index
        contentView.updateForCloud(fileName: fileName, format: nil)
        contentView.sourceLabel.stringValue = "☁ 缓冲中..."
        contentView.playlistPanel.highlightCurrentTrack()

        Task { @MainActor in
            do {
                let ext = (fileName as NSString).pathExtension.lowercased()
                
                // Check cache first
                if let cachedURL = cloudCache.cachedURL(for: fid) {
                    contentView.sourceLabel.stringValue = "💾 缓存播放中..."
                    try playerController.playLocal(url: cachedURL)
                    contentView.updateForCloud(fileName: fileName, format: playerController.currentFormat)
                    contentView.sourceLabel.stringValue = "💾 已缓存"
                    contentView.playlistPanel.highlightCurrentTrack()
                    return
                }
                
                // Not cached - stream with cache write-through
                let source = CloudStreamSource(client: quarkClient, fid: fid, fileSize: fileSize)
                try await playerController.playCloud(source: source, fileExtension: ext)
                contentView.updateForCloud(fileName: fileName, format: playerController.currentFormat)
                contentView.sourceLabel.stringValue = "☁ 流式播放中..."
                contentView.playlistPanel.highlightCurrentTrack()
                
                // After playback starts, save to cache
                Task {
                    try await Task.sleep(nanoseconds: 1_000_000_000)  // Wait 1 second
                    if let data = source.exportToCache() {
                        try? cloudCache.cache(fid: fid, fileName: fileName, data: data)
                    }
                }
            } catch {
                contentView.sourceLabel.stringValue = "☁ 错误: \(error.localizedDescription)"
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

// MARK: - Vox-Style Content View

final class VoxContentView: NSView {
    private let playerController: PlayerController
    private weak var hostWindow: NSWindow?

    // UI elements
    private var backgroundView: NSVisualEffectView!
    private var coverView: NSImageView!
    private var coverShadow: NSShadow!
    private var titleLabel: NSTextField!
    private var artistLabel: NSTextField!
    var sourceLabel: NSTextField!
    private var badgeStack: NSStackView!
    private var progressBar: NSSlider!
    private var dsdBadge: DSDBadgeView!
    private var timeLeftLabel: NSTextField!
    private var timeRightLabel: NSTextField!
    private var waveformView: NSView!
    private var scrollWaveformView: WaveformView!
    private var playBtn: NSButton!
    private var prevBtn: NSButton!
    private var nextBtn: NSButton!
    private var cloudBtn: NSButton!
    private var volumeSlider: NSSlider!
    private var volumeIcon: NSImageView!
    private var hifiLabel: NSTextField!
    private var signalPathLabel: NSTextField!
    private var bottomBar: NSView!
    private var progressTimer: Timer?
    var playlistPanel: PlaylistPanel!
    private var queueView: QueueView!
    private var queueManager: QueueManager!
    private var playlistToggleBtn: NSButton!
    private var queueToggleBtn: NSButton!
    private var modeBtn: NSButton!
    private var libraryPanel: NSView!
    private var libraryBrowser: LibraryBrowser!
    private var albumGridView: AlbumGridView!
    private var searchBar: SearchBar!
    private var libraryToggleBtn: NSButton!
    private var isLibraryVisible = false
    private var isQueueVisible = false

    /// 外部注入的云盘按钮回调
    var onCloudTapped: (() -> Void)?

    init(playerController: PlayerController, window: NSWindow) {
        self.playerController = playerController
        self.hostWindow = window
        super.init(frame: .zero)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        // Background with vibrancy
        backgroundView = NSVisualEffectView()
        backgroundView.material = .hudWindow
        backgroundView.blendingMode = .behindWindow
        backgroundView.state = .active
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backgroundView)

        // Album Art (hero, 60% height)
        coverView = NSImageView()
        coverView.imageScaling = .scaleProportionallyUpOrDown
        coverView.wantsLayer = true
        coverView.layer?.cornerRadius = 12
        coverView.layer?.masksToBounds = true
        coverView.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        coverView.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
        coverView.contentTintColor = NSColor(white: 0.3, alpha: 1)
        coverView.translatesAutoresizingMaskIntoConstraints = false
        coverView.shadow = NSShadow()
        coverView.shadow?.shadowColor = NSColor.black.withAlphaComponent(0.5)
        coverView.shadow?.shadowOffset = NSSize(width: 0, height: -4)
        coverView.shadow?.shadowBlurRadius = 20
        addSubview(coverView)

        // Title
        titleLabel = makeLabel("PurePlay", size: 17, weight: .semibold, color: .white)
        addSubview(titleLabel)

        // Artist
        artistLabel = makeLabel("Hi-Res Music Player", size: 14, weight: .regular,
                                color: NSColor(white: 0.6, alpha: 1))
        addSubview(artistLabel)

        // Source label (📁/☁/💾)
        sourceLabel = makeLabel("", size: 11, weight: .medium,
                                color: NSColor(red: 0.42, green: 0.75, blue: 0.76, alpha: 1))
        addSubview(sourceLabel)

        // Tech badges (right side)
        let badge1 = makeBadge("—")
        let badge2 = makeBadge("—")
        let badge3 = makeBadge("—")
        let badge4 = makeBadge("—")
        badgeStack = NSStackView(views: [badge1, badge2, badge3, badge4])
        badgeStack.orientation = .vertical
        badgeStack.spacing = 2
        badgeStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badgeStack)

        // Progress bar
        progressBar = NSSlider(value: 0, minValue: 0, maxValue: 1, target: self, action: #selector(progressBarChanged(_:)))
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.controlSize = .small
        progressBar.isContinuous = false
        addSubview(progressBar)

        // DSD high-res badge (shown only when DSD is active)
        dsdBadge = DSDBadgeView()
        dsdBadge.translatesAutoresizingMaskIntoConstraints = false
        dsdBadge.isHidden = true
        addSubview(dsdBadge)

        // Time labels
        timeLeftLabel = makeLabel("00:00", size: 10, weight: .medium,
                                  color: NSColor(white: 0.5, alpha: 1))
        timeLeftLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        addSubview(timeLeftLabel)

        timeRightLabel = makeLabel("00:00", size: 10, weight: .medium,
                                   color: NSColor(white: 0.5, alpha: 1))
        timeRightLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        addSubview(timeRightLabel)

        // Spectrum analyzer + visualizer
        let analyzer = SpectrumAnalyzer(bandCount: 48)
        playerController.spectrumAnalyzer = analyzer
        let spectrum = SpectrumView(analyzer: analyzer)
        spectrum.wantsLayer = true
        spectrum.layer?.backgroundColor = NSColor(white: 0.06, alpha: 1).cgColor
        spectrum.layer?.cornerRadius = 6
        spectrum.translatesAutoresizingMaskIntoConstraints = false
        waveformView = spectrum
        addSubview(waveformView)

        // Scrolling waveform tap (sibling above spectrum)
        scrollWaveformView = WaveformView()
        scrollWaveformView.buffer = playerController.waveformBuffer
        scrollWaveformView.translatesAutoresizingMaskIntoConstraints = false
        scrollWaveformView.startRendering()
        addSubview(scrollWaveformView)

        // Transport controls
        prevBtn = makeTransportButton("backward.fill")
        prevBtn.target = self
        prevBtn.action = #selector(prevTrack)
        playBtn = makeTransportButton("play.fill")
        playBtn.target = self
        playBtn.action = #selector(playPauseToggle)
        nextBtn = makeTransportButton("forward.fill")
        nextBtn.target = self
        nextBtn.action = #selector(nextTrack)
        cloudBtn = makeTransportButton("icloud.fill")
        cloudBtn.contentTintColor = NSColor(red: 0.42, green: 0.75, blue: 0.76, alpha: 1)
        cloudBtn.target = self
        cloudBtn.action = #selector(cloudButtonClicked)
        cloudBtn.toolTip = "夸克网盘 (⌘K)"
        playlistToggleBtn = makeTransportButton("list.bullet")
        playlistToggleBtn.target = self
        playlistToggleBtn.action = #selector(togglePlaylist)
        playlistToggleBtn.toolTip = "播放列表"
        queueToggleBtn = makeTransportButton("music.note.list")
        queueToggleBtn.target = self
        queueToggleBtn.action = #selector(toggleQueue)
        queueToggleBtn.toolTip = "播放队列"
        libraryToggleBtn = makeTransportButton("books.vertical")
        libraryToggleBtn.target = self
        libraryToggleBtn.action = #selector(toggleLibrary)
        libraryToggleBtn.toolTip = "音乐库"
        let initialMode = playerController.playMode
        modeBtn = makeTransportButton(initialMode.iconName)
        modeBtn.target = self
        modeBtn.action = #selector(togglePlayMode)
        modeBtn.toolTip = initialMode.displayName
        modeBtn.contentTintColor = initialMode == .sequential
            ? NSColor(white: 0.6, alpha: 1)
            : NSColor(red: 0.42, green: 0.75, blue: 0.76, alpha: 1)

        let transport = NSStackView(views: [modeBtn, prevBtn, playBtn, nextBtn, cloudBtn, playlistToggleBtn, queueToggleBtn, libraryToggleBtn])
        transport.spacing = 24
        transport.translatesAutoresizingMaskIntoConstraints = false
        addSubview(transport)

        // Volume control
        volumeIcon = NSImageView(image: NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: nil)!)
        volumeIcon.contentTintColor = NSColor(white: 0.5, alpha: 1)
        volumeIcon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(volumeIcon)

        volumeSlider = NSSlider(value: 0.75, minValue: 0, maxValue: 1, target: self, action: #selector(volumeChanged))
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
        volumeSlider.controlSize = .small
        addSubview(volumeSlider)

        let volumeMaxIcon = NSImageView(image: NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil)!)
        volumeMaxIcon.contentTintColor = NSColor(white: 0.5, alpha: 1)
        volumeMaxIcon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(volumeMaxIcon)

        // Hi-Fi / DSD status indicator (added to bottomBar later)
        hifiLabel = NSTextField(labelWithString: "")
        hifiLabel.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .bold)
        hifiLabel.textColor = NSColor(red: 0.91, green: 0.57, blue: 0.23, alpha: 1) // warm amber
        hifiLabel.alignment = .center
        hifiLabel.translatesAutoresizingMaskIntoConstraints = false

        // Playlist panel
        playlistPanel = PlaylistPanel(playerController: playerController)
        playlistPanel.translatesAutoresizingMaskIntoConstraints = false
        playlistPanel.isHidden = false
        playlistPanel.onPlayTrack = { [weak self] index in
            self?.playTrackAtIndex(index)
        }
        addSubview(playlistPanel)

        // Queue manager and view
        queueManager = QueueManager(playerController: playerController, databaseManager: DatabaseManager.shared)
        queueView = QueueView()
        queueView.configure(with: queueManager)
        queueView.translatesAutoresizingMaskIntoConstraints = false
        queueView.isHidden = true
        addSubview(queueView)

        // Library browser panel
        libraryPanel = NSView()
        libraryPanel.wantsLayer = true
        libraryPanel.layer?.backgroundColor = NSColor(calibratedRed: 0.1, green: 0.1, blue: 0.12, alpha: 1.0).cgColor
        libraryPanel.translatesAutoresizingMaskIntoConstraints = false
        libraryPanel.isHidden = true
        addSubview(libraryPanel)

        // Library browser sidebar
        libraryBrowser = LibraryBrowser()
        libraryBrowser.translatesAutoresizingMaskIntoConstraints = false
        libraryBrowser.onSelectionChanged = { [weak self] section in
            self?.handleLibrarySectionChanged(section)
        }
        libraryPanel.addSubview(libraryBrowser)

        // Search bar
        searchBar = SearchBar()
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchBar.onSearch = { [weak self] query in
            self?.handleSearchQuery(query)
        }
        libraryPanel.addSubview(searchBar)

        // Album grid view
        albumGridView = AlbumGridView()
        albumGridView.translatesAutoresizingMaskIntoConstraints = false
        albumGridView.onAlbumSelected = { [weak self] album in
            self?.handleAlbumSelected(album)
        }
        libraryPanel.addSubview(albumGridView)

        // Signal path bar (placed inside bottomBar container)
        signalPathLabel = makeLabel("⏸ Ready", size: 10, weight: .regular,
                                    color: NSColor(white: 0.55, alpha: 1))
        signalPathLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

        // Bottom bar container — opaque, layered on top of all switchable panels
        bottomBar = NSView()
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.wantsLayer = true
        bottomBar.layer?.backgroundColor = NSColor(red: 0.07, green: 0.07, blue: 0.085, alpha: 1).cgColor
        bottomBar.addSubview(hifiLabel)
        bottomBar.addSubview(signalPathLabel)
        addSubview(bottomBar)

        // Layout
        NSLayoutConstraint.activate([
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),

            coverView.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            coverView.centerXAnchor.constraint(equalTo: centerXAnchor),
            coverView.widthAnchor.constraint(equalToConstant: 240),
            coverView.heightAnchor.constraint(equalToConstant: 240),

            titleLabel.topAnchor.constraint(equalTo: coverView.bottomAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),

            dsdBadge.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            dsdBadge.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            dsdBadge.widthAnchor.constraint(equalToConstant: 78),
            dsdBadge.heightAnchor.constraint(equalToConstant: 26),

            artistLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            artistLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),

            sourceLabel.topAnchor.constraint(equalTo: artistLabel.bottomAnchor, constant: 4),
            sourceLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),

            badgeStack.topAnchor.constraint(equalTo: coverView.bottomAnchor, constant: 18),
            badgeStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),

            progressBar.topAnchor.constraint(equalTo: sourceLabel.bottomAnchor, constant: 16),
            progressBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            progressBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),

            timeLeftLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 2),
            timeLeftLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),

            timeRightLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 2),
            timeRightLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),

            waveformView.topAnchor.constraint(equalTo: scrollWaveformView.bottomAnchor, constant: 8),
            waveformView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            waveformView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            waveformView.heightAnchor.constraint(equalToConstant: 40),

            scrollWaveformView.topAnchor.constraint(equalTo: timeLeftLabel.bottomAnchor, constant: 12),
            scrollWaveformView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            scrollWaveformView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            scrollWaveformView.heightAnchor.constraint(equalToConstant: 36),

            transport.topAnchor.constraint(equalTo: waveformView.bottomAnchor, constant: 16),
            transport.centerXAnchor.constraint(equalTo: centerXAnchor),

            // Volume row
            volumeIcon.topAnchor.constraint(equalTo: transport.bottomAnchor, constant: 14),
            volumeIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            volumeIcon.widthAnchor.constraint(equalToConstant: 14),
            volumeIcon.heightAnchor.constraint(equalToConstant: 14),

            volumeSlider.centerYAnchor.constraint(equalTo: volumeIcon.centerYAnchor),
            volumeSlider.leadingAnchor.constraint(equalTo: volumeIcon.trailingAnchor, constant: 8),
            volumeSlider.trailingAnchor.constraint(equalTo: volumeMaxIcon.leadingAnchor, constant: -8),

            volumeMaxIcon.centerYAnchor.constraint(equalTo: volumeIcon.centerYAnchor),
            volumeMaxIcon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            volumeMaxIcon.widthAnchor.constraint(equalToConstant: 18),
            volumeMaxIcon.heightAnchor.constraint(equalToConstant: 14),

            // Playlist panel
            playlistPanel.topAnchor.constraint(equalTo: volumeIcon.bottomAnchor, constant: 10),
            playlistPanel.leadingAnchor.constraint(equalTo: leadingAnchor),
            playlistPanel.trailingAnchor.constraint(equalTo: trailingAnchor),
            playlistPanel.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            // Queue view (same position as playlist panel)
            queueView.topAnchor.constraint(equalTo: volumeIcon.bottomAnchor, constant: 10),
            queueView.leadingAnchor.constraint(equalTo: leadingAnchor),
            queueView.trailingAnchor.constraint(equalTo: trailingAnchor),
            queueView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            // Library browser panel (same position as playlist panel)
            libraryPanel.topAnchor.constraint(equalTo: volumeIcon.bottomAnchor, constant: 10),
            libraryPanel.leadingAnchor.constraint(equalTo: leadingAnchor),
            libraryPanel.trailingAnchor.constraint(equalTo: trailingAnchor),
            libraryPanel.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            // Library browser sidebar
            libraryBrowser.topAnchor.constraint(equalTo: libraryPanel.topAnchor),
            libraryBrowser.leadingAnchor.constraint(equalTo: libraryPanel.leadingAnchor),
            libraryBrowser.widthAnchor.constraint(equalToConstant: 200),
            libraryBrowser.bottomAnchor.constraint(equalTo: libraryPanel.bottomAnchor),

            // Search bar
            searchBar.topAnchor.constraint(equalTo: libraryPanel.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: libraryBrowser.trailingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: libraryPanel.trailingAnchor),
            searchBar.heightAnchor.constraint(equalToConstant: 40),

            // Album grid view
            albumGridView.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            albumGridView.leadingAnchor.constraint(equalTo: libraryBrowser.trailingAnchor),
            albumGridView.trailingAnchor.constraint(equalTo: libraryPanel.trailingAnchor),
            albumGridView.bottomAnchor.constraint(equalTo: libraryPanel.bottomAnchor),

            // Bottom bar container — pinned to window bottom, full width
            bottomBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 38),

            // Hi-Fi label inside bottomBar (top half)
            hifiLabel.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 6),
            hifiLabel.centerXAnchor.constraint(equalTo: bottomBar.centerXAnchor),
            hifiLabel.leadingAnchor.constraint(greaterThanOrEqualTo: bottomBar.leadingAnchor, constant: 12),
            hifiLabel.trailingAnchor.constraint(lessThanOrEqualTo: bottomBar.trailingAnchor, constant: -12),

            // Signal path bar inside bottomBar (bottom half)
            signalPathLabel.bottomAnchor.constraint(equalTo: bottomBar.bottomAnchor, constant: -8),
            signalPathLabel.centerXAnchor.constraint(equalTo: bottomBar.centerXAnchor),
            signalPathLabel.leadingAnchor.constraint(greaterThanOrEqualTo: bottomBar.leadingAnchor, constant: 12),
            signalPathLabel.trailingAnchor.constraint(lessThanOrEqualTo: bottomBar.trailingAnchor, constant: -12),
        ])
    }

    @objc func openFile() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = [
            "flac", "ape", "wav", "aiff", "aif",
            "dsf", "dff",
            "alac", "m4a", "mp4",
            "mp3", "ogg", "opus",
            "wv", "tta", "wma", "mka", "aac", "caf"
        ]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        if panel.runModal() == .OK && !panel.urls.isEmpty {
            playlistPanel.addURLs(panel.urls)
            let startIndex = playlistPanel.entries.count - panel.urls.count
            playTrackAtIndex(max(0, startIndex))
        }
    }

    @objc private func playPauseToggle() {
        switch playerController.state {
        case .playing:
            playerController.pause()
            updatePlayButtonIcon()
        case .paused:
            try? playerController.resume()
            updatePlayButtonIcon()
        case .stopped, .buffering:
            openFile()
        }
    }

    @objc private func prevTrack() {
        do {
            try playerController.previous()
            if let idx = playerController.queue.indices.contains(playerController.currentTrackIndex) ? playerController.currentTrackIndex : nil {
                playTrackAtIndex(idx)
            }
        } catch {
            titleLabel.stringValue = "Error"
            artistLabel.stringValue = error.localizedDescription
        }
    }

    @objc private func nextTrack() {
        do {
            try playerController.next()
            if let idx = playerController.queue.indices.contains(playerController.currentTrackIndex) ? playerController.currentTrackIndex : nil {
                playTrackAtIndex(idx)
            }
        } catch {
            titleLabel.stringValue = "Error"
            artistLabel.stringValue = error.localizedDescription
        }
    }

    private func updatePlayButtonIcon() {
        switch playerController.state {
        case .playing:
            playBtn.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: nil)
        case .paused, .stopped, .buffering:
            playBtn.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        }
    }

    func handleMediaPlayPause() {
        playPauseToggle()
    }

    func handleMediaNext() {
        nextTrack()
    }

    func handleMediaPrevious() {
        prevTrack()
    }

    func handleMediaStop() {
        playerController.stop()
        updatePlayButtonIcon()
    }

    @objc private func cloudButtonClicked() {
        onCloudTapped?()
    }

    @objc private func volumeChanged() {
        let vol = Float(volumeSlider.doubleValue)
        playerController.setVolume(vol)
        // Update system volume icon based on level
        if vol == 0 {
            volumeIcon.image = NSImage(systemSymbolName: "speaker.slash.fill", accessibilityDescription: nil)
        } else {
            volumeIcon.image = NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: nil)
        }
    }

    @objc private func togglePlaylist() {
        playlistPanel.isHidden.toggle()
        // Hide library and queue when showing playlist
        if !playlistPanel.isHidden {
            libraryPanel.isHidden = true
            isLibraryVisible = false
            queueView.isHidden = true
            isQueueVisible = false
        }
    }

    @objc private func toggleLibrary() {
        isLibraryVisible.toggle()
        libraryPanel.isHidden = !isLibraryVisible
        // Hide playlist and queue when showing library
        if isLibraryVisible {
            playlistPanel.isHidden = true
            queueView.isHidden = true
            isQueueVisible = false
            // Load albums when library is shown
            loadAlbums()
        }
    }

    @objc private func toggleQueue() {
        isQueueVisible.toggle()
        queueView.isHidden = !isQueueVisible
        // Hide playlist and library when showing queue
        if isQueueVisible {
            playlistPanel.isHidden = true
            libraryPanel.isHidden = true
            isLibraryVisible = false
        }
    }

    private func handleLibrarySectionChanged(_ section: LibrarySection) {
        switch section {
        case .albums:
            loadAlbums()
        case .artists:
            // TODO: Load artists view
            loadAlbums()
        case .genres:
            // TODO: Load genres view
            loadAlbums()
        case .playlists:
            loadPlaylists()
        case .favorites:
            loadFavoriteAlbums()
        case .recentlyPlayed:
            loadRecentlyPlayedAlbums()
        }
    }

    private func handleSearchQuery(_ query: String) {
        if query.isEmpty {
            loadAlbums()
        } else {
            searchAlbums(query: query)
        }
    }

    private func handleAlbumSelected(_ album: AlbumRecord) {
        // Load tracks from this album and add to playlist
        do {
            let tracks = try DatabaseManager.shared.tracks(byAlbum: album.title, artist: album.artist)
            let urls = tracks.map { URL(fileURLWithPath: $0.filePath) }
            playlistPanel.addURLs(urls)
        } catch {
            print("Error loading album tracks: \(error)")
        }
    }

    private func loadAlbums() {
        do {
            let albums = try DatabaseManager.shared.allAlbums()
            albumGridView.albums = albums
        } catch {
            print("Error loading albums: \(error)")
            albumGridView.albums = []
        }
    }

    private func loadFavoriteAlbums() {
        do {
            let favoriteTracks = try DatabaseManager.shared.favoriteTracks()
            // Group by album
            let albumDict = Dictionary(grouping: favoriteTracks, by: { $0.album })
            let albums = albumDict.map { (albumTitle, tracks) -> AlbumRecord in
                let artist = tracks.first?.artist ?? "Unknown Artist"
                return AlbumRecord(
                    title: albumTitle,
                    artist: artist,
                    albumArtist: tracks.first?.albumArtist ?? artist,
                    year: tracks.first?.year,
                    trackCount: tracks.count,
                    duration: tracks.reduce(0) { $0 + $1.duration },
                    coverArtPath: tracks.first?.coverArtPath
                )
            }
            albumGridView.albums = albums
        } catch {
            print("Error loading favorite albums: \(error)")
            albumGridView.albums = []
        }
    }

    private func loadRecentlyPlayedAlbums() {
        do {
            let allTracks = try DatabaseManager.shared.allTracks()
            // Filter tracks that have been played
            let playedTracks = allTracks.filter { $0.playCount > 0 }
            // Sort by last played date
            let sortedTracks = playedTracks.sorted { ($0.lastPlayed ?? Date.distantPast) > ($1.lastPlayed ?? Date.distantPast) }
            // Group by album
            let albumDict = Dictionary(grouping: sortedTracks, by: { $0.album })
            let albums = albumDict.map { (albumTitle, tracks) -> AlbumRecord in
                let artist = tracks.first?.artist ?? "Unknown Artist"
                return AlbumRecord(
                    title: albumTitle,
                    artist: artist,
                    albumArtist: tracks.first?.albumArtist ?? artist,
                    year: tracks.first?.year,
                    trackCount: tracks.count,
                    duration: tracks.reduce(0) { $0 + $1.duration },
                    coverArtPath: tracks.first?.coverArtPath
                )
            }
            albumGridView.albums = albums
        } catch {
            print("Error loading recently played albums: \(error)")
            albumGridView.albums = []
        }
    }

    private func searchAlbums(query: String) {
        do {
            // 先走 FTS5（bm25 相关度排序），结果为空时回退到 LIKE
            var tracks = try DatabaseManager.shared.searchTracksFTS(query: query)
            if tracks.isEmpty {
                tracks = try DatabaseManager.shared.searchTracks(query: query)
            }
            // Group by album
            let albumDict = Dictionary(grouping: tracks, by: { $0.album })
            let albums = albumDict.map { (albumTitle, tracks) -> AlbumRecord in
                let artist = tracks.first?.artist ?? "Unknown Artist"
                return AlbumRecord(
                    title: albumTitle,
                    artist: artist,
                    albumArtist: tracks.first?.albumArtist ?? artist,
                    year: tracks.first?.year,
                    trackCount: tracks.count,
                    duration: tracks.reduce(0) { $0 + $1.duration },
                    coverArtPath: tracks.first?.coverArtPath
                )
            }
            albumGridView.albums = albums
        } catch {
            print("Error searching albums: \(error)")
            albumGridView.albums = []
        }
    }

    private func loadPlaylists() {
        // For now, show all albums when playlists section is selected
        // In a full implementation, this would show actual playlists
        loadAlbums()
        
        // Add a button to create smart playlist
        // This would be better integrated into the UI in a full implementation
    }

    func showSmartPlaylistEditor() {
        let editor = SmartPlaylistEditor()
        editor.onSave = { [weak self] name, rules in
            self?.createSmartPlaylist(name: name, rules: rules)
        }
        editor.makeKeyAndOrderFront(nil)
    }

    private func createSmartPlaylist(name: String, rules: [SmartPlaylistRule]) {
        do {
            let playlistId = try SmartPlaylistEngine.createSmartPlaylist(
                name: name,
                rules: rules,
                databaseManager: DatabaseManager.shared
            )
            print("Created smart playlist: \(name) with ID: \(playlistId)")
            // Reload playlists view
            loadPlaylists()
        } catch {
            print("Error creating smart playlist: \(error)")
        }
    }

    @objc private func togglePlayMode() {
        playerController.playMode = playerController.playMode.next()
        let mode = playerController.playMode
        modeBtn.image = NSImage(systemSymbolName: mode.iconName, accessibilityDescription: nil)
        modeBtn.toolTip = mode.displayName
        modeBtn.contentTintColor = mode == .sequential
            ? .white
            : NSColor(red: 0.91, green: 0.57, blue: 0.23, alpha: 1)
    }

    /// 外部注入的云盘播放回调（AppDelegate 设置）
    var onPlayCloudTrack: ((Int) -> Void)?

    private func playTrackAtIndex(_ index: Int) {
        guard index >= 0 && index < playerController.queue.count else { return }
        let track = playerController.queue[index]
        switch track {
        case .local(let url):
            do {
                try playerController.playFromQueue(index: index)
                updateNowPlaying(url: url)
                playlistPanel.highlightCurrentTrack()
            } catch {
                titleLabel.stringValue = "Error"
                artistLabel.stringValue = error.localizedDescription
            }
        case .cloud:
            onPlayCloudTrack?(index)
        }
    }

    func playTrackAtIndexFromCallback(_ index: Int) {
        playTrackAtIndex(index)
    }

    /// 无缝换曲后只刷新 UI（不重启播放，pipeline 已自行 swapDecoder）
    func updateUIForCurrentTrack(_ index: Int) {
        guard index >= 0 && index < playerController.queue.count else { return }
        let track = playerController.queue[index]
        switch track {
        case .local(let url):
            updateNowPlaying(url: url)
            playlistPanel.highlightCurrentTrack()
        case .cloud:
            playlistPanel.highlightCurrentTrack()
        }
    }

    private func updateHiFiStatus(format: AudioFormat) {
        var parts: [String] = []

        // DSD detection
        if format.isDSD {
            let rate = format.dsdRateRaw
            let dsdLabel: String
            if rate >= 22_579_200 { dsdLabel = "DSD512" }
            else if rate >= 11_289_600 { dsdLabel = "DSD256" }
            else if rate >= 5_644_800 { dsdLabel = "DSD128" }
            else { dsdLabel = "DSD64" }
            parts.append(dsdLabel)
            parts.append("Native 1-bit")
        } else {
            // Hi-Res detection: >44.1kHz or >16bit
            if format.sampleRate > 44100 || format.bitDepth > 16 {
                parts.append("Hi-Res")
            }
            if format.sampleRate >= 96000 {
                parts.append("\(Int(format.sampleRate / 1000))kHz")
            }
            if format.bitDepth >= 24 {
                parts.append("\(format.bitDepth)bit")
            }
        }

        if playerController.isBitPerfect {
            parts.append("Bit-Perfect")
        }

        if parts.isEmpty {
            hifiLabel.stringValue = ""
        } else {
            hifiLabel.stringValue = parts.joined(separator: " · ")
        }
    }

    /// Compose the bottom signal-path string.
    /// Format: `🔊 <DAC> · <rate>Hz · <bits>bit · <Bit-Perfect|Mixed> · <Hog ✓ | —>`
    fileprivate func buildSignalPath(format: AudioFormat, isCloud: Bool) -> String {
        var parts: [String] = []
        let dacName = playerController.currentOutputDevice()?.name ?? "System Default"
        let prefix = isCloud ? "☁ \(dacName)" : "🔊 \(dacName)"
        parts.append(prefix)
        parts.append("\(Int(format.sampleRate))Hz")
        parts.append("\(format.bitDepth)bit")

        // Bit-Perfect requires both DSP bypass AND matching hardware rate (if device selected)
        let dspBypass = playerController.isBitPerfect
        let rateMatched = playerController.currentOutputDevice() == nil
            ? true
            : playerController.pipelineHardwareRateMatched()
        if format.isDSD {
            // DSD path is always DoP (the only macOS option) and inherently bit-perfect
            // because any DSP would corrupt the marker bytes; AudioPipeline.start() refuses otherwise.
            parts.append("DoP")
        } else {
            parts.append((dspBypass && rateMatched) ? "Bit-Perfect" : "Mixed")
        }
        parts.append(playerController.isHogModeActive ? "Hog ✓" : "—")
        return "▶ " + parts.joined(separator: " · ")
    }

    /// Public refresh entry — called from AppDelegate after device or Hog changes.
    func refreshSignalPath() {
        // 优先用 Core 结构化数据；只有空闲时才回落到自拼字符串
        if let p = playerController.currentSignalPath() {
            let dot: String
            if p.isBitPerfect {
                dot = "🟢"
            } else if !p.output.hardwareRateMatched {
                dot = "🔴"
            } else {
                dot = "🟠"
            }
            signalPathLabel.stringValue = "\(dot) \(p.displayText)"
            return
        }
        // Idle: show device + Hog preference only
        let dac = playerController.currentOutputDevice()?.name ?? "System Default"
        let hog = playerController.isHogModeEnabled ? "Hog (pending)" : "—"
        signalPathLabel.stringValue = "⚪ \(dac) · \(hog)"
    }

    func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateProgress()
        }
    }

    func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    @objc private func progressBarChanged(_ sender: NSSlider) {
        let fraction = sender.doubleValue
        do {
            try playerController.seek(toFraction: fraction)
        } catch {
            NSSound.beep()
        }
        updateProgress()
    }

    private func updateProgress() {
        // Don't fight the user while they drag the slider.
        if progressBar.isHighlighted { return }

        let current = playerController.currentFrame
        let total = playerController.totalFrames
        guard total > 0 else { return }

        let fraction = Double(current) / Double(total)
        progressBar.doubleValue = fraction

        let sampleRate = playerController.currentFormat?.sampleRate ?? 44100
        let currentSec = Double(current) / sampleRate
        let totalSec = Double(total) / sampleRate
        timeLeftLabel.stringValue = formatTime(currentSec)
        timeRightLabel.stringValue = formatTime(totalSec)
    }

    private func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }

    private func updateNowPlaying(url: URL) {
        let vm = NowPlayingViewModel.derive(
            from: playerController,
            sourceLine: "📁 Local"
        )
        applyNowPlaying(vm)
        resetProgressUI()

        if let fmt = playerController.currentFormat {
            updateBadges(format: fmt)
            updateHiFiStatus(format: fmt)
            refreshSignalPath()
        }
        hostWindow?.title = "PurePlay — \(vm.title)"
        startProgressTimer()
        updatePlayButtonIcon()
    }

    /// 单点更新 Now Playing 区 — 唯一推荐入口
    /// 把分散在多处的 titleLabel/artistLabel/sourceLabel/dsdBadge 直接写更新
    /// 集中到这里，便于将来迁移 SwiftUI。
    func applyNowPlaying(_ vm: NowPlayingViewModel) {
        titleLabel.stringValue = vm.title
        artistLabel.stringValue = vm.artistAlbum
        if !vm.sourceLine.isEmpty {
            sourceLabel.stringValue = vm.sourceLine
        }
        if vm.showDSDBadge {
            dsdBadge.configure(dsdRate: Double(vm.dsdMultiplier) * 44100.0)
            dsdBadge.isHidden = false
        } else {
            dsdBadge.isHidden = true
        }
    }

    private func resetProgressUI() {
        progressBar.doubleValue = 0
        timeLeftLabel.stringValue = "00:00"
        timeRightLabel.stringValue = "00:00"
    }

    private func updateDSDLogo(format: AudioFormat?) {
        guard let fmt = format, fmt.isDSD else {
            dsdBadge.isHidden = true
            return
        }
        dsdBadge.configure(dsdRate: fmt.dsdRateRaw)
        dsdBadge.isHidden = false
    }

    func updateForCloud(fileName: String, format: AudioFormat?) {
        titleLabel.stringValue = (fileName as NSString).deletingPathExtension
        sourceLabel.stringValue = "☁ 夸克网盘"
        resetProgressUI()
        if let fmt = format {
            updateBadges(format: fmt)
            updateHiFiStatus(format: fmt)
            updateDSDLogo(format: fmt)
            signalPathLabel.stringValue = buildSignalPath(format: fmt, isCloud: true)
            startProgressTimer()
            updatePlayButtonIcon()
        } else {
            updateDSDLogo(format: nil)
        }
    }

    private func updateBadges(format: AudioFormat) {
        let views = badgeStack.arrangedSubviews.compactMap { $0 as? NSTextField }
        guard views.count >= 4 else { return }

        if format.isDSD {
            let rate = format.dsdRateRaw
            if rate >= 22_579_200 { views[0].stringValue = "DSD512" }
            else if rate >= 11_289_600 { views[0].stringValue = "DSD256" }
            else if rate >= 5_644_800 { views[0].stringValue = "DSD128" }
            else { views[0].stringValue = "DSD64" }
            views[1].stringValue = "1-bit"
            views[2].stringValue = "DoP"
            views[3].stringValue = "Native"
        } else {
            let rateStr: String
            if format.sampleRate >= 1000 { rateStr = "\(Int(format.sampleRate / 1000))kHz" }
            else { rateStr = "\(Int(format.sampleRate))Hz" }
            views[0].stringValue = rateStr
            views[1].stringValue = "\(format.bitDepth)bit"
            views[2].stringValue = format.sampleFormat == .float32 ? "FL32" : "PCM"
            views[3].stringValue = playerController.isBitPerfect ? "Bit-P" : "DSP"
        }
    }

    // MARK: - Helpers

    private func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func makeBadge(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        label.textColor = NSColor(red: 0.42, green: 0.75, blue: 0.76, alpha: 1)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func makeTransportButton(_ symbol: String) -> NSButton {
        let btn = NSButton()
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        btn.bezelStyle = .regularSquare
        btn.isBordered = false
        btn.contentTintColor = .white
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.widthAnchor.constraint(equalToConstant: 28).isActive = true
        btn.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return btn
    }
}

// MARK: - Launch

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
