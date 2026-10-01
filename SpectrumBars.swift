import AppKit
import SwiftUI

/// Bars whose heights are the actual frequency content of what the machine is
/// playing.
///
/// Falls back to a synthetic bounce when there is no spectrum to draw — capture
/// permission not granted, or capture not started yet — so the pill still
/// reads as alive rather than broken.
///
/// A thin SwiftUI wrapper around `SpectrumBarsView`. The bars used to be a
/// `TimelineView` redrawing a `Canvas` thirty times a second, and that alone
/// was 4.5% CPU for three bars: every tick re-ran SwiftUI's view graph and
/// re-rasterised the canvas on the CPU. Now SwiftUI only hears about changes
/// of *configuration*; the animation itself never goes through it.
struct SpectrumBars: NSViewRepresentable {
    var source: AudioSpectrumSource?
    var barCount: Int = 3
    var isAnimating: Bool = true
    var tint: Color = .white
    var barWidth: CGFloat = 4
    var spacing: CGFloat = 3

    func makeNSView(context: Context) -> SpectrumBarsView { SpectrumBarsView() }

    func updateNSView(_ view: SpectrumBarsView, context: Context) {
        view.source = source
        view.configure(barCount: barCount, tint: NSColor(tint),
                       barWidth: barWidth, spacing: spacing)
        view.isAnimating = isAnimating
    }
}

/// One `CALayer` per bar, moved by a display link.
///
/// Each tick only sets a few layer frames, which the GPU composites — nothing
/// is redrawn. The link runs only while animating and only while on screen.
final class SpectrumBarsView: NSView {

    var source: AudioSpectrumSource?

    var isAnimating = false {
        didSet {
            guard isAnimating != oldValue else { return }
            updateLink()
            renderFrame()
        }
    }

    private var bars: [CALayer] = []
    private var barWidth: CGFloat = 4
    private var spacing: CGFloat = 3
    private var link: CADisplayLink?

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Purely decorative: clicks go to whatever is underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(barCount: Int, tint: NSColor, barWidth: CGFloat, spacing: CGFloat) {
        self.barWidth = barWidth
        self.spacing = spacing
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if bars.count != barCount {
            bars.forEach { $0.removeFromSuperlayer() }
            bars = (0..<barCount).map { _ in
                let bar = CALayer()
                layer?.addSublayer(bar)
                return bar
            }
        }
        for bar in bars {
            bar.backgroundColor = tint.cgColor
            bar.cornerRadius = barWidth / 2
        }
        CATransaction.commit()
        renderFrame()
    }

    override func layout() {
        super.layout()
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
            // The analyser has a new frame every ~21 ms; 30 Hz is all of them
            // a display at rest needs.
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
        guard !bars.isEmpty else { return }
        let levels = isAnimating
            ? Self.levels(from: source?.bands ?? [], count: bars.count, at: CACurrentMediaTime())
            : Array(repeating: 0.35, count: bars.count)
        let size = bounds.size
        let total = barWidth * CGFloat(bars.count) + spacing * CGFloat(bars.count - 1)
        var x = (size.width - total) / 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (bar, level) in zip(bars, levels) {
            // Never let a bar vanish: a quiet passage should read as quiet,
            // not as a rendering failure.
            let height = size.height * (isAnimating ? max(level, 0.16) : level)
            bar.frame = CGRect(x: x, y: (size.height - height) / 2, width: barWidth, height: height)
            x += barWidth + spacing
        }
        CATransaction.commit()
    }

    /// The heights to draw, 0...1, low frequency first: the analyser's bands
    /// averaged down to `count`, or the synthetic bounce when there are none.
    static func levels(from bands: [Float], count: Int, at time: TimeInterval) -> [CGFloat] {
        guard count > 0 else { return [] }
        guard !bands.isEmpty else {
            return (0..<count).map { synthetic(at: time, bar: $0) }
        }
        guard bands.count > count else { return bands.map { CGFloat($0) } }

        let per = Double(bands.count) / Double(count)
        return (0..<count).map { i in
            let lo = Int(Double(i) * per)
            let hi = min(max(lo + 1, Int(Double(i + 1) * per)), bands.count)
            let slice = bands[lo..<hi]
            return CGFloat(slice.reduce(0, +) / Float(slice.count))
        }
    }

    /// The old fake waveform, kept as the no-signal fallback. Offsetting each
    /// bar's phase is what makes it read as a waveform rather than bars
    /// pulsing in unison.
    private static func synthetic(at time: TimeInterval, bar: Int) -> CGFloat {
        let phase = time * 3.2 + Double(bar) * 0.9
        return 0.35 + 0.65 * abs(sin(phase))
    }
}
