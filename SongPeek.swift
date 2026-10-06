import Foundation

/// When a new song starts, the closed notch grows a little downward for a
/// moment to show its title and artist, then settles back.
///
/// Only for a *different* song that is *playing*, with the panel closed: not
/// on launch (the first song seen isn't a change), not when you resume the
/// same song, not when the open panel already shows it.
@MainActor
final class SongPeek {

    /// Long enough to read a title and an artist; short enough not to linger.
    static let duration: TimeInterval = 3.5

    private let model: NotchModel
    private var previous: Track?
    private var hide: DispatchWorkItem?

    init(model: NotchModel) {
        self.model = model
    }

    func trackChanged(to track: Track?) {
        if Self.shouldPeek(from: previous, to: track, expanded: model.isExpanded,
                           enabled: Preferences.showSongPeek) {
            show()
        }
        previous = track
    }

    func show() {
        model.peeking = true
        hide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.model.peeking = false }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration, execute: work)
    }

    nonisolated static func shouldPeek(from old: Track?, to new: Track?,
                                       expanded: Bool, enabled: Bool) -> Bool {
        guard enabled, !expanded, let old, let new, new.isPlaying else { return false }
        return !new.isSameTrack(as: old)
    }
}
