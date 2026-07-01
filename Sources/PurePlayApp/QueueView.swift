import Foundation
import AppKit
import PurePlayCore

/// 播放队列视图
/// 显示当前播放队列，支持拖拽重排、删除、保存等操作
final class QueueView: NSView {
    
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let toolbar = NSStackView()
    private let clearButton = NSButton()
    private let saveButton = NSButton()
    private let countLabel = NSTextField()
    
    private var queueManager: QueueManager?
    
    var onQueueChanged: (() -> Void)?
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func configure(with queueManager: QueueManager) {
        self.queueManager = queueManager
        queueManager.onQueueChanged = { [weak self] in
            self?.reloadData()
        }
        reloadData()
    }
    
    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.14, alpha: 1.0).cgColor
        
        // Toolbar
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toolbar)
        
        // Count label
        countLabel.stringValue = "0 tracks"
        countLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        countLabel.textColor = NSColor(calibratedWhite: 0.7, alpha: 1.0)
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addArrangedSubview(countLabel)
        
        // Spacer
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addArrangedSubview(spacer)
        
        // Save button
        saveButton.title = "Save"
        saveButton.bezelStyle = .rounded
        saveButton.font = NSFont.systemFont(ofSize: 11)
        saveButton.target = self
        saveButton.action = #selector(saveQueue)
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addArrangedSubview(saveButton)
        
        // Clear button
        clearButton.title = "Clear"
        clearButton.bezelStyle = .rounded
        clearButton.font = NSFont.systemFont(ofSize: 11)
        clearButton.target = self
        clearButton.action = #selector(clearQueue)
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addArrangedSubview(clearButton)
        
        // Scroll view
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        addSubview(scrollView)
        
        // Table view
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.headerView = nil
        tableView.rowHeight = 32
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.delegate = self
        tableView.dataSource = self
        tableView.allowsMultipleSelection = true
        
        // Enable drag and drop
        tableView.registerForDraggedTypes([.queueTrack])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        
        // Columns
        let trackColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("track"))
        trackColumn.width = 300
        tableView.addTableColumn(trackColumn)
        
        let durationColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("duration"))
        durationColumn.width = 60
        tableView.addTableColumn(durationColumn)
        
        scrollView.documentView = tableView
        
        // Layout
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            toolbar.heightAnchor.constraint(equalToConstant: 28),
            
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    
    private func reloadData() {
        tableView.reloadData()
        updateCountLabel()
        onQueueChanged?()
    }
    
    private func updateCountLabel() {
        let count = queueManager?.queueCount ?? 0
        countLabel.stringValue = "\(count) track\(count == 1 ? "" : "s")"
    }
    
    @objc private func clearQueue() {
        queueManager?.clearQueue()
    }
    
    @objc private func saveQueue() {
        guard let queueManager = queueManager, queueManager.queueCount > 0 else { return }
        
        let alert = NSAlert()
        alert.messageText = "Save Queue as Playlist"
        alert.informativeText = "Enter a name for the playlist:"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        input.placeholderString = "Playlist name"
        alert.accessoryView = input
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                do {
                    try queueManager.saveQueueAsPlaylist(name: name)
                } catch {
                    let errorAlert = NSAlert()
                    errorAlert.messageText = "Failed to save playlist"
                    errorAlert.informativeText = error.localizedDescription
                    errorAlert.alertStyle = .warning
                    errorAlert.runModal()
                }
            }
        }
    }
}

// MARK: - NSTableViewDataSource

extension QueueView: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return queueManager?.queueCount ?? 0
    }
    
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        if dropOperation == .above {
            return .move
        }
        return []
    }
    
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let pasteboard = info.draggingPasteboard
        guard let data = pasteboard.data(forType: .queueTrack),
              let sourceRow = String(data: data, encoding: .utf8).flatMap({ Int($0) }) else {
            return false
        }
        
        queueManager?.moveInQueue(from: sourceRow, to: row)
        return true
    }
}

// MARK: - NSTableViewDelegate

extension QueueView: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let queueManager = queueManager,
              row < queueManager.queueCount else { return nil }
        
        let track = queueManager.currentQueue[row]
        let isCurrentTrack = row == queueManager.currentIndex
        
        let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("track")
        
        let cell: NSTextField
        if let reusedCell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField {
            cell = reusedCell
        } else {
            cell = NSTextField(labelWithString: "")
            cell.identifier = identifier
            cell.lineBreakMode = .byTruncatingTail
        }
        
        switch identifier.rawValue {
        case "track":
            cell.stringValue = track.displayName
            cell.font = NSFont.systemFont(ofSize: 12, weight: isCurrentTrack ? .semibold : .regular)
            cell.textColor = isCurrentTrack
                ? NSColor(calibratedRed: 0.91, green: 0.57, blue: 0.23, alpha: 1.0)
                : NSColor(calibratedWhite: 0.85, alpha: 1.0)
        case "duration":
            // Duration would require loading metadata
            cell.stringValue = "—"
            cell.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            cell.textColor = NSColor(calibratedWhite: 0.6, alpha: 1.0)
            cell.alignment = .right
        default:
            break
        }
        
        return cell
    }
    
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        // Set drag image
    }
    
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString("\(row)", forType: .queueTrack)
        return item
    }
}

// MARK: - Custom Pasteboard Type

extension NSPasteboard.PasteboardType {
    static let queueTrack = NSPasteboard.PasteboardType("com.pureplay.queuetrack")
}
