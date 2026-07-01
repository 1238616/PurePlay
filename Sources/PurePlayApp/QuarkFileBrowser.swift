import Foundation
import AppKit
import PurePlayCore

/// 夸克网盘文件浏览器 — 目录浏览 + 音频文件选择播放
final class QuarkFileBrowser: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    private let client: QuarkAPIClient
    private var onFileSelected: ((QuarkFile) -> Void)?
    private var onAddToPlaylist: (([QuarkFile]) -> Void)?

    private var currentFid: String = "0"
    private var navigationStack: [(fid: String, name: String)] = []
    private var files: [QuarkFile] = []
    private var isLoading = false

    private var tableView: NSTableView!
    private var pathLabel: NSTextField!
    private var backButton: NSButton!
    private var playButton: NSButton!
    private var addAllButton: NSButton!
    private var refreshButton: NSButton!
    private var statusLabel: NSTextField!
    private var loadingIndicator: NSProgressIndicator!

    init(client: QuarkAPIClient,
         onFileSelected: @escaping (QuarkFile) -> Void,
         onAddToPlaylist: @escaping ([QuarkFile]) -> Void) {
        self.client = client
        self.onFileSelected = onFileSelected
        self.onAddToPlaylist = onAddToPlaylist

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "☁ 夸克网盘"
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 400, height: 320)
        panel.center()
        panel.appearance = NSAppearance(named: .darkAqua)

        super.init(window: panel)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - UI Setup

    private func setupUI() {
        guard let panel = window else { return }
        let container = NSView(frame: panel.contentView!.bounds)
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.118, alpha: 1).cgColor

        // Toolbar: back button + path + refresh
        backButton = NSButton(title: "◀", target: self, action: #selector(goBack))
        backButton.bezelStyle = .rounded
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.isEnabled = false
        container.addSubview(backButton)

        pathLabel = NSTextField(labelWithString: "/ 根目录")
        pathLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        pathLabel.textColor = .white
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pathLabel)

        refreshButton = NSButton(title: "↻", target: self, action: #selector(refresh))
        refreshButton.bezelStyle = .rounded
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(refreshButton)

        // Table view
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        tableView = NSTableView()
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.rowHeight = 36
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(doubleClickRow)
        tableView.target = self
        tableView.allowsMultipleSelection = true

        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.title = "名称"
        nameCol.width = 300
        nameCol.minWidth = 150
        tableView.addTableColumn(nameCol)

        let sizeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeCol.title = "大小"
        sizeCol.width = 80
        sizeCol.minWidth = 60
        tableView.addTableColumn(sizeCol)

        let formatCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("format"))
        formatCol.title = "格式"
        formatCol.width = 60
        formatCol.minWidth = 40
        tableView.addTableColumn(formatCol)

        scrollView.documentView = tableView
        container.addSubview(scrollView)

        // Bottom bar: status + play button
        statusLabel = NSTextField(labelWithString: "就绪")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = NSColor(white: 0.5, alpha: 1)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusLabel)

        playButton = NSButton(title: "▶ 播放", target: self, action: #selector(playSelected))
        playButton.bezelStyle = .rounded
        playButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.isEnabled = false
        container.addSubview(playButton)

        addAllButton = NSButton(title: "＋ 全部加入列表", target: self, action: #selector(addAllToPlaylist))
        addAllButton.bezelStyle = .rounded
        addAllButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(addAllButton)

        loadingIndicator = NSProgressIndicator()
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.isHidden = true
        container.addSubview(loadingIndicator)

        // Layout
        NSLayoutConstraint.activate([
            backButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            backButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            backButton.widthAnchor.constraint(equalToConstant: 32),

            pathLabel.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
            pathLabel.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 8),
            pathLabel.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -8),

            refreshButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            refreshButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            refreshButton.widthAnchor.constraint(equalToConstant: 32),

            loadingIndicator.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
            loadingIndicator.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: backButton.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),

            statusLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),

            addAllButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            addAllButton.trailingAnchor.constraint(equalTo: playButton.leadingAnchor, constant: -8),

            playButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            playButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
        ])

        panel.contentView = container
    }

    // MARK: - Directory Loading

    private func loadDirectory(fid: String, name: String, pushToStack: Bool = false) {
        currentFid = fid
        isLoading = true
        loadingIndicator.isHidden = false
        loadingIndicator.startAnimation(nil)
        statusLabel.stringValue = "加载中..."
        files = []
        tableView.reloadData()

        Task { @MainActor in
            do {
                let items = try await client.listAudioFiles(parentFid: fid)
                if pushToStack {
                    self.navigationStack.append((fid: fid, name: name))
                }
                self.files = items.sorted { a, b in
                    if a.isDir != b.isDir { return a.isDir }
                    return a.fileName.localizedCaseInsensitiveCompare(b.fileName) == .orderedAscending
                }
                self.tableView.reloadData()
                let dirCount = items.filter(\.isDir).count
                let fileCount = items.count - dirCount
                self.statusLabel.stringValue = "\(dirCount) 个目录, \(fileCount) 个文件"
                self.updatePath()
            } catch {
                self.statusLabel.stringValue = "加载失败: \(error.localizedDescription)"
                self.files = []
                self.tableView.reloadData()
                self.updatePath()
            }
            self.isLoading = false
            self.loadingIndicator.stopAnimation(nil)
            self.loadingIndicator.isHidden = true
        }
    }

    private func updatePath() {
        let path = navigationStack.map(\.name).joined(separator: " / ")
        pathLabel.stringValue = path.isEmpty ? "/ 根目录" : "/ \(path)"
        backButton.isEnabled = !navigationStack.isEmpty
    }

    // MARK: - Actions

    @objc private func goBack() {
        guard !navigationStack.isEmpty else { return }
        navigationStack.removeLast()
        let parentFid = navigationStack.last?.fid ?? "0"
        let parentName = navigationStack.last?.name ?? "根目录"
        loadDirectory(fid: parentFid, name: parentName, pushToStack: false)
    }

    @objc private func refresh() {
        loadDirectory(fid: currentFid, name: navigationStack.last?.name ?? "根目录", pushToStack: false)
    }

    @objc private func doubleClickRow() {
        let row = tableView.clickedRow
        guard row >= 0 && row < files.count else { return }
        let file = files[row]

        if file.isDir {
            loadDirectory(fid: file.id, name: file.fileName, pushToStack: true)
        } else if file.isAudioFile {
            onFileSelected?(file)
            statusLabel.stringValue = "▶ 播放: \(file.fileName)"
        }
    }

    @objc private func playSelected() {
        let row = tableView.selectedRow
        guard row >= 0 && row < files.count else { return }
        let file = files[row]
        guard file.isAudioFile else { return }
        onFileSelected?(file)
        statusLabel.stringValue = "▶ 播放: \(file.fileName)"
    }

    @objc private func addAllToPlaylist() {
        let audioFiles = files.filter(\.isAudioFile)
        guard !audioFiles.isEmpty else {
            statusLabel.stringValue = "当前目录无音频文件"
            return
        }
        onAddToPlaylist?(audioFiles)
        statusLabel.stringValue = "✓ 已添加 \(audioFiles.count) 首到播放列表"
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { files.count }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < files.count else { return nil }
        let file = files[row]
        let id = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("")

        let cell = NSTextField(labelWithString: "")
        cell.lineBreakMode = .byTruncatingTail
        cell.textColor = .white
        cell.font = NSFont.systemFont(ofSize: 12)

        switch id.rawValue {
        case "name":
            let icon = file.isDir ? "📂 " : "🎵 "
            cell.stringValue = icon + file.fileName
            if file.isDir {
                cell.textColor = NSColor(red: 0.42, green: 0.75, blue: 0.76, alpha: 1)
            }
        case "size":
            if file.isDir {
                cell.stringValue = "—"
            } else {
                cell.stringValue = formatFileSize(file.fileSize)
            }
            cell.textColor = NSColor(white: 0.5, alpha: 1)
        case "format":
            cell.stringValue = file.isDir ? "" : file.fileExtension.uppercased()
            cell.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
            cell.textColor = NSColor(red: 0.42, green: 0.75, blue: 0.76, alpha: 1)
        default:
            break
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        if row >= 0 && row < files.count {
            playButton.isEnabled = files[row].isAudioFile
        } else {
            playButton.isEnabled = false
        }
    }

    // MARK: - Helpers

    private func formatFileSize(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        return String(format: "%.2f GB", Double(bytes) / 1_073_741_824)
    }

    func showModal() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        navigationStack.removeAll()
        currentFid = "0"
        loadDirectory(fid: "0", name: "根目录")
    }
}
