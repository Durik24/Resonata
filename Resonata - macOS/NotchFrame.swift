import AppKit
import SwiftUI

/// The notch's frame, silhouette and fills, animated as one unit.
///
/// Three things had to end up in one `Animatable` modifier:
///
/// 1. A plain `.frame(width:height:)` reports its *final* size to the parent
///    and renders the *animated* size centred in that slot, so an opening
///    panel started in the middle of its final area. An animatable modifier
///    re-runs its body with the interpolated size, so layout is real on
///    every frame.
/// 2. Even then, SwiftUI animates the view's *position* on its own, a frame
///    ahead of the layout-driven size — and the shape sat a few points below
///    the notch while it grew: the "little gap". Aligning to the top of a
///    constant outer frame *inside* this body sidesteps that: results of an
///    animatable body are applied directly, never re-animated, and the node
///    the parent places never changes size or position at all.
/// 3. The clip, the hit shape and the fills must use the *same* interpolated
///    radii as each other, so they are built here from the same numbers.
struct NotchFrame: ViewModifier, Animatable {
    var size: CGSize
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    /// Sideways shift of the shape from the window's centre. Animated with
    /// the width, so a pill that grows by `w` while shifting by `w / 2` keeps
    /// its left edge exactly still — the song peek sliding out to the right.
    var xOffset: CGFloat = 0
    /// What to draw under the content, given the current silhouette.
    var background: (NotchShape) -> AnyView

    var animatableData: AnimatablePair<AnimatablePair<AnimatablePair<CGFloat, CGFloat>,
                                                      AnimatablePair<CGFloat, CGFloat>>,
                                       CGFloat> {
        get {
            AnimatablePair(AnimatablePair(AnimatablePair(size.width, size.height),
                                          AnimatablePair(topRadius, bottomRadius)),
                           xOffset)
        }
        set {
            size = CGSize(width: newValue.first.first.first, height: newValue.first.first.second)
            topRadius = newValue.first.second.first
            bottomRadius = newValue.first.second.second
            xOffset = newValue.second
        }
    }

    func body(content: Content) -> some View {
        let shape = NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
        if FrameProbe.isOn { FrameProbe.record("\(size.width) \(size.height)") }
        return content
            // The content's size comes from this modifier, frame by frame.
            // Without this, SwiftUI *also* animated the content's own layout
            // from old to new on the same transaction — two animations of one
            // position that briefly disagree. Measured on the peek: the
            // artwork and bars drifted 6pt right mid-slide while the pill's
            // edge held still. Fades and transitions inside keep their own
            // animations; only this implicit one is removed.
            .transaction { $0.animation = nil }
            .frame(width: size.width, height: size.height)
            .background(background(shape))
            // Both states are laid out at their final size and clipped, so
            // the content is revealed by the growing box rather than
            // re-laid-out on every frame of it.
            .clipShape(shape)
            // Hit-test the silhouette only — the rest of the panel stays
            // click-through so you can still reach the menu bar beside it.
            .contentShape(shape)
            // Applied here, inside the animatable body, like everything else:
            // a shift animated separately from the width would let the left
            // edge wander while the pill grows.
            .offset(x: xOffset)
            // Fill whatever the window is and pin the shape to its top
            // centre. Not a fixed canvas size: the hosting view reports a
            // fixed frame as the content's intrinsic size, and AppKit then
            // refuses to shrink the window below it — the pill window stayed
            // 640 wide at the origin meant for a 303-wide one, 168pt right of
            // the notch. The window's size is the controller's business; the
            // controller never resizes it mid-animation, so this outer frame
            // is constant while anything inside moves.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Debug (`RESONATA_DEBUG_FRAMES=1`): the size the notch was laid out at on
/// every frame, with the time, so a stutter can be read off as numbers — a
/// gap in the times is a dropped frame, a step in the sizes is a jump.
/// `com.local.resonata.toggle` writes them to `RESONATA_DEBUG_DIR` a moment
/// after each open and close.
@MainActor
enum FrameProbe {
    static let isOn = ProcessInfo.processInfo.environment["RESONATA_DEBUG_FRAMES"] == "1"
    private static var lines: [String] = []
    private static var start = CACurrentMediaTime()

    static func begin() {
        lines = []
        start = CACurrentMediaTime()
        watchRunLoop()
    }

    private static var watching = false
    private static var woke = CACurrentMediaTime()
    private static var phases = ""

    /// Every pass of the main run loop that kept it busy for over 6 ms —
    /// work that a frame had to wait behind.
    private static func watchRunLoop() {
        guard !watching else { return }
        watching = true
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.allActivities.rawValue, true, 0
        ) { _, activity in
            MainActor.assumeIsolated {
                let now = CACurrentMediaTime()
                if activity == .afterWaiting {
                    woke = now
                    phases = ""
                } else if activity == .beforeWaiting {
                    if now - woke > 0.006 {
                        record(String(format: "busy %.1f ms%@", (now - woke) * 1000, phases))
                    }
                } else {
                    let name = activity == .beforeTimers ? "T" : activity == .beforeSources ? "S" : "?"
                    phases += String(format: " %@%.1f", name, (now - woke) * 1000)
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    static func record(_ what: String) {
        lines.append(String(format: "%7.1f  %@", (CACurrentMediaTime() - start) * 1000, what))
    }

    private static var count = 0

    static func write(tag: String) {
        count += 1
        let dir = ProcessInfo.processInfo.environment["RESONATA_DEBUG_DIR"] ?? NSTemporaryDirectory()
        try? lines.joined(separator: "\n").write(
            to: URL(fileURLWithPath: dir).appendingPathComponent("frames-\(count)-\(tag).txt"),
            atomically: true, encoding: .utf8)
    }
}
