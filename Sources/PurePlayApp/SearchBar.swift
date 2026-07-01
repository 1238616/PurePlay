import Foundation
import AppKit

final class SearchBar: NSView {
    private let searchField = NSSearchField()
    private let searchLabel = NSTextField()
    
    var onSearch: ((String) -> Void)?
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.1, green: 0.1, blue: 0.12, alpha: 1.0).cgColor
        
        // Search label
        searchLabel.translatesAutoresizingMaskIntoConstraints = false
        searchLabel.stringValue = "Search:"
        searchLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        searchLabel.textColor = NSColor(calibratedWhite: 0.7, alpha: 1.0)
        searchLabel.isBezeled = false
        searchLabel.isEditable = false
        searchLabel.backgroundColor = .clear
        addSubview(searchLabel)
        
        // Search field
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Tracks, albums, artists..."
        searchField.font = NSFont.systemFont(ofSize: 13)
        searchField.target = self
        searchField.action = #selector(searchFieldChanged)
        addSubview(searchField)
        
        // Layout
        NSLayoutConstraint.activate([
            searchLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            searchLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            
            searchField.leadingAnchor.constraint(equalTo: searchLabel.trailingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            searchField.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchField.heightAnchor.constraint(equalToConstant: 28)
        ])
    }
    
    @objc private func searchFieldChanged() {
        let query = searchField.stringValue
        onSearch?(query)
    }
    
    func clearSearch() {
        searchField.stringValue = ""
        onSearch?("")
    }
}
