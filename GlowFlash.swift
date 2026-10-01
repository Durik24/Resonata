import AppKit
import SwiftUI

/// The flash: the accent wash, brighter, fading out over a third of a
/// second as each new line of lyrics begins (`LyricPulse`).
///
/// Done in Core Animation because the SwiftUI version — animating the wash's
/// opacity — re-rendered the whole notch for the length of every flash, which
/// at a flash twice a second doubled the app's CPU (4.5% → 8.7%). A
/// `CABasicAnimation` runs in the render server: once added, the app does no
/// work at all until the next one.
struct GlowFlash: NSViewRepresentable {
    var shape: NotchShape
    var color: Color?
    var expanded: Bool
    /// Counts up once per new lyric line; each change is one flash.
    var pulse: Int

    func makeNSView(context: Context) -> GlowFlashView { GlowFlashView() }

    func updateNSView(_ view: GlowFlashView, context: Context) {
        view.update(shape: shape, color: color.map { NSColor($0) }, expanded: expanded)
        view.pulse(pulse)
    }
}

final class GlowFlashView: NSView {
    private let gradient = CAGradientLayer()
    private let mask = CAShapeLayer()
    private var shape = NotchShape()
    private var lastPulse: Int?

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        gradient.opacity = 0
        gradient.mask = mask
        // Unit space with the origin at the bottom left: top-leading to
        // bottom-trailing, the same diagonal as the SwiftUI wash beneath.
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        gradient.locations = [0, 0.45, 1]
        layer?.addSublayer(gradient)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(shape: NotchShape, color: NSColor?, expanded: Bool) {
        self.shape = shape
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let color {
            // The SwiftUI wash's stops, scaled by the bloom strength: drawn on
            // top of it at full opacity, this is the wash at its brightest.
            let bloom = CGFloat(NotchMetrics.flashBloom)
            let stops: [CGFloat] = expanded ? [0.55, 0.16, 0] : [0.38, 0.18, 0.06]
            gradient.colors = stops.map { color.withAlphaComponent($0 * bloom).cgColor }
            gradient.isHidden = false
        } else {
            gradient.isHidden = true
        }
        CATransaction.commit()
        layoutLayers()
    }

    /// Flashes once per new pulse number. The first value seen is only
    /// recorded: appearing on screen is not a new line.
    func pulse(_ count: Int) {
        defer { lastPulse = count }
        guard let lastPulse, count != lastPulse, !gradient.isHidden else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.32
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        gradient.add(fade, forKey: "pulse")
    }

    override func layout() {
        super.layout()
        layoutLayers()
    }

    /// Clipped to the notch silhouette by its own mask rather than trusting
    /// SwiftUI's clip to reach into a platform view. The shape's path is in
    /// SwiftUI's top-left space; the layer's origin is bottom-left.
    private func layoutLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        mask.frame = bounds
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: bounds.height)
        mask.path = shape.path(in: bounds).cgPath.copy(using: &flip)
        CATransaction.commit()
    }
}
