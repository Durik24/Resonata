// Tests for the parts of Resonata that are pure logic: the playhead, the
// lyrics parser, the FFT and beat detector, and the MediaRemote stream.
//
// No XCTest: this builds with the same bare `swiftc` the app does, so
// `./test.sh` needs nothing but the command-line tools. Each check prints
// on failure; the run exits non-zero if any failed.

import AppKit
import Foundation
import SwiftUI

// Line-buffered, so results already printed survive a crash in a later test.
setvbuf(stdout, nil, _IOLBF, 0)

nonisolated(unsafe) var failures: [String] = []
nonisolated(unsafe) var passed = 0

func check(_ condition: @autoclosure () -> Bool, _ name: String,
           _ detail: @autoclosure () -> String = "") {
    if condition() {
        passed += 1
    } else {
        let extra = detail()
        failures.append(name)
        print("FAIL  \(name)\(extra.isEmpty ? "" : "  —  \(extra)")")
    }
}

func approx(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool {
    abs(a - b) <= tolerance
}

// MARK: - Playhead

let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

func track(_ position: Double, playing: Bool, duration: Double = 100,
           title: String = "A") -> Track {
    Track(title: title, artist: "X", album: "Y", duration: duration,
          sampledPosition: position, sampledAt: t0, isPlaying: playing,
          artworkURL: nil, source: "Spotify")
}

check(approx(track(10, playing: true).position(at: t0 + 5), 15),
      "playhead: advances while playing")
check(approx(track(10, playing: false).position(at: t0 + 5), 10),
      "playhead: holds while paused")
check(approx(track(10, playing: true).position(at: t0 + 500), 100),
      "playhead: stops at the end of the track")
check(approx(track(10, playing: true).position(at: t0 - 50), 0),
      "playhead: never negative")
check(approx(track(10, playing: true, duration: 0).position(at: t0 + 5), 15),
      "playhead: unknown duration does not clamp")
check(track(1, playing: true).isSameTrack(as: track(42, playing: false)),
      "same song: ignores position and play state")
check(!track(1, playing: true).isSameTrack(as: track(1, playing: true, title: "B")),
      "same song: a different title is a different song")

// MARK: - AppleScript number parsing (Czech locale sends commas)

check(approx(AppleScriptNowPlaying.number("124,615"), 124.615), "number: comma decimal")
check(approx(AppleScriptNowPlaying.number("12.5"), 12.5), "number: point decimal")
check(AppleScriptNowPlaying.number("") == 0, "number: empty is zero")

// MARK: - Lyrics

MainActor.assumeIsolated {
    let numb = """
    [ar:Linkin Park]
    [ti:Numb]
    [00:22.54] I'm tired of being what you want me to be
    [00:27.10] Feeling so faithless, lost under the surface
    [00:31.80] Don't know what you're expecting of me
    [00:36.05] Put under the pressure of walking in your shoes
    """
    let lines = LyricsStore.parse(numb)
    check(lines?.count == 4, "LRC: metadata tags dropped, timed lines kept",
          "\(lines?.count ?? -1) lines")
    check(approx(lines?.first?.time ?? -1, 22.54), "LRC: mm:ss.xx parsed")
    check(lines?.first?.text == "I'm tired of being what you want me to be",
          "LRC: text after the stamp, trimmed")

    let chorus = LyricsStore.parse(
        "[00:10.00][01:10.00] chorus\n[00:05.00] a\n[00:20.00] b\n[00:30.00] c")
    check(chorus?.map(\.time) == [5, 10, 20, 30, 70],
          "LRC: a line with two stamps appears twice, sorted",
          "\(chorus?.map(\.time) ?? [])")

    check(LyricsStore.parse("[00:01.00] a\n[00:02.00] b\n[00:03.00]\n[00:04.00]") == nil,
          "LRC: under four sung lines is a placeholder, not lyrics")

    let crlf = LyricsStore.parse("[00:01.00] a\r\n[00:02.00] b\r\n[00:03.00] c\r\n[00:04.00] d\r\n")
    check(crlf?.map(\.text) == ["a", "b", "c", "d"], "LRC: Windows line endings")

    let forms = LyricsStore.parse("[01:05.50] a\n[01:06] b\n[01:07.1] c\n[01:08.123] d")
    check(forms?.map(\.time) == [65.5, 66, 67.1, 68.123], "LRC: every stamp precision",
          "\(forms?.map(\.time) ?? [])")

    let three = [LyricLine(time: 10, text: "a"), LyricLine(time: 20, text: "b"),
                 LyricLine(time: 30, text: "c")]
    check(LyricsStore.index(in: [], at: 5) == nil, "lyrics index: no lines")
    check(LyricsStore.index(in: three, at: 5) == nil, "lyrics index: before the first line")
    check(LyricsStore.index(in: three, at: 10) == 0, "lyrics index: exactly on a line")
    check(LyricsStore.index(in: three, at: 25) == 1, "lyrics index: between lines")
    check(LyricsStore.index(in: three, at: 999) == 2, "lyrics index: after the last line")
}

// MARK: - MediaRemote stream

func streamLine(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object) + Data([0x0A])
}

func fileText(_ url: URL?) -> String? {
    url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
}

MainActor.assumeIsolated {
    let artA = Data("artwork-A".utf8).base64EncodedString()
    let artB = Data("artwork-B".utf8).base64EncodedString()

    // Exactly what `stream --micros` prints.
    let source = MediaRemoteNowPlaying()
    source.ingest(streamLine(["type": "data", "diff": false, "payload": [
        "title": "Song A", "artist": "X", "album": "One", "playing": true,
        "durationMicros": 185_000_000, "elapsedTimeMicros": 30_500_000,
        "timestampEpochMicros": 1_790_837_636_964_104,
        "artworkData": artA, "artworkMimeType": "image/jpeg",
    ]]))
    check(source.track?.title == "Song A", "MediaRemote: full payload becomes a track")
    check(approx(source.track?.sampledPosition ?? -1, 30.5), "MediaRemote: elapsed time in micros",
          "\(source.track?.sampledPosition ?? -1)")
    check(approx(source.track?.duration ?? -1, 185), "MediaRemote: duration in micros")
    check(approx(source.track?.sampledAt.timeIntervalSince1970 ?? 0, 1_790_837_636.964104, 1e-4),
          "MediaRemote: timestamp keeps sub-second precision",
          "\(source.track?.sampledAt.timeIntervalSince1970 ?? 0)")
    check(fileText(source.track?.artworkURL) == "artwork-A", "MediaRemote: artwork written for the song")

    // Track change: the title arrives first, the new artwork in a later diff.
    source.ingest(streamLine(["type": "data", "diff": true, "payload": [
        "title": "Song B", "album": "Two"]]))
    source.ingest(streamLine(["type": "data", "diff": true, "payload": ["artworkData": artB]]))
    check(source.track?.title == "Song B", "MediaRemote: diff updates the title")
    check(fileText(source.track?.artworkURL) == "artwork-B",
          "MediaRemote: new artwork shows even when it arrives after the title",
          "showing \(fileText(source.track?.artworkURL) ?? "nil")")

    source.ingest(streamLine(["type": "data", "diff": true, "payload": ["artworkData": NSNull()]]))
    check(source.track?.artworkURL == nil, "MediaRemote: artwork cleared when the player drops it")

    // A line split across two pipe reads.
    let split = streamLine(["type": "data", "diff": false, "payload": ["title": "Split", "playing": false]])
    source.ingest(split.prefix(12))
    check(source.track?.title == "Song B", "MediaRemote: half a line is not parsed yet")
    source.ingest(split.dropFirst(12))
    check(source.track?.title == "Split", "MediaRemote: the line completes on the next read")

    source.ingest(streamLine(["type": "data", "diff": false, "payload": [:] as [String: Any]]))
    check(source.track == nil, "MediaRemote: empty payload means nothing is playing")
}

// MARK: - Volume

// Up is louder whatever the natural-scrolling setting: the device direction is
// what counts, not the direction the content would scroll.
check(SystemVolume.scrollDelta(deltaY: -10, precise: true, inverted: true) > 0,
      "volume: fingers up on a trackpad (natural scrolling) turns it up")
check(SystemVolume.scrollDelta(deltaY: 10, precise: true, inverted: false) > 0,
      "volume: fingers up on a trackpad (classic scrolling) turns it up")
check(SystemVolume.scrollDelta(deltaY: 1, precise: false, inverted: false) > 0,
      "volume: wheel rolled away turns it up")
check(SystemVolume.scrollDelta(deltaY: -1, precise: false, inverted: false) < 0,
      "volume: wheel rolled back turns it down")
check(approx(SystemVolume.scrollDelta(deltaY: 1, precise: false, inverted: false), 1.0 / 16),
      "volume: one wheel notch is a volume-key step")
check(approx(SystemVolume.scrollDelta(deltaY: 25, precise: true, inverted: false), 0.1),
      "volume: a calm two-finger swipe is about 10%")
check(approx(SystemVolume.scrollDelta(deltaY: 400, precise: true, inverted: false), 0.125),
      "volume: a flung swipe is capped per event")
// Read-only: never changes the volume of the machine running the tests.
let level = SystemVolume.level
check(level == nil || (0...1).contains(level!), "volume: the current level reads as 0...1",
      "\(String(describing: level))")

// MARK: - Motion (no listening)

// The bars and the wave move by `Motion`, not by sound.
let motionSamples = (0..<200).flatMap { t in (0..<24).map { Motion.level($0, at: Double(t) * 0.1) } }
check(motionSamples.allSatisfy { (0...1).contains($0) }, "motion: always within 0...1")
check(motionSamples.max()! - motionSamples.min()! > 0.5, "motion: has real range, not a twitch",
      "\(motionSamples.min()!)...\(motionSamples.max()!)")
check(abs(Motion.level(3, at: 1) - Motion.level(3, at: 1.5)) > 0.01, "motion: moves over time")
check(abs(Motion.level(0, at: 2) - Motion.level(1, at: 2)) > 0.01, "motion: neighbours move differently")

let bars = MusicBarsView.levels(count: 3, at: 4)
check(bars.count == 3 && bars.allSatisfy { $0 >= 0.2 && $0 <= 1 }, "bars: three, never vanishing")

let waveLevels = MusicWaveView.levels(animating: true, at: 2)
check(waveLevels.count == 24, "wave: 24 points")
check(waveLevels.allSatisfy { $0 >= 0 && $0 <= 1 }, "wave: heights stay within 0...1")
check(waveLevels.first! < 0.4 && waveLevels.last! < 0.4, "wave: tapers toward the baseline at both ends",
      "ends \(waveLevels.first!), \(waveLevels.last!)")
check(MusicWaveView.levels(animating: false, at: 2).max()! < 0.1, "wave: at rest it is a low line")

let waveRect = CGRect(x: 0, y: 0, width: 426, height: 26)
let (waveLine, waveFill) = MusicWaveView.paths(for: waveLevels, in: waveRect)
check(waveRect.insetBy(dx: -0.5, dy: -0.5).contains(waveFill.boundingBoxOfPath),
      "wave: the curve never leaves its strip", "\(waveFill.boundingBoxOfPath)")
check(abs(waveLine.boundingBoxOfPath.width - waveRect.width) < 0.5, "wave: spans the full width")

// MARK: - Lyric pulse

let pulseLines = [LyricLine(time: 10, text: "a"), LyricLine(time: 15, text: ""),
                  LyricLine(time: 20, text: "b"), LyricLine(time: 30, text: "c")]
check(LyricPulse.nextLineTime(in: pulseLines, after: 0) == 10, "pulse: the first line, from the start")
check(LyricPulse.nextLineTime(in: pulseLines, after: 10) == 20,
      "pulse: skips an instrumental break (empty line)")
check(LyricPulse.nextLineTime(in: pulseLines, after: 9.97) == 20,
      "pulse: a line starting this instant doesn't fire twice")
check(LyricPulse.nextLineTime(in: pulseLines, after: 31) == nil, "pulse: nothing after the last line")
check(LyricPulse.nextLineTime(in: [], after: 0) == nil, "pulse: no lyrics, no pulse")

// MARK: - Next features

check(HotKeyChoice.off.combo == nil, "shortcut: off registers nothing")
check(HotKeyChoice.shiftCommandSpace.combo?.keyCode == 49, "shortcut: ⇧⌘Space is the space key")
check(Set(HotKeyChoice.allCases.compactMap { $0.combo.map { "\($0.keyCode)-\($0.modifiers)" } }).count == 2,
      "shortcut: the choices are distinct")

check(Color(hex: "#D9A64C")?.hex == "#D9A64C", "colour: hex round-trips")
check(Color(hex: "nope") == nil, "colour: junk is rejected")

Preferences.registerDefaults()
check(Preferences.idleChoices.contains(Preferences.idleTimeout), "settings: idle default is a menu choice",
      "\(Preferences.idleTimeout)")

MainActor.assumeIsolated {
    for source in [MusicFavorite.readSource, MusicFavorite.toggleSource] {
        var error: NSDictionary?
        let compiled = NSAppleScript(source: source)?.compileAndReturnError(&error) ?? false
        check(compiled, "Music heart: script compiles against Music's dictionary", "\(String(describing: error))")
    }
}

// MARK: - Song-change peek

let songA = track(10, playing: true, title: "A")
let songB = track(0, playing: true, title: "B")
var pausedB = songB; pausedB.isPlaying = false
check(SongPeek.shouldPeek(from: songA, to: songB, expanded: false, enabled: true),
      "peek: a new song that's playing")
check(!SongPeek.shouldPeek(from: nil, to: songB, expanded: false, enabled: true),
      "peek: not for the first song seen (launch)")
check(!SongPeek.shouldPeek(from: songA, to: track(50, playing: true, title: "A"), expanded: false, enabled: true),
      "peek: not when the same song carries on or is resumed")
check(!SongPeek.shouldPeek(from: songA, to: pausedB, expanded: false, enabled: true),
      "peek: not for a song that isn't playing")
check(!SongPeek.shouldPeek(from: songA, to: songB, expanded: true, enabled: true),
      "peek: not while the panel is open")
check(!SongPeek.shouldPeek(from: songA, to: songB, expanded: false, enabled: false),
      "peek: not when switched off in settings")
let notch = CGSize(width: 209, height: 38)
let peek = NotchView.peekSize(notch: notch)
check(peek.width == notch.width + NotchMetrics.collapsedContentWidth + NotchView.peekExtraWidth
      && peek.height == notch.height + NotchMetrics.collapsedExtraHeight,
      "peek: slides out sideways — wider than the playing pill, same height", "\(peek)")
// Left edge stays put: shape centred in the window, then shifted right.
let peekWindow = NotchView.peekWindowSize(notch: notch)
let pillLeft = -(notch.width + NotchMetrics.collapsedContentWidth) / 2
let peekLeft = -peek.width / 2 + NotchView.peekShift
check(abs(peekLeft - pillLeft) < 0.01, "peek: the left edge (artwork) doesn't move",
      "pill \(pillLeft), peek \(peekLeft)")
check(peek.width / 2 + NotchView.peekShift <= peekWindow.width / 2 + 0.01,
      "peek: the shifted shape fits in its window")

// MARK: - Notes and to-dos

MainActor.assumeIsolated {
    let file = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("resonata-notes-test-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }

    let store = NotesStore(url: file)
    check(store.note.isEmpty && store.todos.isEmpty, "notes: a new file starts empty")
    store.note = "Koupit struny"
    store.add("  Zavolat Petrovi  ")
    store.add("   ")
    store.add("Nahrát demo")
    check(store.todos.map(\.text) == ["Zavolat Petrovi", "Nahrát demo"],
          "to-dos: trimmed, blanks ignored, kept in order", "\(store.todos.map(\.text))")
    store.toggle(store.todos[0].id)
    check(store.todos[0].done && !store.todos[1].done, "to-dos: tick one off")
    store.save()

    let reloaded = NotesStore(url: file)
    check(reloaded.note == "Koupit struny", "notes: the note survives a restart")
    check(reloaded.todos == store.todos, "to-dos: survive a restart, ticks included")
    reloaded.removeDone()
    check(reloaded.todos.map(\.text) == ["Nahrát demo"], "to-dos: clear the ticked ones")
    reloaded.remove(reloaded.todos[0].id)
    check(reloaded.todos.isEmpty, "to-dos: delete one")
}

// MARK: - App shortcuts

let parsed = QuickApps.urls(from: "/Applications/A.app\n\n/Applications/B.app\n/Applications/A.app")
check(parsed.map(\.path) == ["/Applications/A.app", "/Applications/B.app"],
      "apps: blank lines and duplicates dropped", "\(parsed.map(\.path))")
check(QuickApps.urls(from: QuickApps.string(from: parsed)) == parsed, "apps: list round-trips")
let defaults = QuickApps.defaultPaths()
check(!defaults.isEmpty && defaults.allSatisfy { FileManager.default.fileExists(atPath: $0) },
      "apps: defaults are only apps that exist here", "\(defaults)")
check(defaults.count <= QuickApps.limit, "apps: defaults fit the grid")
check(QuickApps.name(of: URL(fileURLWithPath: "/System/Applications/System Settings.app")) == "System Settings"
      || !FileManager.default.fileExists(atPath: "/System/Applications/System Settings.app"),
      "apps: names drop the .app")

// MARK: - Calendar and battery

do {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Europe/Prague")!
    let noon = cal.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 12))!
    let days = CalendarStore.days(around: noon, calendar: cal)
    check(days.count == 5, "calendar: five days shown")
    check(days[2] == cal.startOfDay(for: noon), "calendar: today in the middle, at midnight")
    check(cal.component(.day, from: days[0]) == 4 && cal.component(.day, from: days[4]) == 8,
          "calendar: two days either side", "\(days.map { cal.component(.day, from: $0) })")

    func at(_ day: Int, _ hour: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }
    let events = [
        CalendarStore.Event(id: "a", title: "Ráno", start: at(6, 9), end: at(6, 10), isAllDay: false),
        CalendarStore.Event(id: "b", title: "Přes půlnoc", start: at(6, 22), end: at(7, 2), isAllDay: false),
        CalendarStore.Event(id: "c", title: "Zítra", start: at(7, 9), end: at(7, 10), isAllDay: false),
    ]
    check(CalendarStore.events(events, on: at(6, 0), calendar: cal).map(\.id) == ["a", "b"],
          "calendar: a day's own events")
    check(CalendarStore.events(events, on: at(7, 0), calendar: cal).map(\.id) == ["b", "c"],
          "calendar: an event past midnight shows on both days")
    check(CalendarStore.events(events, on: at(8, 0), calendar: cal).isEmpty,
          "calendar: an empty day is empty")
}

check(Battery(percent: 100, charging: false).symbol == "battery.100percent", "battery: full")
check(Battery(percent: 70, charging: false).symbol == "battery.75percent", "battery: 70 rounds to three quarters")
check(Battery(percent: 5, charging: false).symbol == "battery.0percent", "battery: nearly empty")
check(Battery(percent: 5, charging: true).symbol == "battery.100percent.bolt", "battery: charging shows the bolt")
check(Battery(percent: 15, charging: false).isLow && !Battery(percent: 15, charging: true).isLow,
      "battery: low only when not charging")

// MARK: - Claude limits

do {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let json = #"{"five_hour":{"used_percentage":34.2,"resets_at":1003600},"seven_day":{"used_percentage":12,"resets_at":999000}}"#
    let limits = ClaudeLimits.parse(Data(json.utf8), now: now)
    check(limits?.fiveHour?.usedPercentage == 34.2, "claude: session limit read")
    check(limits?.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_003_600), "claude: reset time read")
    check(limits != nil && limits?.sevenDay == nil, "claude: a window that has already reset is dropped")
    let over = #"{"five_hour":{"used_percentage":90,"resets_at":999999}}"#
    check(ClaudeLimits.parse(Data(over.utf8), now: now) == nil, "claude: nothing current, nothing shown")
    check(ClaudeLimits.parse(Data("garbage".utf8), now: now) == nil, "claude: a broken file is ignored")
}

// MARK: - Last: a lyrics line that used to crash the parser

// The stamp's end was taken as a UTF-16 offset and walked as a count of
// characters. Anything wider than one UTF-16 unit before the stamp walked
// past the end of the string — a crash, not a wrong answer — so this runs
// last and announces itself first.
print("…  LRC with emoji before the stamp")
MainActor.assumeIsolated {
    let odd = LyricsStore.parse("🎵🎵🎵🎵[00:01.00] hi\n[00:02.00] b\n[00:03.00] c\n[00:04.00] d")
    check(odd?.first?.text == "hi", "LRC: emoji before a stamp", "\(odd?.first?.text ?? "nil")")
}

print("\n\(passed) passed, \(failures.count) failed")
exit(failures.isEmpty ? 0 : 1)
