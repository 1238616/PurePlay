import AppKit
import PurePlayCore

final class EQBandTableView: NSView, NSTableViewDataSource, NSTableViewDelegate {

    var bands: [ParametricBand] = [] {
        didSet { tableView.reloadData() }
    }
    var preamp: Float = 0 {
        didSet {
            preampSlider.floatValue = preamp
            preampField.stringValue = String(format: "%+.1f dB", preamp)
        }
    }

    var onBandsChanged: (([ParametricBand]) -> Void)?
    var onPreampChanged: ((Float) -> Void)?
    var onSelectionChanged: ((Int?) -> Void)?

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let preampSlider = NSSlider()
    private let preampField = NSTextField()
    private let addButton = NSButton()
    private let deleteButton = NSButton()

    private static let typeOptions = ["Peak", "Low Shelf", "High Shelf", "LPF 12dB", "HPF 12dB"]

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1).cgColor

        let preampLabel = makeLabel("Preamp")
        preampSlider.minValue = -24
        preampSlider.maxValue = 24
        preampSlider.target = self
        preampSlider.action = #selector(preampChanged)
        preampSlider.translatesAutoresizingMaskIntoConstraints = false

        preampField.isEditable = false
        preampField.isBordered = false
        preampField.backgroundColor = .clear
        preampField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        preampField.textColor = .labelColor
        preampField.stringValue = "+0.0 dB"
        preampField.translatesAutoresizingMaskIntoConstraints = false

        preampLabel.translatesAutoresizingMaskIntoConstraints = false
        preampField.translatesAutoresizingMaskIntoConstraints = false

        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = NSTableHeaderView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.selectionHighlightStyle = .regular
        tableView.backgroundColor = NSColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1)
        tableView.gridColor = NSColor(white: 0.15, alpha: 1)
        tableView.gridStyleMask = [.solidHorizontalGridLineMask]
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 4, height: 2)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        let columns: [(String, CGFloat, String)] = [
            ("type", 110, "Type"),
            ("freq", 130, "Freq"),
            ("q", 80, "Q"),
            ("gain", 130, "Gain"),
            ("enabled", 60, "Enable"),
        ]
        for (id, width, title) in columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title
            col.width = width
            col.minWidth = 28
            let header = col.headerCell
            header.font = .systemFont(ofSize: 10, weight: .medium)
            header.textColor = NSColor(white: 0.5, alpha: 1)
            header.alignment = .center
            tableView.addTableColumn(col)
        }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        addButton.title = "+"
        addButton.bezelStyle = .smallSquare
        addButton.font = .systemFont(ofSize: 14, weight: .bold)
        addButton.target = self
        addButton.action = #selector(addBand)
        addButton.toolTip = "Add band"
        addButton.translatesAutoresizingMaskIntoConstraints = false

        deleteButton.title = "−"
        deleteButton.bezelStyle = .smallSquare
        deleteButton.font = .systemFont(ofSize: 14, weight: .bold)
        deleteButton.target = self
        deleteButton.action = #selector(deleteBand)
        deleteButton.toolTip = "Delete selected band"
        deleteButton.translatesAutoresizingMaskIntoConstraints = false

        let buttonsStack = NSStackView(views: [addButton, deleteButton])
        buttonsStack.orientation = .horizontal
        buttonsStack.spacing = 4
        buttonsStack.alignment = .centerY
        buttonsStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(preampLabel)
        addSubview(preampSlider)
        addSubview(preampField)
        addSubview(scrollView)
        addSubview(buttonsStack)

        NSLayoutConstraint.activate([
            preampLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            preampLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),

            preampSlider.centerYAnchor.constraint(equalTo: preampLabel.centerYAnchor),
            preampSlider.leadingAnchor.constraint(equalTo: preampLabel.trailingAnchor, constant: 6),
            preampSlider.widthAnchor.constraint(equalToConstant: 120),

            preampField.centerYAnchor.constraint(equalTo: preampLabel.centerYAnchor),
            preampField.leadingAnchor.constraint(equalTo: preampSlider.trailingAnchor, constant: 6),
            preampField.widthAnchor.constraint(equalToConstant: 60),

            buttonsStack.centerYAnchor.constraint(equalTo: preampLabel.centerYAnchor),
            buttonsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            buttonsStack.heightAnchor.constraint(equalToConstant: 22),

            scrollView.topAnchor.constraint(equalTo: preampLabel.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            addButton.widthAnchor.constraint(equalToConstant: 24),
            addButton.heightAnchor.constraint(equalToConstant: 22),
            deleteButton.widthAnchor.constraint(equalToConstant: 24),
            deleteButton.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        bands.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < bands.count, let colID = tableColumn?.identifier.rawValue else { return nil }
        let band = bands[row]

        switch colID {
        case "type":
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItems(withTitles: Self.typeOptions)
            popup.font = .systemFont(ofSize: 10)
            popup.selectItem(at: typeIndex(band.type))
            popup.tag = row
            popup.target = self
            popup.action = #selector(typeChanged(_:))
            popup.isBordered = false
            return popup

        case "freq":
            return makeTextCell(formatFreq(band.frequency), align: .right)

        case "q":
            return makeTextCell(String(format: "%.2f", band.q), align: .right)

        case "gain":
            return makeTextCell(String(format: "%+.1f dB", band.gain), align: .right)

        case "enabled":
            let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(enabledChanged(_:)))
            check.state = band.enabled ? .on : .off
            check.tag = row
            return check

        default:
            return nil
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        onSelectionChanged?(row >= 0 ? row : nil)
    }

    // MARK: - Actions

    @objc private func preampChanged() {
        preamp = preampSlider.floatValue
        preampField.stringValue = String(format: "%+.1f dB", preamp)
        onPreampChanged?(preamp)
    }

    @objc private func typeChanged(_ sender: NSPopUpButton) {
        let row = sender.tag
        guard row < bands.count else { return }
        bands[row].type = filterTypeFromIndex(sender.indexOfSelectedItem)
        onBandsChanged?(bands)
    }

    @objc private func enabledChanged(_ sender: NSButton) {
        let row = sender.tag
        guard row < bands.count else { return }
        bands[row].enabled = (sender.state == .on)
        onBandsChanged?(bands)
    }

    @objc private func addBand() {
        guard bands.count < ParametricBand.maxBands else { return }
        bands.append(ParametricBand(type: .peaking, frequency: 1000, gain: 0, q: 1.414))
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: bands.count - 1), byExtendingSelection: false)
        onBandsChanged?(bands)
    }

    @objc private func deleteBand() {
        let row = tableView.selectedRow
        guard row >= 0 && row < bands.count else { return }
        bands.remove(at: row)
        tableView.reloadData()
        if !bands.isEmpty {
            let newRow = min(row, bands.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: newRow), byExtendingSelection: false)
        }
        onBandsChanged?(bands)
    }

    func selectBand(at index: Int?) {
        guard let idx = index, idx < bands.count else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        tableView.scrollRowToVisible(idx)
    }

    // MARK: - Helpers

    private func makeTextCell(_ text: String, align: NSTextAlignment, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        field.textColor = color
        field.alignment = align
        return field
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func formatFreq(_ hz: Double) -> String {
        if hz >= 1000 {
            return String(format: "%.1f kHz", hz / 1000)
        }
        return String(format: "%.0f Hz", hz)
    }

    private func typeIndex(_ type: FilterType) -> Int {
        switch type {
        case .peaking: return 0
        case .lowShelf: return 1
        case .highShelf: return 2
        case .lowPass12: return 3
        case .highPass12: return 4
        }
    }

    private func filterTypeFromIndex(_ index: Int) -> FilterType {
        switch index {
        case 0: return .peaking
        case 1: return .lowShelf
        case 2: return .highShelf
        case 3: return .lowPass12
        case 4: return .highPass12
        default: return .peaking
        }
    }
}
