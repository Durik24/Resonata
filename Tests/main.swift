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

// MARK: - Spectrum

let sampleRate = 48_000.0

func tone(_ hz: Double, seconds: Double, amplitude: Float = 0.5) -> [Float] {
    (0..<Int(seconds * sampleRate)).map {
        amplitude * Float(sin(2 * .pi * hz * Double($0) / sampleRate))
    }
}

/// A kick drum: a 70 Hz thump that decays in ~60 ms, repeated at `bpm`.
func kicks(bpm: Double, seconds: Double) -> [Float] {
    let period = 60 / bpm
    return (0..<Int(seconds * sampleRate)).map { i in
        let since = (Double(i) / sampleRate).truncatingRemainder(dividingBy: period)
        return Float(0.8 * exp(-since / 0.06) * sin(2 * .pi * 70 * since))
    }
}

/// Feeds a signal through in 1024-sample buffers, the size ScreenCaptureKit
/// delivers, and returns every frame the analyser produced.
func feed(_ analyzer: SpectrumAnalyzer, _ signal: [Float], chunk: Int = 1024) -> [SpectrumFrame] {
    var frames: [SpectrumFrame] = []
    signal.withUnsafeBufferPointer { buffer in
        var i = 0
        while i < buffer.count {
            let n = min(chunk, buffer.count - i)
            if let frame = analyzer.process(buffer.baseAddress! + i, count: n) {
                frames.append(frame)
            }
            i += n
        }
    }
    return frames
}

func loudestBand(_ bands: [Float]) -> Int {
    bands.indices.max { bands[$0] < bands[$1] } ?? -1
}

let geometry = SpectrumAnalyzer(bandCount: 32, sampleRate: sampleRate)!
let ranges = geometry.bandRanges
check(ranges.count == 32, "spectrum: 32 bands")
check(ranges.allSatisfy { !$0.isEmpty && $0.lowerBound >= 1 && $0.upperBound <= 1024 },
      "spectrum: every band has bins, none is DC, none past Nyquist")
check(zip(ranges, ranges.dropFirst()).allSatisfy { $0.lowerBound <= $1.lowerBound },
      "spectrum: bands ascend in frequency")
check((ranges.last?.count ?? 0) > (ranges[16].count) * 10,
      "spectrum: bands widen with frequency (log spacing)")

let silence = feed(SpectrumAnalyzer(bandCount: 32, sampleRate: sampleRate)!,
                   [Float](repeating: 0, count: 24_000)).last!.bands
check(silence.allSatisfy { $0 == 0 }, "spectrum: silence is all zeros")

let oneK = SpectrumAnalyzer(bandCount: 32, sampleRate: sampleRate)!
let oneKBands = feed(oneK, tone(1000, seconds: 0.5)).last!.bands
let oneKBin = Int((1000 / (sampleRate / 2048)).rounded())
check(oneK.bandRanges[loudestBand(oneKBands)].contains(oneKBin),
      "spectrum: a 1 kHz tone lights the band containing 1 kHz",
      "loudest band \(loudestBand(oneKBands)) = bins \(oneK.bandRanges[loudestBand(oneKBands)]), 1 kHz is bin \(oneKBin)")
check(oneKBands.allSatisfy { $0 >= 0 && $0 <= 1 }, "spectrum: levels stay within 0...1")

let low = loudestBand(feed(SpectrumAnalyzer(bandCount: 32, sampleRate: sampleRate)!,
                           tone(100, seconds: 0.5)).last!.bands)
let high = loudestBand(feed(SpectrumAnalyzer(bandCount: 32, sampleRate: sampleRate)!,
                            tone(6000, seconds: 0.5)).last!.bands)
check(low < loudestBand(oneKBands) && loudestBand(oneKBands) < high,
      "spectrum: 100 Hz < 1 kHz < 6 kHz, left to right",
      "bands \(low), \(loudestBand(oneKBands)), \(high)")

let quiet = feed(SpectrumAnalyzer(bandCount: 32, sampleRate: sampleRate)!,
                 tone(1000, seconds: 0.5, amplitude: 0.001)).last!.bands.max()!
check(quiet < (oneKBands.max()! - 0.3), "spectrum: a -60 dB tone draws much lower than a loud one",
      "quiet \(quiet), loud \(oneKBands.max()!)")

// The detector has to count beats on the *audio's* clock. Audio here arrives
// far faster than real time, which is also what a burst of queued buffers
// looks like in the app.
let kickFrames = feed(SpectrumAnalyzer(bandCount: 32, sampleRate: sampleRate)!,
                      kicks(bpm: 120, seconds: 8))
let kickBeats = kickFrames.filter(\.beat).count
check((13...16).contains(kickBeats), "beats: a 120 BPM kick over 8 s gives ~16 beats",
      "\(kickBeats) beats")

let steadyBeats = feed(SpectrumAnalyzer(bandCount: 32, sampleRate: sampleRate)!,
                       tone(80, seconds: 4)).filter(\.beat).count
check(steadyBeats == 0, "beats: a steady bass tone is not a beat", "\(steadyBeats) beats")

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

// MARK: - Wave

/// Bands as recorded from real music earlier (RESONATA_DEBUG_BANDS sparklines).
func bands(_ sparkline: String) -> [Float] {
    let blocks = Array(" ▁▂▃▄▅▆▇█")
    return sparkline.map { Float(blocks.firstIndex(of: $0) ?? 0) / 8 }
}
let rock = bands("▃▄▄▄▄▆▇▆▆▇▆▆▆▆▄▄▅▄▂▂▂▂▃▂▂▂▁▁▁▁  ")
let loud = bands("▄▅▅▅▆▇▆▄▆▆▅▅▆▆▄▃▄▄▃▃▂▂▂▂▂▂▂▁▁▁▁ ")

let waveLevels = SpectrumWaveView.levels(from: rock, animating: true, at: 0)
check(waveLevels.count == rock.count, "wave: one point per band")
check(waveLevels.allSatisfy { $0 >= 0 && $0 <= 1 }, "wave: heights stay within 0...1")
check(waveLevels.first! < 0.1 && waveLevels.last! < 0.1, "wave: tapers to the baseline at both ends",
      "ends \(waveLevels.first!), \(waveLevels.last!)")
// "Barcode" means every band about as tall as the loudest. Compare how far a
// typical band sits below the peak, in the wave and in the raw bands.
func dip(_ values: [CGFloat]) -> CGFloat {
    let peak = values.max()!, median = values.sorted()[values.count / 2]
    return (peak - median) / peak
}
let middle = Array(waveLevels[6..<18])
let inMiddle = rock[6..<18].map { CGFloat($0) }
// 1.25x rather than more: the treble tilt deliberately lifts the quieter
// right-hand bands, trading a little of this contrast for a right side that
// isn't flat.
check(dip(middle) > dip(inMiddle) * 1.25, "wave: peaks stand out (no more barcode)",
      "wave dip \(dip(middle)), bands dip \(dip(inMiddle))")
check(waveLevels.max()! > 0.8, "wave: real music uses most of the strip's height",
      "peak \(waveLevels.max()!)")
check(waveLevels[22..<28].max()! > 0.15, "wave: the treble side isn't dead flat",
      "treble peak \(waveLevels[22..<28].max()!)")
check(SpectrumWaveView.levels(from: rock, animating: false, at: 0).max()! < 0.1,
      "wave: at rest it is a low line")
check(SpectrumWaveView.levels(from: [], animating: true, at: 3).max()! > 0.05,
      "wave: with no signal it still swells")

let waveRect = CGRect(x: 0, y: 0, width: 426, height: 26)
let (waveLine, waveFill) = SpectrumWaveView.paths(for: waveLevels, in: waveRect)
check(waveRect.insetBy(dx: -0.5, dy: -0.5).contains(waveFill.boundingBoxOfPath),
      "wave: the curve never leaves its strip", "\(waveFill.boundingBoxOfPath)")
check(abs(waveLine.boundingBoxOfPath.width - waveRect.width) < 0.5, "wave: spans the full width")

/// Draws waves to a PNG to look at; prints where.
func renderWaves(_ sets: [[Float]], colour: NSColor) -> URL {
    let scale: CGFloat = 2, w = waveRect.width, h = waveRect.height + 8
    let rows = CGFloat(sets.count)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * scale),
                               pixelsHigh: Int(h * rows * scale), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.scaleBy(x: scale, y: scale)
    ctx.setFillColor(NSColor(white: 0.06, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h * rows))
    for (row, set) in sets.enumerated() {
        let rect = waveRect.offsetBy(dx: 0, dy: CGFloat(sets.count - 1 - row) * h + 4)
        let (line, fill) = SpectrumWaveView.paths(
            for: SpectrumWaveView.levels(from: set, animating: true, at: 0), in: rect)
        ctx.saveGState()
        ctx.addPath(fill); ctx.clip()
        let gradient = CGGradient(colorsSpace: nil, colors: [
            colour.withAlphaComponent(0.6).cgColor, colour.withAlphaComponent(0.05).cgColor] as CFArray,
            locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.maxY),
                               end: CGPoint(x: 0, y: rect.minY), options: [])
        ctx.restoreGState()
        ctx.addPath(line)
        ctx.setStrokeColor(colour.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(1.5); ctx.setLineCap(.round)
        ctx.strokePath()
    }
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("resonata-wave.png")
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
    return url
}
if ProcessInfo.processInfo.environment["RESONATA_RENDER_WAVE"] == "1" {
    print("wave render: \(renderWaves([rock, loud], colour: NSColor(red: 0.85, green: 0.65, blue: 0.3, alpha: 1)).path)")
}

// MARK: - Next features

if #available(macOS 14.2, *) {
    check(ProcessTapSpectrum.belongs("com.spotify.client", to: "com.spotify.client"), "tap: the app's own process")
    check(ProcessTapSpectrum.belongs("com.google.Chrome.helper", to: "com.google.Chrome"), "tap: a helper process")
    check(ProcessTapSpectrum.belongs("com.apple.WebKit.GPU", to: "com.apple.Safari"), "tap: Safari's shared WebKit audio")
    check(!ProcessTapSpectrum.belongs("com.spotify.clientX", to: "com.spotify.client"), "tap: a lookalike ID is someone else")
    check(!ProcessTapSpectrum.belongs("com.apple.WebKit.GPU", to: "com.google.Chrome"), "tap: WebKit belongs only to Safari")
}

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

// MARK: - Animation styles

check(OpenStyle.allCases.filter { !$0.scalesContent } == [.pour], "open styles: only Pour reveals instead of zooming")
check(Set(OpenStyle.allCases.map(\.title)).count == OpenStyle.allCases.count, "open styles: distinct names")
check(PillStyle(rawValue: UserDefaults.standard.string(forKey: Preferences.Key.pillStyle) ?? "") == .bars,
      "pill style: bars by default")
check(TrackChange(rawValue: UserDefaults.standard.string(forKey: Preferences.Key.trackChange) ?? "") == .fade,
      "track change: fade by default")

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
