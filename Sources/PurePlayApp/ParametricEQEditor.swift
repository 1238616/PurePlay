import AppKit
import PurePlayCore

public final class ParametricEQEditor: NSView {

    public var bands: [ParametricBand] = [] {
        didSet { needsDisplay = true; onBandsChanged?(bands) }
    }
    public var preamp: Float = 0 {
        didSet { needsDisplay = true }
    }
    public var selectedBandIndex: Int? = nil {
        didSet { needsDisplay = true; onSelectionChanged?(selectedBandIndex) }
    }

    public var onBandsChanged: (([ParametricBand]) -> Void)?
    public var onSelectionChanged: ((Int?) -> Void)?

    private var draggingBand: Int?
    private var hoverBand: Int?
    private var trackingArea: NSTrackingArea?
    private let sampleRate: Double = 48000

    private let plotInset = NSEdgeInsets(top: 16, left: 40, bottom: 24, right: 16)
    private let dbRange: ClosedRange<Double> = -24...24
    private let freqRange: ClosedRange<Double> = 20...20000
    private let curvePoints = 384

    private let bandColors: [NSColor] = [
        .systemOrange, .systemCyan, .systemGreen, .systemPink,
        .systemYellow, .systemPurple, .systemTeal, .systemRed,
        .systemIndigo, .systemMint
    ]

    override public var isFlipped: Bool { false }

    // MARK: - Drawing

    override public func draw(_ dirtyRect: NSRect) {
        let bg = NSColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)
        bg.setFill()
        bounds.fill()

        let plot = plotRect()
        drawGrid(in: plot)
        drawCombinedCurve(in: plot)
        drawBandNodes(in: plot)
    }

    private func plotRect() -> NSRect {
        NSRect(x: bounds.minX + plotInset.left,
               y: bounds.minY + plotInset.bottom,
               width: bounds.width - plotInset.left - plotInset.right,
               height: bounds.height - plotInset.top - plotInset.bottom)
    }

    private func drawGrid(in plot: NSRect) {
        let dbLines: [Double] = [-24, -18, -12, -6, 0, 6, 12, 18, 24]
        for db in dbLines {
            let y = yForDB(db, in: plot)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: plot.minX, y: y))
            path.line(to: NSPoint(x: plot.maxX, y: y))
            if db == 0 {
                NSColor(white: 0.40, alpha: 1).setStroke()
                path.lineWidth = 1.5
            } else {
                NSColor(white: 0.20, alpha: 1).setStroke()
                path.lineWidth = 0.5
            }
            path.stroke()

            let label = db == 0 ? "0" : String(format: "%+.0f", db)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: NSColor(white: 0.5, alpha: 1)
            ]
            let str = NSAttributedString(string: label, attributes: attrs)
            str.draw(at: NSPoint(x: plot.minX - 32, y: y - 5))
        }

        let freqLabels: [(Double, String)] = [
            (20, "20"), (50, "50"), (100, "100"), (200, "200"), (500, "500"),
            (1000, "1k"), (2000, "2k"), (5000, "5k"), (10000, "10k"), (20000, "20k")
        ]
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor(white: 0.5, alpha: 1)
        ]
        for (freq, label) in freqLabels {
            let x = xForFreq(freq, in: plot)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: plot.minY))
            path.line(to: NSPoint(x: x, y: plot.maxY))
            NSColor(white: 0.14, alpha: 1).setStroke()
            path.lineWidth = 0.5
            path.stroke()

            let str = NSAttributedString(string: label, attributes: attrs)
            let size = str.size()
            str.draw(at: NSPoint(x: x - size.width / 2, y: plot.minY - 16))
        }

        let axisAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor(white: 0.4, alpha: 1)
        ]
        let dbLabel = NSAttributedString(string: "dB", attributes: axisAttrs)
        dbLabel.draw(at: NSPoint(x: plot.minX - 28, y: plot.maxY + 2))

        let freqAxisLabel = NSAttributedString(string: "Frequency (Hz)", attributes: axisAttrs)
        let freqSize = freqAxisLabel.size()
        freqAxisLabel.draw(at: NSPoint(x: plot.midX - freqSize.width / 2, y: plot.minY - 22))
    }

    private func drawCombinedCurve(in plot: NSRect) {
        guard !bands.isEmpty else { return }

        let node = ParametricEQNode(bands: bands, preamp: preamp)
        let format = AudioFormat(sampleRate: sampleRate, channels: 2, sampleFormat: .float32)
        _ = node.configure(inputFormat: format)

        let path = NSBezierPath()
        var first = true
        for i in 0..<curvePoints {
            let t = Double(i) / Double(curvePoints - 1)
            let freq = freqRange.lowerBound * pow(freqRange.upperBound / freqRange.lowerBound, t)
            let db = node.magnitudeDBAt(frequency: freq)
            let x = xForFreq(freq, in: plot)
            let y = yForDB(db, in: plot)
            if first { path.move(to: NSPoint(x: x, y: y)); first = false }
            else { path.line(to: NSPoint(x: x, y: y)) }
        }

        let curveColor = NSColor(red: 0.87, green: 0.83, blue: 0, alpha: 1)
        curveColor.withAlphaComponent(0.85).setStroke()
        path.lineWidth = 2
        path.stroke()

        let fillPath = path.copy() as! NSBezierPath
        let zeroY = yForDB(0, in: plot)
        fillPath.line(to: NSPoint(x: plot.maxX, y: zeroY))
        fillPath.line(to: NSPoint(x: plot.minX, y: zeroY))
        fillPath.close()
        curveColor.withAlphaComponent(0.06).setFill()
        fillPath.fill()
    }

    private func drawBandNodes(in plot: NSRect) {
        for (i, band) in bands.enumerated() {
            guard band.enabled else { continue }
            let x = xForFreq(band.frequency, in: plot)
            let y = yForDB(Double(band.gain), in: plot)
            let color = bandColors[i % bandColors.count]
            let radius: CGFloat = (i == selectedBandIndex || i == draggingBand) ? 8 : 6

            let circle = NSBezierPath(ovalIn: NSRect(x: x - radius, y: y - radius,
                                                      width: radius * 2, height: radius * 2))
            color.withAlphaComponent(0.9).setFill()
            circle.fill()
            NSColor.white.withAlphaComponent(0.8).setStroke()
            circle.lineWidth = (i == selectedBandIndex) ? 2 : 1
            circle.stroke()

            if i == hoverBand || i == selectedBandIndex {
                let label = String(format: "%.0f Hz  %+.1f dB  Q%.2f", band.frequency, band.gain, band.q)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: NSColor.white
                ]
                let str = NSAttributedString(string: label, attributes: attrs)
                let size = str.size()
                let labelX = min(max(x - size.width / 2, plot.minX), plot.maxX - size.width)
                let labelY = y + radius + 4
                let pillRect = NSRect(x: labelX - 4, y: labelY - 2, width: size.width + 8, height: size.height + 4)
                let pill = NSBezierPath(roundedRect: pillRect, xRadius: 4, yRadius: 4)
                NSColor(white: 0.1, alpha: 0.9).setFill()
                pill.fill()
                str.draw(at: NSPoint(x: labelX, y: labelY))
            }
        }
    }

    // MARK: - Coordinate Mapping

    private func xForFreq(_ freq: Double, in plot: NSRect) -> CGFloat {
        let logMin = log10(freqRange.lowerBound)
        let logMax = log10(freqRange.upperBound)
        let t = (log10(freq) - logMin) / (logMax - logMin)
        return plot.minX + CGFloat(t) * plot.width
    }

    private func freqForX(_ x: CGFloat, in plot: NSRect) -> Double {
        let t = Double((x - plot.minX) / plot.width)
        let logMin = log10(freqRange.lowerBound)
        let logMax = log10(freqRange.upperBound)
        return pow(10, logMin + t * (logMax - logMin))
    }

    private func yForDB(_ db: Double, in plot: NSRect) -> CGFloat {
        let clamped = max(dbRange.lowerBound, min(dbRange.upperBound, db))
        let t = (clamped - dbRange.lowerBound) / (dbRange.upperBound - dbRange.lowerBound)
        return plot.minY + CGFloat(t) * plot.height
    }

    private func dbForY(_ y: CGFloat, in plot: NSRect) -> Double {
        let t = Double((y - plot.minY) / plot.height)
        return dbRange.lowerBound + t * (dbRange.upperBound - dbRange.lowerBound)
    }

    // MARK: - Hit Testing

    private func bandHitTest(_ point: NSPoint, in plot: NSRect) -> Int? {
        let hitRadius: CGFloat = 12
        for (i, band) in bands.enumerated().reversed() {
            guard band.enabled else { continue }
            let bx = xForFreq(band.frequency, in: plot)
            let by = yForDB(Double(band.gain), in: plot)
            let dx = point.x - bx
            let dy = point.y - by
            if dx * dx + dy * dy <= hitRadius * hitRadius {
                return i
            }
        }
        return nil
    }

    // MARK: - Mouse Events

    override public func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let plot = plotRect()

        if let hit = bandHitTest(loc, in: plot) {
            if event.clickCount == 2 {
                bands[hit].gain = 0
            } else {
                draggingBand = hit
                selectedBandIndex = hit
            }
        } else if plot.contains(loc) && event.clickCount == 2 {
            guard bands.count < ParametricBand.maxBands else { return }
            let freq = freqForX(loc.x, in: plot)
            let gain = Float(dbForY(loc.y, in: plot))
            let newBand = ParametricBand(type: .peaking, frequency: freq, gain: gain, q: 1.414)
            bands.append(newBand)
            selectedBandIndex = bands.count - 1
        } else {
            selectedBandIndex = nil
        }
    }

    override public func mouseDragged(with event: NSEvent) {
        guard let idx = draggingBand else { return }
        let loc = convert(event.locationInWindow, from: nil)
        let plot = plotRect()

        let freq = max(freqRange.lowerBound, min(freqRange.upperBound, freqForX(loc.x, in: plot)))
        let gain = Float(max(dbRange.lowerBound, min(dbRange.upperBound, dbForY(loc.y, in: plot))))
        bands[idx].frequency = freq
        bands[idx].gain = gain
    }

    override public func mouseUp(with event: NSEvent) {
        draggingBand = nil
    }

    override public func scrollWheel(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let plot = plotRect()
        guard let idx = bandHitTest(loc, in: plot) else { return }

        let delta = event.scrollingDeltaY * 0.05
        let newQ = max(ParametricBand.qRange.lowerBound,
                       min(ParametricBand.qRange.upperBound,
                           bands[idx].q + delta))
        bands[idx].q = newQ
        selectedBandIndex = idx
    }

    override public func rightMouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let plot = plotRect()
        guard let idx = bandHitTest(loc, in: plot) else { return }

        let menu = NSMenu()
        let peakItem = NSMenuItem(title: "Peak", action: #selector(setFilterType(_:)), keyEquivalent: "")
        peakItem.tag = idx * 10
        let lowShelfItem = NSMenuItem(title: "Low Shelf", action: #selector(setFilterType(_:)), keyEquivalent: "")
        lowShelfItem.tag = idx * 10 + 1
        let highShelfItem = NSMenuItem(title: "High Shelf", action: #selector(setFilterType(_:)), keyEquivalent: "")
        highShelfItem.tag = idx * 10 + 2
        menu.addItem(peakItem)
        menu.addItem(lowShelfItem)
        menu.addItem(highShelfItem)
        menu.addItem(.separator())
        let deleteItem = NSMenuItem(title: "Delete Band", action: #selector(deleteBand(_:)), keyEquivalent: "")
        deleteItem.tag = idx
        menu.addItem(deleteItem)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func setFilterType(_ sender: NSMenuItem) {
        let idx = sender.tag / 10
        let typeIndex = sender.tag % 10
        guard idx < bands.count else { return }
        switch typeIndex {
        case 0: bands[idx].type = .peaking
        case 1: bands[idx].type = .lowShelf
        case 2: bands[idx].type = .highShelf
        default: break
        }
    }

    @objc private func deleteBand(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard idx < bands.count else { return }
        bands.remove(at: idx)
        if selectedBandIndex == idx { selectedBandIndex = nil }
        else if let sel = selectedBandIndex, sel > idx { selectedBandIndex = sel - 1 }
    }

    // MARK: - Tracking

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea { removeTrackingArea(area) }
        trackingArea = NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self)
        addTrackingArea(trackingArea!)
    }

    override public func mouseMoved(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let plot = plotRect()
        hoverBand = bandHitTest(loc, in: plot)
        needsDisplay = true
    }
}
