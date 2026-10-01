import AppKit
import SwiftUI

/// The spectrum as a smooth filled wave, bass on the left, treble on the
/// right, in the album's colour.
///
/// Same approach as `SpectrumBars`: SwiftUI only hears about configuration;
/// a display link reshapes two Core Animation layers — a gradient fill masked
/// by the curve, and a brighter line along its top.
struct SpectrumWave: NSViewRepresentable {
    var source: AudioSpectrumSource?
    /// The album's accent colour; white when the cover has none.
    var color: Color?
    var isAnimating: Bool

    func makeNSView(context: Context) -> SpectrumWaveView { SpectrumWaveView() }

    func updateNSView(_ view: SpectrumWaveView, context: Context) {
        view.source = source
        view.setColor(color.map { NSColor($0) })
        view.isAnimating = isAnimating
    }
}

final class SpectrumWaveView: NSView {

    var source: AudioSpectrumSource?

    var isAnimating = false {
        didSet {
            guard isAnimating != oldValue else { return }
            updateLink()
            renderFrame()
        }
    }

    private let fill = CAGradientLayer()
    private let fillShape = CAShapeLayer()
    private let line = CAShapeLayer()
    private var link: CADisplayLink?

    /// Heights as drawn, eased toward the analyser's each frame so the curve
    /// glides between frames instead of snapping.
    private var shown: [CGFloat] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        fill.mask = fillShape
        // Bottom-left origin: colour at the crest, fading to nothing at the
        // baseline, so the wave sinks into the panel rather than sitting on it.
        fill.startPoint = CGPoint(x: 0.5, y: 1)
        fill.endPoint = CGPoint(x: 0.5, y: 0)
        line.fillColor = nil
        line.lineWidth = 1.5
        line.lineJoin = .round
        line.lineCap = .round
        layer?.addSublayer(fill)
        layer?.addSublayer(line)
        setColor(nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setColor(_ color: NSColor?) {
        let base = color ?? .white
        // A colourless cover gets a quieter white: full-strength white would
        // be the brightest thing in the panel.
        let strength: CGFloat = color == nil ? 0.6 : 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.colors = [base.withAlphaComponent(0.6 * strength).cgColor,
                       base.withAlphaComponent(0.05).cgColor]
        line.strokeColor = base.withAlphaComponent(0.85 * strength).cgColor
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds
        fillShape.frame = bounds
        line.frame = bounds
        CATransaction.commit()
        renderFrame()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLink()
    }

    private func updateLink() {
        let wanted = isAnimating && window != nil
        if wanted, link == nil {
            let link = displayLink(target: self, selector: #selector(tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
            link.add(to: .main, forMode: .common)
            self.link = link
        } else if !wanted, let link {
            link.invalidate()
            self.link = nil
        }
    }

    @objc private func tick(_ link: CADisplayLink) { renderFrame() }

    private func renderFrame() {
        let target = Self.levels(from: source?.bands ?? [], animating: isAnimating,
                                 at: CACurrentMediaTime())
        if shown.count != target.count { shown = target }
        for i in shown.indices { shown[i] += (target[i] - shown[i]) * 0.35 }

        let (open, closed) = Self.paths(for: shown, in: bounds)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.path = open
        fillShape.path = closed
        CATransaction.commit()
    }

    /// Wave heights, 0...1.
    ///
    /// The raw bands make a poor wave, for two reasons the first version of
    /// this showed. A loud mix puts every band between about 0.6 and 0.8, so
    /// the shape is a near-flat line; and music has far less energy up top,
    /// so the right third lay dead on the baseline. Three steps fix that:
    ///
    /// 1. Tilt the treble up — about 12 dB across the range, the usual
    ///    "pink" correction visualisers make so a balanced mix looks level.
    /// 2. Raise to a power, which pulls the quieter bands down further than
    ///    the loud ones, so peaks stand out from their neighbours.
    /// 3. Scale the frame so its peak sits near the top. Quiet passages get
    ///    less of a lift (the gain is capped), so loudness still shows.
    ///
    /// Then tapered to nothing at both ends, so the wave rises out of the
    /// baseline instead of starting and ending in mid-air.
    static func levels(from bands: [Float], animating: Bool, at time: TimeInterval) -> [CGFloat] {
        let count = bands.isEmpty ? 24 : bands.count
        let raw: [Double]
        if !animating {
            raw = Array(repeating: 0.06, count: count)            // at rest: a calm line
        } else if bands.isEmpty {
            raw = (0..<count).map { i in                           // no signal: a slow swell
                let x = Double(i)
                let travel: Double = sin(time * 1.6 - x * 0.42)
                let breathe: Double = sin(time * 0.55 + x * 0.17)
                return 0.45 + 0.35 * travel * breathe
            }
        } else {
            let span = Double(max(count - 1, 1))
            let shaped = bands.enumerated().map { i, band -> Double in
                let tilted = min(Double(max(band, 0)) + 0.22 * Double(i) / span, 1)
                return pow(tilted, 1.8)
            }
            let gain = 0.92 / max(shaped.max() ?? 0, 0.35)
            raw = shaped.map { $0 * gain }
        }
        return raw.enumerated().map { i, level in
            let edge = sin(.pi * (Double(i) + 0.5) / Double(count))
            return CGFloat(min(max(level, 0), 1) * pow(edge, 0.6))
        }
    }

    /// The curve through the levels, as an open line and as a closed shape
    /// down to the baseline. Catmull-Rom, so it passes through every band
    /// rather than approximating them; control points are kept between the
    /// baseline and the top, or a steep neighbour makes it dip below zero.
    static func paths(for levels: [CGFloat], in rect: CGRect) -> (CGPath, CGPath) {
        let open = CGMutablePath()
        guard levels.count > 1, rect.width > 0, rect.height > 0 else {
            return (open, open)
        }
        let baseline = rect.minY + 1
        let amplitude = rect.height - 2.5
        let step = rect.width / CGFloat(levels.count - 1)
        let points = levels.enumerated().map { i, level in
            CGPoint(x: rect.minX + CGFloat(i) * step, y: baseline + level * amplitude)
        }
        func clampY(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x, y: min(max(p.y, baseline), baseline + amplitude))
        }

        open.move(to: points[0])
        for i in 0..<(points.count - 1) {
            let p0 = points[max(i - 1, 0)], p1 = points[i]
            let p2 = points[i + 1], p3 = points[min(i + 2, points.count - 1)]
            let c1 = clampY(CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6))
            let c2 = clampY(CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
            open.addCurve(to: p2, control1: c1, control2: c2)
        }

        let closed = open.mutableCopy()!
        closed.addLine(to: CGPoint(x: points.last!.x, y: rect.minY))
        closed.addLine(to: CGPoint(x: points.first!.x, y: rect.minY))
        closed.closeSubpath()
        return (open, closed)
    }
}
