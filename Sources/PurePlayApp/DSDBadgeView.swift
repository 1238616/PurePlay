import Foundation
import AppKit

/// Stylized golden DSD badge inspired by the Hi-Res Audio gold badge / DSD logotype.
/// Renders with a radial gold gradient, fine border, and subtle inner highlight.
final class DSDBadgeView: NSView {

    enum Rate {
        case dsd64, dsd128, dsd256, dsd512, dsd1024

        init(sampleRate: Double) {
            switch sampleRate {
            case 45_000_000...: self = .dsd1024
            case 22_000_000...: self = .dsd512
            case 11_000_000...: self = .dsd256
            case  5_500_000...: self = .dsd128
            default:            self = .dsd64
            }
        }

        var rateLabel: String {
            switch self {
            case .dsd64:   return "64"
            case .dsd128:  return "128"
            case .dsd256:  return "256"
            case .dsd512:  return "512"
            case .dsd1024: return "1024"
            }
        }
    }

    private var rate: Rate = .dsd64

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 78, height: 26) }

    func configure(dsdRate: Double) {
        self.rate = Rate(sampleRate: dsdRate)
        needsDisplay = true
        invalidateIntrinsicContentSize()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let radius: CGFloat = rect.height / 2

        // Soft outer shadow
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 4,
                      color: NSColor(calibratedRed: 0.7, green: 0.55, blue: 0.0, alpha: 0.55).cgColor)

        // Gold radial gradient fill
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        ctx.addPath(path.cgPath)
        ctx.clip()

        let goldLight = NSColor(calibratedRed: 1.00, green: 0.93, blue: 0.55, alpha: 1.0).cgColor
        let goldMid   = NSColor(calibratedRed: 0.95, green: 0.78, blue: 0.20, alpha: 1.0).cgColor
        let goldDeep  = NSColor(calibratedRed: 0.72, green: 0.52, blue: 0.05, alpha: 1.0).cgColor

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let gradient = CGGradient(colorsSpace: colorSpace,
                                  colors: [goldLight, goldMid, goldDeep] as CFArray,
                                  locations: [0.0, 0.5, 1.0])!
        let center = CGPoint(x: rect.midX, y: rect.maxY)
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: rect.midX, y: rect.maxY),
                               end:   CGPoint(x: rect.midX, y: rect.minY),
                               options: [])
        _ = center

        ctx.restoreGState()

        // Glossy top highlight
        ctx.saveGState()
        ctx.addPath(path.cgPath)
        ctx.clip()
        let highlight = CGGradient(colorsSpace: colorSpace,
                                   colors: [
                                    NSColor(white: 1.0, alpha: 0.55).cgColor,
                                    NSColor(white: 1.0, alpha: 0.0).cgColor
                                   ] as CFArray,
                                   locations: [0.0, 1.0])!
        let highlightRect = CGRect(x: rect.minX, y: rect.midY,
                                   width: rect.width, height: rect.height / 2)
        ctx.clip(to: highlightRect)
        ctx.drawLinearGradient(highlight,
                               start: CGPoint(x: rect.midX, y: rect.maxY),
                               end:   CGPoint(x: rect.midX, y: rect.midY),
                               options: [])
        ctx.restoreGState()

        // Border
        ctx.saveGState()
        ctx.addPath(path.cgPath)
        ctx.setStrokeColor(NSColor(calibratedRed: 0.55, green: 0.40, blue: 0.05, alpha: 0.9).cgColor)
        ctx.setLineWidth(0.8)
        ctx.strokePath()
        ctx.restoreGState()

        // Text: "DSD<rate>" — DSD bold serif italic, rate subscript
        let dsdAttr: [NSAttributedString.Key: Any] = [
            .font: NSFontManager.shared.font(withFamily: "Times New Roman",
                                             traits: [.boldFontMask, .italicFontMask],
                                             weight: 9, size: 13)
                ?? NSFont.boldSystemFont(ofSize: 13),
            .foregroundColor: NSColor(calibratedRed: 0.18, green: 0.10, blue: 0.0, alpha: 1.0),
            .kern: -0.3
        ]
        let rateAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .heavy),
            .foregroundColor: NSColor(calibratedRed: 0.18, green: 0.10, blue: 0.0, alpha: 1.0)
        ]

        let dsdString = NSAttributedString(string: "DSD", attributes: dsdAttr)
        let rateString = NSAttributedString(string: rate.rateLabel, attributes: rateAttr)

        let dsdSize = dsdString.size()
        let rateSize = rateString.size()
        let totalWidth = dsdSize.width + 2 + rateSize.width
        let startX = rect.midX - totalWidth / 2
        let dsdY = rect.midY - dsdSize.height / 2 + 0.5
        let rateY = rect.minY + 3

        dsdString.draw(at: NSPoint(x: startX, y: dsdY))
        rateString.draw(at: NSPoint(x: startX + dsdSize.width + 2, y: rateY))
    }
}

private extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            switch element(at: i, associatedPoints: &points) {
            case .moveTo:    path.move(to: points[0])
            case .lineTo:    path.addLine(to: points[0])
            case .curveTo, .cubicCurveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo:
                path.addQuadCurve(to: points[1], control: points[0])
            case .closePath: path.closeSubpath()
            @unknown default: break
            }
        }
        return path
    }
}
