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
    /// MediaRemote first — it sees every player. If the adapter can't start
    /// or MediaRemote won't answer on this macOS, the AppleScript source takes
    /// over and the app behaves exactly as it did before Phase 5.
    private let mediaRemote = MediaRemoteNowPlaying()
    private var appleScript: AppleScriptNowPlaying?
    private var sourceCancellables = Set<AnyCancellable>()

    private let lyrics = LyricsStore()

    /// Flashes the notch as each new lyric line begins. Resonata doesn't
    /// listen to the computer's sound, so the lyrics' timing is the music's
    /// timing it shows.
    private let lyricPulse = LyricPulse()

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

        openAtLoginOnce()
        controller.show()
        startNowPlaying()

        HotKey.shared.action = { [weak self] in self?.controller.toggle() }
        HotKey.shared.apply(Preferences.hotKey)

        // A flash as each lyric line begins, re-armed on every change to the
        // track (play, pause, seek, new song) or to its lyrics.
        lyricPulse.onPulse = { [weak self] in self?.model.pulse &+= 1 }

        // A new song gets a moment in the closed notch.
        model.$track
            .sink { [weak self] track in self?.songPeek.trackChanged(to: track) }
            .store(in: &cancellables)
        model.$track
            .combineLatest(model.$lyrics)
            .sink { [weak self] track, lines in self?.lyricPulse.update(track: track, lines: lines) }
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
            center.addObserver(forName: Notification.Name("com.local.resonata.page"),
                               object: nil, queue: .main) { [weak self] note in
                let name = note.object as? String
                MainActor.assumeIsolated {
                    if let tab = PanelTab(rawValue: name ?? "") { self?.model.tab = tab }
                }
            }
        }

        // `RESONATA_DEBUG_FAKE_PULSES=1`: a flash twice a second, so the cost
        // of the flash can be measured without music.
        if ProcessInfo.processInfo.environment["RESONATA_DEBUG_FAKE_PULSES"] == "1" {
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.pulse &+= 1 }
            }
        }

        lyrics.$lines
            .sink { [weak self] lines in self?.model.lyrics = lines }
            .store(in: &cancellables)

        lyrics.$isFetching
            .sink { [weak self] pending in self?.model.lyricsPending = pending }
            .store(in: &cancellables)

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
                self?.lyrics.load(for: track)
            }
            .store(in: &sourceCancellables)

        // Kept separate from `track` on purpose: idle only silences the
        // collapsed pill, the track stays loaded so it can be resumed.
        idlePublisher
            .sink { [weak self] idle in self?.model.isIdle = idle }
            .store(in: &sourceCancellables)
    }

    private func loadFavorite(for track: Track?) {
        model.isFavorite = nil
        guard track?.bundleID == MusicFavorite.bundleID else { return }
        MusicFavorite.read { [weak self] value in self?.model.isFavorite = value }
    }

    /// Adds Resonata to System Settings › General › Login Items, once.
    ///
    /// It has no Dock icon and no window, so after a restart nothing hinted
    /// that it hadn't started — the notch was just a notch. Registered only
    /// on the first launch that succeeds: switching it off in System
    /// Settings is a choice, and re-registering on every launch would undo it.
    private func openAtLoginOnce() {
        let key = "registeredLoginItem"
        let status = SMAppService.mainApp.status
        NSLog("Resonata: login item status %ld", status.rawValue)
        // `.notFound` is the system losing track of the bundle — a rebuild
        // can do that — not the user saying no, so it's safe to re-register.
        guard !UserDefaults.standard.bool(forKey: key) || status == .notFound else { return }
        if LoginItem.set(true) { UserDefaults.standard.set(true, forKey: key) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        mediaRemote.stop()
        appleScript?.stop()
        lyricPulse.stop()
    }
}
