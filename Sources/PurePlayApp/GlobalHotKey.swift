import Foundation
import AppKit
import Carbon.HIToolbox

/// 全局热键管理（Carbon RegisterEventHotKey）
///
/// macOS 没有 Cocoa 级别的全局热键 API；必须走 Carbon HIToolbox。
/// 该模块封装注册、回调路由与系统级热键事件分派。
///
/// 用法：
///   let hk = GlobalHotKey()
///   hk.register(id: .playPause, keyCode: kVK_F8, modifiers: [.control, .option]) { ... }
///
/// 默认建议绑定：
///   ⌃⌥F8  播放/暂停
///   ⌃⌥→   下一曲
///   ⌃⌥←   上一曲
///
/// 注意：用户首次触发热键时系统会弹出"输入监控"权限请求，需要在系统设置中授权。
final class GlobalHotKey {

    enum Action: UInt32 {
        case playPause = 1
        case nextTrack = 2
        case previousTrack = 3
        case stopTrack = 4
        case volumeUp = 5
        case volumeDown = 6
    }

    struct ModifierFlags: OptionSet {
        let rawValue: UInt32
        static let command = ModifierFlags(rawValue: UInt32(cmdKey))
        static let option  = ModifierFlags(rawValue: UInt32(optionKey))
        static let control = ModifierFlags(rawValue: UInt32(controlKey))
        static let shift   = ModifierFlags(rawValue: UInt32(shiftKey))
    }

    private var hotKeyRefs: [Action: EventHotKeyRef] = [:]
    private var handlers: [Action: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?
    private static let hotKeySignature: OSType = OSType("PPLY".fourCharCode)

    init() {
        installEventHandler()
        Self.checkAccessibilityIfNeeded()
    }

    /// 是否已被授予"输入监控"权限（Accessibility）
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// 首次检测：未授权时弹出提示引导用户到系统设置
    private static func checkAccessibilityIfNeeded() {
        guard !isTrusted else { return }
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "需要「输入监控」权限"
            alert.informativeText = "PurePlay 使用全局热键（⌃⌥F8 等）控制播放。请在「系统设置 → 隐私与安全 → 输入监控」中授权 PurePlay。"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "稍后")
            let resp = alert.runModal()
            if resp == .alertFirstButtonReturn {
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
                NSWorkspace.shared.open(url)
            }
        }
    }

    deinit {
        unregisterAll()
        if let h = eventHandler {
            RemoveEventHandler(h)
        }
    }

    /// 注册一个全局热键
    /// - Returns: true = 注册成功；false = 系统拒绝（通常因为其他 App 已占用此组合）
    @discardableResult
    func register(action: Action, keyCode: Int,
                  modifiers: ModifierFlags,
                  handler: @escaping () -> Void) -> Bool {
        unregister(action: action)
        handlers[action] = handler

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.hotKeySignature, id: action.rawValue)
        let status = RegisterEventHotKey(UInt32(keyCode),
                                         modifiers.rawValue,
                                         id,
                                         GetApplicationEventTarget(),
                                         0,
                                         &ref)
        if status == noErr, let r = ref {
            hotKeyRefs[action] = r
            return true
        }
        handlers.removeValue(forKey: action)
        return false
    }

    func unregister(action: Action) {
        if let r = hotKeyRefs[action] {
            UnregisterEventHotKey(r)
            hotKeyRefs.removeValue(forKey: action)
        }
        handlers.removeValue(forKey: action)
    }

    func unregisterAll() {
        for action in hotKeyRefs.keys {
            if let r = hotKeyRefs[action] {
                UnregisterEventHotKey(r)
            }
        }
        hotKeyRefs.removeAll()
        handlers.removeAll()
    }

    // MARK: - Carbon Event Handler

    private func installEventHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(),
                            GlobalHotKey.eventCallback,
                            1, &spec, me, &eventHandler)
    }

    fileprivate func dispatch(actionRawValue: UInt32) {
        guard let action = Action(rawValue: actionRawValue),
              let handler = handlers[action] else { return }
        DispatchQueue.main.async(execute: handler)
    }

    private static let eventCallback: EventHandlerUPP = { (_, eventRef, userData) -> OSStatus in
        guard let event = eventRef, let userData = userData else { return noErr }
        var hkID = EventHotKeyID()
        let status = GetEventParameter(event,
                                       EventParamName(kEventParamDirectObject),
                                       EventParamType(typeEventHotKeyID),
                                       nil,
                                       MemoryLayout<EventHotKeyID>.size,
                                       nil,
                                       &hkID)
        guard status == noErr else { return status }
        let me = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
        me.dispatch(actionRawValue: hkID.id)
        return noErr
    }
}

private extension String {
    /// 把 4 字符 ASCII 串编码成 FourCharCode（OSType）
    var fourCharCode: UInt32 {
        var v: UInt32 = 0
        for (i, ch) in unicodeScalars.prefix(4).enumerated() {
            v |= UInt32(ch.value & 0xFF) << (8 * (3 - i))
        }
        return v
    }
}
