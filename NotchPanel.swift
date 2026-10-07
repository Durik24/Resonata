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
        // The panel is black whatever the system appearance; text fields in
        // the notes page need to draw as on a dark background — light text,
        // a light caret — even when the Mac is in light mode.
        appearance = NSAppearance(named: .darkAqua)
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

    /// ⌘X, ⌘C, ⌘V, ⌘A, ⌘Z and ⇧⌘Z in the notes.
    ///
    /// In a normal app these come from the Edit menu's key equivalents.
    /// Resonata has no menu bar, so nothing would turn ⌘V into "paste" —
    /// typing works in a text field here, pasting silently doesn't. This sends
    /// the same actions down the responder chain the menu would have.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let action: Selector?
        switch (modifiers, key) {
        case (.command, "x"): action = #selector(NSText.cut(_:))
        case (.command, "c"): action = #selector(NSText.copy(_:))
        case (.command, "v"): action = #selector(NSText.paste(_:))
        case (.command, "a"): action = #selector(NSText.selectAll(_:))
        case (.command, "z"): action = Selector(("undo:"))
        case ([.command, .shift], "z"): action = Selector(("redo:"))
        default: action = nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// Called for every mouse-down that reaches this window.
    ///
    /// Opening is handled here rather than with a SwiftUI tap gesture. A tap
    /// recogniser wants a down and an up on the same view with no drift in
    /// between, on a subtree that redraws thirty times a second with a scale
    /// animation on it — and in practice it fired about one click in ten.
    /// When collapsed, the window is exactly the pill, so a mouse-down anywhere
    /// in it *is* a click on the pill. No recognition needed.
    var onMouseDown: ((NSPoint) -> Void)?
    /// Right-click, or control-click: the app's menu.
    var onContextMenu: ((NSEvent) -> Void)?
    /// Scrolling over the notch: the volume, or swipes.
    var onScroll: ((NSEvent) -> Void)?
    /// Whether a scroll is the notch's (`onScroll`) or the page's under the
    /// pointer — a list of to-dos has to scroll like any list.
    var takesScroll: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .rightMouseDown:
            onContextMenu?(event)
            return
        case .leftMouseDown where event.modifierFlags.contains(.control):
            onContextMenu?(event)
            return
        case .leftMouseDown:
            if Self.debugClick {
                NSLog("click: mouse-down reached the panel at %@", NSStringFromPoint(event.locationInWindow))
            }
            onMouseDown?(event.locationInWindow)
        case .scrollWheel where takesScroll?(event) ?? true:
            onScroll?(event)
            return
        default:
            break
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

    /// The pointer moved over this window, entered it or left it. For
    /// hover-to-open, which then asks where the pointer is on screen.
    var onPointer: (() -> Void)?

    private var pointerTracking: NSTrackingArea?

    /// One tracking area over the whole view. `.inVisibleRect` keeps it
    /// matched to the window as the window resizes; `.activeAlways` because
    /// this window is never key, and the default only tracks in key windows.
    /// It reports only while the pointer is over *this* window — nothing
    /// watches the mouse anywhere else.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved,
                                            .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onPointer?()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onPointer?()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointer?()
    }
}

/// A menu item that runs a closure, so the controller needn't be an NSObject.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}

/// Owns the panel and keeps it glued to the notch across display changes.
@MainActor
final class NotchPanelController {

    /// The panel is always sized to the *largest* state. The SwiftUI content
    /// draws the smaller collapsed shape inside it and leaves the rest clear —
    /// resizing an NSWindow every frame looks terrible, animating a SwiftUI
    /// shape inside a fixed window looks like Apple did it.
    static let canvasWidth: CGFloat = 680
    /// Room for the expanded panel, plus a little to spare.
    static let canvasHeight: CGFloat = 280

    private var panel: NotchPanel?
    private let model: NotchModel
    private var observer: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()
    private var shrink: DispatchWorkItem?
    private var clickMonitors: [Any] = []
    private var visibilityTimer: Timer?

    /// Whether a full-screen app owns the target display, as of the last
    /// visibility check. Cached because the check walks the window server's
    /// entire on-screen list, so it is asked on the visibility timer rather
    /// than on every event.
    private var fullScreenCovered = false

    /// Display the user pinned via the switch button, if any. Stored as an id
    /// because NSScreen instances are replaced on every display change.
    private var pinnedScreenID: CGDirectDisplayID?

    /// Hides the volume meter a moment after the last scroll.
    private var volumeHide: DispatchWorkItem?

    /// Hover state — see `pointerMoved(to:)`.
    private var pointerInside = false
    private var hoverTask: Task<Void, Never>?
    /// Watches the pointer *outside* our window, only while it's on the notch
    /// — see `pointerMoved(to:)`.
    private var leaveMonitor: Any?
    /// The song peek on show is the hover preview, not a song change — so
    /// leaving the notch takes it away again.
    private var hoverPeeking = false

    /// The swipe in progress on the notch — see `swipe(_:)`.
    private var swipeTravel = CGSize.zero
    private var swipeDone = false

    /// How long the pointer has to rest on the notch before it opens, so
    /// passing over it on the way to the menu bar doesn't.
    static let hoverDwell: Duration = .milliseconds(300)
    /// How long after the pointer leaves before the panel closes — enough to
    /// forgive overshooting the edge by a hair.
    static let hoverLeaveDelay: Duration = .milliseconds(100)

    init(model: NotchModel) {
        self.model = model
    }

    func show() {
        guard let screen = targetScreen else { return }

        adoptGeometry(of: screen)
        model.switchScreen = { [weak self] in self?.moveToNextScreen() }
        model.close = { [weak self] in self?.setExpanded(false) }

        let panel = NotchPanel(contentRect: frame(for: screen))
        let hosting = FirstClickHostingView(rootView: NotchView(model: model))
        // The controller owns the window's size; the hosting view must not.
        //
        // By default an NSHostingView sizes its window to SwiftUI's content.
        // With the notch shape animating *through layout*, the content's
        // reported size changes on every frame — and the window followed it,
        // anchored at its left edge: mid-close the window became 259x78 at
        // x=750, the pill was drawn centred in *that*, and so it slid right
        // and then snapped back under the notch at the deferred shrink.
        hosting.sizingOptions = []
        hosting.onPointer = { [weak self] in
            MainActor.assumeIsolated { self?.pointerMoved(to: NSEvent.mouseLocation) }
        }
        panel.contentView = hosting
        panel.onMouseDown = { [weak self] location in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.model.isExpanded {
                    // Only a click on the pill itself. The window is usually
                    // exactly the pill, but not always: during a peek it's
                    // wider on the left than the shape, and for a moment after
                    // closing it's still the panel's size.
                    guard self.pillRect.insetBy(dx: -2, dy: -2).contains(location) else { return }
                    //
                    // Set on the next run-loop pass, not inside the event
                    // dispatch. Published from within `sendEvent`, the change
                    // resized the window at once but SwiftUI didn't re-render
                    // for seconds — until some unrelated publish woke it. From
                    // outside the dispatch it renders on the next frame; the
                    // explicit layout below makes sure of it.
                    if NotchPanel.debugClick { NSLog("click: EXPAND") }
                    self.setExpanded(true)
                    if NotchPanel.debugClick { self.debugSnapshots(tag: "open") }
                } else if !self.expandedShapeRect.contains(location) {
                    // Expanded, the window is a 680x280 canvas and the panel
                    // is drawn in the top-centre of it. A click in the
                    // transparent margin is ours, so the global monitor never
                    // sees it — but to the user it is plainly a click outside
                    // the panel, and it should close it like one.
                    if NotchPanel.debugClick { NSLog("click: in the margin -> COLLAPSE") }
                    self.setExpanded(false)
                    if NotchPanel.debugClick { self.debugSnapshots(tag: "close") }
                }
            }
        }
        panel.onContextMenu = { [weak self] event in
            MainActor.assumeIsolated { self?.showMenu(for: event) }
        }
        panel.takesScroll = { [weak self] event in
            MainActor.assumeIsolated { self?.takesScroll(event) ?? true }
        }
        panel.onScroll = { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if Preferences.openMode == .nook {
                    self.swipe(event)
                } else {
                    self.scrollVolume(event)
                }
            }
        }
        self.panel = panel
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
        // The volume meter shows in the pill's wing, so it widens the pill
        // too — even an idle one. Mirrors `NotchModel.showsCollapsedContent`.
        let collapsedContentVisible = model.$track.map { $0 != nil }
            .combineLatest(model.$isIdle, model.$volumeLevel)
            .map { hasTrack, idle, volume in (hasTrack && !idle) || volume != nil }
            .removeDuplicates()

        model.$isExpanded
            .removeDuplicates()
            .combineLatest(collapsedContentVisible, model.$peeking.removeDuplicates(),
                           model.$hovering.removeDuplicates())
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
            .sink { [weak self] expanded, hasTrack, peeking, hovering in
                self?.apply(expanded: expanded, hasTrack: hasTrack, peeking: peeking,
                            hovering: hovering)
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
                if NotchPanel.debugClick { self.debugSnapshots(tag: "close") }
            }
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
            handler: outsideClick
        ) {
            clickMonitors.append(monitor)
        }

        // Debug: `com.local.resonata.toggle` opens or closes the panel from
        // outside, so the open can be driven and photographed from a script.
        if NotchPanel.debugClick {
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.local.resonata.toggle"), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let opening = !self.model.isExpanded
                    self.setExpanded(opening)
                    self.debugSnapshots(tag: opening ? "open" : "close")
                }
            }
        }

        // Debug: `com.local.resonata.snap` photographs the panel now, tagged
        // with the notification's object — for states no click produces.
        if NotchPanel.debugClick {
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.local.resonata.snap"), object: nil, queue: .main
            ) { [weak self] note in
                let tag = (note.object as? String) ?? "snap"
                MainActor.assumeIsolated { self?.debugSnapshots(tag: tag) }
            }
        }

        // Debug: `com.local.resonata.hover` with "in" or "out" plays the
        // pointer arriving on the notch or leaving it.
        if NotchPanel.debugClick {
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.local.resonata.hover"), object: nil, queue: .main
            ) { [weak self] note in
                let arriving = (note.object as? String) == "in"
                MainActor.assumeIsolated {
                    guard let self, let shape = self.shapeOnScreen else { return }
                    self.pointerMoved(to: arriving ? NSPoint(x: shape.midX, y: shape.midY)
                                                   : NSPoint(x: shape.midX, y: shape.minY - 200))
                }
            }
        }

        // Debug: `com.local.resonata.settings` opens the settings window.
        if NotchPanel.debugClick {
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.local.resonata.settings"), object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { SettingsWindowController.shared.show() }
            }
        }

        // Debug: `com.local.resonata.playpause` toggles playback in the
        // current track's player, so idle states can be reproduced from a
        // script.
        if NotchPanel.debugClick {
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.local.resonata.playpause"), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let source = self?.model.track?.source else { return }
                    transport(.playPause, in: source)
                }
            }
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

    // MARK: Menu and volume

    /// Right-click menu: the only way to quit an app with no Dock icon and
    /// no menu bar, plus the two settings that otherwise live elsewhere.
    private func showMenu(for event: NSEvent) {
        guard let view = panel?.contentView else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false

        if NSScreen.screens.count > 1 {
            menu.addItem(ClosureMenuItem("Přepnout na další displej") { [weak self] in
                self?.moveToNextScreen()
            })
        }
        menu.addItem(ClosureMenuItem("Nastavení…") { SettingsWindowController.shared.show() })
        let login = ClosureMenuItem("Spouštět po přihlášení") {
            LoginItem.set(!LoginItem.isEnabled)
        }
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Ukončit Resonata") { NSApp.terminate(nil) })

        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    private func scrollVolume(_ event: NSEvent) {
        // A trackpad keeps sending "momentum" events after the fingers lift.
        // Following them sends the volume coasting on for a second after you
        // stopped, so only the fingers' own movement counts.
        guard event.momentumPhase.isEmpty else { return }
        let delta = SystemVolume.scrollDelta(deltaY: Double(event.scrollingDeltaY),
                                             precise: event.hasPreciseScrollingDeltas,
                                             inverted: event.isDirectionInvertedFromDevice)
        guard delta != 0, let level = SystemVolume.change(by: Float(delta)) else { return }

        // Published on the next pass, never from inside the event dispatch —
        // see `setExpanded`.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.volumeLevel = level
                self.volumeHide?.cancel()
                let hide = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated { self?.model.volumeLevel = nil }
                }
                self.volumeHide = hide
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: hide)
            }
        }
    }

    /// Opens the panel if closed, closes it if open — the keyboard shortcut.
    func toggle() {
        setExpanded(!model.isExpanded)
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
                if expanded {
                    self.model.peeking = false
                    self.model.hovering = false
                    self.hoverPeeking = false
                }
                self.model.isExpanded = expanded
                self.panel?.contentView?.needsLayout = true
                self.panel?.contentView?.layoutSubtreeIfNeeded()
                self.panel?.displayIfNeeded()
            }
        }
    }

    /// The pointer on the notch, in every mode:
    /// - the closed pill swells a little under it (NotchNook's hover state);
    /// - `.hover` (boring.notch): open once the pointer has rested there for
    ///   `hoverDwell`, close `hoverLeaveDelay` after it leaves the panel;
    /// - `.nook` (NotchNook): after the same rest, the song peeks out — title
    ///   and artist — and slides back when the pointer leaves. Opening is a
    ///   click or a swipe down.
    /// A click opens at once in every mode. No haptics, by request.
    ///
    /// "Inside" is the shape actually drawn — the pill, or the open panel —
    /// not the window: open, the window is a larger transparent canvas, and
    /// moving into its margin is leaving the panel.
    ///
    /// Measured in screen coordinates, never against the window. The window
    /// is resized a run-loop pass *after* the panel opens, and an event in
    /// between, measured against the still-small window, put the pointer
    /// outside the open panel — which closed it, which reopened it: tested
    /// with a real pointer resting on the notch, it flickered open and shut
    /// five times a second.
    private func pointerMoved(to point: NSPoint) {
        guard let shape = shapeOnScreen else { return }
        // A hair of slack all round. Not optional: the pointer stops at the
        // screen's top edge, y == maxY, and a rect doesn't contain its own
        // max edge — without it, resting the pointer at the top of the open
        // panel counted as leaving it, and it closed under the pointer.
        let inside = shape.insetBy(dx: -2, dy: -2).contains(point)
        guard inside != pointerInside else { return }
        pointerInside = inside
        hoverTask?.cancel()
        watchForLeaving(inside)
        // Published on the next pass, never from inside the event dispatch —
        // see `setExpanded`.
        // Not in `.nook` mode: there the hover feedback is the song sliding
        // out, and a swell on top of it read as the notch wobbling.
        let swell = inside && !model.isExpanded && Preferences.openMode != .nook
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.model.hovering != swell else { return }
                self.model.hovering = swell
            }
        }

        switch Preferences.openMode {
        case .click:
            break
        case .hover:
            if inside {
                guard !model.isExpanded else { return }
                hoverTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: Self.hoverDwell)
                    guard let self, !Task.isCancelled, self.pointerInside,
                          !self.model.isExpanded else { return }
                    if NotchPanel.debugClick { NSLog("click: hover -> EXPAND") }
                    self.setExpanded(true)
                    if NotchPanel.debugClick { self.debugSnapshots(tag: "hover-open") }
                }
            } else {
                guard model.isExpanded else { return }
                hoverTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: Self.hoverLeaveDelay)
                    guard let self, !Task.isCancelled, !self.pointerInside,
                          self.model.isExpanded, !self.isTyping else { return }
                    if NotchPanel.debugClick { NSLog("click: hover left -> COLLAPSE") }
                    self.setExpanded(false)
                    if NotchPanel.debugClick { self.debugSnapshots(tag: "hover-close") }
                }
            }
        case .nook:
            if inside {
                guard !model.isExpanded, !model.peeking, model.track != nil else { return }
                hoverTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: Self.hoverDwell)
                    guard let self, !Task.isCancelled, self.pointerInside,
                          !self.model.isExpanded, !self.model.peeking else { return }
                    if NotchPanel.debugClick { NSLog("click: hover -> PEEK") }
                    self.hoverPeeking = true
                    self.model.peeking = true
                    if NotchPanel.debugClick { self.debugSnapshots(tag: "hover-peek") }
                }
            } else if hoverPeeking {
                hoverPeeking = false
                if NotchPanel.debugClick { NSLog("click: hover left -> UNPEEK") }
                model.peeking = false
            }
        }
    }

    /// The window's own tracking area can't be trusted to report the pointer
    /// leaving: when the window resizes under a resting pointer — the swell,
    /// the peek sliding out — AppKit can lose track of it being inside, and
    /// then never sends the exit. Tested: the peek stayed out and the pill
    /// stayed swollen after the pointer had gone. So while the pointer is on
    /// the notch, a global monitor follows it outside our window too, and is
    /// removed the moment it has left. Mouse movement only — no permission,
    /// and nothing at all while the pointer is elsewhere.
    private func watchForLeaving(_ inside: Bool) {
        if inside, leaveMonitor == nil {
            leaveMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDragged]
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.pointerMoved(to: NSEvent.mouseLocation) }
            }
        } else if !inside, let monitor = leaveMonitor {
            NSEvent.removeMonitor(monitor)
            leaveMonitor = nil
        }
    }

    /// Scrolls the notch keeps for itself — volume, or swipes in `.nook` mode
    /// — and the ones it passes on to the page under the pointer.
    ///
    /// Closed, and on the music page, every scroll is the notch's: there's
    /// nothing there to scroll. On the notes and apps pages the content has
    /// to scroll like any page — it used to swallow every scroll, so a long
    /// to-do list couldn't be scrolled at all — except along the top strip
    /// beside the cutout, which still works the notch.
    private func takesScroll(_ event: NSEvent) -> Bool {
        guard model.isExpanded, model.tab != .music,
              let notch = targetScreen?.notchSize else { return true }
        return event.locationInWindow.y >= expandedShapeRect.maxY - notch.height
    }

    /// Swipes on the notch, in `.nook` mode — NotchNook's gestures, in place
    /// of scrolling the volume:
    /// - down opens, up closes;
    /// - right skips to the next song, left goes back.
    /// One action per swipe, decided once the fingers have travelled far
    /// enough in one direction; the rest of the swipe and its momentum are
    /// ignored, so a long swipe doesn't skip three songs.
    private func swipe(_ event: NSEvent) {
        guard event.momentumPhase.isEmpty else { return }
        // A trackpad marks where a swipe begins; a mouse wheel doesn't, and
        // each of its clicks is a swipe of its own.
        if event.phase == .began || event.phase == .mayBegin || event.phase.isEmpty {
            swipeTravel = .zero
            swipeDone = false
        }
        guard !swipeDone else { return }

        // Where the *fingers* went, whatever the scrolling direction setting:
        // down and right positive.
        let finger: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        swipeTravel.width += event.scrollingDeltaX * finger
        swipeTravel.height += event.scrollingDeltaY * finger

        guard let action = Self.swipeAction(travel: swipeTravel,
                                            precise: event.hasPreciseScrollingDeltas) else { return }
        swipeDone = true
        if NotchPanel.debugClick { NSLog("click: swipe \(action)") }
        switch action {
        case .down where !model.isExpanded: setExpanded(true)
        case .up where model.isExpanded: setExpanded(false)
        case .left, .right:
            guard let source = model.track?.source else { return }
            transport(action == .right ? .next : .previous, in: source)
        default: break
        }
    }

    enum SwipeAction { case up, down, left, right }

    /// Which way a swipe went, once it has gone far enough to count — and
    /// clearly more one way than the other, so a slightly diagonal swipe
    /// down doesn't skip a song. Sideways needs a longer swipe than up or
    /// down: skipping a song by accident is the worse mistake.
    nonisolated static func swipeAction(travel: CGSize, precise: Bool) -> SwipeAction? {
        let reach: CGFloat = precise ? 36 : 1
        let x = travel.width, y = travel.height
        if abs(y) >= reach, abs(y) > abs(x) * 1.5 {
            return y > 0 ? .down : .up
        }
        if abs(x) >= reach * 1.6, abs(x) > abs(y) * 1.5 {
            return x > 0 ? .right : .left
        }
        return nil
    }

    /// The shape drawn right now, in screen coordinates: the open panel, or
    /// the pill (slid right while peeking). The window is always centred on
    /// the screen's top edge, so this follows from the screen alone.
    private var shapeOnScreen: NSRect? {
        guard let screen = targetScreen else { return nil }
        let top = screen.frame.maxY, mid = screen.frame.midX
        if model.isExpanded {
            let width = model.expandedWidth, height = model.expandedHeight
            return NSRect(x: mid - width / 2, y: top - height, width: width, height: height)
        }
        let pill = pillRect
        return NSRect(x: mid - pill.width / 2 + (model.peeking ? NotchView.peekShift : 0),
                      y: top - pill.height, width: pill.width, height: pill.height)
    }

    /// A note or a to-do is being typed. Leaving the panel then doesn't close
    /// it — reaching for the mouse mid-sentence would throw the text away
    /// from under you. A click outside still closes it.
    private var isTyping: Bool {
        panel?.firstResponder is NSTextView
    }

    /// Debug: photograph our own content view at fixed delays after an open,
    /// and log the window's frame and visibility at each. Shows whether the
    /// app has *drawn* the expanded panel when it thinks it has — the window
    /// is ours, so this needs no permission.
    private func debugSnapshots(tag: String = "open") {
        let dir = ProcessInfo.processInfo.environment["RESONATA_DEBUG_DIR"] ?? NSTemporaryDirectory()
        let t0 = CFAbsoluteTimeGetCurrent()
        for delay in [0.05, 0.15, 0.3, 0.6, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let panel = self.panel, let view = panel.contentView else { return }
                    let dt = CFAbsoluteTimeGetCurrent() - t0
                    NSLog("snap[%@] +%.2fs: expanded=%d content=%d idle=%d frame=%@ notch=%@",
                          tag, dt, self.model.isExpanded ? 1 : 0,
                          self.model.showsCollapsedContent ? 1 : 0, self.model.isIdle ? 1 : 0,
                          NSStringFromRect(panel.frame), NSStringFromSize(self.model.notchSize))
                    _ = view
                    let url = URL(fileURLWithPath: dir)
                        .appendingPathComponent(String(format: "snap-%@-%.2fs.png", tag, delay))
                    Task { await self.captureWindow(to: url) }
                }
            }
        }
    }

    /// Debug: the panel's own layer tree rendered to a PNG — the SwiftUI
    /// content and the Core Animation layers (bars, wave, flash) alike, which
    /// `cacheDisplay` misses. Developer-only (`RESONATA_DEBUG_CLICK=1`), and
    /// it draws this app's own window from the inside: no screen capture, no
    /// permission, nothing outside the app.
    func captureWindow(to url: URL) async {
        guard let panel, let view = panel.contentView, let layer = view.layer,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        let scale = panel.backingScaleFactor
        guard let context = CGContext(
            data: nil, width: Int(view.bounds.width * scale),
            height: Int(view.bounds.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        context.scaleBy(x: scale, y: scale)
        // The hosting view counts from the top; a bitmap counts from the
        // bottom. Without this the photo comes out upside down.
        if view.isFlipped {
            context.translateBy(x: 0, y: view.bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context)
        guard let image = context.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: image)
            .representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Where the closed pill is drawn, in window coordinates: top-centre,
    /// shifted right while peeking.
    private var pillRect: NSRect {
        guard let panel, let screen = targetScreen else { return .zero }
        let window = panel.frame.size
        let notch = screen.notchSize
        var height = notch.height + NotchMetrics.collapsedExtraHeight
        var width = notch.width + (model.showsCollapsedContent ? NotchMetrics.collapsedContentWidth : 0)
        var shift: CGFloat = 0
        if model.peeking {
            width = NotchView.peekSize(notch: notch).width
            shift = NotchView.peekShift
        }
        // The swell stays on through a hover peek — the pointer is still there.
        if model.hovering {
            width += NotchMetrics.hoverGrowth.width
            height += NotchMetrics.hoverGrowth.height
        }
        return NSRect(x: (window.width - width) / 2 + shift, y: window.height - height,
                      width: width, height: height)
    }

    /// Where the expanded panel is drawn, in window coordinates: top-centre
    /// of the canvas, the size the view draws it at.
    private var expandedShapeRect: NSRect {
        let width = model.expandedWidth
        let height = model.expandedHeight
        return NSRect(x: (Self.canvasWidth - width) / 2,
                      y: Self.canvasHeight - height,
                      width: width, height: height)
    }

    /// Visibility only. This used to route through `apply`, which also owns
    /// the deferred window shrink — so every half-second tick cancelled a
    /// pending shrink and resized the window at once, cutting the close
    /// animation short at a random moment and, for one frame, showing the old
    /// wide layout inside the new narrow window: the pill jumped right, then
    /// back.
    private func updateVisibility() {
        guard let panel else { return }
        fullScreenCovered = targetScreen?.isShowingFullScreenApp ?? false
        if fullScreenCovered {
            if panel.isVisible { panel.orderOut(nil) }
        } else if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    /// Sizes the window for a new state: grow at once, shrink afterwards.
    ///
    /// The SwiftUI spring needs room to animate into, and the extra area is
    /// transparent, so growing is immediate. Shrinking has to wait until the
    /// animation has played, or the window clips it — and moves its origin,
    /// so the old, wider content is drawn off-centre for a moment: the pill
    /// jumping sideways.
    ///
    /// One rule for every transition, instead of the flags this used to keep
    /// for "closing after an expand" and "losing content": take the union of
    /// the current and the new frame now, the exact new frame later. That
    /// also covers changes that grow one way and shrink the other, which the
    /// song-change peek brought in.
    private func apply(expanded: Bool, hasTrack: Bool, peeking: Bool, hovering: Bool = false) {
        guard let panel, let screen = targetScreen else { return }
        shrink?.cancel()

        let target = frame(for: screen, expanded: expanded, hasTrack: hasTrack, peeking: peeking,
                           hovering: hovering)
        let room = panel.frame.union(target)
        if room != panel.frame { setPanelFrame(room) }
        guard room != target else { return }

        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.setPanelFrame(target) }
        }
        shrink = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
    }

    private func reposition() {
        guard let screen = targetScreen else { return }
        setPanelFrame(frame(for: screen, expanded: model.isExpanded,
                            hasTrack: model.showsCollapsedContent, peeking: model.peeking))
    }

    private func setPanelFrame(_ rect: NSRect) {
        guard let panel else { return }
        // `display: false`, deliberately. With `true`, AppKit repainted the
        // resized window at once with SwiftUI's *previous* content — and its
        // layers anchor bottom-left, so the old pill flashed at the bottom of
        // the grown window for a frame before SwiftUI moved it to the top and
        // began the spring: a visible jump from below. Leaving the display to
        // SwiftUI's own pass, a moment later, draws the first frame of the new
        // state straight into the new frame.
        panel.setFrame(rect, display: false)
        // ...and lay SwiftUI out at the new size *now*, in the same pass, so
        // the next frame drawn is the new layout in the new frame — never the
        // old layout, anchored at the window's corner, in a frame of another
        // size.
        panel.contentView?.needsLayout = true
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    private func frame(
        for screen: NSScreen,
        expanded: Bool = false,
        hasTrack: Bool = false,
        peeking: Bool = false,
        hovering: Bool = false
    ) -> NSRect {
        let size: CGSize
        if expanded {
            size = CGSize(width: Self.canvasWidth, height: Self.canvasHeight)
        } else if peeking {
            let peek = NotchView.peekWindowSize(notch: screen.notchSize)
            size = CGSize(width: peek.width + (hovering ? NotchMetrics.hoverGrowth.width : 0),
                          height: peek.height + (hovering ? NotchMetrics.hoverGrowth.height : 0))
        } else {
            size = CGSize(width: screen.notchSize.width
                            + (hasTrack ? NotchMetrics.collapsedContentWidth : 0)
                            + (hovering ? NotchMetrics.hoverGrowth.width : 0),
                          height: screen.notchSize.height + NotchMetrics.collapsedExtraHeight
                            + (hovering ? NotchMetrics.hoverGrowth.height : 0))
        }

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
