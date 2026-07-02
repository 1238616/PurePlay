import Foundation
import AppKit
import PurePlayCore

/// 播放列表面板 — 支持本地文件 + 夸克网盘文件
final class PlaylistPanel: NSView, NSTableViewDataSource, NSTableViewDelegate {

    private let playerController: PlayerController
    var onPlayTrack: ((Int) -> Void)?

    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var headerLabel: NSTextField!
    private var addButton: NSButton!
    private var removeButton: NSButton!
    private var clearButton: NSButton!
    private var countLabel: NSTextField!

    private(set) var entries: [TrackSource] = []

    init(playerController: PlayerController) {
        self.playerController = playerController
        super.init(frame: .zero)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - UI

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1).cgColor

        headerLabel = NSTextField(labelWithString: "PLAYLIST")
        headerLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        headerLabel.textColor = NSColor(white: 0.45, alpha: 1)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerLabel)

        countLabel = NSTextField(labelWithString: "0 tracks")
        countLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        countLabel.textColor = NSColor(white: 0.4, alpha: 1)
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countLabel)

        addButton = NSButton(title: "+", target: self, action: #selector(addFiles))
        addButton.bezelStyle = .rounded
        addButton.controlSize = .small
        addButton.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(addButton)

        removeButton = NSButton(title: "−", target: self, action: #selector(removeSelected))
        removeButton.bezelStyle = .rounded
        removeButton.controlSize = .small
        removeButton.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(removeButton)

        clearButton = NSButton(title: "Clear", target: self, action: #selector(clearAll))
        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .small
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clearButton)

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        tableView = NSTableView()
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.rowHeight = 28
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(doubleClickRow)
        tableView.target = self
        tableView.allowsMultipleSelection = true
        tableView.headerView = nil

        let trackCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("track"))
        trackCol.title = ""
        trackCol.width = 300
        tableView.addTableColumn(trackCol)

        let fmtCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("fmt"))
        fmtCol.title = ""
        fmtCol.width = 50
        tableView.addTableColumn(fmtCol)

        scrollView.documentView = tableView
        addSubview(scrollView)

        registerForDraggedTypes([.fileURL])

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),

            countLabel.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
            countLabel.leadingAnchor.constraint(equalTo: headerLabel.trailingAnchor, constant: 8),

            addButton.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
            addButton.trailingAnchor.constraint(equalTo: removeButton.leadingAnchor, constant: -4),
            addButton.widthAnchor.constraint(equalToConstant: 24),

            removeButton.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
            removeButton.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -4),
            removeButton.widthAnchor.constraint(equalToConstant: 24),

            clearButton.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Public API

    /// 添加本地文件 URL
    func addURLs(_ urls: [URL]) {
        let audioExtensions: Set<String> = ["flac","ape","wav","aiff","aif","dsf","dff",
                                             "alac","m4a","mp3","ogg","opus","wv","mp4","aac","caf","dts"]
        for url in urls {
            if url.hasDirectoryPath {
                if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
                    for case let fileURL as URL in enumerator {
                        if audioExtensions.contains(fileURL.pathExtension.lowercased()) {
                            entries.append(.local(fileURL))
                        }
                    }
                }
            } else if audioExtensions.contains(url.pathExtension.lowercased()) {
                entries.append(.local(url))
            }
        }
        syncQueue()
        tableView.reloadData()
        updateCount()
    }

    /// 添加云盘文件
    func addCloudFiles(_ files: [QuarkFile]) {
        for file in files where file.isAudioFile {
            entries.append(.cloud(fid: file.id, fileName: file.fileName, fileSize: file.fileSize))
        }
        syncQueue()
        tableView.reloadData()
        updateCount()
    }

    /// 添加单个云盘文件
    func addCloudFile(_ file: QuarkFile) {
        entries.append(.cloud(fid: file.id, fileName: file.fileName, fileSize: file.fileSize))
        syncQueue()
        tableView.reloadData()
        updateCount()
    }

    func highlightCurrentTrack() {
        let idx = playerController.currentTrackIndex
        if idx >= 0 && idx < entries.count {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            tableView.scrollRowToVisible(idx)
        }
        tableView.reloadData()
    }

    // MARK: - Actions

    @objc private func addFiles() {
        let panel = NSOpenPanel()
        // Use allowedFileTypes (extension-based) because macOS UTI system
        // does not recognise all supported formats (e.g. dsf/dff/dts) as
        // public.audio, so allowedContentTypes = [.audio] would grey them out.
        // addURLs() filters by extension anyway.
        panel.allowedFileTypes = [
            "flac", "ape", "wav", "aiff", "aif",
            "dsf", "dff",
            "alac", "m4a", "mp4",
            "mp3", "ogg", "opus",
            "wv", "tta", "wma", "mka", "aac", "caf", "dts"
        ]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        if panel.runModal() == .OK {
            addURLs(panel.urls)
        }
    }

    @objc private func removeSelected() {
        let selected = tableView.selectedRowIndexes.sorted().reversed()
        for idx in selected {
            guard idx < entries.count else { continue }
            entries.remove(at: idx)
        }
        syncQueue()
        tableView.reloadData()
        updateCount()
    }

    @objc private func clearAll() {
        entries.removeAll()
        syncQueue()
        tableView.reloadData()
        updateCount()
    }

    @objc private func doubleClickRow() {
        let row = tableView.clickedRow
        guard row >= 0 && row < entries.count else { return }
        onPlayTrack?(row)
    }

    private func syncQueue() {
        playerController.queue = entries
    }

    private func updateCount() {
        let cloudCount = entries.filter(\.isCloud).count
        let localCount = entries.count - cloudCount
        if cloudCount > 0 {
            countLabel.stringValue = "\(entries.count) tracks (\(cloudCount)☁)"
        } else {
            countLabel.stringValue = "\(localCount) tracks"
        }
    }

    // MARK: - Drag & Drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else {
            return false
        }
        addURLs(items)
        return true
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < entries.count else { return nil }
        let entry = entries[row]
        let id = tableColumn?.identifier.rawValue ?? ""
        let isPlaying = row == playerController.currentTrackIndex

        let cell = NSTextField(labelWithString: "")
        cell.lineBreakMode = .byTruncatingTail

        switch id {
        case "track":
            let prefix: String
            if isPlaying { prefix = "▶ " }
            else if entry.isCloud { prefix = "\(row + 1). ☁ " }
            else { prefix = "\(row + 1). " }
            cell.stringValue = prefix + entry.displayName
            cell.font = NSFont.systemFont(ofSize: 11, weight: isPlaying ? .semibold : .regular)
            cell.textColor = isPlaying
                ? NSColor(red: 0.91, green: 0.57, blue: 0.23, alpha: 1)
                : .white
        case "fmt":
            cell.stringValue = entry.fileExtension.uppercased()
            cell.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
            cell.textColor = NSColor(red: 0.42, green: 0.75, blue: 0.76, alpha: 1)
            cell.alignment = .right
        default:
            break
        }
        return cell
    }
}
