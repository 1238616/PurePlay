import AppKit
import PurePlayCore

final class EQPanel: NSWindowController {

    static let shared = EQPanel()

    private var parametricEditor: ParametricEQEditor!
    private var bandTableView: EQBandTableView!
    private var enableSwitch: NSSwitch!
    private var presetPopup: NSPopUpButton!
    private var importBtn: NSButton!
    private var headphoneLabel: NSTextField!
    private var clearHeadphoneBtn: NSButton!

    private var presetManager = EQPresetManager.shared
    private var allPresets: [EQPreset] = []

    private(set) var isEnabled: Bool = false
    private(set) var bands: [ParametricBand] = []
    private(set) var preamp: Float = 0

    var onChanged: ((_ enabled: Bool, _ bands: [ParametricBand], _ preamp: Float) -> Void)?

    private init() {
        let rect = NSRect(x: 0, y: 0, width: 780, height: 520)
        let window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Equalizer"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 700, height: 520)
        window.center()
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(red: 0.09, green: 0.09, blue: 0.105, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)

        super.init(window: window)
        buildContent()
        loadPresets()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - UI

    private func buildContent() {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false

        let enableLabel = NSTextField(labelWithString: "Equalizer")
        enableLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        enableLabel.textColor = .white
        enableLabel.translatesAutoresizingMaskIntoConstraints = false

        enableSwitch = NSSwitch()
        enableSwitch.translatesAutoresizingMaskIntoConstraints = false
        enableSwitch.target = self
        enableSwitch.action = #selector(toggleEnabled(_:))

        presetPopup = NSPopUpButton()
        presetPopup.translatesAutoresizingMaskIntoConstraints = false
        presetPopup.target = self
        presetPopup.action = #selector(selectPreset(_:))

        importBtn = NSButton(title: "Import", target: self, action: #selector(importProfile))
        importBtn.bezelStyle = .rounded
        importBtn.translatesAutoresizingMaskIntoConstraints = false

        let saveBtn = NSButton(title: "Save", target: self, action: #selector(savePreset))
        saveBtn.bezelStyle = .rounded
        saveBtn.translatesAutoresizingMaskIntoConstraints = false

        let resetBtn = NSButton(title: "Reset", target: self, action: #selector(resetAll))
        resetBtn.bezelStyle = .rounded
        resetBtn.translatesAutoresizingMaskIntoConstraints = false

        parametricEditor = ParametricEQEditor()
        parametricEditor.translatesAutoresizingMaskIntoConstraints = false
        parametricEditor.onBandsChanged = { [weak self] newBands in
            guard let self = self else { return }
            self.bands = newBands
            self.bandTableView.bands = newBands
            self.onChanged?(self.isEnabled, newBands, self.preamp)
        }
        parametricEditor.onSelectionChanged = { [weak self] idx in
            self?.bandTableView.selectBand(at: idx)
        }

        bandTableView = EQBandTableView()
        bandTableView.translatesAutoresizingMaskIntoConstraints = false
        bandTableView.onBandsChanged = { [weak self] newBands in
            guard let self = self else { return }
            self.bands = newBands
            self.parametricEditor.bands = newBands
            self.onChanged?(self.isEnabled, newBands, self.preamp)
        }
        bandTableView.onPreampChanged = { [weak self] newPreamp in
            guard let self = self else { return }
            self.preamp = newPreamp
            self.parametricEditor.preamp = newPreamp
            self.onChanged?(self.isEnabled, self.bands, self.preamp)
        }
        bandTableView.onSelectionChanged = { [weak self] idx in
            self?.parametricEditor.selectedBandIndex = idx
        }

        headphoneLabel = NSTextField(labelWithString: "")
        headphoneLabel.font = NSFont.systemFont(ofSize: 11)
        headphoneLabel.translatesAutoresizingMaskIntoConstraints = false

        clearHeadphoneBtn = NSButton(title: "✕", target: self, action: #selector(clearHeadphone))
        clearHeadphoneBtn.bezelStyle = .recessed
        clearHeadphoneBtn.controlSize = .small
        clearHeadphoneBtn.font = .systemFont(ofSize: 10)
        clearHeadphoneBtn.translatesAutoresizingMaskIntoConstraints = false

        host.addSubview(enableLabel)
        host.addSubview(enableSwitch)
        host.addSubview(presetPopup)
        host.addSubview(importBtn)
        host.addSubview(saveBtn)
        host.addSubview(resetBtn)
        host.addSubview(parametricEditor)
        host.addSubview(headphoneLabel)
        host.addSubview(clearHeadphoneBtn)
        host.addSubview(bandTableView)

        NSLayoutConstraint.activate([
            enableLabel.topAnchor.constraint(equalTo: host.topAnchor, constant: 18),
            enableLabel.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 20),

            enableSwitch.centerYAnchor.constraint(equalTo: enableLabel.centerYAnchor),
            enableSwitch.leadingAnchor.constraint(equalTo: enableLabel.trailingAnchor, constant: 10),

            presetPopup.centerYAnchor.constraint(equalTo: enableLabel.centerYAnchor),
            presetPopup.leadingAnchor.constraint(equalTo: enableSwitch.trailingAnchor, constant: 16),
            presetPopup.widthAnchor.constraint(equalToConstant: 140),

            importBtn.centerYAnchor.constraint(equalTo: enableLabel.centerYAnchor),
            importBtn.leadingAnchor.constraint(equalTo: presetPopup.trailingAnchor, constant: 8),

            saveBtn.centerYAnchor.constraint(equalTo: enableLabel.centerYAnchor),
            saveBtn.leadingAnchor.constraint(equalTo: importBtn.trailingAnchor, constant: 4),

            resetBtn.centerYAnchor.constraint(equalTo: enableLabel.centerYAnchor),
            resetBtn.leadingAnchor.constraint(equalTo: saveBtn.trailingAnchor, constant: 4),

            clearHeadphoneBtn.centerYAnchor.constraint(equalTo: enableLabel.centerYAnchor),
            clearHeadphoneBtn.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -16),

            headphoneLabel.centerYAnchor.constraint(equalTo: enableLabel.centerYAnchor),
            headphoneLabel.trailingAnchor.constraint(equalTo: clearHeadphoneBtn.leadingAnchor, constant: -4),

            parametricEditor.topAnchor.constraint(equalTo: enableLabel.bottomAnchor, constant: 14),
            parametricEditor.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 16),
            parametricEditor.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -16),
            parametricEditor.bottomAnchor.constraint(equalTo: bandTableView.topAnchor, constant: -8),

            bandTableView.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 16),
            bandTableView.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -16),
            bandTableView.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -16),
            bandTableView.heightAnchor.constraint(equalToConstant: 180),
        ])

        window?.contentView = host
        updateHeadphoneLabel()
    }

    private func loadPresets() {
        allPresets = presetManager.loadFactoryPresets() + presetManager.loadUserPresets()
        populatePresetMenu()
    }

    private func populatePresetMenu() {
        presetPopup.removeAllItems()
        for p in allPresets { presetPopup.addItem(withTitle: p.name) }
    }

    // MARK: - Actions

    @objc private func toggleEnabled(_ sender: NSSwitch) {
        isEnabled = (sender.state == .on)
        onChanged?(isEnabled, bands, preamp)
    }

    @objc private func selectPreset(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        guard idx >= 0 && idx < allPresets.count else { return }
        let preset = allPresets[idx]
        applyPreset(preset)
    }

    @objc private func resetAll() {
        bands = []
        preamp = 0
        parametricEditor.bands = bands
        parametricEditor.preamp = preamp
        parametricEditor.selectedBandIndex = nil
        bandTableView.bands = bands
        bandTableView.preamp = preamp
        onChanged?(isEnabled, bands, preamp)
    }

    @objc private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .json]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let url = panel.url, let self = self else { return }
            do {
                let preset: EQPreset
                if url.pathExtension == "json" {
                    preset = try self.presetManager.importJSON(from: url)
                } else {
                    preset = try self.presetManager.importAutoEQ(from: url)
                }
                DispatchQueue.main.async {
                    self.applyPreset(preset)
                    self.updateHeadphoneLabel()
                    self.parametricEditor.display()
                }
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    @objc private func savePreset() {
        let alert = NSAlert()
        alert.messageText = "Save Preset"
        alert.informativeText = "Enter a name for this preset:"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        input.placeholderString = "My Preset"
        alert.accessoryView = input
        alert.beginSheetModal(for: window!) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self = self else { return }
            let name = input.stringValue.isEmpty ? "Untitled" : input.stringValue
            let preset = EQPreset(name: name, preamp: self.preamp, bands: self.bands)
            try? self.presetManager.saveUserPreset(preset)
            self.loadPresets()
        }
    }

    // MARK: - Public

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func sync(enabled: Bool, bands: [ParametricBand], preamp: Float) {
        self.isEnabled = enabled
        self.bands = bands
        self.preamp = preamp
        enableSwitch?.state = enabled ? .on : .off
        parametricEditor?.bands = bands
        parametricEditor?.preamp = preamp
        bandTableView?.bands = bands
        bandTableView?.preamp = preamp
    }

    // MARK: - Private

    private func applyPreset(_ preset: EQPreset) {
        bands = preset.bands
        preamp = preset.preamp
        parametricEditor.bands = bands
        parametricEditor.preamp = preamp
        bandTableView.bands = bands
        bandTableView.preamp = preamp
        if !bands.isEmpty {
            parametricEditor.selectedBandIndex = 0
            bandTableView.selectBand(at: 0)
        } else {
            parametricEditor.selectedBandIndex = nil
        }
        onChanged?(isEnabled, bands, preamp)
    }

    private func updateHeadphoneLabel() {
        guard let label = headphoneLabel, let btn = clearHeadphoneBtn else { return }
        if let name = AudioPreferences.currentHeadphoneName, !name.isEmpty {
            label.stringValue = "当前耳机：\(name)"
            label.textColor = .secondaryLabelColor
            label.isHidden = false
            btn.isHidden = false
        } else {
            label.stringValue = ""
            label.isHidden = true
            btn.isHidden = true
        }
    }

    @objc private func clearHeadphone() {
        AudioPreferences.currentHeadphoneName = nil
        updateHeadphoneLabel()
    }
}
