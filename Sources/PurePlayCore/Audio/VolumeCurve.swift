import Foundation

/// 音量曲线 — 感知均匀的 dB 映射（issue #17）
///
/// 线性滑杆的问题：人耳对响度的感知是对数的。线性增益 0...1 下，
/// 几乎全部可听变化都挤在滑杆末端一小段行程里，低音量区无法微调。
///
/// 这里把滑杆位置线性映射到 [-60dB, 0dB]：
///   slider 1.0 → 0 dB  → 线性增益 1.0（unity）
///   slider 0.5 → -30dB → 线性增益 ≈ 0.0316
///   slider 0.0 → 静音  → 线性增益 0
/// dB 域上等距 = 感知上等距。
public enum VolumeCurve {

    /// 滑杆 0 位对应的衰减下限（dB）
    public static let minDB: Float = -60

    /// slider (0...1) → dB；slider ≤ 0 返回 -infinity（静音）
    public static func dB(slider: Float) -> Float {
        let x = max(0, min(1, slider))
        guard x > 0 else { return -Float.infinity }
        return minDB * (1 - x)
    }

    /// slider (0...1) → 线性增益 10^(dB/20)；slider ≤ 0 返回 0（静音）
    public static func linearGain(slider: Float) -> Float {
        let x = max(0, min(1, slider))
        guard x > 0 else { return 0 }
        return pow(10, minDB * (1 - x) / 20)
    }
}
