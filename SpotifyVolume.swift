import AppKit
import SwiftUI

/// Spotify's own volume, not the Mac's — the slider beside the controls
/// while Spotify plays.
///
/// Through Spotify's scripting dictionary (`sound volume`, 0–100), the same
/// way the heart reaches Apple Music: no Spotify account or sign-in, just the
/// one-time "Resonata wants to control Spotify" prompt. It moves Spotify's
/// level inside the Mac's, so the rest of the Mac's sound stays where it is.
enum SpotifyVolume {

    static let bundleID = "com.spotify.client"

    /// Only ever while Spotify is already running: `tell application` would
    /// otherwise launch it.
    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    @MainActor
    static func read(_ completion: @escaping @MainActor (Int?) -> Void) {
        guard isRunning else { completion(nil); return }
        queue.async {
            let value = run("tell application \"Spotify\" to get sound volume")?.int32Value
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(value.map(Int.init)) } }
        }
    }

    /// Sets it, dropping any older value still waiting to be sent: a drag
    /// sends dozens a second, and Spotify only needs the last.
    static func set(_ volume: Int) {
        guard isRunning else { return }
        let level = min(max(volume, 0), 100)
        lock.withLock { pending = level }
        queue.async {
            guard let level = lock.withLock({ () -> Int? in defer { pending = nil }; return pending })
            else { return }
            _ = run("tell application \"Spotify\" to set sound volume to \(level)")
        }
    }

    private static let queue = DispatchQueue(label: "com.local.resonata.spotify-volume",
                                             qos: .userInitiated)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: Int?

    /// Off the main thread: `NSAppleScript` blocks.
    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let output = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("Resonata: Spotify volume failed: \(error)"); return nil }
        return output
    }
}

/// A speaker and a short slider, for Spotify's volume. Read each time the
/// panel opens — Spotify's own slider may have moved since.
struct SpotifyVolumeControl: View {
    var tint: Color
    /// Shown at once from the last level seen, then corrected by the read.
    /// Waiting for the read, the slider popped in a moment after the page
    /// — in place, not sliding in with the rest of it on a page turn.
    @State private var volume: Double? = SpotifyVolumeControl.lastKnown
    @MainActor static var lastKnown: Double?
    /// The level to go back to when unmuting.
    @MainActor static var beforeMute: Double?

    private func setVolume(_ new: Double) {
        if new < 1, let volume, volume >= 1 { Self.beforeMute = volume }
        volume = new
        Self.lastKnown = new
        SpotifyVolume.set(Int(new.rounded()))
    }

    /// The speaker click: down to 0 from any level, and from 0 back to the
    /// level before — or halfway, if it was never anything else here.
    nonisolated static func toggledMute(_ volume: Double, before: Double?) -> Double {
        volume >= 1 ? 0 : (before.flatMap { $0 >= 1 ? $0 : nil } ?? 50)
    }

    var body: some View {
        Group {
            if let volume {
                HStack(spacing: 6) {
                    // Click to mute Spotify; click again for the level before.
                    Button { setVolume(Self.toggledMute(volume, before: Self.beforeMute)) } label: {
                        Image(systemName: Self.symbol(for: volume))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 18, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(TransportButtonStyle())
                    .help(volume < 1 ? "Zapnout zvuk Spotify" : "Ztlumit Spotify")
                    Slider(value: Binding(get: { volume }, set: { setVolume($0) }), in: 0...100)
                    .controlSize(.mini)
                    .tint(tint)
                    .frame(width: 96)
                }
                .help("Hlasitost Spotify — jen Spotify, ne celého Macu")
                .transition(.opacity)
            } else {
                // Something to appear: an empty group never does, and then
                // the level was never read and the slider never showed.
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .onAppear {
            SpotifyVolume.read { value in
                volume = value.map(Double.init)
                Self.lastKnown = volume
            }
        }
    }

    nonisolated static func symbol(for volume: Double) -> String {
        switch volume {
        case ..<1: "speaker.slash.fill"
        case ..<34: "speaker.wave.1.fill"
        case ..<67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }
}
