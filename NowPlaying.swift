import AppKit
import Combine

struct Track: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval

    /// Where the playhead was as of `sampledAt` — deliberately *not* named
    /// `position`, because it is not where the playhead is now. The player is
    /// only asked every few seconds; read `position(at:)` for the live value.
    var sampledPosition: TimeInterval
    /// When `sampledPosition` was read out of the player.
    var sampledAt: Date

    var isPlaying: Bool
    var artworkURL: URL?
    var source: String   // "Spotify" / "Music"
}

extension Track {
    /// The playhead carried forward to `date` under its own steam.
    ///
    /// Nothing asks the player where it is between syncs any more, so the
    /// position has to be predicted from elapsed time. Paused playback doesn't
    /// advance, so the sample stands as it is.
    func position(at date: Date) -> TimeInterval {
        guard isPlaying else { return sampledPosition }
        let live = sampledPosition + date.timeIntervalSince(sampledAt)
        // Never run past the end. A track can finish between syncs, and a
        // progress bar reading 4:31 of 3:58 looks broken.
        return min(max(live, 0), duration > 0 ? duration : live)
    }

    /// Same song, ignoring everything that moves. Decides whether the playhead
    /// currently being carried still refers to what is actually playing.
    func isSameTrack(as other: Track) -> Bool {
        title == other.title && artist == other.artist
            && album == other.album && source == other.source
    }
}

extension Notification.Name {
    /// Posted after *we* change playback, so the sync happens at once instead
    /// of leaving the interpolated playhead on a stale anchor until the next
    /// safety-net tick. A seek is the case that matters: nothing else tells us
    /// the playhead just moved somewhere unpredictable.
    static let resonataDidCommandPlayer = Notification.Name("ResonataDidCommandPlayer")
}

/// Main-actor isolated: implementations drive `@Published` UI state, and the
/// swap-in replacement (mediaremote-adapter) will too. Without this the
/// conformance straddles actors and is an error under the Swift 6 language mode.
@MainActor
protocol NowPlayingSource: AnyObject {
    var track: Track? { get }
    var objectWillChange: ObservableObjectPublisher { get }
    func start()
    func stop()
}

// MARK: - AppleScript source
//
// Why AppleScript and not MediaRemote?
//
// The private MediaRemote framework used to be the answer — one call gave you
// system-wide now-playing for every app. As of macOS 15.4 the `mediaremoted`
// daemon checks for an entitlement Apple only grants its own processes, so
// MRMediaRemoteGetNowPlayingInfo returns nil for third-party apps. See the
// README for the two workarounds.
//
// Talking to Spotify and Music directly still works, needs no private API, and
// survives OS updates. It only covers those two apps, which for a music widget
// is usually fine.

@MainActor
final class AppleScriptNowPlaying: ObservableObject, NowPlayingSource {

    @Published private(set) var track: Track?

    private var timer: Timer?
    private let apps = ["Spotify", "Music"]

    /// Identity of the track whose Music artwork we've already extracted, so a
    /// once-a-second poll doesn't re-dump the same image to disk 60 times a
    /// minute.
    private var artworkKey: String?
    private var artworkURL: URL?

    /// How often the players are asked where they are, absent any notification.
    ///
    /// This was 1 second, and that single number was most of what the app cost
    /// at rest: 86,400 AppleScript round-trips a day, almost all of them
    /// learning that nothing had changed. Track and play-state changes now
    /// arrive as notifications instead, so this timer only has to catch what
    /// those miss — drift in the interpolated playhead, and a player quitting.
    private static let resyncInterval: TimeInterval = 10

    /// How far the player may be from where we predicted before we believe it
    /// over our own interpolation.
    ///
    /// Interpolation over a 10-second gap is accurate to a few milliseconds, so
    /// anything past this is a real jump — a seek, or a track change — not
    /// accumulated error.
    private static let driftTolerance: TimeInterval = 1.5

    private var distributedObservers: [NSObjectProtocol] = []
    private var localObservers: [NSObjectProtocol] = []

    func start() {
        poll()
        timer = Timer.scheduledTimer(
            withTimeInterval: Self.resyncInterval, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        observe()
    }

    /// Both players announce track and play-state changes system-wide, for free
    /// and without any permission. Listening for those is what lets the poll
    /// above drop to a tenth of its old rate: the moments that actually matter
    /// now push to us, rather than being discovered up to a second late.
    private func observe() {
        let distributed = DistributedNotificationCenter.default()
        for name in Self.playerNotifications {
            let token = distributed.addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            distributedObservers.append(token)
        }

        // Our own transport buttons and scrubs move the playhead without any
        // announcement arriving in time to be useful, so they tell us directly.
        let token = NotificationCenter.default.addObserver(
            forName: .resonataDidCommandPlayer, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        localObservers.append(token)
    }

    private static let playerNotifications = [
        "com.apple.iTunes.playerInfo",              // Music
        "com.spotify.client.PlaybackStateChanged",  // Spotify
    ]

    func stop() {
        timer?.invalidate()
        timer = nil
        for token in distributedObservers {
            DistributedNotificationCenter.default().removeObserver(token)
        }
        for token in localObservers {
            NotificationCenter.default.removeObserver(token)
        }
        distributedObservers.removeAll()
        localObservers.removeAll()
    }

    /// One serial queue for every AppleScript call.
    ///
    /// `NSAppleScript` is not thread-safe, and confining it here is what makes
    /// caching compiled scripts safe — see `compiledScripts`.
    private nonisolated static let scriptQueue = DispatchQueue(
        label: "com.local.resonata.applescript", qos: .utility
    )

    /// Compiled scripts, reused across polls.
    ///
    /// `NSAppleScript(source:)` recompiles from source on first execution, and
    /// we were paying that every single second. Only ever touched on
    /// `scriptQueue`, which is what makes the unchecked mutable state sound.
    private nonisolated(unsafe) static var compiledScripts: [String: NSAppleScript] = [:]

    private func poll() {
        Self.scriptQueue.async { [weak self, apps] in
            var found: Track?
            for app in apps {
                guard NSWorkspace.shared.runningApplications.contains(where: {
                    $0.localizedName == app
                }) else { continue }
                if let t = Self.query(app: app) {
                    found = t
                    if t.isPlaying { break }   // prefer whichever is actually playing
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(found) }
            }
        }
    }

    /// Compiles once per app, then hands back the cached instance.
    private nonisolated static func script(for app: String, source: String) -> NSAppleScript? {
        dispatchPrecondition(condition: .onQueue(scriptQueue))
        if let existing = compiledScripts[app] { return existing }
        let script = NSAppleScript(source: source)
        script?.compileAndReturnError(nil)
        compiledScripts[app] = script
        return script
    }

    /// How long a paused track stays on screen before it's dropped.
    ///
    /// Not zero: hiding the instant you hit pause makes the notch flicker every
    /// time you pause to talk to someone, and it takes the transport controls
    /// away exactly when you want to press play. Not never, either — a track
    /// paused half an hour ago is just stale.
    private static let pausedTimeout: TimeInterval = 15

    private var pausedSince: Date?

    /// Playback has been stopped or paused long enough that the collapsed pill
    /// should go quiet — but the track itself is kept, so opening the notch
    /// still shows what was playing and can start it again.
    @Published private(set) var isIdle = false

    private func apply(_ incoming: Track?) {
        var track = incoming

        // A stopped player reports nothing at all. As long as its app is still
        // open, hold on to the last song rather than forgetting it: the whole
        // point of the expanded view here is to press play again.
        if track == nil, var previous = self.track,
           NSWorkspace.shared.runningApplications.contains(where: {
               $0.localizedName == previous.source
           }) {
            previous.isPlaying = false
            track = previous
        }

        if let t = track, !t.isPlaying {
            let since = pausedSince ?? Date()
            pausedSince = since
            // Only hides it in the collapsed pill. The metadata stays put.
            isIdle = Date().timeIntervalSince(since) > Self.pausedTimeout
        } else {
            pausedSince = nil
            isIdle = false
        }

        // Music exposes artwork as raw image data, not a URL, so there's
        // nothing for AsyncImage to load. Dump it to a file once per track and
        // hand back a file:// URL instead of falling back to the placeholder.
        if var t = track, t.source == "Music", t.artworkURL == nil {
            let key = "\(t.title)\u{1F}\(t.album)\u{1F}\(t.artist)"
            if key != artworkKey {
                artworkKey = key
                artworkURL = Self.extractMusicArtwork()
            }
            t.artworkURL = artworkURL
            track = t
        } else if track?.source != "Music" {
            artworkKey = nil
            artworkURL = nil
        }

        // Keep the existing anchor when the player turns out to be exactly
        // where we predicted. Re-anchoring on every sync would republish
        // `track` — and so redraw the notch — several times a minute with
        // nothing to show for it, and the small disagreement between our clock
        // and the player's would make the progress bar twitch backwards each
        // time. What's left after this check is a genuine jump: a seek, or a
        // new song. Those *should* re-anchor.
        if var t = track, let previous = self.track,
           t.isSameTrack(as: previous), t.isPlaying == previous.isPlaying,
           abs(previous.position(at: t.sampledAt) - t.sampledPosition) < Self.driftTolerance {
            t.sampledPosition = previous.sampledPosition
            t.sampledAt = previous.sampledAt
            track = t
        }

        if self.track != track { self.track = track }
    }

    /// Writes the current Music track's artwork to a temp file and returns it.
    ///
    /// The filename carries a counter so the URL changes between tracks —
    /// AsyncImage keys off the URL, and reusing one path would leave the
    /// previous album's art on screen.
    private nonisolated static func extractMusicArtwork() -> URL? {
        let path = NSTemporaryDirectory()
            + "resonata-artwork-\(UUID().uuidString.prefix(8)).dat"
        let script = """
        tell application "Music"
            if player state is stopped then return ""
            try
                set d to raw data of artwork 1 of current track
            on error
                return ""
            end try
        end tell
        try
            set fh to open for access (POSIX file "\(path)") with write permission
            set eof fh to 0
            write d to fh
            close access fh
        on error
            try
                close access (POSIX file "\(path)")
            end try
            return ""
        end try
        return "\(path)"
        """

        var error: NSDictionary?
        let output = NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            NSLog("Resonata: Music artwork extraction failed: \(error)")
            return nil
        }
        guard let result = output?.stringValue, !result.isEmpty else { return nil }
        return URL(fileURLWithPath: result)
    }

    /// Returns the fields joined by `separator`.
    private nonisolated static func query(app: String) -> Track? {
        // Spotify reports duration in milliseconds and exposes `artwork url`.
        // Music reports seconds and has no URL, so we leave artwork empty there
        // and let the UI fall back to a placeholder (or fetch from iTunes API).
        // NB: `st` is a reserved word in AppleScript — `set st to ...` is a
        // compile error, not a runtime one, so the whole script fails to build
        // and every poll silently returns nil. Don't rename these back.
        let script: String
        if app == "Spotify" {
            script = """
            tell application "Spotify"
                if player state is stopped then return "stopped"
                set sep to (character id 31)
                set playerState to (player state as text)
                set t to current track
                return playerState & sep & (name of t) & sep & (artist of t) & sep ¬
                    & (album of t) & sep & ((duration of t) / 1000) & sep ¬
                    & (player position) & sep & (artwork url of t)
            end tell
            """
        } else {
            script = """
            tell application "Music"
                if player state is stopped then return "stopped"
                set sep to (character id 31)
                set playerState to (player state as text)
                set t to current track
                return playerState & sep & (name of t) & sep & (artist of t) & sep ¬
                    & (album of t) & sep & (duration of t) & sep ¬
                    & (player position) & sep & ""
            end tell
            """
        }

        var error: NSDictionary?
        let output = Self.script(for: app, source: script)?
            .executeAndReturnError(&error)
        if let error {
            // Loud on purpose. A silent nil here is indistinguishable from
            // "nothing is playing", which is how the reserved-word bug above
            // survived: the UI just looked empty forever.
            NSLog("Resonata: AppleScript to \(app) failed: \(error)")
            return nil
        }
        guard let raw = output?.stringValue else { return nil }

        let parts = raw.components(separatedBy: Self.separator)
        guard parts.count >= 6, parts[0] != "stopped" else { return nil }

        return Track(
            title: parts[1],
            artist: parts[2],
            album: parts[3],
            duration: number(parts[4]),
            sampledPosition: number(parts[5]),
            // Stamped here rather than on the main thread, so the queue hop
            // back doesn't get counted as elapsed playback.
            sampledAt: Date(),
            isPlaying: parts[0] == "playing",
            artworkURL: parts.count > 6 ? URL(string: parts[6]) : nil,
            source: app
        )
    }

    /// ASCII unit separator. A literal `"|"` was fine until a track was named
    /// something like "Nothing/Nowhere | Reprise" — then the field count shifts
    /// and the artist becomes the album. A control character can't occur in
    /// metadata, so the split is unambiguous.
    private nonisolated static let separator = "\u{1F}"

    /// AppleScript formats numbers in the *user's* locale, so on a Czech or
    /// German system a duration arrives as `"124,615"`. `Double(_:)` is
    /// POSIX-only and returns nil for that, which zeroed the scrubber on every
    /// machine that doesn't use a decimal point.
    private nonisolated static func number(_ string: String) -> Double {
        Double(string)
            ?? Double(string.replacingOccurrences(of: ",", with: "."))
            ?? 0
    }
}

// MARK: - Transport controls

enum MediaKey: Int32 {
    case playPause = 16
    case next      = 19
    case previous  = 20
}

/// Posts a system-wide media key. Works with every player, including browsers,
/// and doesn't care which app is frontmost.
///
/// Requires Accessibility permission (System Settings → Privacy & Security →
/// Accessibility). If you'd rather not ask for that, send `next track` /
/// `playpause` to Spotify or Music over AppleScript instead — same idea, but
/// only for those two apps.
func postMediaKey(_ key: MediaKey) {
    func send(down: Bool) {
        let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
        let data1 = Int((key.rawValue << 16) | ((down ? 0xA : 0xB) << 8))
        NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        )?.cgEvent?.post(tap: .cghidEventTap)
    }
    send(down: true)
    send(down: false)
}

/// Transport commands sent straight to the player over AppleScript.
///
/// This is deliberately *not* `postMediaKey`. That posts a system-wide HID
/// event, which needs Accessibility permission — and since `build.sh` re-signs
/// ad-hoc on every build, the app's identity changes each time and any grant
/// you made is silently void. The buttons then do nothing, with no error.
///
/// Talking to the player directly reuses the Automation permission we already
/// hold for reading now-playing, so the buttons work the moment the metadata
/// does. Trade-off: only Spotify and Music, where the media keys drove any
/// player. For a widget that already reads from those two, that's no loss.
enum TransportCommand: String {
    case playPause = "playpause"
    case next = "next track"
    case previous = "previous track"
}

func transport(_ command: TransportCommand, in app: String) {
    let script = "tell application \"\(app)\" to \(command.rawValue)"
    Task.detached(priority: .userInitiated) {
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error { NSLog("Resonata: \(command.rawValue) failed: \(error)") }
        await MainActor.run {
            NotificationCenter.default.post(name: .resonataDidCommandPlayer, object: nil)
        }
    }
}

/// Jumps the player to `position` seconds. `player position` is settable in both
/// Spotify's and Music's dictionaries, which is what makes drag-scrubbing work
/// — media keys can't express "seek".
///
/// Runs off the main thread: `NSAppleScript` blocks, and a scrub sends one of
/// these per drag update.
func seek(to position: TimeInterval, in app: String) {
    let clamped = max(0, position)
    // %.3f formats POSIX-style regardless of locale. Handing AppleScript a
    // comma-separated number here would be a syntax error.
    let script = """
    tell application "\(app)" to set player position to \(String(format: "%.3f", clamped))
    """
    Task.detached(priority: .userInitiated) {
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error { NSLog("Resonata: seek failed: \(error)") }
        // Re-sync at once. Nothing else would tell us the playhead moved, and
        // the interpolation would otherwise carry on from the pre-seek anchor
        // until the next safety-net tick — up to ten seconds of visibly wrong
        // progress bar.
        await MainActor.run {
            NotificationCenter.default.post(name: .resonataDidCommandPlayer, object: nil)
        }
    }
}
