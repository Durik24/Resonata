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
    /// MediaRemote first — it sees every player. If the adapter can't start
    /// or MediaRemote won't answer on this macOS, the AppleScript source takes
    /// over and the app behaves exactly as it did before Phase 5.
    private let mediaRemote = MediaRemoteNowPlaying()
    private var appleScript: AppleScriptNowPlaying?
    private var sourceCancellables = Set<AnyCancellable>()

    /// One analysis feeds every view that draws bars. 32 bands is what the
    /// expanded panel draws directly; the collapsed pill averages the same
    /// numbers down to three, which is far cheaper than running the FFT twice.
    private let spectrum: SpectrumCapture = {
        // Core Audio taps from macOS 14.2: no Screen Recording permission.
        if #available(macOS 14.2, *) { return ProcessTapSpectrum(bandCount: 32) }
        return ScreenCaptureSpectrum(bandCount: 32)
    }()
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

    /// Stops audio capture a while after playback stops — see `gateCapture`.
    private var captureStop: DispatchWorkItem?

    /// Set while something is playing but no sound reaches the Mac — see
    /// `watchForSilence`.
    private var silenceTimer: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Preferences.registerDefaults()

        // No Dock icon, no menu bar entry — it lives in the notch.
        NSApp.setActivationPolicy(.accessory)

        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Resonata draws in response to clicks and to live audio"
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

        // Held, not observed — the bars pull the latest frame when they draw.
        model.spectrum = spectrum

        // The tap listens to whichever app is playing, not the whole system.
        model.$track
            .map { $0?.bundleID }
            .removeDuplicates()
            .sink { [weak self] bundleID in self?.spectrum.retarget(bundleID: bundleID) }
            .store(in: &cancellables)

        // Capture follows playback rather than running from launch.
        model.$track
            .map { $0?.isPlaying == true || NotchModel.debugForceLive }
            .removeDuplicates()
            .sink { [weak self] playing in self?.gateCapture(playing: playing) }
            .store(in: &cancellables)

        // The one part of the spectrum that *is* worth publishing: whether to
        // run the animation clock at all.
        spectrum.$hasSignal
            .sink { [weak self] signal in self?.model.hasAudioSignal = signal }
            .store(in: &cancellables)

        spectrum.$beat
            .sink { [weak self] beat in self?.model.beat = beat }
            .store(in: &cancellables)

        // Playing, but no sound reaching the Mac: show motion anyway.
        model.$track.map { $0?.isPlaying == true }
            .combineLatest(spectrum.$hasSignal)
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] playing, signal in self?.watchForSilence(playing: playing, signal: signal) }
            .store(in: &cancellables)

        // Apple Music's heart, read once per song.
        model.$track
            .removeDuplicates { a, b in
                guard let a, let b else { return a == nil && b == nil }
                return a.isSameTrack(as: b)
            }
            .sink { [weak self] track in self?.loadFavorite(for: track) }
            .store(in: &cancellables)

        // `RESONATA_DEBUG_FAKE_BEATS=1`: a beat twice a second (120 BPM), so
        // the cost of the beat animation can be measured without music.
        if ProcessInfo.processInfo.environment["RESONATA_DEBUG_FAKE_BEATS"] == "1" {
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.beat &+= 1 }
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

    /// Audio capture runs only while something is playing.
    ///
    /// It isn't free in silence: ScreenCaptureKit keeps `coreaudiod` streaming
    /// the system mix to us the whole time, measured at 1.5–7% of a core in
    /// *coreaudiod* with nothing playing — none of which showed up as this
    /// app's CPU. It stops ten seconds after playback does, the same delay
    /// the pill uses to go idle, so pausing to talk doesn't bounce the stream;
    /// pressing play starts it again in a fraction of a second.
    ///
    /// The cost: sound from something that doesn't report "now playing" to
    /// the system no longer moves the bars. With MediaRemote that's rare.
    private func gateCapture(playing: Bool) {
        captureStop?.cancel()
        captureStop = nil
        if playing {
            spectrum.start()
        } else {
            let stop = DispatchWorkItem { [weak self] in self?.spectrum.stop() }
            captureStop = stop
            DispatchQueue.main.asyncAfter(deadline: .now() + Preferences.idleTimeout, execute: stop)
        }
    }

    /// Something is playing but no sound has reached the Mac for a couple of
    /// seconds — Spotify playing on a phone or speaker, say. The bars and the
    /// wave then show their gentle fake motion rather than sitting flat,
    /// which looked frozen. Real sound switches them back at once.
    private func watchForSilence(playing: Bool, signal: Bool) {
        silenceTimer?.cancel()
        silenceTimer = nil
        guard playing, !signal else {
            if model.playingElsewhere { model.playingElsewhere = false }
            return
        }
        let mark = DispatchWorkItem { [weak self] in self?.model.playingElsewhere = true }
        silenceTimer = mark
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: mark)
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
        spectrum.stop()
    }
}
