import AppKit
import Combine
import Foundation

/// Now-playing for *every* player — browsers, VLC, podcasts — via MediaRemote.
///
/// MediaRemote is the private framework behind Control Center's Now Playing
/// tile. Since macOS 15.4 it only answers Apple-signed processes, and
/// `/usr/bin/perl` is one: the vendored adapter (see `Vendor/mediaremote-
/// adapter`) is a Perl script that loads a small framework and streams JSON.
/// This class runs that script and turns its payloads into `Track`s. Where
/// `AppleScriptNowPlaying` can only see Spotify and Music, this sees whatever
/// the system's own Now Playing sees.
///
/// Commands go the same way: `send N` and `seek T` subcommands, so the
/// transport buttons work for a YouTube tab too.
@MainActor
final class MediaRemoteNowPlaying: ObservableObject, NowPlayingSource {

    @Published private(set) var track: Track?
    @Published private(set) var isIdle = false

    /// Set once the stream has produced its first payload, or failed. The
    /// coordinator waits on this to decide whether to fall back to
    /// AppleScript.
    @Published private(set) var status: Status = .starting
    enum Status {
        case starting
        case streaming
        /// Running, but nothing has come out yet. Right after login
        /// `mediaremoted` can be slow to answer; the coordinator covers with
        /// AppleScript meanwhile, and this still turns into `.streaming` the
        /// moment the first payload arrives.
        case silent
        /// The helper is gone. Final.
        case failed
    }

    /// The instance transport commands go through, when one is streaming.
    private(set) static weak var active: MediaRemoteNowPlaying?

    private var process: Process?
    private var buffer = Data()
    private var state: [String: Any] = [:]
    private var pausedSince: Date?
    /// The base64 artwork currently on disk, and where. Keyed on the artwork
    /// *data*, not the song: see `apply`.
    private var artworkSource: String?
    private var artworkURL: URL?
    private var startupTimer: Timer?
    private var idleTimer: Timer?

    /// How long a paused track stays on screen before it's dropped — the same
    /// rule as the AppleScript source, for the same reasons.
    private static let pausedTimeout: TimeInterval = 10

    private nonisolated static var scriptURL: URL? {
        Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl")
    }
    private nonisolated static var frameworkURL: URL? {
        Bundle.main.privateFrameworksURL?.appendingPathComponent("MediaRemoteAdapter.framework")
    }

    /// Both pieces are in the bundle. Says nothing about whether MediaRemote
    /// will actually answer — only `status` does.
    static var isBundled: Bool {
        guard let script = scriptURL, let framework = frameworkURL else { return false }
        return FileManager.default.fileExists(atPath: script.path)
            && FileManager.default.fileExists(atPath: framework.path)
    }

    func start() {
        guard let script = Self.scriptURL, let framework = Self.frameworkURL else {
            status = .failed
            return
        }

        Self.reapOrphans(of: script)
        Self.removeStaleArtwork()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        // `--micros`: the plain stream stamps updates to the whole second,
        // which put the interpolated playhead — and the lyrics — up to a
        // second early. Measured: 06:53:56 printed for 06:53:56.964.
        process.arguments = [script.path, framework.path, "stream", "--micros"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.ingest(data) }
            }
        }
        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.process === proc else { return }
                    NSLog("Resonata: MediaRemote adapter exited (%d)", proc.terminationStatus)
                    self.process = nil
                    if Self.active === self { Self.active = nil }
                    self.status = .failed
                }
            }
        }

        do {
            try process.run()
        } catch {
            NSLog("Resonata: could not start the MediaRemote adapter: \(error)")
            status = .failed
            return
        }
        self.process = process

        // The stream prints an empty payload when nothing is playing, so
        // silence means MediaRemote hasn't answered — not that nothing plays.
        // After a few seconds of it, let AppleScript cover, but keep the
        // helper running: at login it's usually just slow. Killing it here
        // used to strand the app on AppleScript until the next launch.
        startupTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.status == .starting else { return }
                NSLog("Resonata: MediaRemote silent so far; covering with AppleScript")
                self.status = .silent
            }
        }
    }

    func stop() {
        startupTimer?.invalidate()
        startupTimer = nil
        idleTimer?.invalidate()
        idleTimer = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        if Self.active === self { Self.active = nil }
    }

    /// Ends helpers left behind by an earlier run.
    ///
    /// A force-quit or crash skips `stop()`, and the helper carries on with
    /// launchd as its parent, streaming to nobody. Only processes adopted by
    /// launchd (parent 1) that are running *this* script are touched.
    private static func reapOrphans(of script: URL) {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-P", "1", "-f", NSRegularExpression.escapedPattern(for: script.path)]
        pkill.standardOutput = FileHandle.nullDevice
        pkill.standardError = FileHandle.nullDevice
        try? pkill.run()
        pkill.waitUntilExit()
    }

    /// Artwork files from earlier runs. Each run deletes its own as songs
    /// change, but the last one of a run outlives it.
    private static func removeStaleArtwork() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where name.hasPrefix("resonata-mr-") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    // MARK: Stream

    /// Internal rather than private so `Tests/` can feed it recorded stream
    /// output; nothing else in the app calls it.
    func ingest(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(line: Data(line))
        }
    }

    private func handle(line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              (object["type"] as? String) == "data",
              let payload = object["payload"] as? [String: Any]
        else { return }

        if status == .starting || status == .silent {
            status = .streaming
            startupTimer?.invalidate()
            Self.active = self
        }

        let diff = (object["diff"] as? Bool) ?? false
        if diff {
            for (key, value) in payload {
                if value is NSNull { state.removeValue(forKey: key) } else { state[key] = value }
            }
        } else {
            state = payload.filter { !($0.value is NSNull) }
        }
        apply()
    }

    private func apply() {
        var track = Self.track(from: state)

        // Same idle rule as the AppleScript source: a paused track stays for
        // a while, so the pill doesn't vanish the moment you pause to talk.
        //
        // Unlike that source, nothing here polls: a paused player sends no
        // further payloads, so the question "paused long enough yet?" would
        // never be asked again and the pill never went idle. The timer asks
        // it once the timeout has passed.
        idleTimer?.invalidate()
        idleTimer = nil
        if let t = track, !t.isPlaying {
            let since = pausedSince ?? Date()
            pausedSince = since
            let elapsed = Date().timeIntervalSince(since)
            isIdle = elapsed > Self.pausedTimeout
            if !isIdle {
                idleTimer = Timer.scheduledTimer(
                    withTimeInterval: Self.pausedTimeout - elapsed + 0.1, repeats: false
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.apply() }
                }
            }
        } else {
            pausedSince = nil
            isIdle = false
        }

        // Artwork arrives as base64 in the payload; write it to a file the
        // views can load.
        //
        // Keyed on the artwork *data*, not on the song. A track change arrives
        // as diffs — the new title first, the new artwork in a later one — so
        // keying on the song wrote the *previous* cover under the new title
        // and then, seeing the song already had artwork, ignored the real one.
        if let base64 = state["artworkData"] as? String {
            if base64 != artworkSource, let bytes = Data(base64Encoded: base64) {
                let ext = (state["artworkMimeType"] as? String)?.contains("png") == true ? "png" : "jpg"
                let url = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("resonata-mr-\(UUID().uuidString.prefix(8)).\(ext)")
                if (try? bytes.write(to: url)) != nil {
                    // One file at a time; these used to pile up per song.
                    if let old = artworkURL { try? FileManager.default.removeItem(at: old) }
                    artworkSource = base64
                    artworkURL = url
                }
            }
        } else if let old = artworkURL {
            try? FileManager.default.removeItem(at: old)
            artworkSource = nil
            artworkURL = nil
        }
        if var t = track {
            t.artworkURL = artworkURL
            track = t
        }

        // Keep the interpolation anchor unless the player really jumped —
        // the same drift rule the AppleScript source applies.
        if var t = track, let previous = self.track, t.isSameTrack(as: previous),
           t.isPlaying == previous.isPlaying,
           abs(previous.position(at: t.sampledAt) - t.sampledPosition) < 1.5 {
            t.sampledPosition = previous.sampledPosition
            t.sampledAt = previous.sampledAt
            track = t
        }

        if self.track != track { self.track = track }
    }

    private static let iso = ISO8601DateFormatter()

    private static func track(from state: [String: Any]) -> Track? {
        guard let title = state["title"] as? String, !title.isEmpty else { return nil }
        let bundle = (state["bundleIdentifier"] as? String) ?? ""
        return Track(
            title: title,
            artist: (state["artist"] as? String) ?? "",
            album: (state["album"] as? String) ?? "",
            duration: seconds(state, micros: "durationMicros", plain: "duration") ?? 0,
            sampledPosition: seconds(state, micros: "elapsedTimeMicros", plain: "elapsedTime") ?? 0,
            sampledAt: sampledAt(state),
            isPlaying: (state["playing"] as? Bool) ?? false,
            artworkURL: nil,
            source: Self.appName(for: bundle) ?? bundle
        )
    }

    /// A duration, preferring the microsecond field `--micros` provides and
    /// falling back to the plain one in seconds.
    private static func seconds(_ state: [String: Any], micros: String, plain: String) -> Double? {
        if let us = (state[micros] as? NSNumber)?.doubleValue { return us / 1_000_000 }
        return (state[plain] as? NSNumber)?.doubleValue
    }

    /// When the elapsed time was valid. Microsecond epoch when available; the
    /// ISO string is whole seconds only.
    private static func sampledAt(_ state: [String: Any]) -> Date {
        if let us = (state["timestampEpochMicros"] as? NSNumber)?.doubleValue {
            return Date(timeIntervalSince1970: us / 1_000_000)
        }
        return (state["timestamp"] as? String).flatMap(iso.date(from:)) ?? Date()
    }

    /// "Spotify", "Safari", "VLC" — for display, and so the AppleScript path
    /// still recognises the two apps it knows if it ever has to take over.
    private static func appName(for bundle: String) -> String? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.localizedName
    }

    // MARK: Commands

    /// MediaRemote command codes, as the adapter's `send` expects them.
    enum Command: Int {
        case play = 0, pause = 1, togglePlayPause = 2, stop = 3, nextTrack = 4, previousTrack = 5
    }

    nonisolated func send(_ command: Command) {
        Self.run(["send", String(command.rawValue)])
    }

    nonisolated func seek(to position: TimeInterval) {
        // An integer number of *microseconds* — the adapter divides by a
        // million itself. Seconds with a decimal point parse as nothing and
        // seek to zero.
        Self.run(["seek", String(Int((max(0, position) * 1_000_000).rounded()))])
    }

    private nonisolated static func run(_ arguments: [String]) {
        guard let script = scriptURL, let framework = frameworkURL else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, framework.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            NSLog("Resonata: MediaRemote command failed: \(error)")
        }
    }
}
