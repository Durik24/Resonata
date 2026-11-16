import AppKit

// The timer's "stop the music at the end": when it runs out, the music
// fades over ten seconds and pauses, and the volume goes back to where it
// was — so the next song you start isn't silent.
//
// Spotify and Music have a volume of their own to fade; any other player is
// simply paused.

@MainActor
enum MusicSleep {

    nonisolated static let fadeSeconds: TimeInterval = 10
    nonisolated static let steps = 20

    /// The fade in progress; a newer one, or a cancel, makes an older one stop.
    private static var generation = 0

    /// The levels to step through from `start` down to silence, the last
    /// one 0. Even steps: a player's volume is already a perceptual scale.
    nonisolated static func levels(from start: Int, steps: Int) -> [Int] {
        guard start > 0, steps > 0 else { return [] }
        return (1...steps).map { Int((Double(start) * Double(steps - $0) / Double(steps)).rounded()) }
    }

    /// Fades out and pauses whatever `track()` says is playing. `track` is
    /// asked again on every step: music the user has paused meanwhile, or
    /// taken to another app, is left alone.
    static func run(track: @escaping @MainActor () -> Track?) {
        guard let playing = track(), playing.isPlaying else { return }
        generation += 1
        let mine = generation
        guard let player = PlayerVolume.player(for: playing), PlayerVolume.isRunning(player) else {
            pause(playing)
            return
        }
        PlayerVolume.read(player) { volume in
            guard mine == generation else { return }
            guard let volume, volume > 0 else { pause(playing); return }
            let levels = levels(from: volume, steps: steps)
            step(0, levels: levels, original: volume, player: player, started: playing, track: track, mine: mine)
        }
    }

    /// Stops a fade in progress — the timer was started again.
    static func cancel() { generation += 1 }

    private static func step(_ index: Int, levels: [Int], original: Int, player: PlayerVolume.Player,
                             started: Track, track: @escaping @MainActor () -> Track?, mine: Int) {
        // Paused by hand, or another song's player took over: hands off,
        // and the volume back as it was.
        guard mine == generation, let now = track(), now.isPlaying, now.bundleID == started.bundleID else {
            PlayerVolume.set(original, for: player)
            return
        }
        guard index < levels.count else {
            pause(now)
            // Once it is quiet, back up: the pause has to land first, or
            // the last second of the song comes back at full volume.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                MainActor.assumeIsolated { PlayerVolume.set(original, for: player) }
            }
            return
        }
        PlayerVolume.set(levels[index], for: player)
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeSeconds / Double(steps)) {
            MainActor.assumeIsolated {
                step(index + 1, levels: levels, original: original, player: player, started: started,
                     track: track, mine: mine)
            }
        }
    }

    /// Pause, never play: asked of the player by name where it has a
    /// dictionary, through MediaRemote otherwise — "play/pause" would start
    /// music that had stopped by itself in the meantime.
    private static func pause(_ track: Track) {
        if let app = scriptName(for: track) {
            AppleScript.queue.async {
                _ = AppleScript.run("tell application \"\(app)\" to pause", what: "pause")
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .resonataDidCommandPlayer, object: nil)
                }
            }
        } else if let adapter = MediaRemoteNowPlaying.active {
            adapter.send(.pause)
        }
    }
}
