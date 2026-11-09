import AppKit
import SwiftUI

/// The collapsed pill's bars: moving while something plays, at rest when not.
/// The motion is made up — see `Motion` — because Resonata doesn't listen to
/// the computer's sound.
///
/// A thin SwiftUI wrapper around `MusicBarsView`. The bars used to be a
/// `TimelineView` redrawing a `Canvas` thirty times a second, and that alone
/// was 4.5% CPU for three bars: every tick re-ran SwiftUI's view graph and
/// re-rasterised the canvas on the CPU. Now SwiftUI only hears about changes
/// of *configuration*; the animation itself never goes through it.
struct MusicBars: NSViewRepresentable {
    var barCount: Int = 3
    var isAnimating: Bool = true
    var tint: Color = .white
    var barWidth: CGFloat = 4
    var spacing: CGFloat = 3

    func makeNSView(context: Context) -> MusicBarsView { MusicBarsView() }

    func updateNSView(_ view: MusicBarsView, context: Context) {
        view.configure(barCount: barCount, tint: NSColor(tint),
                       barWidth: barWidth, spacing: spacing)
        view.isAnimating = isAnimating
    }
}

/// One `CALayer` per bar, moved by a display link.
///
/// Each tick only sets a few layer frames, which the GPU composites — nothing
/// is redrawn. The link runs only while animating and only while on screen.
final class MusicBarsView: NSView {

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
            // Slow, smooth motion: 30 Hz is plenty.
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
            ? Self.levels(count: bars.count, at: CACurrentMediaTime())
            : Array(repeating: 0.35, count: bars.count)
        let size = bounds.size
        let total = barWidth * CGFloat(bars.count) + spacing * CGFloat(bars.count - 1)
        var x = (size.width - total) / 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (bar, level) in zip(bars, levels) {
            // Never let a bar vanish to nothing.
            let height = size.height * (isAnimating ? max(level, 0.16) : level)
            bar.frame = CGRect(x: x, y: (size.height - height) / 2, width: barWidth, height: height)
            x += barWidth + spacing
        }
        CATransaction.commit()
    }

    /// The heights to draw, 0...1. Bars sit further apart in `Motion`'s
    /// phase than the wave's points, so three of them don't move as one.
    static func levels(count: Int, at time: TimeInterval) -> [CGFloat] {
        (0..<count).map { CGFloat(0.2 + 0.8 * Motion.level($0 * 3, at: time)) }
    }
}
