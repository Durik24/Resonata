import AppKit
import Intents

// A Focus going on or off, said in the closed notch — so the Mac going
// quiet has a reason you can see.
//
// macOS tells an app one thing about Focus, once the user has allowed it:
// whether one is on. Not which one, and not when it changes — so it is
// asked every few seconds, and a change is what gets said. Off until
// switched on in Settings.

@MainActor
final class FocusWatcher {

    static let shared = FocusWatcher()

    /// A Focus has just gone on (true) or off.
    var onChange: ((Bool) -> Void)?

    private var timer: Timer?
    private var last: Bool?
    private var wanted = false

    func setEnabled(_ enabled: Bool) {
        guard enabled != wanted else { return }
        wanted = enabled
        guard enabled else {
            timer?.invalidate()
            timer = nil
            last = nil
            return
        }
        // Asks the user the first time; after that it answers at once.
        INFocusStatusCenter.default.requestAuthorization { status in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard status == .authorized else {
                        NSLog("Resonata: Focus status not allowed (%ld)", status.rawValue)
                        return
                    }
                    self.start()
                }
            }
        }
    }

    private func start() {
        guard wanted, timer == nil else { return }
        last = INFocusStatusCenter.default.focusStatus.isFocused
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.look() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func look() {
        let now = INFocusStatusCenter.default.focusStatus.isFocused
        if let change = Self.change(from: last, to: now) { onChange?(change) }
        if let now { last = now }
    }

    /// What to say when the answer goes from `old` to `new`: nothing the
    /// first time, nothing while it stays, and nothing when macOS declines
    /// to say.
    nonisolated static func change(from old: Bool?, to new: Bool?) -> Bool? {
        guard let old, let new, old != new else { return nil }
        return new
    }
}
