import AppKit
import SwiftUI

/// A player's own volume, not the Mac's — the slider beside the controls
/// while Spotify or Apple Music plays.
///
/// Through the player's scripting dictionary (`sound volume`, 0–100, which
/// both have), the same way the heart reaches Apple Music: no account or
/// sign-in, just the one-time "Resonata wants to control…" prompt. It moves
/// the player's level inside the Mac's, so the rest of the Mac's sound stays
/// where it is.
///
/// This was Spotify's alone (`SpotifyVolume`); Music answers to exactly the
/// same two lines of AppleScript, so it gets the slider too.
enum PlayerVolume {

    /// A player with a volume of its own to set.
    struct Player: Equatable, Sendable {
        /// What AppleScript calls it — never the name shown, which is "Hudba"
        /// for Music on a Czech Mac.
        var scriptName: String
        var bundleID: String
        /// For the tooltips.
        var displayName: String
    }

    static let spotify = Player(scriptName: "Spotify", bundleID: "com.spotify.client",
                                displayName: "Spotify")
    static let music = Player(scriptName: "Music", bundleID: "com.apple.Music",
                              displayName: "Apple Music")

    /// The player `track` came from, when it is one of the two; nil for a
    /// browser tab or anything else, which gets no slider.
    nonisolated static func player(for track: Track?) -> Player? {
        guard let track else { return nil }
        if track.bundleID == spotify.bundleID || track.source == spotify.scriptName { return spotify }
        if track.bundleID == music.bundleID { return music }
        return nil
    }

    /// Only ever while the player is already running: `tell application`
    /// would otherwise launch it.
    static func isRunning(_ player: Player) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).isEmpty
    }

    @MainActor
    static func read(_ player: Player, _ completion: @escaping @MainActor (Int?) -> Void) {
        guard isRunning(player) else { completion(nil); return }
        AppleScript.queue.async {
            let value = AppleScript.run("tell application \"\(player.scriptName)\" to get sound volume",
                                        what: "\(player.scriptName) volume")?.int32Value
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(value.map(Int.init)) } }
        }
    }

    /// Sets it, dropping any older value still waiting to be sent: a drag
    /// sends dozens a second, and the player only needs the last.
    static func set(_ volume: Int, for player: Player) {
        guard isRunning(player) else { return }
        let level = min(max(volume, 0), 100)
        lock.withLock { pending[player.bundleID] = level }
        AppleScript.queue.async {
            guard let level = lock.withLock({ pending.removeValue(forKey: player.bundleID) })
            else { return }
            _ = AppleScript.run("tell application \"\(player.scriptName)\" to set sound volume to \(level)",
                                what: "\(player.scriptName) volume")
        }
    }

    private static let lock = NSLock()
    /// The level waiting to be sent, per player. Only touched under `lock`.
    nonisolated(unsafe) private static var pending: [String: Int] = [:]
}

/// A speaker and a short slider, for the player's own volume. Read each time
/// the panel opens — the player's own slider may have moved since.
struct PlayerVolumeControl: View {
    var player: PlayerVolume.Player
    var tint: Color
    /// Shown at once from the last level seen, then corrected by the read.
    /// Waiting for the read, the slider popped in a moment after the page
    /// — in place, not sliding in with the rest of it on a page turn.
    @State private var volume: Double?
    /// The last level seen, per player.
    @MainActor static var lastKnown: [String: Double] = [:]
    /// The level to go back to when unmuting, per player.
    @MainActor static var beforeMute: [String: Double] = [:]
    /// Moved here since the panel opened. The level read on opening is
    /// then out of date by the time it comes back — the player can take a
    /// moment — and putting it in snapped the knob back mid-drag.
    @State private var moved = false

    init(player: PlayerVolume.Player, tint: Color) {
        self.player = player
        self.tint = tint
        _volume = State(initialValue: Self.lastKnown[player.bundleID])
    }

    /// Counts the moves, so a check asked for after one move is dropped
    /// when another has followed it.
    @State private var moves = 0

    private func setVolume(_ new: Double) {
        moved = true
        if new < 1, let volume, volume >= 1 { Self.beforeMute[player.bundleID] = volume }
        volume = new
        Self.lastKnown[player.bundleID] = new
        PlayerVolume.set(Int(new.rounded()), for: player)
        confirmSoon()
    }

    /// A moment after the last move, asks the player what it made of it and
    /// shows that. The slider used to take its own word for it: with Spotify
    /// playing on another device, which the Mac can't set the volume of, it
    /// sat at 50 % while Spotify stayed at 100 % — tested. Now it slides back
    /// to where the player really is.
    private func confirmSoon() {
        moves += 1
        let mine = moves
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard mine == moves else { return }
            PlayerVolume.read(player) { value in
                guard mine == moves, let value, let shown = volume,
                      Self.disagrees(shown: shown, player: value) else { return }
                withAnimation(.easeOut(duration: 0.2)) { volume = Double(value) }
                Self.lastKnown[player.bundleID] = Double(value)
            }
        }
    }

    /// Whether the player's level is not the one the slider shows. Two points
    /// of slack: Spotify answers 49 after being set to 50.
    nonisolated static func disagrees(shown: Double, player: Int) -> Bool {
        abs(shown - Double(player)) > 2
    }

    /// The speaker click: down to 0 from any level, and from 0 back to the
    /// level before — or halfway, if it was never anything else here.
    nonisolated static func toggledMute(_ volume: Double, before: Double?) -> Double {
        volume >= 1 ? 0 : (before.flatMap { $0 >= 1 ? $0 : nil } ?? 50)
    }

    var body: some View {
        let name = player.displayName
        return Group {
            if let volume {
                let muteLabel = volume < 1 ? L.t("Unmute \(name)", "Zapnout zvuk \(name)")
                                           : L.t("Mute \(name)", "Ztlumit \(name)")
                HStack(spacing: 6) {
                    // Click to mute the player; click again for the level before.
                    Button {
                        setVolume(Self.toggledMute(volume, before: Self.beforeMute[player.bundleID]))
                    } label: {
                        Image(systemName: Self.symbol(for: volume))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 18, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(TransportButtonStyle())
                    .help(muteLabel)
                    .accessibilityLabel(muteLabel)
                    Slider(value: Binding(get: { volume }, set: { setVolume($0) }), in: 0...100)
                    .controlSize(.mini)
                    .tint(tint)
                    .accessibilityLabel(L.t("\(name) volume", "Hlasitost \(name)"))
                    // Shorter when room is short: beside the calendar the
                    // player column is narrow, and a fixed 96 pushed the
                    // whole panel wider than itself — the calendar and the
                    // battery came off the right-hand side. Down to 30 for
                    // Apple Music, whose heart sits in the same row.
                    .frame(minWidth: 30, maxWidth: 96)
                }
                .help(L.t("\(name)'s volume — \(name) only, not the whole Mac",
                          "Hlasitost \(name) — jen \(name), ne celého Macu"))
                .transition(.opacity)
            } else {
                // Something to appear: an empty group never does, and then
                // the level was never read and the slider never showed.
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .onAppear {
            moved = false
            PlayerVolume.read(player) { value in
                if FrameProbe.isOn { FrameProbe.record("volume read") }
                guard !moved else { return }
                volume = value.map(Double.init)
                Self.lastKnown[player.bundleID] = volume
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
