import AppKit
import PurePlayCore

/// AppKit 实现的 SignalPathBar — 显示完整信号链 + 颜色编码的 Bit-Perfect 指示灯
///
/// 渲染源：PurePlayCore.SignalPath（结构化数据，避免 UI 层重复拼字符串）
///
/// 视觉：
///   ┌───────────────────────────────────────────────────────────────┐
///   │ ● FLAC 24/96 → Bit-Perfect → ES9038 · Hog · 96kHz/24bit · ✓ │
///   └───────────────────────────────────────────────────────────────┘
///   ● 绿  = 真 bit-perfect（DSP bypass + 硬件率匹配）
///   ● 橙  = 解码 ↔ DAC 已对接但有 DSP 介入（"Mixed"）
///   ● 红  = 硬件率未匹配（系统会重采样）
///   ● 灰  = 空闲（无活跃管线）
final class SignalPathBar: NSView {

    private let indicatorDot = NSView()
    private let textLabel = NSTextField(labelWithString: "")

    /// 文本字体大小
    var fontSize: CGFloat = 10 {
        didSet { textLabel.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        indicatorDot.translatesAutoresizingMaskIntoConstraints = false
        indicatorDot.wantsLayer = true
        indicatorDot.layer?.cornerRadius = 4
        indicatorDot.layer?.backgroundColor = NSColor.systemGray.cgColor
        addSubview(indicatorDot)

        textLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textLabel.textColor = NSColor(white: 0.7, alpha: 1)
        textLabel.lineBreakMode = .byTruncatingMiddle
        textLabel.maximumNumberOfLines = 1
        textLabel.stringValue = "Ready"
        addSubview(textLabel)

        NSLayoutConstraint.activate([
            indicatorDot.leadingAnchor.constraint(equalTo: leadingAnchor),
            indicatorDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            indicatorDot.widthAnchor.constraint(equalToConstant: 8),
            indicatorDot.heightAnchor.constraint(equalToConstant: 8),

            textLabel.leadingAnchor.constraint(equalTo: indicatorDot.trailingAnchor, constant: 8),
            textLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            textLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// 用 Core 的结构化 SignalPath 更新（推荐入口）
    func update(with path: SignalPath?) {
        guard let p = path else {
            indicatorDot.layer?.backgroundColor = NSColor.systemGray.cgColor
            textLabel.stringValue = "⏸ Idle"
            return
        }
        textLabel.stringValue = p.displayText

        // 颜色判定优先级：bit-perfect > 硬件率不匹配 > Mixed
        let color: NSColor
        if p.isBitPerfect {
            color = .systemGreen
        } else if !p.output.hardwareRateMatched {
            color = .systemRed
        } else {
            color = .systemOrange
        }
        indicatorDot.layer?.backgroundColor = color.cgColor
    }

    /// 兼容旧 API：直接传字符串（保留给未接到 PlayerController 的场景）
    func update(plainText text: String, isBitPerfect: Bool? = nil) {
        textLabel.stringValue = text
        if let bp = isBitPerfect {
            indicatorDot.layer?.backgroundColor = (bp ? NSColor.systemGreen : NSColor.systemOrange).cgColor
        } else {
            indicatorDot.layer?.backgroundColor = NSColor.systemGray.cgColor
        }
    }
}
