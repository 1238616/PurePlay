import Foundation
import AppKit

public enum LibrarySection: String, CaseIterable {
    case albums = "Albums"
    case artists = "Artists"
    case genres = "Genres"
    case playlists = "Playlists"
    case favorites = "Favorites"
    case recentlyPlayed = "Recently Played"
}

final class LibraryBrowser: NSView {
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    
    var onSelectionChanged: ((LibrarySection) -> Void)?
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.14, alpha: 1.0).cgColor
        
        // Configure scroll view
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        addSubview(scrollView)
        
        // Configure table view
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.headerView = nil
        tableView.rowHeight = 32
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.delegate = self
        tableView.dataSource = self
        
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("section"))
        column.width = 180
        tableView.addTableColumn(column)
        
        scrollView.documentView = tableView
        
        // Layout
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}

extension LibraryBrowser: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return LibrarySection.allCases.count
    }
}

extension LibraryBrowser: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let section = LibrarySection.allCases[row]
        
        let identifier = NSUserInterfaceItemIdentifier("SectionCell")
        let cell: NSTextField
        
        if let reusedCell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField {
            cell = reusedCell
        } else {
            cell = NSTextField(labelWithString: "")
            cell.identifier = identifier
            cell.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            cell.textColor = NSColor(calibratedWhite: 0.85, alpha: 1.0)
        }
        
        cell.stringValue = section.rawValue
        
        return cell
    }
    
    func tableViewSelectionDidChange(_ notification: Notification) {
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0 && selectedRow < LibrarySection.allCases.count else { return }
        
        let section = LibrarySection.allCases[selectedRow]
        onSelectionChanged?(section)
    }
}
