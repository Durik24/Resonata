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

// The interface's strings are checked in Czech, whatever the Mac running
// the tests speaks — see `L`.
L.isCzech = true

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

// MARK: - Pause and resume, as Spotify reports them

MainActor.assumeIsolated {
    // Recorded from `stream --micros`: a pause is `playing: false`, then a
    // new timestamp, then — half a second later — the elapsed time. Until
    // that last one the elapsed time in hand is the song's start.
    let source = MediaRemoteNowPlaying()
    let started = Date().addingTimeInterval(-48)
    func micros(_ date: Date) -> Double { (date.timeIntervalSince1970 * 1_000_000).rounded() }
    source.ingest(streamLine(["type": "data", "diff": false, "payload": [
        "title": "Tak To Jsme My!", "artist": "X", "album": "Y", "playing": true,
        "bundleIdentifier": "com.example.player",
        "durationMicros": 183_000_000, "elapsedTimeMicros": 0,
        "timestampEpochMicros": micros(started),
    ]]))
    check(approx(source.track?.position(at: Date()) ?? -1, 48, 0.5), "pause: playing, 48 s in")

    source.ingest(streamLine(["type": "data", "diff": true, "payload": ["playing": false]]))
    check(source.track?.isPlaying == false, "pause: shown as paused")
    check(approx(source.track?.position(at: Date()) ?? -1, 48, 0.5),
          "pause: the bar stays where the song was, not back at 0:00",
          "\(source.track?.position(at: Date()) ?? -1)")
    source.ingest(streamLine(["type": "data", "diff": true, "payload": [
        "timestampEpochMicros": micros(Date())]]))
    check(approx(source.track?.position(at: Date()) ?? -1, 48, 0.5),
          "pause: nor when only the timestamp follows",
          "\(source.track?.position(at: Date()) ?? -1)")
    source.ingest(streamLine(["type": "data", "diff": true, "payload": [
        "elapsedTimeMicros": 47_600_000, "playbackRate": NSNull(),
        "timestampEpochMicros": micros(Date())]]))
    check(approx(source.track?.position(at: Date()) ?? -1, 48, 0.5), "pause: the elapsed time agrees")

    // Resuming: `playing: true` first, the paused elapsed time still in hand.
    source.ingest(streamLine(["type": "data", "diff": true, "payload": ["playing": true]]))
    check(source.track?.isPlaying == true, "resume: shown as playing")
    check(approx(source.track?.position(at: Date()) ?? -1, 48, 0.5),
          "resume: carries on from where it was paused",
          "\(source.track?.position(at: Date()) ?? -1)")

    // A real jump still moves the bar: a seek arrives with its elapsed time.
    source.ingest(streamLine(["type": "data", "diff": true, "payload": [
        "elapsedTimeMicros": 120_000_000, "timestampEpochMicros": micros(Date())]]))
    check(approx(source.track?.position(at: Date()) ?? -1, 120, 0.5), "seek in the player: the bar follows")

    // The button: its click shows at once, before the player reports it.
    source.expectPlayPauseToggle()
    check(source.track?.isPlaying == false, "play/pause: the click shows at once")
    check(approx(source.track?.position(at: Date()) ?? -1, 120, 0.5), "play/pause: paused where it was")
    source.ingest(streamLine(["type": "data", "diff": true, "payload": [
        "timestampEpochMicros": micros(Date())]]))
    check(source.track?.isPlaying == false, "play/pause: a payload still saying playing doesn't undo it")
    source.ingest(streamLine(["type": "data", "diff": true, "payload": ["playing": false]]))
    check(source.track?.isPlaying == false, "play/pause: and the player's report agrees")
    source.ingest(streamLine(["type": "data", "diff": true, "payload": ["playing": true]]))
    check(source.track?.isPlaying == true, "play/pause: a later change in the player is followed")
    source.stop()
}

do {
    let now = Date(timeIntervalSince1970: 5_000)
    let waiting = (value: false, until: now.addingTimeInterval(2))
    check(MediaRemoteNowPlaying.shownPlaying(reported: true, expected: waiting, now: now) == (false, true),
          "play/pause: expected, not yet reported")
    check(MediaRemoteNowPlaying.shownPlaying(reported: false, expected: waiting, now: now) == (false, false),
          "play/pause: reported, nothing left to expect")
    check(MediaRemoteNowPlaying.shownPlaying(reported: true, expected: waiting,
                                             now: now.addingTimeInterval(2.1)) == (true, false),
          "play/pause: never reported — back to what the player says")
    check(MediaRemoteNowPlaying.shownPlaying(reported: true, expected: nil, now: now) == (true, false),
          "play/pause: nothing expected")

    check(MediaRemoteNowPlaying.bringsElapsedTime(["playing": false], diff: true) == false,
          "stream: a diff without the elapsed time says nothing about the playhead")
    check(MediaRemoteNowPlaying.bringsElapsedTime(["elapsedTimeMicros": 5], diff: true),
          "stream: a diff with it does")
    check(MediaRemoteNowPlaying.bringsElapsedTime(["title": "A"], diff: false),
          "stream: a full payload always does")

    // The same song, both ways round.
    let playing = track(10, playing: true), paused = track(10, playing: false)
    let later = t0 + 30
    let stopped = MediaRemoteNowPlaying.anchor(for: paused, after: playing, elapsedIsNew: false,
                                               confirmed: false, now: later)
    check(stopped?.position == 40 && stopped?.at == later, "anchor: paused where the playhead had got to")
    let resumed = MediaRemoteNowPlaying.anchor(for: playing, after: paused, elapsedIsNew: false,
                                               confirmed: true, now: later)
    check(resumed?.position == 10 && resumed?.at == later, "anchor: resumed from where it was paused")
    check(MediaRemoteNowPlaying.anchor(for: paused, after: playing, elapsedIsNew: true,
                                       confirmed: true, now: later) == nil,
          "anchor: a pause that brings its own elapsed time uses it")
    var jumped = playing
    jumped.sampledPosition = 80
    check(MediaRemoteNowPlaying.anchor(for: jumped, after: playing, elapsedIsNew: true,
                                       confirmed: false, now: later) == nil,
          "anchor: a jump the player reports is taken")
    check(MediaRemoteNowPlaying.anchor(for: jumped, after: playing, elapsedIsNew: false,
                                       confirmed: false, now: later)?.position == 10,
          "anchor: stale elapsed time is not a jump")

    check(PlayerVolumeControl.disagrees(shown: 50, player: 100), "volume: the player didn't take it")
    check(!PlayerVolumeControl.disagrees(shown: 50, player: 49), "volume: Spotify's 49 for 50 is agreement")

    let radio = Track(title: "T", artist: "A", album: "B", duration: 0, sampledPosition: 0, sampledAt: t0,
                      isPlaying: true, artworkURL: nil, source: "Safari", bundleID: "com.apple.Safari")
    check(scriptName(for: radio) == nil, "seek: a browser tab goes through MediaRemote")
}

// MARK: - Claude Code in the notch

do {
    var prague = Calendar(identifier: .gregorian)
    prague.timeZone = TimeZone(identifier: "Europe/Prague")!
    func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        prague.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }
    let now = at(2026, 11, 12, 13, 50)

    // Exactly what `claude /usage` printed on 12 November 2026.
    let text = """
    You are currently using your subscription to power your Claude Code usage

    Current session: 6% used · resets Nov 12 at 6:39pm (Europe/Prague)
    Current week (all models): 1% used · resets Nov 13 at 6:59pm (Europe/Prague)
    Current week (Fable): 2% used · resets Nov 13 at 6:59pm (Europe/Prague)

    What's contributing to your usage?
      77%  Start fresh when you switch tasks · run /clear
    """
    let usage = ClaudeUsage.parse(text, now: now)
    check(usage?.sessionPercent == 6, "claude: the session's share is read", "\(String(describing: usage))")
    check(usage?.sessionResets == at(2026, 11, 12, 18, 39), "claude: and when it resets",
          "\(String(describing: usage?.sessionResets))")
    check(usage?.weekPercent == 1, "claude: the week is the line for all models, not one model's")
    check(usage?.weekResets == at(2026, 11, 13, 18, 59), "claude: the week's reset")
    check(usage?.models == [.init(name: "Fable", percent: 2, resets: at(2026, 11, 13, 18, 59))],
          "claude: one model's week is kept beside it, by name")
    check(ClaudeUsage.parse("Current week (Fable): 2% used\nCurrent session: 100% used", now: now)
            == ClaudeUsage(sessionPercent: 100, sessionResets: nil, weekPercent: 2, weekResets: nil),
          "claude: no reset said, one model's week when that is all there is")
    check(ClaudeUsage.parse("Not logged in · Please run /login", now: now) == nil,
          "claude: no session line, nothing to show")
    check(ClaudeUsage.parse("  77%  Start fresh when you switch tasks", now: now) == nil,
          "claude: a percentage that isn't a limit is not one")

    check(ClaudeUsage.resetDate("5:30pm (Europe/Prague)", now: now) == at(2026, 11, 12, 17, 30),
          "claude: a bare time is later today")
    check(ClaudeUsage.resetDate("9:05am (Europe/Prague)", now: now) == at(2026, 11, 13, 9, 5),
          "claude: or tomorrow, once it has passed today")
    check(ClaudeUsage.resetDate("6pm (Europe/Prague)", now: now) == at(2026, 11, 12, 18, 0),
          "claude: a time without minutes")
    check(ClaudeUsage.resetDate("Jan 2 at 9:00am (Europe/Prague)", now: at(2026, 12, 30, 12, 0))
            == at(2027, 1, 2, 9, 0), "claude: a date in January, read in December, is next year's")
    check(ClaudeUsage.resetDate("soon", now: now) == nil, "claude: unreadable reset, no date")

    L.isCzech = false
    check(ClaudeStatus.countdown(to: at(2026, 11, 12, 16, 8), now: now) == "resets in 2 h 18 min",
          "claude: hours and minutes to the reset")
    check(ClaudeStatus.countdown(to: at(2026, 11, 12, 14, 20), now: now) == "resets in 30 min",
          "claude: under an hour, minutes only")
    check(ClaudeStatus.countdown(to: at(2026, 11, 12, 15, 50), now: now) == "resets in 2 h",
          "claude: whole hours")
    check(ClaudeStatus.countdown(to: now.addingTimeInterval(-5), now: now) == "resets now",
          "claude: a reset already due")
    L.isCzech = true
    let shown = ClaudeStatus(state: .working, session: "resonata", usage: usage).summary(now: now)
    check(shown.hasPrefix("Claude · pracuje\n") && shown.contains("využito 6 %")
            && shown.contains("reset za 4 h 49 min") && shown.contains("Týden: 1 %")
            && shown.hasSuffix("\nresonata"),
          "claude: the card says the state, both limits and the session", shown)
    let placed = ClaudeStatus(state: .working, session: "resonata", usage: usage,
                              sessions: [.init(pid: 1, name: "resonata", state: .working, app: "Terminál")])
    check(placed.summary(now: now).hasSuffix("\nresonata · Terminál"), "claude: and the app it runs in, when known")
    check(ClaudeStatus(usage: usage).weekFraction == 0.01 && ClaudeStatus(state: .working).weekFraction == nil,
          "claude: the week's ring is as full as the week")
    check(ClaudeStatus(usage: usage).showsInPill && ClaudeStatus(state: .waiting).showsInPill
            && !ClaudeStatus().showsInPill,
          "claude: limits, or a session at work, are something to show; neither is not")
    check(ClaudeStatus(state: .idle).fraction == nil && ClaudeStatus(usage: usage).fraction == 0.06,
          "claude: the ring is as full as the session is used")

    // The session files, as Claude Code 2.1 writes them.
    func record(_ fields: [String: Any]) -> ClaudeSessionRecord? {
        var json: [String: Any] = ["pid": 7534, "cwd": "/Users/someone/Projects/resonata",
                                   "name": "resonata-16", "nameSource": "derived", "entrypoint": "cli"]
        for (key, value) in fields { json[key] = value }
        return ClaudeSessionRecord(json: json)
    }
    let busy = record(["status": "busy"])
    check(busy?.state == .working && busy?.pid == 7534, "claude: a busy session is working")
    check(busy?.name == "resonata", "claude: a made-up name gives way to the folder")
    check(record(["status": "busy", "name": "Release", "nameSource": "user"])?.name == "Release",
          "claude: a name somebody gave is kept")
    let asking = record(["status": "waiting", "waitingFor": "permission to edit"])
    check(asking?.state == .waiting && asking?.wants == "permission to edit", "claude: a waiting session and what for")
    check(record(["tempo": "blocked", "status": "busy"])?.state == .waiting, "claude: `tempo` is believed over `status`")
    check(record(["status": "idle"])?.state == .idle && record([:])?.state == .idle,
          "claude: idle, and no status at all, are idle")
    check(record(["entrypoint": "sdk-cli", "status": "busy"])?.isHelper == true,
          "claude: a `--print` run is not a session")
    check(ClaudeSessionRecord(json: ["cwd": "/tmp"]) == nil, "claude: a file with no pid is no session")

    if let busy, let asking, let idle = record(["pid": 9, "status": "idle"]) {
        check(ClaudeSessionRecord.summary(of: [idle, busy, asking]).state == .waiting
                && ClaudeSessionRecord.summary(of: [idle, busy, asking]).wants == "permission to edit",
              "claude: one waiting for you comes before one working")
        check(ClaudeSessionRecord.summary(of: [idle, busy]).state == .working
                && ClaudeSessionRecord.summary(of: [idle, busy]).session == "resonata",
              "claude: one working makes the notch show work")
        check(ClaudeSessionRecord.summary(of: [idle]).state == .idle && ClaudeSessionRecord.summary(of: []).session == nil,
              "claude: nothing working, nothing shown")

        check(ClaudeSessionRecord.event(from: .working, to: asking, workedFor: 2)
                == .claudeWaiting(session: "resonata", wants: "permission to edit", pid: 7534),
              "claude: stopping to ask is said, however short the work")
        check(ClaudeSessionRecord.event(from: .working, to: idle, workedFor: 40)
                == .claudeDone(session: "resonata", pid: 9),
              "claude: finishing is said, with the session to go to")
        check(ClaudeSessionRecord.event(from: .working, to: idle, workedFor: 3) == nil,
              "claude: a three-second answer ends without a word")
        check(ClaudeSessionRecord.event(from: nil, to: asking, workedFor: 0) == nil,
              "claude: a session first seen waiting isn't news — nothing at launch")
        check(ClaudeSessionRecord.event(from: .waiting, to: busy, workedFor: 0) == nil
                && ClaudeSessionRecord.event(from: .waiting, to: idle, workedFor: 0) == nil,
              "claude: an answered question is not a piece of work ending")
    }
    check(NotchActivity.claudeWaiting(session: "resonata", wants: nil).look.detail == "resonata"
            && NotchActivity.claudeWaiting(session: "resonata", wants: "Povolit?").look.detail == "resonata · Povolit?",
          "claude: the message says which session, and what it wants when it says")
    check(NotchActivity.claudeWaiting(session: "a", wants: nil, pid: 42).sessionPid == 42
            && NotchActivity.claudeDone(session: "a").sessionPid == nil
            && NotchActivity.charging(percent: 5).sessionPid == nil,
          "claude: a message knows the session a click on it goes to")
    check(NotchActivity.claudeWaiting(session: "a", wants: nil).waitsForClose
            && !NotchActivity.claudeDone(session: "a").waitsForClose,
          "claude: a question waits for the panel to close; a finish seen in the panel doesn't")
}

// MARK: - Mistral Vibe in the notch

do {
    // What the helper printed on 12 November 2026, off a Student plan.
    let usage = VibeUsage.parse(#"{"percent": 2.9651639733333335, "resets": "2026-12-01T00:00:00Z", "payg": false, "plan": "EDU"}"#)
    check(usage?.percent == 2, "vibe: the month's share is read in whole per cents, as Vibe shows it", "\(String(describing: usage))")
    check(VibeUsage.parse(#"{"percent": 2.998338653333333}"#)?.percent == 2 && VibeUsage.parse(#"{"percent": 3.0}"#)?.percent == 3,
          "vibe: 2.99 is still 2, not rounded up to a 3 Vibe doesn't show")
    check(usage?.resets == Date(timeIntervalSince1970: 1_796_083_200), "vibe: and when it resets")
    check(usage?.plan == "Student" && usage?.payAsYouGo == false, "vibe: the plan by the name Vibe gives it")
    check(VibeUsage.parse("Reading API keys\n{\"percent\": 140.2, \"resets\": null, \"payg\": true, \"plan\": \"INDIVIDUAL\"}\n")
            == VibeUsage(percent: 140, resets: nil, plan: "Pro", payAsYouGo: true),
          "vibe: past the allowance on a plan that bills the rest; a line printed before it is passed over")
    check(VibeUsage.parse("") == nil && VibeUsage.parse("{\"plan\": \"EDU\"}") == nil
            && VibeUsage.parse("Traceback (most recent call last):") == nil,
          "vibe: nothing printed, or no share in it, nothing to show")
    check(VibeUsage.planTitle("Scale") == "Scale" && VibeUsage.planTitle(" ") == nil,
          "vibe: a plan it has no name for keeps billing's; none is none")

    check(VibeStatus(usage: usage).fraction == 0.02 && VibeStatus(state: .working).fraction == nil,
          "vibe: the ring is as full as the month is used")
    check(VibeStatus(usage: VibeUsage(percent: 140)).fraction == 1, "vibe: and no fuller than full")
    check(VibeStatus(usage: usage).showsInPill && VibeStatus(state: .waiting).showsInPill && !VibeStatus().showsInPill,
          "vibe: the allowance, or a session at work, is something to show; neither is not")
    let shown = VibeStatus(state: .waiting, session: "milionar", usage: usage,
                           sessions: [.init(pid: 7, name: "milionar", state: .waiting, app: "Terminál", key: "s1")])
        .summary(now: Date())
    check(shown.hasPrefix("Vibe · čeká na tebe\nMěsíc: využito 2 % · reset ") && shown.contains("\nTarif: Student\n")
            && shown.hasSuffix("\nmilionar · Terminál"),
          "vibe: the card says the state, the month, the plan and the session", shown)

    // Journal lines as Vibe 3.1 writes them, cut down to what is read.
    func line(_ type: String, _ payload: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["type": type, "payload": payload, "sequence": 1])
        return String(decoding: data, as: UTF8.self) + "\n"
    }
    func envelope(_ status: String, title: String? = nil, source: String = "auto") -> String {
        var session: [String: Any] = ["status": ["type": status], "titleSource": source]
        if let title { session["title"] = title }
        return line("projection_delta", ["delta": [["op": "append_entry", "entry": ["text": "…"]],
                                                   ["op": "set_envelope", "state": ["session": session]]]])
    }
    func asked(_ id: String, command: String) -> String {
        line("callback_registered", ["callback_id": id, "kind": "approval",
                                     "routing": ["title": "Approve file_system.bash",
                                                 "detail": ["effect": ["toolName": "file_system.bash",
                                                                       "input": ["command": command]]]]])
    }
    func answered(_ id: String) -> String {
        line("callback_resolved", ["callback_id": id, "state": "resolved"])
    }
    func journal(_ lines: String...) -> VibeJournal {
        var journal = VibeJournal()
        journal.read(Data(lines.joined().utf8))
        return journal
    }
    check(VibeJournal().state == .idle, "vibe: an empty journal is a session at rest")
    check(journal(line("command_reserved", ["method": "turn/start"]), envelope("running")).state == .working,
          "vibe: a turn under way is working")
    let waiting = journal(envelope("running"), asked("a1", command: "python3 --version\necho more"), envelope("running"))
    check(waiting.state == .waiting && waiting.wants == "python3 --version",
          "vibe: an approval asked for and not answered is waiting, and the command's first line is what for")
    check(journal(envelope("running"), asked("a1", command: "ls"), answered("a1"), envelope("running")).state == .working,
          "vibe: answered, it is back at work")
    check(journal(envelope("running"), envelope("idle")).state == .idle, "vibe: the newest envelope is the one that counts")
    check(journal(envelope("running"), asked("a1", command: "ls"), envelope("idle")).state == .idle,
          "vibe: a turn stopped with its question open is at rest, not waiting for ever")
    check(journal(envelope("idle"), asked("a1", command: "ls")).state == .waiting,
          "vibe: a question put after the last envelope still stands")
    check(journal(envelope("running"), line("action_result", ["result": "it said set_envelope and callback_registered"]))
            .state == .working, "vibe: a tool's output quoting those words is not one of them")
    var grown = journal(envelope("running"), asked("a1", command: "mkdir x"))
    grown.read(Data(answered("a1").utf8))
    check(grown.state == .working, "vibe: read a piece at a time, as it is written")
    grown.read(Data(envelope("idle", title: "Kvíz", source: "user").utf8))
    check(grown.state == .idle && grown.title == "Kvíz" && grown.titleGiven, "vibe: a name somebody gave is known as one")
    grown.read(Data(envelope("running", title: "Kvíz", source: "user").utf8))
    grown.startOver()
    check(grown.state == .idle && grown.title == "Kvíz", "vibe: a new journal file is a session come to rest; its name stays")
    check(journal(envelope("running", title: "C# quiz game")).titleGiven == false,
          "vibe: Vibe's own title is not a given one")

    func wants(_ effect: [String: Any], title: String? = nil) -> String? {
        var routing: [String: Any] = ["detail": ["effect": effect]]
        if let title { routing["title"] = title }
        return VibeJournal.wants(["routing": routing])
    }
    check(wants(["toolName": "file_system.write_file", "input": ["path": "/Users/a/hra/main.py", "content": "…"]]) == "main.py",
          "vibe: an edit wants its file, by name")
    check(wants(["toolName": "web.fetch", "input": ["url": "x"]]) == "fetch", "vibe: any other tool, the tool")
    check(wants([:], title: "Approve plan") == "Approve plan" && wants([:]) == nil, "vibe: else the title, else nothing")
    check(wants(["input": ["command": String(repeating: "x", count: 90)]])?.count == 60,
          "vibe: a long command is cut to fit the notch")

    check(VibeSessionRecord.name(title: "C# quiz game", given: false, folder: "/Users/a/milionar") == "milionar",
          "vibe: a session goes by its folder, like Claude Code's")
    check(VibeSessionRecord.name(title: "Kvíz", given: true, folder: "/Users/a/milionar") == "Kvíz",
          "vibe: unless somebody named it")
    check(VibeSessionRecord.name(title: "C# quiz game", given: false, folder: nil) == "C# quiz game"
            && VibeSessionRecord.name(title: nil, given: false, folder: nil) == "Vibe",
          "vibe: no folder known, Vibe's title; neither, just Vibe")
    check(VibeSessionReader.isSessionID("8c357c8a-7665-1c01-07b9-0577799f693f")
            && !VibeSessionReader.isSessionID("../../etc") && !VibeSessionReader.isSessionID("")
            && !VibeSessionReader.isSessionID("a/b"),
          "vibe: a session id that would leave its folder is not one")

    let idle = VibeSessionRecord(id: "s0", pid: 9, name: "milionar", state: .idle)
    let busy = VibeSessionRecord(id: "s1", pid: 10, name: "web", state: .working)
    let asking = VibeSessionRecord(id: "s2", pid: 11, name: "milionar", state: .waiting, wants: "mkdir x")
    check(VibeSessionRecord.summary(of: [idle, busy, asking]).state == .waiting
            && VibeSessionRecord.summary(of: [idle, busy, asking]).wants == "mkdir x",
          "vibe: one waiting for you comes before one working")
    check(VibeSessionRecord.summary(of: [idle, busy]).session == "web" && VibeSessionRecord.summary(of: [idle]).state == .idle,
          "vibe: one working makes the notch show work; none, nothing")
    check(VibeSessionRecord.event(from: .working, to: asking, workedFor: 2)
            == .vibeWaiting(session: "milionar", wants: "mkdir x", pid: 11),
          "vibe: stopping to ask is said, however short the work")
    check(VibeSessionRecord.event(from: .working, to: idle, workedFor: 40) == .vibeDone(session: "milionar", pid: 9)
            && VibeSessionRecord.event(from: .working, to: idle, workedFor: 3) == nil,
          "vibe: finishing is said after real work, not after a three-second answer")
    check(VibeSessionRecord.event(from: nil, to: asking, workedFor: 0) == nil
            && VibeSessionRecord.event(from: .waiting, to: idle, workedFor: 0) == nil,
          "vibe: a session first seen waiting, or an answered question, isn't news")
    check(NotchActivity.vibeWaiting(session: "milionar", wants: "mkdir x").look.detail == "milionar · mkdir x"
            && NotchActivity.vibeWaiting(session: "milionar", wants: nil, pid: 11).sessionPid == 11
            && NotchActivity.vibeWaiting(session: "a", wants: nil).waitsForClose
            && !NotchActivity.vibeDone(session: "a").waitsForClose,
          "vibe: its messages say what Claude Code's do, and go to the session's app")

    check(VibeMonitor.interpreter(inFirstLine: "#!/Users/a/.local/share/uv/tools/mistral-vibe/bin/python3\n# -*- coding: utf-8 -*-")
            == "/Users/a/.local/share/uv/tools/mistral-vibe/bin/python3",
          "vibe: its Python is the one its command names")
    check(VibeMonitor.interpreter(inFirstLine: "#!/usr/bin/env python3\n") == nil
            && VibeMonitor.interpreter(inFirstLine: "#!/bin/sh\nexec python") == nil
            && VibeMonitor.interpreter(inFirstLine: "\u{7f}ELF") == nil,
          "vibe: some other Python, a shell or a binary is not it")

    // Who gets which place in the closed notch and in the top bar.
    let claude = ClaudeStatus(usage: ClaudeUsage(sessionPercent: 6, weekPercent: 20))
    let vibe = VibeStatus(usage: usage)
    let both = PillRing.placed(claude: claude, vibe: vibe, musicLive: false)
    check(both.cover?.tool == .claude && both.bars?.tool == .vibe && both.bars?.fraction == 0.02,
          "rings: nothing playing, Claude Code's session on the left and Vibe's month on the right")
    let alone = PillRing.placed(claude: claude, vibe: nil, musicLive: false)
    check(alone.cover?.tool == .claude && alone.bars == PillRing(tool: .claudeWeek, fraction: 0.2),
          "rings: Claude Code alone keeps its week opposite its session")
    check(PillRing.placed(claude: ClaudeStatus(), vibe: vibe, musicLive: false).cover?.tool == .vibe
            && PillRing.placed(claude: nil, vibe: vibe, musicLive: false).bars == nil,
          "rings: Vibe alone goes where the cover is, with nothing opposite")
    check(PillRing.placed(claude: claude, vibe: vibe, musicLive: true).bars == nil
            && PillRing.placed(claude: claude, vibe: vibe, musicLive: true).cover == nil,
          "rings: music playing and nobody at work, the cover and the bars stay")
    var working = claude, stopped = vibe
    working.state = .working
    stopped.state = .waiting
    check(PillRing.placed(claude: working, vibe: vibe, musicLive: true).bars?.tool == .claude
            && PillRing.placed(claude: claude, vibe: stopped, musicLive: true).bars?.state == .waiting,
          "rings: over music, a session at work or waiting takes the bars' place")
    check(PillRing.placed(claude: working, vibe: stopped, musicLive: true).bars?.tool == .vibe,
          "rings: of two, the one waiting for you")
    check(PillRing.inTopBar(claude: claude, vibe: vibe, room: 3).map(\.tool) == [.claude, .claudeWeek, .vibe]
            && PillRing.inTopBar(claude: claude, vibe: vibe, room: 2).map(\.tool) == [.claude, .vibe]
            && PillRing.inTopBar(claude: claude, vibe: nil, room: 2).map(\.tool) == [.claude, .claudeWeek],
          "rings: the top bar has each tool's ring, and the week's where there is room left")
    check(PillRing.inTopBar(claude: claude, vibe: vibe, room: 1).map(\.tool) == [.claude]
            && PillRing.inTopBar(claude: claude, vibe: stopped, room: 1).map(\.tool) == [.vibe]
            && PillRing.inTopBar(claude: claude, vibe: vibe, room: 0).count == 1
            && PillRing.inTopBar(claude: nil, vibe: nil, room: 3).isEmpty,
          "rings: room for one, the tool that is busy has it — Claude Code's otherwise; none switched on, none")

    let rows = ClaudeUsagePage.rows(
        claude: ClaudeStatus(sessions: [.init(pid: 1, name: "resonata", state: .idle, app: "Terminál")]),
        vibe: VibeStatus(sessions: [.init(pid: 1, name: "milionar", state: .working, app: nil, key: "s1")]))
    check(rows.map(\.session.name) == ["milionar", "resonata"] && Set(rows.map(\.id)).count == 2,
          "sessions: both tools' in one list, the one at work first, told apart even on one pid")
    check(ClaudeUsagePage.doing(rows[0]) == "Vibe · pracuje" && ClaudeUsagePage.doing(rows[1]) == "Claude · volno · Terminál",
          "sessions: with both switched on, each line says whose it is")
    // A click on a session's row: the Terminal tab it is typed into.
    let tabScript = ClaudeMonitor.terminalTabScript(tty: "/dev/ttys001")
    check(tabScript?.contains("if tty of t is \"/dev/ttys001\" then") == true
            && tabScript?.contains("set selected of t to true") == true,
          "session click: the script picks the tab on the session's terminal")
    check(ClaudeMonitor.terminalTabScript(tty: "/dev/ttys001\" then\ndo shell script \"x") == nil
            && ClaudeMonitor.terminalTabScript(tty: "ttys001") == nil
            && ClaudeMonitor.terminalTabScript(tty: "/dev/disk1") == nil,
          "session click: nothing but a terminal's path goes into the script")
    // These tests have a terminal behind them only when run from one, so
    // only the shape is checked; no process, no terminal.
    check(ClaudeMonitor.tty(of: getpid()).map { $0.hasPrefix("/dev/") } ?? true,
          "session click: a process's terminal is a device path", "\(ClaudeMonitor.tty(of: getpid()) ?? "none")")
    check(ClaudeMonitor.tty(of: 0x3FFF_FFF0) == nil, "session click: no such process, no terminal")
    check(ClaudeUsagePage.rows(claude: nil, vibe: VibeStatus(sessions: [.init(pid: 1, name: "a", state: .idle)]))
            .map(ClaudeUsagePage.doing) == ["volno"], "sessions: one tool, no need to say")
}

MainActor.assumeIsolated {
    let model = NotchModel()
    check(!model.showsCollapsedContent, "claude: nothing playing, nothing in the pill")
    model.claude = ClaudeStatus(state: .working, session: "resonata")
    check(model.showsCollapsedContent, "claude: a working session puts its ring in the closed notch")
    model.claude = ClaudeStatus(state: .idle, usage: ClaudeUsage(sessionPercent: 6))
    check(model.showsCollapsedContent && !model.musicLive,
          "claude: nothing playing, the limits have the closed notch")
    model.claude = ClaudeStatus(state: .idle)
    check(!model.showsCollapsedContent, "claude: idle and no limits read, the notch is a notch again")

    // The sixth page is there only while Claude Code is switched on.
    UserDefaults.standard.set(false, forKey: Preferences.Key.showClaude)
    check(PanelTab.shown == [.music, .notes, .apps, .timer, .shelf] && PanelTab.shelf.neighbour(1) == nil,
          "page: without Claude Code, five pages and the shelf is the last")
    UserDefaults.standard.set(true, forKey: Preferences.Key.showClaude)
    check(PanelTab.shown.last == .usage && PanelTab.shelf.neighbour(1) == .usage
            && PanelTab.usage.neighbour(-1) == .shelf && PanelTab.usage.neighbour(1) == nil,
          "page: with it, the usage page follows the shelf")
    UserDefaults.standard.removeObject(forKey: Preferences.Key.showClaude)
    // Or Mistral Vibe: either one brings the page, and names it.
    UserDefaults.standard.set(true, forKey: Preferences.Key.showVibe)
    check(PanelTab.shown.last == .usage && PanelTab.usage.title == "Limity Mistral Vibe",
          "page: Vibe alone brings the usage page too, under its own name")
    UserDefaults.standard.set(true, forKey: Preferences.Key.showClaude)
    check(PanelTab.usage.title == "Limity Claude Code a Vibe", "page: both, and it says both")
    UserDefaults.standard.removeObject(forKey: Preferences.Key.showClaude)
    UserDefaults.standard.removeObject(forKey: Preferences.Key.showVibe)
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
    check(PlayerVolumeControl.symbol(for: 0) == "speaker.slash.fill"
          && PlayerVolumeControl.symbol(for: 50) == "speaker.wave.2.fill"
          && PlayerVolumeControl.symbol(for: 100) == "speaker.wave.3.fill", "spotify: speaker follows the level")
    check(PlayerVolumeControl.toggledMute(70, before: nil) == 0, "spotify: speaker click mutes")
    check(PlayerVolumeControl.toggledMute(0, before: 70) == 70, "spotify: second click brings the level back")
    check(PlayerVolumeControl.toggledMute(0, before: nil) == 50, "spotify: unmuting with nothing to go back to")
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
    // The pages beside the cutout: a name and a row of dots. The strip is
    // 103 pt without the calendar on a 14-inch screen.
    check(NotchView.pageDotsWidth(count: PanelTab.allCases.count) <= 103 - 20
            && NotchView.pageDotsWidth(count: PanelTab.allCases.count + 2) <= 103,
          "page dots: six fit the short strip with room over, and so would eight")
    check(PanelTab.allCases.allSatisfy { !$0.shortTitle.contains(" ") && $0.shortTitle.count <= 9 },
          "page name: one short word each, to fit the strip beside the cutout")
    check(C.swipeAction(travel: CGSize(width: 60, height: 5), precise: true) == .right, "swipe: right is next")
    check(C.swipeAction(travel: CGSize(width: -60, height: 0), precise: true) == .left, "swipe: left is previous")
    check(C.swipeAction(travel: CGSize(width: 40, height: 0), precise: true) == nil,
          "swipe: sideways needs a longer swipe than up or down")
    check(C.swipeAction(travel: CGSize(width: 35, height: 40), precise: true) == nil,
          "swipe: a diagonal is neither")
    check(C.swipeAction(travel: CGSize(width: 0, height: 1), precise: false) == .down,
          "swipe: one wheel click counts")
}

// MARK: - Updates

check(Updater.isNewer("1.0.8", than: "1.0.7"), "update: 1.0.8 is newer than 1.0.7")
check(Updater.isNewer("1.0.10", than: "1.0.9"), "update: compared as numbers, not text")
check(Updater.isNewer("1.1", than: "1.0.9"), "update: a missing part counts as 0")
check(!Updater.isNewer("1.0.7", than: "1.0.7"), "update: the same version isn't newer")
check(!Updater.isNewer("1.0", than: "1.0.0"), "update: 1.0 and 1.0.0 are the same")
check(!Updater.isNewer("1.0.6", than: "1.0.7"), "update: an older release isn't offered")
do {
    let json = """
    {"tag_name":"v1.0.8","html_url":"https://github.com/Durik24/Resonata/releases/tag/v1.0.8",
     "draft":false,"prerelease":false,
     "assets":[{"name":"notes.txt","browser_download_url":"https://example.invalid/notes.txt"},
               {"name":"Resonata-1.0.8-macOS-AppleSilicon.zip",
                "browser_download_url":"https://github.com/Durik24/Resonata/releases/download/v1.0.8/Resonata-1.0.8-macOS-AppleSilicon.zip"}]}
    """
    let release = Updater.parseRelease(Data(json.utf8))
    check(release?.version == "1.0.8", "update: the v is dropped from the tag", "\(release?.version ?? "nil")")
    check(release?.zip.lastPathComponent == "Resonata-1.0.8-macOS-AppleSilicon.zip", "update: the zip is the one installed")
    let pre = json.replacingOccurrences(of: "\"prerelease\":false", with: "\"prerelease\":true")
    check(Updater.parseRelease(Data(pre.utf8)) == nil, "update: a pre-release isn't offered")
    let bare = #"{"tag_name":"v1.0.8","html_url":"https://github.com/x","assets":[]}"#
    check(Updater.parseRelease(Data(bare.utf8)) == nil, "update: a release with no zip isn't offered")
}
check(!Updater.isSignedLikeMe(URL(fileURLWithPath: "/System/Applications/Calculator.app")),
      "update: an app signed by someone else is refused")

// MARK: - Language

check(L.usesCzech(setting: "czech", preferred: ["en-GB"]), "language: Czech when chosen, whatever the Mac speaks")
check(!L.usesCzech(setting: "english", preferred: ["cs-CZ"]), "language: English when chosen")
check(L.usesCzech(setting: nil, preferred: ["cs-CZ", "en-GB"]), "language: left alone, Czech on a Czech Mac")
check(!L.usesCzech(setting: "system", preferred: ["en-GB", "cs-CZ"]), "language: left alone, English when Czech isn't first")
check(!L.usesCzech(setting: nil, preferred: []), "language: English when the Mac says nothing")
check(L.more(2, czech: true) == "+ 2 další" && L.more(4, czech: true) == "+ 4 další",
      "plural: two to four are 'další'")
check(L.more(5, czech: true) == "+ 5 dalších" && L.more(12, czech: true) == "+ 12 dalších",
      "plural: five and up are 'dalších'")
check(L.more(5, czech: false) == "+ 5 more", "plural: English has the one form")
check(PanelTab.music.title == "Hudba", "language: the tests run in Czech")
L.isCzech = false
check(PanelTab.music.title == "Music" && OpenMode.click.title == "Click", "language: the same strings in English")
L.isCzech = true

// MARK: - What lyrics are looked up for

do {
    func song(_ duration: Double, artist: String = "X") -> Track {
        Track(title: "A", artist: artist, album: "Y", duration: duration, sampledPosition: 0,
              sampledAt: t0, isPlaying: true, source: "Safari")
    }
    check(LyricsStore.shouldLookUp(song(214)), "lyrics: a song is looked up")
    check(!LyricsStore.shouldLookUp(song(0)), "lyrics: no length — a live stream, or not known yet — isn't")
    check(!LyricsStore.shouldLookUp(song(3600)), "lyrics: an hour-long episode isn't")
    check(!LyricsStore.shouldLookUp(song(12)), "lyrics: a twelve-second clip isn't")
    check(!LyricsStore.shouldLookUp(song(214, artist: "  ")), "lyrics: nothing without an artist")
    check(LyricsStore.shouldLookUp(song(15 * 60)) && !LyricsStore.shouldLookUp(song(15 * 60 + 1)),
          "lyrics: a quarter of an hour is the longest song")

    // Search results: the album cut is 214 s; a live version runs 263.
    check(LyricsStore.closest([263, 214.4, 198], to: 214) == 1, "lyrics: the result nearest in length, not the first")
    check(LyricsStore.closest([263, 301], to: 214) == nil, "lyrics: none within ten seconds, none used")
    check(LyricsStore.closest([224], to: 214) == 0 && LyricsStore.closest([224.5], to: 214) == nil,
          "lyrics: ten seconds out is the limit")
    check(LyricsStore.closest([nil, 215], to: 214) == 1, "lyrics: a result with a length beats one without")
    check(LyricsStore.closest([nil, nil], to: 214) == 0, "lyrics: no lengths to go by, the first as before")
    check(LyricsStore.closest([], to: 214) == nil, "lyrics: no results, none used")
    check(LyricsStore.closest([300, 200], to: 0) == 0, "lyrics: the song's own length unknown, the first")
}

// MARK: - The bigger lyrics view

check(LyricsList.window(count: 40, current: 10, visible: 5) == 8..<13, "lyrics list: the sung line in the middle")
check(LyricsList.window(count: 40, current: nil, visible: 5) == 0..<5, "lyrics list: before the first line, the first five")
check(LyricsList.window(count: 40, current: 1, visible: 5) == 0..<5, "lyrics list: no gap above the first line")
check(LyricsList.window(count: 40, current: 39, visible: 5) == 35..<40, "lyrics list: the last five at the end")
check(LyricsList.window(count: 4, current: 2, visible: 5) == 0..<4, "lyrics list: a short song shows whole")
check(LyricsList.window(count: 0, current: nil, visible: 5).isEmpty, "lyrics list: nothing to show")

// MARK: - Live streams

check(!NotchView.isLive(duration: 0, settled: false), "live: not while the length may still be on its way")
check(NotchView.isLive(duration: 0, settled: true), "live: still no length after a moment")
check(!NotchView.isLive(duration: 214, settled: true), "live: a song with a length isn't")

// MARK: - Keys on the open panel

do {
    typealias C = NotchPanelController
    check(C.keyAction(keyCode: 53, expanded: true, typing: false) == .close, "keys: Esc closes the open panel")
    check(C.keyAction(keyCode: 53, expanded: true, typing: true) == .close, "keys: Esc closes it from a note too")
    check(C.keyAction(keyCode: 53, expanded: true, typing: true, composing: true) == nil,
          "keys: Esc is the input method's while it composes")
    check(C.keyAction(keyCode: 49, expanded: true, typing: false) == .playPause, "keys: Space plays and pauses")
    check(C.keyAction(keyCode: 49, expanded: true, typing: true) == nil, "keys: Space in a note is a space")
    check(C.keyAction(keyCode: 49, expanded: false, typing: false) == nil
          && C.keyAction(keyCode: 53, expanded: false, typing: false) == nil, "keys: nothing while closed")
    check(C.keyAction(keyCode: 49, expanded: true, typing: false, modified: true) == nil,
          "keys: with ⌘ held it's somebody's shortcut")
    check(C.keyAction(keyCode: 0, expanded: true, typing: false) == nil, "keys: other keys are left alone")
}

// MARK: - Volume for Spotify and Apple Music

do {
    func playing(_ source: String, _ bundle: String?) -> Track {
        Track(title: "A", artist: "X", album: "Y", duration: 100, sampledPosition: 0, sampledAt: t0,
              isPlaying: true, source: source, bundleID: bundle)
    }
    check(PlayerVolume.player(for: playing("Spotify", "com.spotify.client")) == PlayerVolume.spotify,
          "volume: Spotify has a slider")
    check(PlayerVolume.player(for: playing("Hudba", "com.apple.Music")) == PlayerVolume.music,
          "volume: so has Music, found by its ID — it's 'Hudba' on a Czech Mac")
    check(PlayerVolume.music.scriptName == "Music", "volume: AppleScript is told 'Music', never the name shown")
    check(PlayerVolume.player(for: playing("Safari", "com.apple.Safari")) == nil, "volume: a browser has none")
    check(PlayerVolume.player(for: nil) == nil, "volume: nothing playing, no slider")
}

// MARK: - Settling, and an update found before a restart

check(AnimationSpeed.normal.settleTime == 0.55 && AnimationSpeed.fast.settleTime == 0.55,
      "settle: fast and normal as before")
check(AnimationSpeed.slow.settleTime > 0.9, "settle: the slow spring is given time to land")

do {
    let day = 24.0 * 3600
    check(!Updater.shouldCheck(atLaunch: true, lastCheck: 1000, now: 1000 + 3600, announced: nil, current: "1.0.8"),
          "update: checked an hour ago, nothing found, not again")
    check(Updater.shouldCheck(atLaunch: true, lastCheck: 1000, now: 1000 + 3600, announced: "1.0.9", current: "1.0.8"),
          "update: one found before the restart is looked up again at launch")
    check(!Updater.shouldCheck(atLaunch: false, lastCheck: 1000, now: 1000 + 3600, announced: "1.0.9", current: "1.0.8"),
          "update: but only at launch, not every hour")
    check(!Updater.shouldCheck(atLaunch: true, lastCheck: 1000, now: 1000 + 3600, announced: "1.0.8", current: "1.0.8"),
          "update: once it's installed there's nothing to look up")
    check(Updater.shouldCheck(atLaunch: false, lastCheck: 1000, now: 1000 + day, announced: nil, current: "1.0.8"),
          "update: and once a day regardless")
}

// MARK: - Last: a lyrics line that used to crash the parser

// The open spring's clock starts at its first drawn frame. Opened by hover,
// the first frame came 33 to 51 ms after the state change and the panel
// started a third to a half of the way out.
check(StartsOnFirstFrame.lateness(firstFrameAt: 1.0 / 60) == 0,
      "Open spring: a first frame on time drops nothing")
check(StartsOnFirstFrame.lateness(firstFrameAt: 0.008) == 0,
      "Open spring: an early first frame (120 Hz) drops nothing")
check(abs(StartsOnFirstFrame.lateness(firstFrameAt: 0.051) - (0.051 - 1.0 / 60)) < 1e-9,
      "Open spring: a late first frame is counted as one frame in")

// The cover flying between the pill and the panel starts and lands on the
// resting covers' own frames, measured from the top of the notch's centre
// line. On the 13" Air: a 185 x 38 cutout, the pill 303 wide.
do {
    let notch = CGSize(width: 185, height: 38)
    let pill = notch.width + NotchMetrics.contentWidth(scale: 1)
    let closed = NotchView.closedCoverFrame(notch: notch, scale: 1, swollen: false)
    check(closed == CGRect(x: -pill / 2 + 6 + NotchMetrics.collapsedInset, y: 4, width: 30, height: 30),
          "Flying cover: starts on the pill's cover", "\(closed)")
    let swollen = NotchView.closedCoverFrame(notch: notch, scale: 1, swollen: true)
    check(swollen.minX == closed.minX - NotchMetrics.hoverGrowth.width / 2
            && swollen.minY == closed.minY + NotchMetrics.hoverGrowth.height / 2
            && swollen.size == closed.size,
          "Flying cover: follows the pill swollen under the pointer", "\(swollen)")
    let open = NotchView.openCoverFrame(notch: notch, panelWidth: 470,
                                        inPage: CGRect(x: 0, y: 0, width: 110, height: 110))
    check(open == CGRect(x: -215, y: 46, width: 110, height: 110),
          "Flying cover: lands on the panel's cover", "\(open)")
    let lower = NotchView.openCoverFrame(notch: notch, panelWidth: 640,
                                         inPage: CGRect(x: 0, y: 6, width: 110, height: 110))
    check(lower.minX == -300 && lower.minY == 52,
          "Flying cover: lands where the page put the cover", "\(lower)")
    func at(_ progress: CGFloat, swell: CGFloat = 0) -> CGRect {
        FlyingCover.frame(progress: progress, swell: swell, closed: closed, swollen: swollen, open: open)
    }
    check(at(0) == closed && at(1) == open && at(0, swell: 1) == swollen,
          "Flying cover: the ends are the ends")
    check(at(1, swell: 1) == open, "Flying cover: the swell is nothing once open")
    let half = at(0.5)
    check(half.width == 70 && half.minX == (closed.minX + open.minX) / 2 && half.minY == 25,
          "Flying cover: a straight line in between", "\(half)")
    // Inside the box all the way: the box's left edge and height are
    // straight lines in the same progress.
    let inside = stride(from: CGFloat(0), through: 1, by: 0.1).allSatisfy { t in
        let frame = at(t)
        let boxLeft = -(pill + (470 - pill) * t) / 2, boxHeight = 38 + (NotchView.expandedHeight - 38) * t
        return frame.minX >= boxLeft && frame.maxY <= boxHeight
    }
    check(inside, "Flying cover: never outside the box it flies in")
    check(FlyingCover.badgeOpacity(progress: 0) == 0 && FlyingCover.badgeOpacity(progress: 0.5) == 0
            && FlyingCover.badgeOpacity(progress: 1) == 1 && FlyingCover.badgeOpacity(progress: 1.02) == 1,
          "Flying cover: the badge is the panel's end of the flight")
}

// MARK: - Full-screen Spaces

// What macOS 27.2 reports, trimmed: the laptop's display on a Split View
// Space (Terminal beside Discord), an external one on a desktop.
do {
    let laptop = "37D8832A-2D66-02CA-B9F7-8F30A301B230", monitor = "0B1C2D3E-0000-4000-8000-123456789ABC"
    func display(_ id: String, type: Int) -> [String: Any] {
        ["Display Identifier": id,
         "Current Space": ["type": type, "ManagedSpaceID": 105, "uuid": "5D4CA236"] as [String: Any],
         "Spaces": [["type": 0, "ManagedSpaceID": 3], ["type": type, "ManagedSpaceID": 105]]]
    }
    let both = [display(laptop, type: 4), display(monitor, type: 0)]
    check(ManagedSpaces.showsFullScreen(displays: both, uuid: laptop) == true,
          "Spaces: a full-screen Space on this display")
    check(ManagedSpaces.showsFullScreen(displays: both, uuid: monitor) == false,
          "Spaces: a desktop on the other display")
    check(ManagedSpaces.showsFullScreen(displays: both, uuid: laptop.lowercased()) == true,
          "Spaces: the UUID's case doesn't matter")
    // "Displays have separate Spaces" off: one entry for every display.
    check(ManagedSpaces.showsFullScreen(displays: [display("Main", type: 4)], uuid: monitor) == true,
          "Spaces: one shared Space covers every display")
    check(ManagedSpaces.showsFullScreen(displays: [display("Main", type: 0)], uuid: nil) == false,
          "Spaces: a shared desktop")
    // No answer — nil, so the window list is asked instead.
    check(ManagedSpaces.showsFullScreen(displays: [], uuid: laptop) == nil, "Spaces: nothing reported")
    check(ManagedSpaces.showsFullScreen(displays: [display(monitor, type: 4)], uuid: laptop) == nil,
          "Spaces: this display isn't in the list")
    check(ManagedSpaces.showsFullScreen(displays: [["Display Identifier": laptop]], uuid: laptop) == nil,
          "Spaces: no current Space in the entry")
}

// The hidden notch comes back when the pointer is where the pill would be.
do {
    // The pill on the laptop at 1710x1112: 304x38 at the top, round the cutout.
    let pill = NSRect(x: 703, y: 1074, width: 304, height: 38)
    check(NotchPanelController.pointsAtNotch(NSPoint(x: 855, y: 1100), shape: pill), "Hidden notch: pointed at")
    check(NotchPanelController.pointsAtNotch(NSPoint(x: 855, y: 1112), shape: pill),
          "Hidden notch: the pointer stopped at the screen's top edge")
    check(!NotchPanelController.pointsAtNotch(NSPoint(x: 855, y: 1060), shape: pill), "Hidden notch: below it")
    check(!NotchPanelController.pointsAtNotch(NSPoint(x: 600, y: 1100), shape: pill),
          "Hidden notch: in the menu bar beside it")
}

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
