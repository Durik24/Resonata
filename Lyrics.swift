import Combine
import CryptoKit
import Foundation

/// One timed line of a song.
struct LyricLine: Equatable {
    var time: TimeInterval
    var text: String
}

/// Fetches synced lyrics for whatever is playing and keeps them ready.
///
/// Source is LRCLIB (https://lrclib.net): free, no key, community-maintained,
/// and it serves lyrics in LRC form — `[mm:ss.xx] line` — which is exactly the
/// timestamped list the view needs. The interpolated playhead from
/// `Track.position(at:)` is what makes line-by-line highlighting stay in time;
/// against a once-a-second poll it would visibly lag.
@MainActor
final class LyricsStore: ObservableObject {

    /// Lines for the current track, or nil when there are none — not found,
    /// not synced, not fetched yet, or nothing playing.
    @Published private(set) var lines: [LyricLine]?

    /// A fetch is in flight for the current track. The view keeps the lyrics
    /// row's height reserved while this is true, so skipping tracks doesn't
    /// make the panel shrink and grow again a second later.
    @Published private(set) var isFetching = false

    private var current: String?
    private var task: Task<Void, Never>?

    /// Songs LRCLIB has already said no to, so a track that stays on repeat
    /// doesn't ask again every time the poller re-syncs.
    private var misses = Set<String>()

    private static let endpoint = URL(string: "https://lrclib.net/api")!

    /// LRCLIB asks for one. It's how they tell clients apart in their logs.
    private static let userAgent = "Resonata/1.0 (https://github.com/local/resonata)"

    /// On-disk cache: one `.lrc` per song under Caches. Lyrics don't change,
    /// and refetching them on every launch would be rude to a free service.
    private static let cacheDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("com.local.resonata/lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Points the store at `track`. Same song as last time is a no-op; nil
    /// clears the lines.
    func load(for track: Track?) {
        guard let track else {
            current = nil
            task?.cancel()
            lines = nil
            isFetching = false
            return
        }

        let key = Self.key(for: track)
        guard key != current else { return }
        current = key
        task?.cancel()
        lines = nil

        if misses.contains(key) { isFetching = false; return }

        if let cached = Self.readCache(key) {
            lines = cached
            isFetching = false
            return
        }

        isFetching = true
        task = Task { [weak self] in
            let result = await Self.fetch(track)
            guard !Task.isCancelled, let self, self.current == key else { return }
            self.isFetching = false
            if let result, !result.isEmpty {
                self.lines = result
                Self.writeCache(key, lines: result)
                NSLog("Resonata: lyrics loaded for \"%@\" (%d lines)", track.title, result.count)
            } else {
                self.misses.insert(key)
                NSLog("Resonata: no synced lyrics for \"%@\"", track.title)
            }
        }
    }

    // MARK: Identity

    /// Same fields `Track.isSameTrack(as:)` compares, plus duration, which
    /// LRCLIB uses to tell the album cut from the extended mix.
    private static func key(for track: Track) -> String {
        let raw = [track.title, track.artist, track.album, String(Int(track.duration))]
            .joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Fetching

    private struct Record: Decodable {
        var syncedLyrics: String?
    }

    /// Exact match first; a looser search if that misses.
    ///
    /// `/get` wants title, artist, album and duration to all line up, and a
    /// Spotify album title with "(Deluxe Edition)" on the end is enough to miss.
    /// `/search` on title and artist alone is forgiving, and the first result
    /// that actually has synced lyrics is almost always the right song.
    private static func fetch(_ track: Track) async -> [LyricLine]? {
        if let exact = await get(track), let lines = parse(exact) { return lines }

        var search = URLComponents(url: endpoint.appendingPathComponent("search"),
                                   resolvingAgainstBaseURL: false)!
        search.queryItems = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artist),
        ]
        guard let url = search.url,
              let data = await request(url),
              let records = try? JSONDecoder().decode([Record].self, from: data)
        else { return nil }

        for record in records {
            if let synced = record.syncedLyrics, let lines = parse(synced) { return lines }
        }
        return nil
    }

    private static func get(_ track: Track) async -> String? {
        var components = URLComponents(url: endpoint.appendingPathComponent("get"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "album_name", value: track.album),
            URLQueryItem(name: "duration", value: String(Int(track.duration.rounded()))),
        ]
        guard let url = components.url, let data = await request(url) else { return nil }
        return (try? JSONDecoder().decode(Record.self, from: data))?.syncedLyrics
    }

    private static func request(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200
        else { return nil }
        return data
    }

    // MARK: LRC

    /// `[mm:ss.xx] text`, one or more timestamps per line. Lines with no
    /// timestamp (metadata like `[ar:Artist]`) are dropped.
    private static let stamp = try! NSRegularExpression(
        pattern: #"\[(\d+):(\d{1,2}(?:\.\d+)?)\]"#
    )

    static func parse(_ lrc: String) -> [LyricLine]? {
        var out: [LyricLine] = []
        for rawLine in lrc.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let range = NSRange(line.startIndex..., in: line)
            let matches = stamp.matches(in: line, range: range)
            // `NSRange` counts UTF-16 units; walking that many *characters*
            // overran the string — a crash — whenever anything wider than one
            // unit, an emoji say, came before the stamp. Convert, don't count.
            guard let last = matches.last, let stamp = Range(last.range, in: line) else { continue }
            let text = line[stamp.upperBound...].trimmingCharacters(in: .whitespaces)

            for match in matches {
                guard let mr = Range(match.range(at: 1), in: line),
                      let sr = Range(match.range(at: 2), in: line),
                      let minutes = Double(line[mr]), let seconds = Double(line[sr])
                else { continue }
                out.append(LyricLine(time: minutes * 60 + seconds, text: text))
            }
        }
        out.sort { $0.time < $1.time }
        // A handful of timestamps with no words between them is a placeholder,
        // not lyrics.
        return out.filter { !$0.text.isEmpty }.count >= 4 ? out : nil
    }

    /// Index of the line that should be highlighted at `time` — the last one
    /// whose timestamp has passed. nil before the first line.
    static func index(in lines: [LyricLine], at time: TimeInterval) -> Int? {
        var lo = 0, hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= time { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }

    // MARK: Cache

    private static func readCache(_ key: String) -> [LyricLine]? {
        let url = cacheDirectory.appendingPathComponent(key + ".lrc")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text)
    }

    private static func writeCache(_ key: String, lines: [LyricLine]) {
        let url = cacheDirectory.appendingPathComponent(key + ".lrc")
        let text = lines.map { line -> String in
            let m = Int(line.time) / 60
            let s = line.time - Double(m * 60)
            return String(format: "[%02d:%05.2f] %@", m, s, line.text)
        }.joined(separator: "\n")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
