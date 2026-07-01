import Foundation
#if canImport(CoreAudio)
import CoreAudio
import AudioToolbox
#endif

/// 音频设备描述
public struct AudioDevice: Identifiable, Sendable {
    public let id: UInt32   // AudioObjectID
    public let name: String
    public let uid: String
    public let maxSampleRate: Double
    public let supportedRates: [Double]

    public init(id: UInt32, name: String, uid: String, maxSampleRate: Double, supportedRates: [Double]) {
        self.id = id
        self.name = name
        self.uid = uid
        self.maxSampleRate = maxSampleRate
        self.supportedRates = supportedRates
    }
}

/// CoreAudio 输出抽象
/// 本文件提供生产用 CoreAudio HAL 操作 + 一个 Mock 实现用于无硬件 CI
public protocol AudioOutputBackend: AnyObject {
    var currentDevice: AudioDevice? { get }
    var isHogMode: Bool { get }
    var currentSampleRate: Double { get }

    func start(format: AudioFormat, renderCallback: @escaping AudioRenderCallback) throws
    func stop()
    func setVolume(_ volume: Float)
    func setDevice(_ device: AudioDevice) throws
    func acquireHogMode() throws
    func releaseHogMode() throws
    func switchSampleRate(to rate: Double) throws
    func listDevices() -> [AudioDevice]

    /// 读取设备当前实际的硬件名义采样率（用于 switchSampleRate 后轮询确认）
    /// 无 currentDevice 时返回 0
    func readNominalSampleRate() -> Double

    /// 设置设备 PhysicalFormat（精确控制位深+采样率，bit-perfect 关键）
    /// 失败时不抛错，仅返回 false；NominalSampleRate 作为回退
    @discardableResult
    func setPhysicalFormat(_ format: AudioFormat) -> Bool

    /// 设备生命周期事件回调（在主线程异步派发）
    var onDeviceLost: (() -> Void)? { get set }
    var onDefaultDeviceChanged: ((AudioDevice?) -> Void)? { get set }
    var onStreamFormatChanged: (() -> Void)? { get set }
    var onDevicesChanged: (() -> Void)? { get set }
}

/// 默认无操作实现 — 让 Mock 等简单后端无需感知设备事件
public extension AudioOutputBackend {
    @discardableResult
    func setPhysicalFormat(_ format: AudioFormat) -> Bool { false }
}

/// 渲染回调类型
/// callback(outBuffer, framesNeeded) → 实际填充帧数
public typealias AudioRenderCallback = (UnsafeMutableRawPointer, Int) -> Int

#if canImport(CoreAudio)
/// 真实 CoreAudio HAL 后端（macOS 使用）
/// 借鉴 VLC auhal.c 的设备枚举与 hog mode 实现
public final class CoreAudioHALOutput: AudioOutputBackend {

    public private(set) var currentDevice: AudioDevice?
    public private(set) var isHogMode: Bool = false
    public private(set) var currentSampleRate: Double = 0

    private var audioUnit: AudioComponentInstance?
    private var renderCb: AudioRenderCallback?

    /// Hog Mode 前的 mixable 值，stop/release 时用于恢复（发烧友 App 的礼貌）
    private var savedMixable: UInt32?

    public var onDeviceLost: (() -> Void)?
    public var onDefaultDeviceChanged: ((AudioDevice?) -> Void)?
    public var onStreamFormatChanged: (() -> Void)?
    public var onDevicesChanged: (() -> Void)?

    /// 已注册的监听器（stop 时移除）
    private var listener: AudioDeviceListener?

    public init() {}

    deinit { stop() }

    public func listDevices() -> [AudioDevice] {
        var propSize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                       &address, 0, nil, &propSize)
        let count = Int(propSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                   &address, 0, nil, &propSize, &ids)
        return ids.compactMap { deviceFrom(id: $0) }
    }

    public func setDevice(_ device: AudioDevice) throws {
        currentDevice = device
    }

    public func acquireHogMode() throws {
        guard let dev = currentDevice else { throw PurePlayError.deviceNotFound }

        // 1. Save current mixable state for later restore
        var mixAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertySupportsMixing,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var prevMixable: UInt32 = 1
        var sz = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(dev.id, &mixAddr, 0, nil, &sz, &prevMixable) == noErr {
            savedMixable = prevMixable
        }

        // 2. Take Hog Mode (set pid = our pid)
        var pid = getpid()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyHogMode,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(dev.id, &address, 0, nil,
                                                UInt32(MemoryLayout<pid_t>.size), &pid)
        if status != noErr { throw PurePlayError.hogModeDenied }
        isHogMode = true

        // 3. Force mixable = 0 (best-effort; some DACs may not allow it)
        var disable: UInt32 = 0
        _ = AudioObjectSetPropertyData(dev.id, &mixAddr, 0, nil,
                                       UInt32(MemoryLayout<UInt32>.size), &disable)
    }

    public func releaseHogMode() throws {
        guard let dev = currentDevice else { return }

        // 1. Release Hog (pid = -1)
        var pid: pid_t = -1
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyHogMode,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(dev.id, &address, 0, nil,
                                   UInt32(MemoryLayout<pid_t>.size), &pid)
        isHogMode = false

        // 2. Restore mixable (so other apps can use device after we exit)
        if let prev = savedMixable {
            var restore = prev
            var mixAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertySupportsMixing,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            _ = AudioObjectSetPropertyData(dev.id, &mixAddr, 0, nil,
                                           UInt32(MemoryLayout<UInt32>.size), &restore)
            savedMixable = nil
        }
    }

    public func switchSampleRate(to rate: Double) throws {
        guard let dev = currentDevice else { throw PurePlayError.deviceNotFound }
        var r = Float64(rate)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(dev.id, &address, 0, nil,
                                                UInt32(MemoryLayout<Float64>.size), &r)
        if status != noErr {
            throw PurePlayError.sampleRateUnsupported(rate)
        }
        currentSampleRate = rate
    }

    /// 设置设备 PhysicalFormat — 真正的 bit-perfect 路径
    /// 在第一个输出流上写入 ASBD，让 DAC 接收原生位深+采样率
    /// macOS 仅在 SPDIF/HDMI 上严格遵守此设置；多数 USB DAC 也支持
    @discardableResult
    public func setPhysicalFormat(_ format: AudioFormat) -> Bool {
        guard let dev = currentDevice else { return false }

        // 1. 取设备的输出流数组
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev.id, &addr, 0, nil, &size) == noErr,
              size > 0 else { return false }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var streams = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(dev.id, &addr, 0, nil, &size, &streams) == noErr,
              let stream = streams.first else { return false }

        // 2. 构造目标 ASBD
        var asbd = makeASBD(for: format)

        // 3. 写入 PhysicalFormat
        var physAddr = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyPhysicalFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(stream, &physAddr, 0, nil,
                                                UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                                                &asbd)
        if status == noErr {
            currentSampleRate = format.sampleRate
            return true
        }
        return false
    }

    /// 构造与 AudioFormat 对应的 ASBD
    /// 整数 PCM 直通：kAudioFormatFlagIsSignedInteger | Packed（不强制 Float）
    /// 24-bit PCM 注意走 NativeEndian + Packed
    private func makeASBD(for format: AudioFormat) -> AudioStreamBasicDescription {
        let flags: UInt32
        if format.sampleFormat == .float32 {
            flags = kAudioFormatFlagIsFloat
                  | kAudioFormatFlagIsPacked
                  | kAudioFormatFlagsNativeEndian
        } else {
            flags = kAudioFormatFlagIsSignedInteger
                  | kAudioFormatFlagIsPacked
                  | kAudioFormatFlagsNativeEndian
        }
        return AudioStreamBasicDescription(
            mSampleRate: format.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: flags,
            mBytesPerPacket: UInt32(format.bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(format.bytesPerFrame),
            mChannelsPerFrame: UInt32(format.channels),
            mBitsPerChannel: UInt32(format.containerBitDepth),
            mReserved: 0
        )
    }

    public func start(format: AudioFormat, renderCallback: @escaping AudioRenderCallback) throws {
        self.renderCb = renderCallback
        currentSampleRate = format.sampleRate

        // 已选设备 → HALOutput 并绑定；否则走 DefaultOutput 兼容旧行为
        let subType: OSType = currentDevice != nil
            ? kAudioUnitSubType_HALOutput
            : kAudioUnitSubType_DefaultOutput
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: subType,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw PurePlayError.deviceNotFound
        }
        var unit: AudioComponentInstance?
        AudioComponentInstanceNew(comp, &unit)
        guard let au = unit else { throw PurePlayError.deviceNotFound }
        audioUnit = au

        if var devID = currentDevice?.id {
            let status = AudioUnitSetProperty(
                au, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0,
                &devID, UInt32(MemoryLayout<AudioObjectID>.size))
            if status != noErr {
                AudioComponentInstanceDispose(au)
                audioUnit = nil
                throw PurePlayError.deviceNotFound
            }
        }

        var asbd = makeASBD(for: format)
        AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Input, 0,
                             &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

        // 注册设备监听器（拔插 / 默认设备变更 / 流格式变更）
        if let dev = currentDevice {
            let l = AudioDeviceListener(deviceID: dev.id)
            l.onDeviceAlive = { [weak self] alive in
                guard !alive else { return }
                DispatchQueue.main.async { self?.onDeviceLost?() }
            }
            l.onDefaultDeviceChanged = { [weak self] newID in
                guard let self = self else { return }
                let dev = newID.flatMap { self.deviceFrom(id: $0) }
                DispatchQueue.main.async { self.onDefaultDeviceChanged?(dev) }
            }
            l.onStreamFormatChanged = { [weak self] in
                DispatchQueue.main.async { self?.onStreamFormatChanged?() }
            }
            l.onDevicesChanged = { [weak self] in
                DispatchQueue.main.async { self?.onDevicesChanged?() }
            }
            l.install()
            self.listener = l
        }

        var callbackStruct = AURenderCallbackStruct(
            inputProc: { (inRefCon, _, _, _, inNumberFrames, ioData) in
                let output = Unmanaged<CoreAudioHALOutput>.fromOpaque(inRefCon).takeUnretainedValue()
                guard let cb = output.renderCb,
                      let bufs = ioData else { return noErr }
                let ptr = UnsafeMutableAudioBufferListPointer(bufs)
                guard let data = ptr[0].mData else { return noErr }
                let frames = cb(data, Int(inNumberFrames))
                if frames < Int(inNumberFrames) {
                    let bytesPerFrame = inNumberFrames > 0 ? Int(ptr[0].mDataByteSize) / Int(inNumberFrames) : 4
                    let filled = frames * bytesPerFrame
                    let total = Int(ptr[0].mDataByteSize)
                    memset(data.advanced(by: filled), 0, max(0, total - filled))
                }
                return noErr
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback,
                             kAudioUnitScope_Input, 0,
                             &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        AudioUnitInitialize(au)
        AudioOutputUnitStart(au)
    }

    public func setVolume(_ volume: Float) {
        guard let au = audioUnit else { return }
        let clamped = max(0.0, min(1.0, volume))
        AudioUnitSetParameter(au, kHALOutputParam_Volume, kAudioUnitScope_Global, 0, clamped, 0)
    }

    public func stop() {
        if let au = audioUnit {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
            audioUnit = nil
        }
        renderCb = nil

        // 移除监听器
        listener?.uninstall()
        listener = nil

        // 仍持有 Hog Mode 时优雅释放（恢复 mixable，让其他 App 可用设备）
        if isHogMode {
            try? releaseHogMode()
        }
    }

    public func readNominalSampleRate() -> Double {
        guard let dev = currentDevice else { return 0 }
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(dev.id, &addr, 0, nil, &size, &rate)
        return status == noErr ? Double(rate) : 0
    }

    // MARK: Private helpers

    private func deviceFrom(id: AudioObjectID) -> AudioDevice? {
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name)

        // 检查是否有输出流
        addr.mSelector = kAudioDevicePropertyStreams
        addr.mScope = kAudioObjectPropertyScopeOutput
        var streamSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &streamSize)
        guard streamSize > 0 else { return nil }

        // 真实 UID（持久化用，跨重启稳定）
        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let uidStatus = AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &uidSize, &uid)
        let uidString = uidStatus == noErr ? (uid as String) : "\(id)"

        // 采样率范围
        addr.mSelector = kAudioDevicePropertyAvailableNominalSampleRates
        addr.mScope = kAudioObjectPropertyScopeGlobal
        var ratesSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &ratesSize)
        let ratesCount = Int(ratesSize) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: ratesCount)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &ratesSize, &ranges)
        let rates = ranges.map { $0.mMaximum }
        let maxRate = rates.max() ?? 44100

        return AudioDevice(id: id, name: name as String, uid: uidString,
                           maxSampleRate: maxRate, supportedRates: rates)
    }
}
#endif

/// Mock 输出后端（CI/无 DAC 环境测试用）
public final class MockAudioOutput: AudioOutputBackend {
    public private(set) var currentDevice: AudioDevice?
    public private(set) var isHogMode: Bool = false
    public private(set) var currentSampleRate: Double = 0
    public private(set) var currentVolume: Float = 1.0

    public var onDeviceLost: (() -> Void)?
    public var onDefaultDeviceChanged: ((AudioDevice?) -> Void)?
    public var onStreamFormatChanged: (() -> Void)?
    public var onDevicesChanged: (() -> Void)?

    /// 测试可观察：每次 setPhysicalFormat 被调用都会追加
    public private(set) var setPhysicalFormatCalls: [AudioFormat] = []
    /// 模拟硬件是否接受 setPhysicalFormat
    public var physicalFormatSucceeds: Bool = true

    private var renderCb: AudioRenderCallback?
    public private(set) var isPlaying = false
    public private(set) var framesRendered: Int64 = 0
    public private(set) var configuredFormat: AudioFormat?

    public init() {}

    public func listDevices() -> [AudioDevice] {
        [AudioDevice(id: 1, name: "Mock DAC", uid: "mock-1",
                     maxSampleRate: 768_000, supportedRates: [44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000, 705600, 768000])]
    }

    public func setDevice(_ device: AudioDevice) throws {
        currentDevice = device
    }

    public func acquireHogMode() throws {
        isHogMode = true
    }

    public func releaseHogMode() throws {
        isHogMode = false
    }

    public func switchSampleRate(to rate: Double) throws {
        currentSampleRate = rate
    }

    @discardableResult
    public func setPhysicalFormat(_ format: AudioFormat) -> Bool {
        setPhysicalFormatCalls.append(format)
        if physicalFormatSucceeds {
            currentSampleRate = format.sampleRate
            return true
        }
        return false
    }

    public func readNominalSampleRate() -> Double {
        currentSampleRate
    }

    public func start(format: AudioFormat, renderCallback: @escaping AudioRenderCallback) throws {
        self.renderCb = renderCallback
        self.currentSampleRate = format.sampleRate
        self.configuredFormat = format
        self.isPlaying = true
    }

    public func setVolume(_ volume: Float) {
        currentVolume = max(0.0, min(1.0, volume))
    }

    public func stop() {
        isPlaying = false
        renderCb = nil
    }

    /// 模拟拉取 n 帧（测试用）
    @discardableResult
    public func pullFrames(_ count: Int, bytesPerFrame: Int) -> Int {
        guard let cb = renderCb else { return 0 }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: count * bytesPerFrame, alignment: 16)
        defer { buf.deallocate() }
        let rendered = cb(buf, count)
        framesRendered += Int64(rendered)
        return rendered
    }

    /// 测试辅助：模拟设备生命周期事件
    public func simulateDeviceLost() {
        onDeviceLost?()
    }
    public func simulateDefaultDeviceChanged(to device: AudioDevice?) {
        onDefaultDeviceChanged?(device)
    }
    public func simulateStreamFormatChanged() {
        onStreamFormatChanged?()
    }
    public func simulateDevicesChanged() {
        onDevicesChanged?()
    }
}
