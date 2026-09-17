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
    enum Status { case starting, streaming, failed }

    /// The instance transport commands go through, when one is streaming.
    private(set) static weak var active: MediaRemoteNowPlaying?

    private var process: Process?
    private var buffer = Data()
    private var state: [String: Any] = [:]
    private var pausedSince: Date?
    private var artworkKey: String?
    private var artworkURL: URL?
    private var startupTimer: Timer?

    /// How long a paused track stays on screen before it's dropped — the same
    /// rule as the AppleScript source, for the same reasons.
    private static let pausedTimeout: TimeInterval = 15

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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, framework.path, "stream"]
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

        // MediaRemote answering at all is not guaranteed on a given macOS.
        // If nothing arrives in a few seconds — not even an empty payload,
        // which the stream sends when no player is active — give up and let
        // the coordinator fall back to AppleScript.
        startupTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.status == .starting else { return }
                NSLog("Resonata: MediaRemote adapter produced nothing; falling back")
                self.stop()
                self.status = .failed
            }
        }
    }

    func stop() {
        startupTimer?.invalidate()
        startupTimer = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        if Self.active === self { Self.active = nil }
    }

    // MARK: Stream

    private func ingest(_ data: Data) {
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

        if status == .starting {
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
        var track = Self.track(from: state, previous: self.track)

        // Same idle rule as the AppleScript source: a paused track stays for
        // a while, so the pill doesn't vanish the moment you pause to talk.
        if let t = track, !t.isPlaying {
            let since = pausedSince ?? Date()
            pausedSince = since
            isIdle = Date().timeIntervalSince(since) > Self.pausedTimeout
        } else {
            pausedSince = nil
            isIdle = false
        }

        // Artwork arrives as base64 in the payload. Write it once per song
        // and hand the views a file URL, like the Music path already does.
        if var t = track {
            let key = "\(t.title)\u{1F}\(t.album)\u{1F}\(t.artist)"
            if let base64 = state["artworkData"] as? String, key != artworkKey,
               let bytes = Data(base64Encoded: base64) {
                let ext = (state["artworkMimeType"] as? String)?.contains("png") == true ? "png" : "jpg"
                let url = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("resonata-mr-\(UUID().uuidString.prefix(8)).\(ext)")
                if (try? bytes.write(to: url)) != nil {
                    artworkKey = key
                    artworkURL = url
                }
            }
            if key == artworkKey { t.artworkURL = artworkURL }
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

    private static func track(from state: [String: Any], previous: Track?) -> Track? {
        guard let title = state["title"] as? String, !title.isEmpty else { return nil }
        let bundle = (state["bundleIdentifier"] as? String) ?? ""
        let sampledAt = (state["timestamp"] as? String).flatMap(iso.date(from:)) ?? Date()
        return Track(
            title: title,
            artist: (state["artist"] as? String) ?? "",
            album: (state["album"] as? String) ?? "",
            duration: (state["duration"] as? Double) ?? 0,
            sampledPosition: (state["elapsedTime"] as? Double) ?? 0,
            sampledAt: sampledAt,
            isPlaying: (state["playing"] as? Bool) ?? false,
            artworkURL: previous?.artworkURL,
            source: Self.appName(for: bundle) ?? bundle
        )
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
        Self.run(["seek", String(format: "%.3f", max(0, position))])
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
