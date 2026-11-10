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
    private static let userAgent = "Resonata/1.0 (https://github.com/Durik24/Resonata)"

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
        // Nothing playing — or nothing that's a song: a podcast, a film, a
        // live stream. Then LRCLIB isn't asked, and what's playing stays on
        // this Mac. See `shouldLookUp`.
        guard let track, Self.shouldLookUp(track) else {
            current = nil
            task?.cancel()
            // Only when they change: this is called on every settings change
            // too, and publishing "still nothing" each time redrew the panel.
            if lines != nil { lines = nil }
            if isFetching { isFetching = false }
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
            // No answer at all — offline, say, just after waking — isn't
            // LRCLIB saying no. Remembered as a miss, the song never got its
            // lyrics until Resonata restarted; it's asked again instead, less
            // and less often, for as long as the song is the current one.
            var wait: Duration = .seconds(15)
            while true {
                let outcome = await Self.fetch(track)
                guard !Task.isCancelled, let self, self.current == key else { return }
                switch outcome {
                case .lines(let result):
                    self.isFetching = false
                    self.lines = result
                    Self.writeCache(key, lines: result)
                    NSLog("Resonata: lyrics loaded for \"%@\" (%d lines)", track.title, result.count)
                    return
                case .none:
                    self.isFetching = false
                    self.misses.insert(key)
                    NSLog("Resonata: no synced lyrics for \"%@\"", track.title)
                    return
                case .failed:
                    self.isFetching = false
                    NSLog("Resonata: lyrics lookup failed for \"%@\"; again in %@",
                          track.title, "\(wait)")
                }
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled, self.current == key else { return }
                wait = min(wait * 2, .seconds(240))
                self.isFetching = true
            }
        }
    }

    // MARK: What to look up

    /// Song lengths: half a minute to a quarter of an hour.
    nonisolated static let songLengths: ClosedRange<TimeInterval> = 30...(15 * 60)

    /// Whether `track` is worth asking LRCLIB about.
    ///
    /// Every title and artist used to go there — a YouTube video's, a
    /// podcast episode's, a film's. None of those have synced lyrics, and
    /// what you watch is nobody's business. Asked only for something that
    /// has an artist and runs as long as a song does; a live stream has no
    /// length at all. It also waits out the moment at a song change when the
    /// title has arrived and the length hasn't, which used to cost a second
    /// lookup for every song.
    nonisolated static func shouldLookUp(_ track: Track) -> Bool {
        !track.artist.trimmingCharacters(in: .whitespaces).isEmpty && songLengths.contains(track.duration)
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
        /// The recording's length in seconds, as LRCLIB has it.
        var duration: Double?
    }

    /// What a lookup came to: lyrics, a clear "none", or no answer at all.
    enum Outcome { case lines([LyricLine]), none, failed }

    /// One request's answer: the body, LRCLIB's 404, or nothing usable.
    private enum Answer { case data(Data), notFound, failed }

    /// Exact match first; a looser search if that misses.
    ///
    /// `/get` wants title, artist, album and duration to all line up, and a
    /// Spotify album title with "(Deluxe Edition)" on the end is enough to miss.
    /// `/search` on title and artist alone is forgiving, and the first result
    /// that actually has synced lyrics is almost always the right song.
    private static func fetch(_ track: Track) async -> Outcome {
        var exact = URLComponents(url: endpoint.appendingPathComponent("get"),
                                  resolvingAgainstBaseURL: false)!
        exact.queryItems = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "album_name", value: track.album),
            URLQueryItem(name: "duration", value: String(Int(track.duration.rounded()))),
        ]
        guard let exactURL = exact.url else { return .failed }
        switch await request(exactURL) {
        case .failed: return .failed
        case .notFound: break
        case .data(let data):
            if let synced = (try? JSONDecoder().decode(Record.self, from: data))?.syncedLyrics,
               let lines = parse(synced) { return .lines(lines) }
        }

        var search = URLComponents(url: endpoint.appendingPathComponent("search"),
                                   resolvingAgainstBaseURL: false)!
        search.queryItems = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artist),
        ]
        guard let searchURL = search.url else { return .failed }
        switch await request(searchURL) {
        case .failed: return .failed
        case .notFound: return .none
        case .data(let data):
            let records = (try? JSONDecoder().decode([Record].self, from: data)) ?? []
            // Those that really have timed lyrics, then the one nearest this
            // recording's length — see `closest`.
            let timed = records.compactMap { record -> (duration: Double?, lines: [LyricLine])? in
                guard let synced = record.syncedLyrics, let lines = parse(synced) else { return nil }
                return (record.duration, lines)
            }
            guard let best = closest(timed.map(\.duration), to: track.duration) else { return .none }
            return .lines(timed[best].lines)
        }
    }

    /// How far a search result's length may be from the song's and still be
    /// taken for the same recording.
    nonisolated static let lengthTolerance: TimeInterval = 10

    /// Which search result to use for a song `duration` seconds long, given
    /// each result's own length; nil for none of them.
    ///
    /// The search goes by title and artist alone, so it returns the live
    /// version and the remix along with the album cut. Taking the first with
    /// lyrics — as this used to — showed lines timed for another recording:
    /// right words, drifting further out of time as the song went on. The
    /// nearest in length is the same recording or as good as; one more than
    /// `lengthTolerance` out isn't, and no lyrics beat wrong ones.
    nonisolated static func closest(_ durations: [Double?], to duration: TimeInterval) -> Int? {
        guard !durations.isEmpty else { return nil }
        // Nothing to compare with: the first, as before.
        guard duration > 0 else { return 0 }
        var best: (index: Int, gap: Double)?
        for (index, length) in durations.enumerated() {
            guard let length, length > 0 else { continue }
            let gap = abs(length - duration)
            if gap < (best?.gap ?? .infinity) { best = (index, gap) }
        }
        guard let best else { return 0 }
        return best.gap <= lengthTolerance ? best.index : nil
    }

    private static func request(_ url: URL) async -> Answer {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { return .failed }
        switch http.statusCode {
        case 200: return .data(data)
        case 404: return .notFound
        default: return .failed
        }
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
