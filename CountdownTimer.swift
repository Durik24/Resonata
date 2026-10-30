import AppKit

/// The timer on the open panel's "Časovač" page: count down a few minutes,
/// show the time left in the closed notch, slide out and chime at the end.
///
/// Kept in UserDefaults, so a running timer survives Resonata restarting —
/// `./build.sh run` restarts it, and so does logging out.
@MainActor
final class CountdownTimer: ObservableObject {

    static let shared = CountdownTimer()

    /// The buttons on the page, in minutes.
    static let presets = [5, 10, 15, 25, 45, 60]

    /// When it runs out; nil when stopped or paused.
    @Published private(set) var end: Date?
    /// Time left while paused; nil otherwise.
    @Published private(set) var pausedRemaining: TimeInterval?
    /// The length it was started with, for the ring.
    @Published private(set) var total: TimeInterval = 25 * 60
    /// The last length chosen, offered again by the start button.
    @Published private(set) var chosenMinutes = 25

    /// Called when it runs out, with the minutes it ran for.
    var onFinish: ((Int) -> Void)?

    private var fire: Timer?

    var isActive: Bool { end != nil || pausedRemaining != nil }
    var isPaused: Bool { pausedRemaining != nil }

    init() {
        restore()
    }

    func remaining(at now: Date) -> TimeInterval {
        if let end { return max(0, end.timeIntervalSince(now)) }
        return pausedRemaining ?? TimeInterval(chosenMinutes * 60)
    }

    /// 0 at the start, 1 at the end.
    func progress(at now: Date) -> Double {
        guard isActive, total > 0 else { return 0 }
        return min(max(1 - remaining(at: now) / total, 0), 1)
    }

    func start(minutes: Int) {
        chosenMinutes = minutes
        total = TimeInterval(minutes * 60)
        pausedRemaining = nil
        end = Date().addingTimeInterval(total)
        schedule()
        save()
    }

    /// Debug only: a run of a few seconds, to watch the end without waiting.
    func startForTesting(seconds: TimeInterval) {
        total = seconds
        pausedRemaining = nil
        end = Date().addingTimeInterval(seconds)
        schedule()
    }

    func pause() {
        guard let end else { return }
        pausedRemaining = max(0, end.timeIntervalSinceNow)
        self.end = nil
        fire?.invalidate()
        save()
    }

    func resume() {
        guard let left = pausedRemaining else { return }
        pausedRemaining = nil
        end = Date().addingTimeInterval(left)
        schedule()
        save()
    }

    func cancel() {
        end = nil
        pausedRemaining = nil
        fire?.invalidate()
        save()
    }

    /// "24:59", or "65 min" from an hour up — narrow enough for the slot
    /// beside the notch.
    nonisolated static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        if s >= 3600 { return "\(s / 60) min" }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func schedule() {
        fire?.invalidate()
        guard let end else { return }
        // Fires on time even after sleep: a timer's fire date is a moment,
        // and one that passed while asleep fires on wake.
        let timer = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finished() }
        }
        RunLoop.main.add(timer, forMode: .common)
        fire = timer
    }

    private func finished() {
        let minutes = Int((total / 60).rounded())
        cancel()
        NSSound(named: NSSound.Name("Glass"))?.play()
        onFinish?(minutes)
    }

    // MARK: Kept across restarts

    private enum Key {
        static let end = "timerEnd"
        static let paused = "timerPausedRemaining"
        static let total = "timerTotal"
        static let chosen = "timerChosenMinutes"
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(end, forKey: Key.end)
        d.set(pausedRemaining, forKey: Key.paused)
        d.set(total, forKey: Key.total)
        d.set(chosenMinutes, forKey: Key.chosen)
    }

    private func restore() {
        let d = UserDefaults.standard
        if d.integer(forKey: Key.chosen) > 0 { chosenMinutes = d.integer(forKey: Key.chosen) }
        if d.double(forKey: Key.total) > 0 { total = d.double(forKey: Key.total) }
        pausedRemaining = d.object(forKey: Key.paused) as? TimeInterval
        // One that ran out while Resonata wasn't running is simply over.
        if let saved = d.object(forKey: Key.end) as? Date, saved > Date() {
            end = saved
            schedule()
        } else if d.object(forKey: Key.end) != nil {
            d.removeObject(forKey: Key.end)
        }
    }
}
