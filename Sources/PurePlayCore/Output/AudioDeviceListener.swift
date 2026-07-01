import Foundation
#if canImport(CoreAudio)
import CoreAudio
import AudioToolbox

/// CoreAudio HAL 设备监听器
/// 监听 4 类事件，借鉴 VLC `auhal.c` 的 listener pattern：
///   1. kAudioDevicePropertyDeviceIsAlive — 设备拔出
///   2. kAudioHardwarePropertyDefaultOutputDevice — 系统默认输出变更
///   3. kAudioStreamPropertyPhysicalFormat — 设备流格式变更（外部 App 改了采样率）
///   4. kAudioHardwarePropertyDevices — 设备列表变化（插入新设备）
///
/// 回调可能从 CoreAudio 私有线程触发；调用方负责 dispatch 到主线程。
public final class AudioDeviceListener {

    public let deviceID: AudioObjectID

    public var onDeviceAlive: ((Bool) -> Void)?
    /// 携带新的默认输出 AudioObjectID（nil = 无效）
    public var onDefaultDeviceChanged: ((AudioObjectID?) -> Void)?
    public var onStreamFormatChanged: (() -> Void)?
    public var onDevicesChanged: (() -> Void)?

    // 把回调装进 Unmanaged，让 C trampoline 拿到 self
    private var installed = false
    private var aliveAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsAlive,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var defaultAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var formatAddr = AudioObjectPropertyAddress(
        mSelector: kAudioStreamPropertyPhysicalFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var devicesAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    public init(deviceID: AudioObjectID) {
        self.deviceID = deviceID
    }

    deinit { uninstall() }

    public func install() {
        guard !installed else { return }
        let ctx = Unmanaged.passUnretained(self).toOpaque()

        AudioObjectAddPropertyListener(deviceID, &aliveAddr, Self.aliveCallback, ctx)
        AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject),
                                       &defaultAddr, Self.defaultCallback, ctx)
        // 监听设备主流的 PhysicalFormat 变更
        if let streamID = firstOutputStream() {
            AudioObjectAddPropertyListener(streamID, &formatAddr, Self.formatCallback, ctx)
        }
        AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject),
                                       &devicesAddr, Self.devicesCallback, ctx)
        installed = true
    }

    public func uninstall() {
        guard installed else { return }
        let ctx = Unmanaged.passUnretained(self).toOpaque()

        AudioObjectRemovePropertyListener(deviceID, &aliveAddr, Self.aliveCallback, ctx)
        AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject),
                                          &defaultAddr, Self.defaultCallback, ctx)
        if let streamID = firstOutputStream() {
            AudioObjectRemovePropertyListener(streamID, &formatAddr, Self.formatCallback, ctx)
        }
        AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject),
                                          &devicesAddr, Self.devicesCallback, ctx)
        installed = false
    }

    private func firstOutputStream() -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr,
              size > 0 else { return nil }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var streams = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &streams) == noErr else {
            return nil
        }
        return streams.first
    }

    // MARK: - C trampolines

    private static let aliveCallback: AudioObjectPropertyListenerProc = { _, _, _, ctx in
        guard let ctx = ctx else { return noErr }
        let me = Unmanaged<AudioDeviceListener>.fromOpaque(ctx).takeUnretainedValue()
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(me.deviceID, &me.aliveAddr, 0, nil, &size, &alive)
        me.onDeviceAlive?(alive == 1)
        return noErr
    }

    private static let defaultCallback: AudioObjectPropertyListenerProc = { _, _, _, ctx in
        guard let ctx = ctx else { return noErr }
        let me = Unmanaged<AudioDeviceListener>.fromOpaque(ctx).takeUnretainedValue()
        var newID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &me.defaultAddr, 0, nil, &size, &newID)
        me.onDefaultDeviceChanged?(status == noErr ? newID : nil)
        return noErr
    }

    private static let formatCallback: AudioObjectPropertyListenerProc = { _, _, _, ctx in
        guard let ctx = ctx else { return noErr }
        let me = Unmanaged<AudioDeviceListener>.fromOpaque(ctx).takeUnretainedValue()
        me.onStreamFormatChanged?()
        return noErr
    }

    private static let devicesCallback: AudioObjectPropertyListenerProc = { _, _, _, ctx in
        guard let ctx = ctx else { return noErr }
        let me = Unmanaged<AudioDeviceListener>.fromOpaque(ctx).takeUnretainedValue()
        me.onDevicesChanged?()
        return noErr
    }
}
#endif
