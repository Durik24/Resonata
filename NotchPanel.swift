import AppKit
import Combine
import SwiftUI

/// A borderless, transparent, always-on-top panel.
///
/// The two settings that matter most:
///   - `level = .screenSaver` puts it above the menu bar. `.statusBar` is *not*
///     high enough; you'll end up drawing underneath the clock.
///   - `.nonactivatingPanel` + `canBecomeMain = false` means clicking it never
///     steals focus from whatever app you're actually using.
final class NotchPanel: NSPanel {

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = false
        level = .screenSaver
        collectionBehavior = [
            .canJoinAllSpaces,      // follow you across desktops
            .stationary,            // don't slide during Mission Control
            .ignoresCycle           // stay out of Cmd-Tab
        ]
        // Deliberately *not* .fullScreenAuxiliary: that's what keeps a panel
        // visible on top of full-screen apps, and we want the opposite. The
        // controller also hides it explicitly, since this flag alone isn't
        // reliable across every kind of full-screen window.
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Called for every mouse-down that reaches this window.
    ///
    /// Opening is handled here rather than with a SwiftUI tap gesture. A tap
    /// recogniser wants a down and an up on the same view with no drift in
    /// between, on a subtree that redraws thirty times a second with a scale
    /// animation on it — and in practice it fired about one click in ten.
    /// When collapsed, the window is exactly the pill, so a mouse-down anywhere
    /// in it *is* a click on the pill. No recognition needed.
    var onMouseDown: ((NSPoint) -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            if Self.debugClick {
                NSLog("click: mouse-down reached the panel at %@", NSStringFromPoint(event.locationInWindow))
            }
            onMouseDown?(event.locationInWindow)
        }
        super.sendEvent(event)
    }

    /// `RESONATA_DEBUG_CLICK=1` logs every mouse-down the panel receives.
    static let debugClick = ProcessInfo.processInfo.environment["RESONATA_DEBUG_CLICK"] == "1"
}

/// Hosting view that treats the first click as a click.
///
/// A window that isn't key gets its first mouse-down as "activate me" and the
/// click itself is swallowed, unless the view under it opts in. This panel is
/// never key — it's an accessory app and a non-activating panel — so without
/// this the first click on the pill would do nothing and the second would
/// open it, which is indistinguishable from a bug.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the panel and keeps it glued to the notch across display changes.
@MainActor
final class NotchPanelController {

    /// The panel is always sized to the *largest* state. The SwiftUI content
    /// draws the smaller collapsed shape inside it and leaves the rest clear —
    /// resizing an NSWindow every frame looks terrible, animating a SwiftUI
    /// shape inside a fixed window looks like Apple did it.
    static let canvasWidth: CGFloat = 640
    /// Room for the expanded panel at its tallest — with lyrics — plus the
    /// beat pulse, which scales it a little past that.
    static let canvasHeight: CGFloat = 280

    private var panel: NotchPanel?
    private let model: NotchModel
    private var observer: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()
    private var shrink: DispatchWorkItem?
    private var clickMonitors: [Any] = []
    private var visibilityTimer: Timer?
    private var wasExpanded = false
    private var wasShowingContent = false

    /// Whether a full-screen app owns the target display, as of the last
    /// visibility check. Cached because the check walks the window server's
    /// entire on-screen list, so it is asked on the visibility timer rather
    /// than on every event.
    private var fullScreenCovered = false

    /// Display the user pinned via the switch button, if any. Stored as an id
    /// because NSScreen instances are replaced on every display change.
    private var pinnedScreenID: CGDirectDisplayID?

    init(model: NotchModel) {
        self.model = model
    }

    func show() {
        guard let screen = targetScreen else { return }

        adoptGeometry(of: screen)
        model.switchScreen = { [weak self] in self?.moveToNextScreen() }

        let panel = NotchPanel(contentRect: frame(for: screen))
        panel.contentView = FirstClickHostingView(rootView: NotchView(model: model))
        panel.onMouseDown = { [weak self] location in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.model.isExpanded {
                    // Collapsed, the window is exactly the pill: any click is
                    // a click on it.
                    //
                    // Set on the next run-loop pass, not inside the event
                    // dispatch. Published from within `sendEvent`, the change
                    // resized the window at once but SwiftUI didn't re-render
                    // for seconds — until some unrelated publish woke it. From
                    // outside the dispatch it renders on the next frame; the
                    // explicit layout below makes sure of it.
                    if NotchPanel.debugClick { NSLog("click: EXPAND") }
                    self.setExpanded(true)
                    if NotchPanel.debugClick { self.debugSnapshots() }
                } else if !self.expandedShapeRect.contains(location) {
                    // Expanded, the window is a 640x280 canvas and the panel
                    // is drawn in the top-centre of it. A click in the
                    // transparent margin is ours, so the global monitor never
                    // sees it — but to the user it is plainly a click outside
                    // the panel, and it should close it like one.
                    if NotchPanel.debugClick { NSLog("click: in the margin -> COLLAPSE") }
                    self.setExpanded(false)
                }
            }
        }
        self.panel = panel
        // Starts hidden: nothing is playing yet at launch.
        updateVisibility()

        // The window is only ever as big as the shape currently drawn in it.
        //
        // A fixed 640x220 canvas is the obvious implementation and it's wrong:
        // NSHostingView fills the whole window, so AppKit routes every click in
        // that rect to us and the menu bar underneath goes dead. SwiftUI's
        // `.contentShape` doesn't help — it only decides which *SwiftUI* view
        // gets the event, long after the window already swallowed it.
        //
        // Both values are taken from the publishers rather than read back off
        // the model: `@Published` fires on *willSet*, so inside a sink the
        // property still holds its previous value. Reading `model.isExpanded`
        // here would see `false` on the way into an expand and delay the grow
        // by a whole shrink interval.
        // Sizing follows "is there something to show", which idle turns off —
        // so the pill shrinks back to the cutout when the music stops.
        let collapsedContentVisible = model.$track.map { $0 != nil }
            .combineLatest(model.$isIdle)
            .map { hasTrack, idle in hasTrack && !idle }
            .removeDuplicates()

        model.$isExpanded
            .removeDuplicates()
            .combineLatest(collapsedContentVisible)
            // Deliver on the next run-loop pass, never inside the publish.
            //
            // `@Published` fires on *willSet*. Resizing the window right there
            // made the hosting view lay out and render SwiftUI while
            // `isExpanded` still read its old value — so SwiftUI drew the
            // collapsed pill, cleared its dirty flag, and believed it was up
            // to date. Nothing re-rendered it until something else published:
            // with music playing, the spectrum's next tick a frame later;
            // idle, the ten-second re-sync. That was the "opens after 8s".
            .receive(on: DispatchQueue.main)
            .sink { [weak self] expanded, hasTrack in
                self?.apply(expanded: expanded, hasTrack: hasTrack)
            }
            .store(in: &cancellables)

        // Plugging in a monitor, changing resolution, or waking from sleep all
        // fire this. Without it the panel drifts off the notch.
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }

        // Opening is a click on the pill, handled in the view. Closing is a
        // click anywhere else, handled here: a *global* monitor by definition
        // never sees events delivered to our own windows, so every click it
        // reports is, by construction, a click outside the panel. No rect
        // test, no pointer tracking, nothing that can disagree with what the
        // user actually did.
        let outsideClick: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.isExpanded else { return }
                if NotchPanel.debugClick { NSLog("click: outside -> COLLAPSE") }
                self.setExpanded(false)
            }
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
            handler: outsideClick
        ) {
            clickMonitors.append(monitor)
        }

        // Full-screen state is polled: the space-change notification fires at
        // the *start* of the transition,
        // when the window hasn't resized yet, so a single check right then sees
        // the pre-transition layout and nothing ever re-checks it.
        visibilityTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateVisibility() }
        }

        // Entering or leaving full screen creates and destroys a space, which
        // is what this fires on — cheaper and more precise than polling.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateVisibility() }
        }
    }

    /// Hidden entirely when there's nothing to show, or when a full-screen app
    /// owns the display.
    ///
    /// Hiding the *window* matters — fading the content to zero opacity, which
    /// is what the view used to do, still leaves an empty black pill sitting on
    /// the menu bar.
    /// Fires when a display is added, removed, or reconfigured — closing the
    /// lid, opening it, plugging in a monitor, changing resolution, waking.
    ///
    /// The target screen can change identity here, not just move, so the view's
    /// geometry has to be refreshed before repositioning. Collapse first: a
    /// panel left expanded across a display switch strands itself at the old
    /// size on a screen that may not even have a notch.
    private func screensChanged() {
        guard let screen = targetScreen else { return }
        model.isExpanded = false
        adoptGeometry(of: screen)
        reposition()
        updateVisibility()
    }

    /// The display to draw on: the pinned one if it's still connected, else the
    /// automatic choice — an external monitor when there is one, otherwise the
    /// built-in screen. See `NSScreen.preferred`.
    ///
    /// A display change (`screensChanged`) re-reads this, which is what makes
    /// the notch follow a monitor as it's plugged in and unplugged without
    /// anything else having to notice.
    private var targetScreen: NSScreen? {
        if let pinnedScreenID,
           let pinned = NSScreen.screens.first(where: { $0.displayID == pinnedScreenID }) {
            return pinned
        }
        return NSScreen.preferred
    }

    /// Moves the notch to the next display in the list, wrapping around.
    func moveToNextScreen() {
        let screens = NSScreen.screens
        guard screens.count > 1 else { return }

        let currentID = targetScreen?.displayID
        let index = screens.firstIndex { $0.displayID == currentID } ?? 0
        pinnedScreenID = screens[(index + 1) % screens.count].displayID

        // Same teardown as a display change: collapse, re-read geometry for the
        // new screen, move the window. The pill's size differs between a real
        // cutout and a faked one, so the geometry has to be refreshed.
        screensChanged()
    }

    private func adoptGeometry(of screen: NSScreen) {
        if model.notchSize != screen.notchSize { model.notchSize = screen.notchSize }
        if model.hasRealNotch != screen.hasNotch { model.hasRealNotch = screen.hasNotch }
        let multiple = NSScreen.screens.count > 1
        if model.canSwitchScreens != multiple { model.canSwitchScreens = multiple }
    }

    /// Applies an expand/collapse from outside the current event dispatch and
    /// makes the hosting view lay out at once.
    ///
    /// Published from *within* an event handler — `sendEvent`, or a monitor
    /// callback — the change resized the window immediately but SwiftUI did
    /// not re-render for seconds, until some unrelated publish woke it. From
    /// the next run-loop pass it renders on the next frame, and the explicit
    /// layout removes any remaining doubt.
    private func setExpanded(_ expanded: Bool) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.model.isExpanded != expanded else { return }
                self.model.isExpanded = expanded
                self.panel?.contentView?.needsLayout = true
                self.panel?.contentView?.layoutSubtreeIfNeeded()
                self.panel?.displayIfNeeded()
            }
        }
    }

    /// Debug: photograph our own content view at fixed delays after an open,
    /// and log the window's frame and visibility at each. Shows whether the
    /// app has *drawn* the expanded panel when it thinks it has — the window
    /// is ours, so this needs no permission.
    private func debugSnapshots() {
        let dir = ProcessInfo.processInfo.environment["RESONATA_DEBUG_DIR"] ?? NSTemporaryDirectory()
        let t0 = CFAbsoluteTimeGetCurrent()
        let tag = Int(t0) % 1000
        for delay in [0.1, 0.5, 1.0, 2.0, 3.0, 4.0, 6.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let panel = self.panel, let view = panel.contentView else { return }
                    let dt = CFAbsoluteTimeGetCurrent() - t0
                    NSLog("snap +%.2fs: expanded=%d frame=%@ visible=%d onScreen=%d occlusion=%lu",
                          dt, self.model.isExpanded ? 1 : 0, NSStringFromRect(panel.frame),
                          panel.isVisible ? 1 : 0, panel.isOnActiveSpace ? 1 : 0,
                          panel.occlusionState.rawValue)
                    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        let url = URL(fileURLWithPath: dir).appendingPathComponent(String(format: "snap-%03d-%.1fs.png", tag, delay))
                        try? png.write(to: url)
                    }
                }
            }
        }
    }

    /// Where the expanded panel is drawn, in window coordinates: top-centre
    /// of the canvas, the size the view draws it at.
    private var expandedShapeRect: NSRect {
        let width = NotchView.expandedWidth
        let height = model.expandedHeight
        return NSRect(x: (Self.canvasWidth - width) / 2,
                      y: Self.canvasHeight - height,
                      width: width, height: height)
    }

    private func updateVisibility() {
        fullScreenCovered = targetScreen?.isShowingFullScreenApp ?? false
        apply(expanded: model.isExpanded, hasTrack: model.showsCollapsedContent)
    }

    private func apply(expanded: Bool, hasTrack: Bool) {
        guard let panel, targetScreen != nil else { return }

        // Always present, playing or not. With a real notch the collapsed shape
        // is exactly the hardware cutout, so an idle notch is indistinguishable
        // from the bezel — nothing to hide. Full screen is the one exception.
        if fullScreenCovered {
            if panel.isVisible { panel.orderOut(nil) }
        } else if !panel.isVisible {
            panel.orderFrontRegardless()
        }

        shrink?.cancel()

        // The delayed resize is *only* for closing after an expand.
        //
        // Treating every collapsed state as "shrink later" meant a track
        // starting while collapsed left the window at its old narrow width for
        // half a second: the pill's content widened into a window that hadn't,
        // clipped, and then the window snapped out to catch up. That snap is
        // the jump you see when you hit play in Spotify.
        let closingAfterExpand = wasExpanded && !expanded
        // The pill narrowing when playback stops is a shrink too. Resizing the
        // window first moved its origin to the right while the content was
        // still drawn wide — the pill visibly jumped sideways, then shrank.
        let losingContent = !expanded && wasShowingContent && !hasTrack
        wasExpanded = expanded
        wasShowingContent = hasTrack

        // Grow immediately — the SwiftUI spring needs the room to animate into,
        // and the extra area is transparent anyway. Shrink only once the
        // collapse has finished playing, or we'd clip our own animation.
        if expanded || !(closingAfterExpand || losingContent) {
            reposition(expanded: expanded, hasTrack: hasTrack)
        } else {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.reposition(expanded: false, hasTrack: hasTrack)
                }
            }
            shrink = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
        }
    }

    private func reposition() {
        reposition(expanded: model.isExpanded, hasTrack: model.showsCollapsedContent)
    }

    private func reposition(expanded: Bool, hasTrack: Bool) {
        guard let panel, let screen = targetScreen else { return }
        panel.setFrame(frame(for: screen, expanded: expanded, hasTrack: hasTrack),
                       display: true)
    }

    private func frame(
        for screen: NSScreen,
        expanded: Bool = false,
        hasTrack: Bool = false
    ) -> NSRect {
        let size = expanded
            ? CGSize(width: Self.canvasWidth, height: Self.canvasHeight)
            : CGSize(width: screen.notchSize.width
                        + (hasTrack ? NotchMetrics.collapsedContentWidth : 0),
                     height: screen.notchSize.height + NotchMetrics.collapsedExtraHeight)

        // NSScreen coordinates are global and bottom-left origin, so "top of the
        // screen" is maxY and we subtract the panel height to get the origin.
        return NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }
}
