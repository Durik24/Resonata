import Foundation

/// Apple Music's heart for the current track.
///
/// Only Apple Music: it exposes `favorited` to AppleScript. Spotify has no
/// equivalent on the Mac — its scripting dictionary can't save a song, it
/// doesn't advertise a "like" command to the system's Now Playing, and the
/// MediaRemote helper has none to send — so there the heart isn't shown.
enum MusicFavorite {

    static let bundleID = "com.apple.Music"

    static let readSource = """
    tell application "Music" to get favorited of current track
    """

    static let toggleSource = """
    tell application "Music"
        set favorited of current track to not (favorited of current track)
        return favorited of current track
    end tell
    """

    /// Whether the current track is a favourite; nil when it can't be read.
    static func read(_ completion: @escaping @MainActor (Bool?) -> Void) {
        run(readSource, completion)
    }

    /// Flips the heart and reports the new state.
    static func toggle(_ completion: @escaping @MainActor (Bool?) -> Void) {
        run(toggleSource, completion)
    }

    private static let queue = DispatchQueue(label: "com.local.resonata.favorite", qos: .userInitiated)

    /// Off the main thread: `NSAppleScript` blocks.
    private static func run(_ source: String, _ completion: @escaping @MainActor (Bool?) -> Void) {
        queue.async {
            var error: NSDictionary?
            let output = NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error { NSLog("Resonata: Music favourite failed: \(error)") }
            let value: Bool? = error == nil ? output?.booleanValue : nil
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(value) } }
        }
    }
}
