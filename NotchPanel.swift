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
    private var mouseMonitors: [Any] = []
    private var hoverTimer: Timer?
    private var visibilityTimer: Timer?
    private var wasExpanded = false

    /// Whether a full-screen app owns the target display, as of the last
    /// visibility check. Cached because the check walks the window server's
    /// entire on-screen list, and the hover tick used to ask it 33 times a
    /// second — which is both wasteful and a place for the tick to stall.
    private var fullScreenCovered = false

    /// How far above the screen's top edge the hot zone extends.
    ///
    /// `NSRect.contains` excludes the rect's maximum edges, and a pointer flung
    /// at the notch comes to rest pinned against the top of the screen — where
    /// its y is *exactly* `frame.maxY`, the one row the test rejects. That was
    /// the "sometimes it doesn't notice me": it depended on whether the cursor
    /// had stopped one pixel short. Nothing can be above the screen, so the
    /// slack costs nothing.
    private static let topSlack: CGFloat = 40

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
        panel.contentView = NSHostingView(rootView: NotchView(model: model))
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

        // Hover, tracked from the pointer itself rather than from a SwiftUI
        // `.onHover` on the content.
        //
        // The view can't track its own hover reliably here: expanding resizes
        // the window, resizing rebuilds the hosting view's tracking areas, and
        // that emits a mouse-exit even though the pointer never moved. The
        // exit collapses the panel again, so the first hover appears to do
        // nothing and you have to hover a second time. Comparing the real
        // pointer location against a rect has no such feedback loop.
        //
        // Global monitors fire while another app is active — which is always,
        // since we're an .accessory app — and the local one covers the case
        // where we've taken focus. Mouse monitors need no special permission.
        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHover() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged], handler: handler
        ) {
            mouseMonitors.append(global)
        }
        let local = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged],
            handler: { event in handler(event); return event }
        )
        if let local { mouseMonitors.append(local) }

        // Polling the pointer is what actually drives hover; the monitors above
        // are only there to make it feel instant.
        //
        // Neither monitor can see the moment that matters. A *global* monitor
        // by definition doesn't receive events delivered to our own app — and
        // the instant the pointer crosses onto the panel, the event is ours, so
        // the monitor goes silent exactly when "entered" happens. The local
        // monitor doesn't cover it either: we're an .accessory app and never
        // become active, so we're not in the responder path. Reading
        // `NSEvent.mouseLocation` on a timer has no such blind spot.
        // 0.03 rather than 0.08: this interval is the worst-case lag between
        // the pointer arriving and the panel opening, and at 0.08 that delay
        // was doing as much to make the open feel slow as the animation was.
        // The tick itself is a rect test against `NSEvent.mouseLocation`.
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHover() }
        }

        // Full-screen state is polled too, and for the same reason the hover is:
        // the space-change notification fires at the *start* of the transition,
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

    /// Expanded whenever the pointer is inside the shape currently on screen.
    ///
    /// The rect deliberately differs by state: collapsed, only the pill itself
    /// counts, so the panel doesn't pop open from halfway across the menu bar;
    /// expanded, the whole expanded shape counts, so moving down onto the
    /// buttons doesn't close it under your cursor.
    private func updateHover() {
        guard let screen = targetScreen, !fullScreenCovered else { return }

        let size = model.isExpanded
            ? CGSize(width: NotchView.expandedWidth, height: model.expandedHeight)
            : CGSize(width: screen.notchSize.width
                        + (model.showsCollapsedContent
                            ? NotchMetrics.collapsedContentWidth : 0),
                     height: screen.notchSize.height + NotchMetrics.collapsedExtraHeight)

        let hot = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            // Origin is the bottom-left, so extra height grows upward, past
            // the top of the screen. See `topSlack`.
            height: size.height + Self.topSlack
        )

        let inside = hot.contains(NSEvent.mouseLocation)
        if model.isExpanded != inside { model.isExpanded = inside }
    }

    private func updateVisibility() {
        fullScreenCovered = targetScreen?.isShowingFullScreenApp ?? false
        apply(expanded: model.isExpanded, hasTrack: model.showsCollapsedContent)
    }

    private func apply(expanded: Bool, hasTrack: Bool) {
        guard let panel, let screen = targetScreen else { return }

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
        wasExpanded = expanded

        // Grow immediately — the SwiftUI spring needs the room to animate into,
        // and the extra area is transparent anyway. Shrink only once the
        // collapse has finished playing, or we'd clip our own animation.
        if expanded || !closingAfterExpand {
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
