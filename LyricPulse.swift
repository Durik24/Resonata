import Foundation

/// Fires once as each new line of synced lyrics begins.
///
/// The one musical timing Resonata has without listening to the sound: the
/// lyrics' own timestamps, against the interpolated playhead. Each line start
/// flashes the colour wash, which used to flash on detected beats.
///
/// No polling. One timer, set for exactly the next line, re-armed when it
/// fires and whenever the track changes — play, pause, seek, new song.
@MainActor
final class LyricPulse {

    var onPulse: (() -> Void)?

    private var timer: Timer?

    /// Re-arms for the line after `track`'s current position. Paused, no
    /// lyrics, or past the last line: nothing is armed.
    func update(track: Track?, lines: [LyricLine]?) {
        timer?.invalidate()
        timer = nil
        guard let track, track.isPlaying, let lines else { return }

        let position = track.position(at: Date())
        guard let next = Self.nextLineTime(in: lines, after: position) else { return }

        timer = Timer.scheduledTimer(withTimeInterval: max(next - position, 0.01),
                                     repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                if NotchPanel.debugClick {
                    NSLog("pulse: line at %.2f s, fired at %.3f s",
                          next, track.position(at: Date()))
                }
                self?.onPulse?()
                // The same anchor still holds while the song plays on; any
                // change to it arrives as a new `track` and re-arms from that.
                self?.update(track: track, lines: lines)
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Start of the first sung line strictly after `position`. Empty lines
    /// (instrumental breaks) don't count — nothing starts there to mark.
    nonisolated static func nextLineTime(in lines: [LyricLine], after position: TimeInterval) -> TimeInterval? {
        lines.first { $0.time > position + 0.05 && !$0.text.isEmpty }?.time
    }
}
