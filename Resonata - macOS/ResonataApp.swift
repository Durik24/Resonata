import Combine
import ServiceManagement
import SwiftUI

@main
struct ResonataApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // No windows. The whole UI is the panel the delegate creates.
        Settings { SettingsView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = NotchModel()
    private lazy var controller = NotchPanelController(model: model)
    private lazy var songPeek = SongPeek(model: model)
    private lazy var activityPeek = ActivityPeek(model: model)
    private let meetingReminder = MeetingReminder()
    private let claude = ClaudeMonitor()
    private let vibe = VibeMonitor()
    /// MediaRemote first — it sees every player. If the adapter can't start
    /// or MediaRemote won't answer on this macOS, the AppleScript source takes
    /// over and the app behaves exactly as it did before Phase 5.
    private let mediaRemote = MediaRemoteNowPlaying()
    private var appleScript: AppleScriptNowPlaying?
    private var sourceCancellables = Set<AnyCancellable>()

    private let lyrics = LyricsStore()

    private var cancellables = Set<AnyCancellable>()

    /// Keeps the process out of App Nap for as long as it lives.
    ///
    /// An agent app spawned by launchd is a background app as far as the
    /// scheduler is concerned, and macOS naps it: timers and drawing get
    /// multi-second tolerances. That showed up as a click on the pill taking
    /// five to eight seconds to *draw* — the state changed at once, the window
    /// resized at once, and SwiftUI's render was simply not run until
    /// something else woke the process. Launched from a terminal it inherits
    /// a foreground role and the same click renders in 84ms.
    private var activity: NSObjectProtocol?

    /// SIGTERM — `pkill`, `./build.sh run`, logging out — normally kills a
    /// Cocoa app on the spot, without `applicationWillTerminate`. That left the
    /// MediaRemote helper running with no parent. Turned into an ordinary quit.
    private var termination: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Preferences.registerDefaults()

        // No Dock icon, no menu bar entry — it lives in the notch.
        NSApp.setActivationPolicy(.accessory)

        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Resonata draws in response to clicks and to playback"
        )

        signal(SIGTERM, SIG_IGN)
        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm.setEventHandler { NSApp.terminate(nil) }
        sigterm.resume()
        termination = sigterm

        // The demo saves nothing, the login item included: run from a
        // project folder for screenshots, it must not make itself the copy
        // that starts at login.
        if !Demo.isOn { openAtLoginOnce() }
        controller.show()
        // The demo's made-up song stands in for real playback — see `Demo`.
        if !Demo.isOn { startNowPlaying() }

        HotKey.shared.action = { [weak self] in self?.controller.toggle(fromKeyboard: true) }
        HotKey.shared.apply(Preferences.hotKey)

        // Plugging in the charger gets a moment in the closed notch too.
        PowerWatcher.shared.onPlugIn = { [weak self] battery in
            guard Preferences.showChargingPeek else { return }
            self?.activityPeek.show(.charging(percent: battery.percent))
        }
        PowerWatcher.shared.onLow = { [weak self] battery in
            guard Preferences.showChargingPeek else { return }
            self?.activityPeek.show(.lowBattery(percent: battery.percent))
        }
        PowerWatcher.shared.start()

        // So do headphones taking over the sound.
        OutputWatcher.shared.onHeadphones = { [weak self] name in
            guard Preferences.showHeadphonesPeek else { return }
            self?.activityPeek.show(.headphones(name: name))
        }
        OutputWatcher.shared.start()

        // And an event about to start.
        meetingReminder.onReminder = { [weak self] event in
            self?.activityPeek.show(.meeting(title: event.title, start: event.start))
        }
        meetingReminder.start()

        // Claude Code: its limit as a ring, and a word when a session stops
        // to ask something or finishes. Off unless switched on in Settings.
        claude.$status
            .sink { [weak self] status in self?.model.claude = status }
            .store(in: &cancellables)
        claude.onEvent = { [weak self] activity in self?.activityPeek.show(activity) }
        // Mistral Vibe, the same way: its month's allowance and its sessions.
        vibe.$status
            .sink { [weak self] status in self?.model.vibe = status }
            .store(in: &cancellables)
        vibe.onEvent = { [weak self] activity in self?.activityPeek.show(activity) }
        model.refreshClaude = { [weak self] in
            self?.claude.refreshUsage()
            self?.vibe.refreshUsage()
        }
        // The panel opening is somebody about to read the ring.
        model.$isExpanded
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                self?.claude.refreshUsage(ifOlderThan: 60)
                self?.vibe.refreshUsage(ifOlderThan: 60)
            }
            .store(in: &cancellables)
        if !Demo.isOn {
            claude.setEnabled(Preferences.showClaude)
            vibe.setEnabled(Preferences.showVibe)
        }

        // A new version on GitHub, said once in the notch.
        Updater.shared.onFound = { [weak self] release in
            self?.activityPeek.show(.update(version: release.version))
        }
        Updater.shared.start()

        // The timer: its state shows in the closed notch, and its end is an
        // activity of its own.
        let timer = CountdownTimer.shared
        timer.$end.combineLatest(timer.$pausedRemaining)
            .map { end, paused in end != nil || paused != nil }
            .removeDuplicates()
            .sink { [weak self] running in self?.model.timerRunning = running }
            .store(in: &cancellables)
        timer.onFinish = { [weak self] minutes in self?.activityPeek.show(.timerDone(minutes: minutes)) }
        timer.onPhase = { [weak self] phase, minutes in
            self?.activityPeek.show(.pomodoro(rest: phase == .rest, minutes: minutes))
        }

        // A new song gets a moment in the closed notch.
        model.$track
            .sink { [weak self] track in self?.songPeek.trackChanged(to: track) }
            .store(in: &cancellables)

        // Apple Music's heart, read once per song.
        model.$track
            .removeDuplicates { a, b in
                guard let a, let b else { return a == nil && b == nil }
                return a.isSameTrack(as: b)
            }
            .sink { [weak self] track in self?.loadFavorite(for: track) }
            .store(in: &cancellables)

        // Debug triggers, so the peek and each page can be driven and
        // photographed from a script: `com.local.resonata.peek`, and
        // `com.local.resonata.page` with the page name as the object.
        if NotchPanel.debugClick {
            let center = DistributedNotificationCenter.default()
            center.addObserver(forName: Notification.Name("com.local.resonata.peek"),
                               object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.songPeek.show() }
            }
            // `com.local.resonata.notrack`: as if nothing were playing.
            center.addObserver(forName: Notification.Name("com.local.resonata.notrack"),
                               object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.track = nil }
            }
            // `com.local.resonata.activity` with lowbattery, headphones,
            // meeting or timer: that activity's peek, without the real thing.
            center.addObserver(forName: Notification.Name("com.local.resonata.activity"),
                               object: nil, queue: .main) { [weak self] note in
                let kind = note.object as? String
                MainActor.assumeIsolated {
                    let activity: NotchActivity? = switch kind {
                    case "lowbattery": .lowBattery(percent: 20)
                    case "headphones": .headphones(name: OutputWatcher.currentName ?? L.t("Headphones", "Sluchátka"))
                    case "meeting": .meeting(title: L.t("Meeting", "Schůzka"), start: Date().addingTimeInterval(300))
                    case "timer": .timerDone(minutes: 25)
                    case "update": .update(version: "1.0.8")
                    default: nil
                    }
                    if let activity { self?.activityPeek.show(activity) }
                }
            }
            // `com.local.resonata.pomodoro`: Pomodoro at 1/100 speed — 25 min
            // of work in 15 s, a 5-minute break in 3 s.
            center.addObserver(forName: Notification.Name("com.local.resonata.pomodoro"),
                               object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    CountdownTimer.shared.testScale = 0.01
                    CountdownTimer.shared.startPomodoro()
                }
            }
            // `com.local.resonata.timer`: an 8-second timer, to watch it end.
            center.addObserver(forName: Notification.Name("com.local.resonata.timer"),
                               object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { CountdownTimer.shared.startForTesting(seconds: 8) }
            }
            // `com.local.resonata.charging`: the charging peek, without a cable.
            center.addObserver(forName: Notification.Name("com.local.resonata.charging"),
                               object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.activityPeek.show(.charging(percent: Battery.read()?.percent ?? 80))
                }
            }
            // `com.local.resonata.lyrics`: the music page's bigger lyrics
            // view, on and off.
            center.addObserver(forName: Notification.Name("com.local.resonata.lyrics"),
                               object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.showingLyrics.toggle() }
            }
            // `com.local.resonata.live`: as if the song were a live stream,
            // with no length.
            center.addObserver(forName: Notification.Name("com.local.resonata.live"),
                               object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.track?.duration = 0 }
            }
            // `com.local.resonata.claude` with working, waiting, done, idle
            // or off: Claude Code's ring and messages, without a session.
            center.addObserver(forName: Notification.Name("com.local.resonata.claude"),
                               object: nil, queue: .main) { [weak self] note in
                let kind = note.object as? String
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let usage = ClaudeUsage(sessionPercent: 62, sessionResets: Date().addingTimeInterval(8280),
                                            weekPercent: 18, weekResets: Date().addingTimeInterval(250_000),
                                            models: [.init(name: "Fable", percent: 27, resets: nil)])
                    func sessions(_ state: ClaudeStatus.State) -> [ClaudeStatus.Session] {
                        [.init(pid: 1, name: "resonata", state: state, app: "Terminál"),
                         .init(pid: 2, name: "web", state: .idle, app: "Visual Studio Code")]
                    }
                    let asks = L.t("Allow the edit?", "Povolit úpravu?")
                    switch kind {
                    case "working":
                        self.model.claude = ClaudeStatus(state: .working, session: "resonata", usage: usage,
                                                         sessions: sessions(.working))
                    case "waiting":
                        self.model.claude = ClaudeStatus(state: .waiting, session: "resonata", wants: asks,
                                                         usage: usage, sessions: sessions(.waiting))
                        self.activityPeek.show(.claudeWaiting(session: "resonata", wants: asks))
                    case "done":
                        self.model.claude = ClaudeStatus(state: .idle, usage: usage, sessions: sessions(.idle))
                        self.activityPeek.show(.claudeDone(session: "resonata"))
                    case "idle":
                        self.model.claude = ClaudeStatus(state: .idle, usage: usage, sessions: sessions(.idle))
                    default:
                        self.model.claude = nil
                    }
                }
            }
            // `com.local.resonata.vibe`, with the same words: Mistral Vibe's.
            center.addObserver(forName: Notification.Name("com.local.resonata.vibe"),
                               object: nil, queue: .main) { [weak self] note in
                let kind = note.object as? String
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let usage = VibeUsage(percent: 34, resets: Date().addingTimeInterval(1_600_000), plan: "Student")
                    func sessions(_ state: ClaudeStatus.State) -> [ClaudeStatus.Session] {
                        [.init(pid: 3, name: "milionar", state: state, app: "Terminál", key: "demo")]
                    }
                    let asks = "python3 --version"
                    switch kind {
                    case "working":
                        self.model.vibe = VibeStatus(state: .working, session: "milionar", usage: usage,
                                                     sessions: sessions(.working))
                    case "waiting":
                        self.model.vibe = VibeStatus(state: .waiting, session: "milionar", wants: asks,
                                                     usage: usage, sessions: sessions(.waiting))
                        self.activityPeek.show(.vibeWaiting(session: "milionar", wants: asks))
                    case "done":
                        self.model.vibe = VibeStatus(state: .idle, usage: usage, sessions: sessions(.idle))
                        self.activityPeek.show(.vibeDone(session: "milionar"))
                    case "idle":
                        self.model.vibe = VibeStatus(state: .idle, usage: usage, sessions: sessions(.idle))
                    default:
                        self.model.vibe = nil
                    }
                }
            }
            center.addObserver(forName: Notification.Name("com.local.resonata.page"),
                               object: nil, queue: .main) { [weak self] note in
                let name = note.object as? String
                MainActor.assumeIsolated {
                    if let tab = PanelTab(rawValue: name ?? "") { self?.model.tab = tab }
                }
            }
        }

        lyrics.$lines
            .sink { [weak self] lines in self?.model.lyrics = lines }
            .store(in: &cancellables)

        lyrics.$isFetching
            .sink { [weak self] pending in self?.model.lyricsPending = pending }
            .store(in: &cancellables)

        // Lyrics switched on in Settings are fetched for the song already
        // playing; switched off, they're dropped. Any settings change lands
        // here, and for the same song `load` does nothing.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !Demo.isOn else { return }
                self.loadLyrics(for: self.model.track)
                self.claude.setEnabled(Preferences.showClaude)
                self.vibe.setEnabled(Preferences.showVibe)
                // Switched off while its page was open: back to the music.
                if !PanelTab.shown.contains(.usage), self.model.tab == .usage { self.model.tab = .music }
            }
        }

        // Last, so nothing above overwrites the demo's song or lyrics.
        if Demo.isOn { Demo.install(on: model) }

    }

    private func startNowPlaying() {
        guard MediaRemoteNowPlaying.isBundled else {
            NSLog("Resonata: MediaRemote adapter not bundled; using AppleScript")
            useAppleScript()
            return
        }
        bind(mediaRemote)
        mediaRemote.start()
        mediaRemote.$status
            .sink { [weak self] status in
                guard let self else { return }
                switch status {
                case .streaming:
                    NSLog("Resonata: now-playing via MediaRemote")
                    // MediaRemote came good after AppleScript stepped in.
                    if let fallback = self.appleScript {
                        fallback.stop()
                        self.appleScript = nil
                        self.bind(self.mediaRemote)
                    }
                case .silent, .failed:
                    self.useAppleScript()
                case .starting:
                    break
                }
            }
            .store(in: &cancellables)
    }

    private func useAppleScript() {
        guard appleScript == nil else { return }
        NSLog("Resonata: now-playing via AppleScript")
        let source = AppleScriptNowPlaying()
        appleScript = source
        bind(source)
        source.start()
    }

    /// Routes one source's track and idle state into the model. Rebinding
    /// drops the previous source's subscriptions.
    private func bind(_ source: some NowPlayingSource) {
        sourceCancellables.removeAll()
        // Both sources publish the same two things; take them by concrete
        // type so the @Published publishers are available.
        let trackPublisher: AnyPublisher<Track?, Never>
        let idlePublisher: AnyPublisher<Bool, Never>
        if let s = source as? MediaRemoteNowPlaying {
            trackPublisher = s.$track.eraseToAnyPublisher()
            idlePublisher = s.$isIdle.eraseToAnyPublisher()
        } else if let s = source as? AppleScriptNowPlaying {
            trackPublisher = s.$track.eraseToAnyPublisher()
            idlePublisher = s.$isIdle.eraseToAnyPublisher()
        } else {
            return
        }

        trackPublisher
            .sink { [weak self] track in
                self?.model.track = track
                // Cheap when the song hasn't changed — the store keys on the
                // song, not on the position, so a re-sync is a no-op.
                self?.loadLyrics(for: track)
            }
            .store(in: &sourceCancellables)

        // Kept separate from `track` on purpose: idle only silences the
        // collapsed pill, the track stays loaded so it can be resumed.
        idlePublisher
            .sink { [weak self] idle in self?.model.isIdle = idle }
            .store(in: &sourceCancellables)
    }

    /// Lyrics only while they're switched on. The switch used to hide the
    /// line and nothing more: every song's title and artist still went to
    /// LRCLIB. Off, the store is told there's nothing playing.
    private func loadLyrics(for track: Track?) {
        lyrics.load(for: Preferences.showLyrics ? track : nil)
    }

    private func loadFavorite(for track: Track?) {
        model.isFavorite = nil
        guard let track, track.bundleID == MusicFavorite.bundleID else { return }
        MusicFavorite.read { [weak self] value in
            // Music can take a moment to answer, and the song may have moved
            // on by then — to Spotify, say, where a heart then turned up
            // that set a favourite in Music. Only for the song it was asked
            // about.
            guard let self, let now = self.model.track, now.bundleID == MusicFavorite.bundleID,
                  now.isSameTrack(as: track) else { return }
            self.model.isFavorite = value
        }
    }

    /// Adds Resonata to System Settings › General › Login Items, once.
    ///
    /// It has no Dock icon and no window, so after a restart nothing hinted
    /// that it hadn't started — the notch was just a notch. Registered only
    /// on the first launch that succeeds: switching it off in System
    /// Settings is a choice, and re-registering on every launch would undo it.
    ///
    /// The login item belongs to one copy of the app, by path. When the copy
    /// in /Applications runs and the item was registered by another copy —
    /// the build in the project folder — it moves the item to itself, so
    /// tidying the project folder can't quietly stop Resonata starting.
    /// Only ever *to* /Applications: a test run from the project folder must
    /// not pull it back. And never when it was switched off.
    private func openAtLoginOnce() {
        let key = "registeredLoginItem"
        let pathKey = "registeredLoginItemPath"
        let status = SMAppService.mainApp.status
        let path = Bundle.main.bundlePath
        NSLog("Resonata: login item status %ld", status.rawValue)
        let registered = UserDefaults.standard.bool(forKey: key)
        let installed = path.hasPrefix("/Applications/")
        let elsewhere = UserDefaults.standard.string(forKey: pathKey) != path
        if registered, installed, elsewhere, status == .enabled || status == .notFound {
            LoginItem.set(false)
            if LoginItem.set(true) { UserDefaults.standard.set(path, forKey: pathKey) }
            return
        }
        // `.notFound` is the system losing track of the bundle — a rebuild
        // can do that — not the user saying no, so it's safe to re-register.
        guard !registered || status == .notFound else { return }
        if LoginItem.set(true) {
            UserDefaults.standard.set(true, forKey: key)
            UserDefaults.standard.set(path, forKey: pathKey)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotesStore.shared.saveIfPending()
        mediaRemote.stop()
        appleScript?.stop()
    }
}
