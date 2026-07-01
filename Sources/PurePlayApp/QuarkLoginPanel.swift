import Foundation
import AppKit
import PurePlayCore

/// 夸克网盘登录面板 — Cookie 手动输入方式（稳定，不依赖 WebKit）
/// 用户从浏览器开发者工具中复制 Cookie 字符串粘贴到输入框
final class QuarkLoginPanel: NSWindowController {

    private var cookieTextField: NSTextField!
    private var statusLabel: NSTextField!
    private var connectButton: NSButton!
    private let client: QuarkAPIClient
    private var onLoginSuccess: (() -> Void)?

    init(client: QuarkAPIClient, onSuccess: @escaping () -> Void) {
        self.client = client
        self.onLoginSuccess = onSuccess

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "连接夸克网盘"
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.appearance = NSAppearance(named: .darkAqua)

        super.init(window: panel)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        guard let panel = window else { return }

        let container = NSView(frame: panel.contentView!.bounds)
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1).cgColor

        // Title
        let titleLabel = NSTextField(labelWithString: "连接夸克网盘")
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        // Instructions
        let instructions = NSTextField(wrappingLabelWithString: """
        步骤：
        1. 在浏览器中打开 pan.quark.cn 并登录
        2. 按 F12 打开开发者工具 → Network 标签
        3. 刷新页面，点击任意请求
        4. 复制 Request Headers 中的 Cookie 值
        5. 粘贴到下方输入框
        """)
        instructions.font = NSFont.systemFont(ofSize: 11)
        instructions.textColor = NSColor(white: 0.6, alpha: 1)
        instructions.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(instructions)

        // Cookie input field
        cookieTextField = NSTextField()
        cookieTextField.placeholderString = "粘贴 Cookie 字符串 (包含 __puus=...)"
        cookieTextField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        cookieTextField.translatesAutoresizingMaskIntoConstraints = false
        cookieTextField.lineBreakMode = .byTruncatingTail
        container.addSubview(cookieTextField)

        // Status
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = NSColor(red: 0.42, green: 0.75, blue: 0.76, alpha: 1)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusLabel)

        // Connect button
        connectButton = NSButton(title: "连接", target: self, action: #selector(connectClicked))
        connectButton.bezelStyle = .rounded
        connectButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(connectButton)

        // Warning
        let warning = NSTextField(labelWithString: "⚠️ Cookie 仅存储于本机 Keychain，不上传任何服务器")
        warning.font = NSFont.systemFont(ofSize: 10)
        warning.textColor = NSColor(white: 0.4, alpha: 1)
        warning.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(warning)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),

            instructions.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            instructions.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            instructions.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            cookieTextField.topAnchor.constraint(equalTo: instructions.bottomAnchor, constant: 12),
            cookieTextField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            cookieTextField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            cookieTextField.heightAnchor.constraint(equalToConstant: 24),

            statusLabel.topAnchor.constraint(equalTo: cookieTextField.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),

            connectButton.topAnchor.constraint(equalTo: cookieTextField.bottomAnchor, constant: 8),
            connectButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            warning.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            warning.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        ])

        panel.contentView = container
    }

    @objc private func connectClicked() {
        let raw = cookieTextField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            statusLabel.stringValue = "请粘贴 Cookie 字符串"
            statusLabel.textColor = .systemRed
            return
        }

        // Parse cookie string: "key1=val1; key2=val2; ..."
        var cookies: [String: String] = [:]
        let parts = raw.components(separatedBy: ";")
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard let eqIdx = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[trimmed.startIndex..<eqIdx])
            let value = String(trimmed[trimmed.index(after: eqIdx)...])
            cookies[key] = value
        }

        guard cookies["__puus"] != nil || cookies["__pus"] != nil else {
            statusLabel.stringValue = "Cookie 无效：未找到 __puus 或 __pus 字段"
            statusLabel.textColor = .systemOrange
            return
        }

        client.setCookies(cookies)
        statusLabel.stringValue = "✅ 连接成功！"
        statusLabel.textColor = .systemGreen

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.window?.close()
            self?.onLoginSuccess?()
        }
    }

    func showModal() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
