import Foundation

/// 采样率匹配策略 + 切换 + 轮询锁定
/// 用于在每曲起播前把硬件率切到匹配源文件，实现 bit-perfect
public enum SampleRateManager {

    /// 在设备支持的采样率集合里挑一个最匹配 source 的目标率
    /// 策略：
    ///   1. 精确匹配优先
    ///   2. 否则回退到 deviceDefault（用户决策：保证能出声）
    public static func pickTargetRate(source: Double,
                                      supported: [Double],
                                      deviceDefault: Double) -> Double {
        if matches(source, in: supported) { return source }
        return deviceDefault
    }

    /// 切换硬件采样率，并轮询读取 NominalSampleRate 直到匹配或超时
    /// - Parameters:
    ///   - output: 已设置 currentDevice 的后端
    ///   - rate: 目标率
    ///   - timeout: 总超时（秒），默认 1.0
    /// - Throws: PurePlayError.sampleRateUnsupported 若设备拒绝写入
    public static func switchAndWait(output: AudioOutputBackend,
                                     to rate: Double,
                                     timeout: TimeInterval = 1.0) throws {
        // 已经是目标率则跳过
        if matches(output.readNominalSampleRate(), in: [rate]) {
            try? output.switchSampleRate(to: rate)  // 仍同步内部状态
            return
        }
        try output.switchSampleRate(to: rate)

        let deadline = Date().addingTimeInterval(timeout)
        let pollInterval: TimeInterval = 0.02
        while Date() < deadline {
            let actual = output.readNominalSampleRate()
            if matches(actual, in: [rate]) { return }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        // 超时未锁定：不再抛错（设备已接受写入；某些 DAC 锁定较慢）
    }

    /// 浮点率比较：允许 0.5Hz 容差
    private static func matches(_ a: Double, in rates: [Double]) -> Bool {
        for r in rates where abs(a - r) < 0.5 { return true }
        return false
    }
}
