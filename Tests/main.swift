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
let peek = NotchView.peekSize(notch: notch, scale: 1)
check(peek.width == notch.width + NotchMetrics.collapsedContentWidth + NotchView.peekExtraWidth
      && peek.height == notch.height + NotchMetrics.collapsedExtraHeight,
      "peek: slides out sideways — wider than the playing pill, same height", "\(peek)")
// Left edge stays put: shape centred in the window, then shifted right.
let peekWindow = NotchView.peekWindowSize(notch: notch, scale: 1)
let pillLeft = -(notch.width + NotchMetrics.collapsedContentWidth) / 2
let peekLeft = -peek.width / 2 + NotchView.peekShift
check(abs(peekLeft - pillLeft) < 0.01, "peek: the left edge (artwork) doesn't move",
      "pill \(pillLeft), peek \(peekLeft)")
check(peek.width / 2 + NotchView.peekShift <= peekWindow.width / 2 + 0.01,
      "peek: the shifted shape fits in its window")

// MARK: - Playhead from the player

do {
    let t0 = Date(timeIntervalSince1970: 1_000)
    let track = Track(title: "Píseň", artist: "A", album: "B", duration: 197, sampledPosition: 0.126,
                      sampledAt: t0, isPlaying: true, artworkURL: nil, source: "Spotify",
                      bundleID: "com.spotify.client")
    // Now Playing said 0:00 a minute ago; Spotify itself is at 2:58.
    let now = t0.addingTimeInterval(58)
    let moved = MediaRemoteNowPlaying.correctedAnchor(of: track, playerPosition: 178.5, at: now)
    check(moved?.position == 178.5 && moved?.at == now, "playhead: the player's own position wins")
    var after = track
    if let moved { after.sampledPosition = moved.position; after.sampledAt = moved.at }
    check(abs(after.position(at: now.addingTimeInterval(2)) - 180.5) < 1e-6, "playhead: and runs on from there")
    check(MediaRemoteNowPlaying.correctedAnchor(of: track, playerPosition: 58.2, at: now) == nil,
          "playhead: within a quarter second, left alone — no twitch")
    check(MediaRemoteNowPlaying.correctedAnchor(of: track, playerPosition: 58.7, at: now) != nil,
          "playhead: 0.6 s behind is put right")
}

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
check(PowerWatcher.isPlugIn(was: false, now: true), "power: battery to charger is a plug-in")
check(!PowerWatcher.isPlugIn(was: true, now: true), "power: the charge ticking up on the charger isn't")
check(!PowerWatcher.isPlugIn(was: nil, now: true), "power: already on the charger at launch isn't")
check(!PowerWatcher.isPlugIn(was: true, now: false), "power: unplugging isn't")

// MARK: - Notes

MainActor.assumeIsolated {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("resonata-notes-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = NotesStore(url: url)
    store.note = "ahoj"
    store.add("  koupit mléko  ")
    store.add("   ")
    check(store.todos.map(\.text) == ["koupit mléko"], "notes: to-dos trimmed, blanks ignored")
    // Quit inside the half-second debounce: the change must still be on disk.
    store.saveIfPending()
    let again = NotesStore(url: url)
    check(again.note == "ahoj" && again.todos.count == 1, "notes: a quit straight after typing keeps it")
    if let id = again.todos.first?.id { again.toggle(id) }
    again.removeDone()
    check(again.todos.isEmpty, "notes: ticked to-dos cleared")
}

MainActor.assumeIsolated {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("resonata-notes-bad-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("notes.json")
    try? Data("{\"note\": \"rozepsan".utf8).write(to: url)
    let store = NotesStore(url: url)
    store.note = "nová"
    store.save()
    let kept = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    let aside = kept.first { $0.hasPrefix("notes-unreadable-") }
    check(store.note == "nová" && aside != nil,
          "notes: an unreadable file is kept aside, not overwritten", "\(kept)")
    if let aside {
        let text = (try? String(contentsOf: dir.appendingPathComponent(aside), encoding: .utf8)) ?? ""
        check(text.contains("rozepsan"), "notes: the kept file is the old one")
    }
}

// MARK: - Activities

check(PowerWatcher.crossesWarning(from: 21, to: 20), "low battery: 21 -> 20 warns")
check(PowerWatcher.crossesWarning(from: 11, to: 10), "low battery: 11 -> 10 warns")
check(PowerWatcher.crossesWarning(from: 23, to: 19), "low battery: a jump past 20 warns")
check(!PowerWatcher.crossesWarning(from: 20, to: 19), "low battery: already below 20, no repeat")
check(!PowerWatcher.crossesWarning(from: 19, to: 20), "low battery: going up isn't a warning")
check(!PowerWatcher.crossesWarning(from: nil, to: 15), "low battery: not at launch")
check(!PowerWatcher.crossesWarning(from: 50, to: 49), "low battery: nowhere near")

do {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func event(_ id: String, inMinutes m: Double, allDay: Bool = false) -> CalendarStore.Event {
        let start = now.addingTimeInterval(m * 60)
        return CalendarStore.Event(id: id, title: id, start: start,
                                   end: start.addingTimeInterval(3600), isAllDay: allDay)
    }
    let events = [event("later", inMinutes: 30), event("soon", inMinutes: 4),
                  event("sooner", inMinutes: 1), event("started", inMinutes: -2),
                  event("allday", inMinutes: 3, allDay: true)]
    let due = MeetingReminder.due(events, now: now, lead: 300).map(\.id)
    check(due == ["sooner", "soon"], "reminder: timed events within 5 min, soonest first", "\(due)")
    check(NotchActivity.meetingDetail(start: now.addingTimeInterval(300), now: now).hasPrefix("za 5 min · "),
          "reminder: 'za 5 min · time'")
    check(NotchActivity.meetingDetail(start: now, now: now).hasPrefix("teď"), "reminder: 'teď' once started")
}

check(CountdownTimer.format(25 * 60) == "25:00", "timer: 25:00")
check(CountdownTimer.format(59.2) == "1:00", "timer: rounds up, never shows 0:00 early")
check(CountdownTimer.format(9 * 60 + 5) == "9:05", "timer: 9:05")
check(CountdownTimer.format(65 * 60) == "65 min", "timer: an hour and up in minutes")

// MARK: - Redraw pacing

check(approx(NotchView.progressInterval(duration: 240), 0.4), "progress: a 4-min song redraws every 0.4 s")
check(approx(NotchView.progressInterval(duration: 5), 1.0 / 30), "progress: never faster than 30 fps")
check(approx(NotchView.progressInterval(duration: 3600), 0.5), "progress: never slower than twice a second")
check(approx(NotchView.progressInterval(duration: 0), 0.5), "progress: unknown length, twice a second")
do {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let lines = [LyricLine(time: 10, text: "a"), LyricLine(time: 20, text: "b"), LyricLine(time: 30, text: "c")]
    let playing = Track(title: "T", artist: "A", album: "", duration: 60, sampledPosition: 15,
                        sampledAt: now, isPlaying: true, artworkURL: nil, source: "Spotify")
    let starts = LyricsView.lineStarts(lines, track: playing, after: now)
    check(starts == [now, now.addingTimeInterval(5), now.addingTimeInterval(15)],
          "lyrics: redraws now and as each coming line begins", "\(starts.map { $0.timeIntervalSince(now) })")
    var paused = playing; paused.isPlaying = false
    check(LyricsView.lineStarts(lines, track: paused, after: now) == [now], "lyrics: paused, just once")
    check(LyricsView.rows([LyricLine(time: 1, text: "a"), LyricLine(time: 2, text: "")]) == ["\u{266A}", "a", "\u{266A}"],
          "lyrics: a note for the intro and for empty lines")
    check(LyricsView.row(for: nil) == 0 && LyricsView.row(for: 0) == 1 && LyricsView.row(for: 4) == 5,
          "lyrics: before the first line is the intro row")
    check(SpotifyVolumeControl.symbol(for: 0) == "speaker.slash.fill"
          && SpotifyVolumeControl.symbol(for: 50) == "speaker.wave.2.fill"
          && SpotifyVolumeControl.symbol(for: 100) == "speaker.wave.3.fill", "spotify: speaker follows the level")
    check(SpotifyVolumeControl.toggledMute(70, before: nil) == 0, "spotify: speaker click mutes")
    check(SpotifyVolumeControl.toggledMute(0, before: 70) == 70, "spotify: second click brings the level back")
    check(SpotifyVolumeControl.toggledMute(0, before: nil) == 50, "spotify: unmuting with nothing to go back to")
}

// MARK: - Pomodoro

do {
    typealias T = CountdownTimer
    let std = PomodoroPlan.standard
    let afterWork1 = T.next(after: .work, round: 1, plan: std)
    check(afterWork1.phase == .rest && afterWork1.minutes == 5 && afterWork1.round == 1, "pomodoro: work -> 5-min break")
    let afterRest1 = T.next(after: .rest, round: 1, plan: std)
    check(afterRest1.phase == .work && afterRest1.minutes == 25 && afterRest1.round == 2, "pomodoro: break -> work, next round")
    check(T.next(after: .work, round: 4, plan: std).minutes == 15, "pomodoro: the fourth break is the long one")
    check(T.next(after: .work, round: 5, plan: std).minutes == 5, "pomodoro: then short again")
    // Anyone's own lengths.
    let mine = PomodoroPlan(work: 50, rest: 10, longRest: 30, rounds: 2)
    check(T.next(after: .rest, round: 1, plan: mine).minutes == 50, "pomodoro: custom work length")
    check(T.next(after: .work, round: 1, plan: mine).minutes == 10, "pomodoro: custom break")
    check(T.next(after: .work, round: 2, plan: mine).minutes == 30, "pomodoro: custom long break every 2nd")
    check(T.next(after: .work, round: 3, plan: PomodoroPlan(work: 25, rest: 5, longRest: 20, rounds: 1)).minutes == 20,
          "pomodoro: every break long when set to 1")
    let wild = PomodoroPlan(work: 0, rest: -3, longRest: 999, rounds: 50).clamped
    check(wild == PomodoroPlan(work: 1, rest: 1, longRest: 240, rounds: 12), "pomodoro: odd values kept in range", "\(wild)")
}

// MARK: - Swipes on the notch

do {
    typealias C = NotchPanelController
    check(C.swipeAction(travel: CGSize(width: 0, height: 40), precise: true) == .down, "swipe: down opens")
    check(C.swipeAction(travel: CGSize(width: 0, height: -40), precise: true) == .up, "swipe: up closes")
    check(C.swipeAction(travel: CGSize(width: 0, height: 20), precise: true) == nil, "swipe: too short does nothing")
    // Pages: two fingers sideways on the open panel.
    check(C.pageAxis(travel: CGSize(width: 3, height: 1), precise: true) == nil, "page: undecided at first")
    check(C.pageAxis(travel: CGSize(width: 10, height: 2), precise: true) == .horizontal, "page: sideways locks horizontal")
    check(C.pageAxis(travel: CGSize(width: 4, height: 9), precise: true) == .vertical, "page: up/down stays the list's")
    check(C.pageAxis(travel: CGSize(width: 7, height: 7), precise: true) == .vertical, "page: diagonal is not a page turn")
    check(C.pageTurn(from: .music, travel: 50, precise: true) == .notes, "page: swiping right is the next page")
    check(C.pageTurn(from: .notes, travel: -50, precise: true) == .music, "page: swiping left is the previous page")
    check(C.pageTurn(from: .music, travel: -50, precise: true) == nil, "page: nothing before the first")
    check(C.pageTurn(from: .shelf, travel: 50, precise: true) == nil, "page: nothing after the last")
    check(C.pageTurn(from: .music, travel: 20, precise: true) == nil, "page: too short turns nothing")
    check(C.pageTurn(from: .music, travel: -50, precise: true, reversed: true) == .notes, "page: reversed, swiping left is the next page")
    check(C.pageTurn(from: .notes, travel: 50, precise: true, reversed: true) == .music, "page: reversed, swiping right is the previous page")
    check(CountdownTimer.clampMinutes(0) == 1 && CountdownTimer.clampMinutes(999) == 240
          && CountdownTimer.clampMinutes(37) == 37, "timer: button lengths kept to 1–240 min")
    check(EagerGrid<Int, EmptyView>.rows([1, 2, 3, 4, 5, 6, 7], columns: 3) == [[1, 2, 3], [4, 5, 6], [7]],
          "grid: rows of three, the last one short")
    check(EagerGrid<Int, EmptyView>.rows([], columns: 3).isEmpty, "grid: nothing, no rows")
    // The cutout from the 13" Air, as macOS reported it: 209 x 38 pt at
    // 1710 wide (56.9 px high, which matches the hardware) and 179 x 32 at
    // 1470 (55.7 px, a pixel short).
    let air1710 = NotchCalibration.fit(CGSize(width: 209, height: 38), pixelsPerPoint: 2560.0 / 1710, largestPixels: nil)
    check(abs(air1710.largestPixels.height - 56.89) < 0.01, "notch: 38 pt at 1710 is 56.9 px")
    let air1470 = NotchCalibration.fit(CGSize(width: 179, height: 32), pixelsPerPoint: 2560.0 / 1470,
                                       largestPixels: air1710.largestPixels)
    check(abs(air1470.size.height - 32.67) < 0.01 && abs(air1470.size.width - 179.67) < 0.01,
          "notch: at 1470 the pill is 32.7 pt, the 1710 size, not the reported 32", "\(air1470.size)")
    check(air1470.largestPixels == air1710.largestPixels, "notch: a smaller reading doesn't replace a larger one")
    let first = NotchCalibration.fit(CGSize(width: 179, height: 32), pixelsPerPoint: 2560.0 / 1470, largestPixels: nil)
    check(first.size == CGSize(width: 179, height: 32), "notch: with nothing better, the reported size")
    // Read mid-change from 1710 to 1280: the new width in points, the old
    // 38 pt height — 87 px against the cutout's 57. It mustn't stick.
    let torn = NotchCalibration.fit(CGSize(width: 209, height: 38), pixelsPerPoint: 2560.0 / 1280,
                                    largestPixels: air1710.largestPixels)
    let after = NotchCalibration.fit(CGSize(width: 156, height: 28), pixelsPerPoint: 2560.0 / 1280,
                                     largestPixels: torn.largestPixels)
    check(abs(after.size.height - 28) < 0.01,
          "notch: a reading far off the others is replaced by the next one", "\(after.size)")
    let air1280 = NotchCalibration.fit(CGSize(width: 156, height: 28), pixelsPerPoint: 2560.0 / 1280,
                                       largestPixels: air1710.largestPixels)
    check(abs(air1280.size.height - 28.44) < 0.01,
          "notch: at 1280 the 1710 size still counts", "\(air1280.size)")
    // At 1470 the cutout is 32.5 pt high: the wings scale with it, so they
    // cover the same pixels as 94 pt at 1710 (38 pt high).
    let k1470 = NotchMetrics.scale(notchHeight: 32.5, real: true)
    check(abs(NotchMetrics.contentWidth(scale: k1470) * 2560 / 1470 - 94 * 2560 / 1710) < 1.5,
          "pill: the wings are the same width in pixels at 1470 as at 1710")
    check(NotchMetrics.scale(notchHeight: 32, real: false) == 1, "pill: no cutout, no scaling")
    check(PanelTab.timer.neighbour(1) == .shelf && PanelTab.timer.neighbour(-1) == .apps, "page: neighbours follow the strip")
    check(C.swipeAction(travel: CGSize(width: 60, height: 5), precise: true) == .right, "swipe: right is next")
    check(C.swipeAction(travel: CGSize(width: -60, height: 0), precise: true) == .left, "swipe: left is previous")
    check(C.swipeAction(travel: CGSize(width: 40, height: 0), precise: true) == nil,
          "swipe: sideways needs a longer swipe than up or down")
    check(C.swipeAction(travel: CGSize(width: 35, height: 40), precise: true) == nil,
          "swipe: a diagonal is neither")
    check(C.swipeAction(travel: CGSize(width: 0, height: 1), precise: false) == .down,
          "swipe: one wheel click counts")
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
