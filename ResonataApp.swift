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
    private let nowPlaying = AppleScriptNowPlaying()

    /// One analysis feeds every view that draws bars. 32 bands is what the
    /// expanded panel draws directly; the collapsed pill averages the same
    /// numbers down to three, which is far cheaper than running the FFT twice.
    private let spectrum = SystemAudioSpectrum(bandCount: 32)
    private let lyrics = LyricsStore()

    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, no menu bar entry — it lives in the notch.
        NSApp.setActivationPolicy(.accessory)

        controller.show()
        nowPlaying.start()

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

        nowPlaying.$track
            .sink { [weak self] track in
                self?.model.track = track
                // Cheap when the song hasn't changed — the store keys on the
                // song, not on the position, so a re-sync is a no-op.
                self?.lyrics.load(for: track)
            }
            .store(in: &cancellables)

        lyrics.$lines
            .sink { [weak self] lines in self?.model.lyrics = lines }
            .store(in: &cancellables)

        lyrics.$isFetching
            .sink { [weak self] pending in self?.model.lyricsPending = pending }
            .store(in: &cancellables)

        // Kept separate from `track` on purpose: idle only silences the
        // collapsed pill, the track stays loaded so it can be resumed.
        nowPlaying.$isIdle
            .sink { [weak self] idle in self?.model.isIdle = idle }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        nowPlaying.stop()
        spectrum.stop()
    }
}

struct SettingsView: View {
    var body: some View {
        Text("Resonata")
            .padding(40)
    }
}
