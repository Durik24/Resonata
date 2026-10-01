import Combine
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
    private let spectrum = SystemAudioSpectrum(bandCount: 32)
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

        controller.show()
        startNowPlaying()

        // Held, not observed — the bars pull the latest frame when they draw.
        model.spectrum = spectrum
        spectrum.start()

        // The one part of the spectrum that *is* worth publishing: whether to
        // run the animation clock at all.
        spectrum.$hasSignal
            .sink { [weak self] signal in self?.model.hasAudioSignal = signal }
            .store(in: &cancellables)

        spectrum.$beat
            .sink { [weak self] beat in self?.model.beat = beat }
            .store(in: &cancellables)

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
                switch status {
                case .streaming: NSLog("Resonata: now-playing via MediaRemote")
                case .failed: self?.useAppleScript()
                case .starting: break
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

    func applicationWillTerminate(_ notification: Notification) {
        mediaRemote.stop()
        appleScript?.stop()
        spectrum.stop()
    }
}

struct SettingsView: View {
    var body: some View {
        Text("Resonata")
            .padding(40)
    }
}
