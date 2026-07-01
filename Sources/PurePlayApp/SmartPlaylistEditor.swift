import Foundation
import AppKit
import PurePlayCore

final class SmartPlaylistEditor: NSWindow {
    private let nameField = NSTextField()
    private let rulesStackView = NSStackView()
    private let addButton = NSButton()
    private let saveButton = NSButton()
    private let cancelButton = NSButton()
    
    var rules: [SmartPlaylistRule] = []
    var onSave: ((String, [SmartPlaylistRule]) -> Void)?
    
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        title = "Create Smart Playlist"
        setupUI()
    }
    
    private func setupUI() {
        let contentView = NSView()
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor(calibratedRed: 0.1, green: 0.1, blue: 0.12, alpha: 1.0).cgColor
        self.contentView = contentView
        
        // Playlist name
        let nameLabel = NSTextField(labelWithString: "Playlist Name:")
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = NSColor(calibratedWhite: 0.8, alpha: 1.0)
        contentView.addSubview(nameLabel)
        
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.placeholderString = "My Smart Playlist"
        nameField.font = NSFont.systemFont(ofSize: 13)
        contentView.addSubview(nameField)
        
        // Rules label
        let rulesLabel = NSTextField(labelWithString: "Rules:")
        rulesLabel.translatesAutoresizingMaskIntoConstraints = false
        rulesLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        rulesLabel.textColor = NSColor(calibratedWhite: 0.8, alpha: 1.0)
        contentView.addSubview(rulesLabel)
        
        // Rules stack view
        rulesStackView.translatesAutoresizingMaskIntoConstraints = false
        rulesStackView.orientation = .vertical
        rulesStackView.spacing = 8
        contentView.addSubview(rulesStackView)
        
        // Add rule button
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.title = "+ Add Rule"
        addButton.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(addRule)
        contentView.addSubview(addButton)
        
        // Button container
        let buttonContainer = NSStackView()
        buttonContainer.translatesAutoresizingMaskIntoConstraints = false
        buttonContainer.orientation = .horizontal
        buttonContainer.spacing = 12
        contentView.addSubview(buttonContainer)
        
        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        buttonContainer.addArrangedSubview(cancelButton)
        
        saveButton.title = "Save"
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(save)
        buttonContainer.addArrangedSubview(saveButton)
        
        // Layout
        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            
            nameField.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 8),
            nameField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            nameField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            nameField.heightAnchor.constraint(equalToConstant: 28),
            
            rulesLabel.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 20),
            rulesLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            
            rulesStackView.topAnchor.constraint(equalTo: rulesLabel.bottomAnchor, constant: 12),
            rulesStackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            rulesStackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            
            addButton.topAnchor.constraint(equalTo: rulesStackView.bottomAnchor, constant: 12),
            addButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            
            buttonContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            buttonContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20)
        ])
        
        // Add initial rule
        addRule()
    }
    
    @objc private func addRule() {
        let rule = SmartPlaylistRule(field: .title, op: .contains, value: "")
        rules.append(rule)
        
        let ruleView = createRuleView(for: rules.count - 1)
        rulesStackView.addArrangedSubview(ruleView)
    }
    
    private func createRuleView(for index: Int) -> NSView {
        let container = NSStackView()
        container.orientation = .horizontal
        container.spacing = 8
        
        // Field popup
        let fieldPopup = NSPopUpButton()
        fieldPopup.addItems(withTitles: SmartPlaylistRule.Field.allCases.map { $0.rawValue })
        fieldPopup.selectItem(withTitle: rules[index].field.rawValue)
        fieldPopup.target = self
        fieldPopup.action = #selector(fieldChanged(_:))
        fieldPopup.tag = index
        container.addArrangedSubview(fieldPopup)
        
        // Operator popup
        let opPopup = NSPopUpButton()
        opPopup.addItems(withTitles: SmartPlaylistRule.Operator.allCases.map { $0.rawValue })
        opPopup.selectItem(withTitle: rules[index].op.rawValue)
        opPopup.target = self
        opPopup.action = #selector(opChanged(_:))
        opPopup.tag = index
        container.addArrangedSubview(opPopup)
        
        // Value field
        let valueField = NSTextField()
        valueField.placeholderString = "Value"
        valueField.stringValue = rules[index].value
        valueField.target = self
        valueField.action = #selector(valueChanged(_:))
        valueField.tag = index
        container.addArrangedSubview(valueField)
        
        // Remove button
        let removeButton = NSButton()
        removeButton.title = "−"
        removeButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(removeRule(_:))
        removeButton.tag = index
        container.addArrangedSubview(removeButton)
        
        return container
    }
    
    @objc private func fieldChanged(_ sender: NSPopUpButton) {
        let index = sender.tag
        guard index < rules.count else { return }
        
        if let title = sender.titleOfSelectedItem,
           let field = SmartPlaylistRule.Field(rawValue: title) {
            rules[index].field = field
        }
    }
    
    @objc private func opChanged(_ sender: NSPopUpButton) {
        let index = sender.tag
        guard index < rules.count else { return }
        
        if let title = sender.titleOfSelectedItem,
           let op = SmartPlaylistRule.Operator(rawValue: title) {
            rules[index].op = op
        }
    }
    
    @objc private func valueChanged(_ sender: NSTextField) {
        let index = sender.tag
        guard index < rules.count else { return }
        rules[index].value = sender.stringValue
    }
    
    @objc private func removeRule(_ sender: NSButton) {
        let index = sender.tag
        guard index < rules.count else { return }
        
        rules.remove(at: index)
        if index < rulesStackView.arrangedSubviews.count {
            let view = rulesStackView.arrangedSubviews[index]
            rulesStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        
        // Rebuild views with updated tags
        rebuildRuleViews()
    }
    
    private func rebuildRuleViews() {
        rulesStackView.arrangedSubviews.forEach { rulesStackView.removeArrangedSubview($0) }
        
        for (index, _) in rules.enumerated() {
            let ruleView = createRuleView(for: index)
            rulesStackView.addArrangedSubview(ruleView)
        }
    }
    
    @objc private func save() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Please enter a playlist name"
            alert.runModal()
            return
        }
        
        onSave?(name, rules)
        close()
    }
    
    @objc private func cancel() {
        close()
    }
}
