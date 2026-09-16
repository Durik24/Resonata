import AppKit

/// Everything about *where* the physical notch is.
///
/// macOS 12+ exposes this through two properties:
///   - `safeAreaInsets.top` — the height of the notch (0 on non-notched displays)
///   - `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` — the usable menu-bar
///     strips either side of the notch. What's left in the middle *is* the notch.
/// Every tunable dimension, in one place. Change these, not the call sites.
enum NotchMetrics {
    /// Collapsed pill on a display with no physical notch, sized to match the
    /// real cutout *physically* rather than in points.
    ///
    /// Copying the point size across displays is the trap. This Mac's cutout is
    /// 209x38pt on a panel of roughly 5.9pt/mm; a 27" 1440p monitor runs about
    /// 4.3pt/mm, so the same 209pt covers ~49mm there against ~35mm on the
    /// laptop — a quarter wider, and it reads as a slab. 35mm at the monitor's
    /// density is ~152pt.
    ///
    /// Recalculate if you use a monitor of a different size or resolution:
    ///     points = 35mm x (horizontal pixels / display width in mm)
    static let fakeWidth: CGFloat = 152

    /// Physically this works out near 28pt, and the menu bar on that display is
    /// 30 — this is 2pt past it, so the pill hangs very slightly below the menu
    /// bar rather than sitting flush inside it. The panel is pinned to the top
    /// of the screen, so extra height only ever grows downward.
    static let fakeHeight: CGFloat = 32

    /// Extra collapsed width claimed for the artwork and the waveform.
    ///
    /// Sized so that once padding and inset come out, each strip beside the
    /// cutout is just wide enough for the artwork to fill it edge to edge.
    ///
    /// 94, not 100, because `topRadius` went to 0. That radius also set where
    /// the shape's body began — at 3 it inset the vertical sides by 3 points
    /// each, so the pill drew 6 points narrower than its own rect. Straight
    /// edges removed that inset, and this takes the 6 back.
    static let collapsedContentWidth: CGFloat = 94

    /// Height offset applied to the collapsed pill, relative to the notch.
    ///
    /// Negative on the laptop for a reason: `safeAreaInsets.top` is the menu
    /// bar height, which runs a couple of points past the bottom of the
    /// physical cutout. Drawing the pill at the full inset leaves a visible
    /// shoulder of black sticking out below the hardware — close, but not
    /// flush, which is exactly the "trochu větší než notch" effect.
    ///
    /// Careful with units here: this is in *points*, but pixel rows are what
    /// you actually see. This panel renders 2x and scales down, so one point is
    /// roughly 1.5 physical pixels — "three pixel rows" is about two points.
    static let collapsedExtraHeight: CGFloat = 0

    /// Pulls the artwork and waveform in from the outer edges of the collapsed
    /// pill, without changing the pill's own size. Raise to tuck them further
    /// toward the cutout.
    /// 4, down from 7, for the same reason the width changed: the contents used
    /// to be measured from a body edge that sat 3 points in. Without that inset
    /// they'd drift inward by 3 unless this drops to match.
    static let collapsedInset: CGFloat = 4

    /// Shifts the waveform further left, on its own. Applied as trailing
    /// padding, so it moves the wave without touching the artwork opposite it.
    static let waveformNudge: CGFloat = 0

    /// How much the notch grows on a beat, as a fraction of its size.
    ///
    /// Small on purpose. At 0.03 the collapsed pill gets about six points wider
    /// and one taller, which is enough to see and not enough to notice — the
    /// cutout appears to breathe. Past about 0.06 it starts to twitch instead,
    /// and reads as a rendering glitch rather than as the music.
    static let beatPulseScale: CGFloat = 0.03

    /// How much brighter the artwork colour wash gets on a beat, as a
    /// multiplier on its opacity. 1.0 would double it.
    static let beatWashBloom: Double = 0.5
}

extension NSScreen {

    var hasNotch: Bool {
        safeAreaInsets.top > 0
    }

    /// Notch height in points, faked on displays without one.
    ///
    /// Note this can exceed the menu bar height (24pt on a standard display),
    /// so the rounded bottom hangs slightly below the menu bar. That's the
    /// intended look — it's what a real notch does — but it does mean the pill
    /// overlaps the top of whatever window is underneath.
    var notchHeight: CGFloat {
        hasNotch ? safeAreaInsets.top : NotchMetrics.fakeHeight
    }

    /// Physical notch width in points.
    var notchWidth: CGFloat {
        guard let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea else {
            return NotchMetrics.fakeWidth
        }
        return frame.width - left.width - right.width
    }

    /// True when a window is covering this whole display.
    ///
    /// Asks the window server directly rather than inferring it from
    /// `visibleFrame`. The old `visibleFrame.maxY >= frame.maxY` test had two
    /// problems: it was read from the space-change notification, which arrives
    /// *before* the full-screen transition finishes, so it measured the old
    /// layout; and it reported true permanently for anyone who turns on
    /// "Automatically hide and show the menu bar".
    ///
    /// Only bounds and layer are read, so this needs no Screen Recording
    /// permission — that's required for window *titles*.
    var isShowingFullScreenApp: Bool {
        guard let primary = NSScreen.screens.first else { return false }

        // CGWindow bounds are top-left origin, anchored to the primary display;
        // NSScreen is bottom-left origin. Flip before comparing.
        let target = CGRect(
            x: frame.minX,
            y: primary.frame.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )

        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        return windows.contains { window in
            // Layer 0 is ordinary app windows. Our own panel sits far above it,
            // so we can't mistake ourselves for a full-screen app.
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let raw = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary)
            else { return false }

            let tolerance: CGFloat = 2
            return abs(bounds.minX - target.minX) < tolerance
                && abs(bounds.minY - target.minY) < tolerance
                && abs(bounds.width - target.width) < tolerance
                && abs(bounds.height - target.height) < tolerance
        }
    }

    var notchSize: CGSize {
        CGSize(width: notchWidth, height: notchHeight)
    }

    /// Stable identifier for this display. `NSScreen` objects are recreated on
    /// every configuration change, so a pinned choice has to be remembered by
    /// id rather than by holding on to the screen itself.
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// The screen to draw on: the notched one if it's connected, otherwise the
    /// display that owns the menu bar.
    ///
    /// Closing the lid removes the built-in screen from `screens`, so this
    /// falls through to the external display and the app draws a pill there
    /// instead; opening it again moves back. `screens.first` is the primary
    /// display — deliberately not `main`, which follows the key window and so
    /// would hop between monitors as you click around.
    static var notched: NSScreen? {
        screens.first(where: { $0.hasNotch }) ?? screens.first ?? main
    }
}
