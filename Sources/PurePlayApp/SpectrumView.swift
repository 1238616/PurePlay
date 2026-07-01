import Foundation
import AppKit
import PurePlayCore

final class SpectrumView: NSView {
    private let analyzer: SpectrumAnalyzer
    private var displayLink: CVDisplayLink?
    private var lastBands: [Float]
    private var peaks: [Float]
    private let peakDecay: Float = 0.015

    init(analyzer: SpectrumAnalyzer) {
        self.analyzer = analyzer
        self.lastBands = [Float](repeating: 0, count: analyzer.bandCount)
        self.peaks = [Float](repeating: 0, count: analyzer.bandCount)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { startDisplayLink() } else { stopDisplayLink() }
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let displayLink = link else { return }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(displayLink, { (_, _, _, _, _, ctx) -> CVReturn in
            guard let ctx = ctx else { return kCVReturnSuccess }
            let view = Unmanaged<SpectrumView>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async {
                view.refresh()
            }
            return kCVReturnSuccess
        }, userInfo)
        CVDisplayLinkStart(displayLink)
        self.displayLink = displayLink
    }

    private func stopDisplayLink() {
        if let dl = displayLink {
            CVDisplayLinkStop(dl)
            displayLink = nil
        }
    }

    deinit { stopDisplayLink() }

    private func refresh() {
        let bands = analyzer.currentBands()
        lastBands = bands
        for i in 0..<peaks.count {
            if bands[i] > peaks[i] {
                peaks[i] = bands[i]
            } else {
                peaks[i] = max(0, peaks[i] - peakDecay)
            }
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let count = lastBands.count
        guard count > 0 else { return }
        let totalWidth = bounds.width
        let gap: CGFloat = 2
        let barWidth = max(1, (totalWidth - CGFloat(count - 1) * gap) / CGFloat(count))
        let height = bounds.height

        for i in 0..<count {
            let value = CGFloat(max(0, min(1, lastBands[i])))
            let barHeight = max(1, value * height)
            let x = CGFloat(i) * (barWidth + gap)
            let rect = NSRect(x: x, y: 0, width: barWidth, height: barHeight)
            let color = NSColor(calibratedHue: 0.55 - CGFloat(i) / CGFloat(count) * 0.4,
                                saturation: 0.8,
                                brightness: 0.95,
                                alpha: 0.85)
            ctx.setFillColor(color.cgColor)
            ctx.fill(rect)

            let peak = CGFloat(peaks[i])
            if peak > 0.02 {
                let peakY = peak * height
                let peakRect = NSRect(x: x, y: peakY, width: barWidth, height: 2)
                ctx.setFillColor(NSColor(calibratedWhite: 1.0, alpha: 0.6).cgColor)
                ctx.fill(peakRect)
            }
        }
    }
}
