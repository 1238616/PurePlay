import AppKit
import PurePlayCore

/// 滚动波形视图（CoreGraphics 渲染，零外部依赖）
///
/// 每个 bin 渲染为一根竖条：
///   - 半透明外框  = peak（高度由 |最大幅值| 决定）
///   - 实色内芯    = rms（高度由 RMS 决定）
/// 颜色随 peak 接近 1.0 渐变（绿 → 黄 → 红），便于发烧友直观看到过载风险。
///
/// 用法：
///   let waveform = WaveformView()
///   waveform.buffer = playerController.waveformBuffer
///   // 启动定时刷新；推荐 30 FPS 已足够流畅
///   waveform.startRendering()
final class WaveformView: NSView {

    var buffer: WaveformBuffer?
    /// 一屏显示的 bin 数（视图宽度 / barWidth + spacing）
    var visibleBins: Int = 256
    /// 颜色基调（默认 Vox 暖橙）
    var baseColor: NSColor = NSColor(red: 1.0, green: 0.55, blue: 0.25, alpha: 1.0)
    /// 背景色
    var backgroundColor: NSColor = NSColor(white: 0.07, alpha: 1)

    private var renderTimer: Timer?
    private var lastSnapshot: [WaveformBuffer.Bin] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        stopRendering()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = backgroundColor.cgColor
        layer?.cornerRadius = 4
    }

    override var isFlipped: Bool { true }

    func startRendering(fps: Double = 30) {
        stopRendering()
        let interval = 1.0 / fps
        renderTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard let buf = self.buffer else { return }
            self.lastSnapshot = buf.snapshot(count: self.visibleBins)
            self.setNeedsDisplay(self.bounds)
        }
    }

    func stopRendering() {
        renderTimer?.invalidate()
        renderTimer = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(backgroundColor.cgColor)
        ctx.fill(bounds)

        let bins = lastSnapshot
        guard !bins.isEmpty else { return }

        let w = bounds.width
        let h = bounds.height
        let n = CGFloat(bins.count)
        let barW = max(1.5, (w / n) * 0.7)
        let step = w / n
        let midY = h / 2

        for (i, bin) in bins.enumerated() {
            let x = CGFloat(i) * step + (step - barW) / 2
            let peakH = CGFloat(bin.peak) * h
            let rmsH = CGFloat(bin.rms) * h * 0.95
            let color = colorFor(peak: bin.peak)

            // peak (semi-transparent envelope)
            let peakRect = CGRect(x: x, y: midY - peakH / 2,
                                  width: barW, height: peakH)
            ctx.setFillColor(color.withAlphaComponent(0.35).cgColor)
            ctx.fill(peakRect)

            // rms (solid core)
            let rmsRect = CGRect(x: x, y: midY - rmsH / 2,
                                 width: barW, height: rmsH)
            ctx.setFillColor(color.cgColor)
            ctx.fill(rmsRect)
        }
    }

    /// peak [0,1] → green→amber→red gradient
    private func colorFor(peak: Float) -> NSColor {
        let p = max(0, min(1, peak))
        if p < 0.7 {
            return baseColor
        } else if p < 0.9 {
            return NSColor.systemYellow
        } else {
            return NSColor.systemRed
        }
    }

    override func layout() {
        super.layout()
        // 根据宽度动态调整 visibleBins，使每个 bin ≈ 3-4 像素
        let target = max(64, min(1024, Int(bounds.width / 3)))
        if target != visibleBins {
            visibleBins = target
        }
    }
}
