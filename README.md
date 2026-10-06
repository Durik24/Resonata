# Resonata — a music notch for the MacBook

A Dynamic-Island-style music player pinned over the MacBook notch. Collapsed, it
shows the album art and moving bars; click it and it expands to the title, a
scrubber, transport controls, synced lyrics and a wave in the album's colour.
Click anywhere else to close it.

**It doesn't listen to your computer's sound.** No audio capture, no
recording permission of any kind. It knows what's playing from macOS's own
"now playing" information, the same thing Control Center shows. The bars and
the wave move with a calm made-up motion while something plays and rest when
it's paused. The colour flashes as each new line of the lyrics begins, so it
stays in time with the song without hearing it.

macOS 14+, Swift 6, no Xcode project needed. See `NAVOD.txt` for the
step-by-step (Czech).

## Getting it running

```
./setup-signing.sh   # once: a stable signing identity, so permissions stick
./build.sh run
```

The only permission it may ask for is **Automation** for Spotify / Music,
used by the fallback that reads what's playing and by the Apple Music heart.

Why the signing step matters: an ad-hoc signature is a hash of the binary, so
every rebuild gave the app a new identity and macOS silently revoked its
permissions. `setup-signing.sh` makes a self-signed certificate in your login
keychain; `build.sh` uses it when present.

## What each file does

| File | Job |
|---|---|
| `ScreenGeometry.swift` | Finds the notch's real size via `safeAreaInsets` and `auxiliaryTopLeftArea` |
| `NotchShape.swift` | The silhouette — concave top corners, rounded bottom, animatable radii |
| `NotchPanel.swift` | Borderless `NSPanel` above the menu bar, repositions on display changes |
| `NowPlaying.swift` | Reads Spotify/Music over AppleScript, driven by their change notifications; interpolates the playhead between syncs |
| `Lyrics.swift` | Synced lyrics from LRCLIB, LRC parsing, on-disk cache |
| `MediaRemote.swift` | System-wide now-playing via the vendored adapter; transport and seek for any player; AppleScript fallback |
| `Vendor/mediaremote-adapter/` | BSD-3 sources of the adapter, built into the bundle by `build.sh` |
| `NotchModel.swift` | Everything the views show: track, state, lyrics, volume level |
| `NotchView.swift` | The notch itself: size, colour wash, collapsed pill, open/close |
| `NotchView+Expanded.swift` | The open panel: artwork, title, scrubber, transport, lyrics row |
| `NotchFrame.swift` | Animates the notch's size and shape as one unit, pinned to the top |
| `Motion.swift` | The made-up motion behind the bars and the wave |
| `MusicBars.swift` | The pill's bars, as Core Animation layers on a display link |
| `MusicWave.swift` | The open panel's wave: Catmull-Rom curve, gradient fill |
| `LyricPulse.swift` | Fires as each lyric line begins: one timer, set for the next line |
| `GlowFlash.swift` | The colour flash, a render-server animation masked to the notch |
| `SongPeek.swift` | Decides when a new song gets a moment in the closed notch |
| `Notes.swift`, `NotesView.swift` | The notes page and its local storage |
| `QuickApps.swift`, `QuickAppsView.swift` | The app shortcuts page and its list |
| `LyricsView.swift` | Three lines of synced lyrics |
| `ArtworkAccent.swift` | Picks the accent colour out of the album art |
| `Controls.swift` | Transport button press style and the volume meter |
| `Volume.swift` | Output volume via Core Audio, and the scroll-to-volume mapping |
| `ResonataApp.swift` | Wires it together, sets `.accessory` activation policy |
| `setup-signing.sh` | One-time: creates the "Resonata Dev" signing identity |

## Cost

About 1.2% CPU on an M4 while something plays (the bars' display link), and
nothing at rest: the display links stop when playback does, and the lyric
flash is a single timer set for the next line rather than a poll.

The bars and the flash used to be SwiftUI animations, which re-ran the view
graph and re-rasterised every frame (4.5%, 8.7% with flashes). They are
`CALayer`s moved by a display link and a `CABasicAnimation` that runs in the
render server.

Measure with `RESONATA_DEBUG_FORCE_LIVE=1` (animate as if playing) and
`RESONATA_DEBUG_FAKE_PULSES=1` (a flash every 0.5 s).

## No listening

Resonata used to draw a real spectrum: it captured the playing app's sound
(ScreenCaptureKit, then a Core Audio process tap), ran an FFT over it and
detected beats. All of that is gone, by choice: no capture code, no
ScreenCaptureKit, Accelerate or AVFoundation linked, and no audio-capture
usage string in the Info.plist, so macOS never asks. It's in the git history
(`git log -- AudioSpectrum.swift ProcessTap.swift`) if it's ever wanted back.

## Song peek, notes, app shortcuts

Ideas taken from NotchNook (lo.cafe) and rebuilt from scratch — none of its
code or assets — keeping only what needs no permission:

- **Song peek** (`SongPeek.swift`): when a different song starts playing and
  the panel is closed, the pill slides out to the right, past the bars, for
  3.5 s with the title and artist. Its left edge (the artwork) stays still:
  `NotchFrame` animates a sideways shift together with the width, and the
  content takes its size from that one animation only. Not on launch, not on resume, not while open;
  switchable in settings.
- **Pages**: icons in the strip beside the cutout switch the open panel
  between Music, Notes and Apps.
- **Notes & to-dos** (`Notes.swift`, `NotesView.swift`): a note and a
  checklist, saved locally to `~/Library/Application Support/Resonata/
  notes.json`, half a second after the last change. ⌘C/⌘V/⌘X/⌘A/⌘Z work even
  though the app has no Edit menu (`NotchPanel.performKeyEquivalent`).
- **App shortcuts** (`QuickApps.swift`, `QuickAppsView.swift`): up to eleven
  apps; click to open, "+" to add, remove and reorder in settings.

Left out on purpose: the camera mirror and the volume-key HUD (camera and
Accessibility permissions), per the no-listening, no-camera choice above.

## Settings, shortcut, heart

Right-click → Nastavení… opens a settings window: open at login, a global
shortcut to open the notch (⇧⌘Space by default; Carbon hot keys, so no
Accessibility permission), how long after a pause the notch shrinks,
animation speed, lyrics on/off, and the wave's colour (album, white, or your
own). Apple Music tracks get a heart button (`favorited` over AppleScript);
Spotify has no way to like a song from the Mac short of its web API.

## Menu and volume

Right-click (or control-click) the notch: switch display, open at login,
quit. Scroll over it to change the output volume — up is louder whatever the
natural-scrolling setting, turning it up unmutes, and the level shows in the
notch for a moment. Volume goes through Core Audio directly, so no permission
is needed.

## Starts at login

The first launch registers Resonata with `SMAppService.mainApp`, so it opens
again after a restart; macOS shows a "Login item added" notice. It registers
once only: switching it off in System Settings › General › Login Items is
respected. The registration survives `./build.sh` rebuilds (checked).

## Tests

```
./test.sh
```

Builds `Tests/main.swift` against the logic files with plain `swiftc` (no
Xcode project, no XCTest) and runs it: the interpolated playhead, the LRC
parser and line lookup, the made-up motion and the wave's curve, when the
lyric flash fires, and the MediaRemote stream parser fed
recorded `stream --micros` output — including a track change where the new
artwork arrives in a later diff than the new title. Exits non-zero on any
failure.

## The one hard problem: getting now-playing data

This is the part that trips everyone up, so it's worth understanding before you
pick an approach.

**MediaRemote** is Apple's private framework that backs Control Center's Now
Playing tile. `MRMediaRemoteGetNowPlayingInfo` used to give any app system-wide
metadata — title, artist, artwork, position — for *every* player including
browsers. Every notch app, BetterTouchTool, and `nowplaying-cli` was built on it.

As of **macOS 15.4**, `mediaremoted` checks for an entitlement Apple only issues
to its own processes. Third-party callers get nil back. Playback *commands* still
work; only reads are gated.

Three ways around it:

1. **Talk to players directly** (what this scaffold does). AppleScript /
   ScriptingBridge to Spotify and Music. No private API, no SIP changes, stable
   across OS updates. Downside: only apps with a scripting dictionary — no
   browser audio, no VLC. For a music widget that's usually enough.

2. **`mediaremote-adapter`** — <https://github.com/ungive/mediaremote-adapter>.
   Clever trick: processes with a `com.apple.*` bundle identifier are still
   allowed through, and `/usr/bin/perl` is one of them. So it shells out to the
   system Perl, which loads a small bundled framework, which talks to MediaRemote
   and streams JSON back. No SIP disabling. There's a maintained Swift package
   fork at <https://github.com/ejbills/mediaremote-adapter> — that's the one to
   use if you want full system-wide coverage. This is what the current crop of
   notch apps run on.

3. **JXA / AppleScript into MediaRemote** — no extra binaries, but no artwork and
   polling-based updates. Reference implementation:
   <https://gist.github.com/SKaplanOfficial/f9f5bdd6455436203d0d318c078358de>

Option 2 is the real answer if you want parity with NotchNook. Start with 1
because it'll be working in ten minutes, then swap the `NowPlayingSource`
implementation later — that protocol exists precisely so you can.

Note that anything touching MediaRemote is private API: it can break on any macOS
release and won't pass App Store review. Fine for a personal app or direct
distribution.

## Worth reading before you build much

**boring.notch** — <https://github.com/TheBoredTeam/boring.notch> — open source
(MIT), Swift, and does exactly what you're describing. Read how it handles the
panel lifecycle, multi-display, and the media backend before reinventing any of
it. NotchNook itself is closed source.

## Things that will bite you

- **Window level.** `.statusBar` draws *under* the menu bar. Use `.screenSaver`
  or higher.
- **Full-screen apps.** Without `.fullScreenAuxiliary` the panel vanishes the
  moment you full-screen something.
- **Resizing the window per state looks bad.** Keep the panel at a fixed large
  size and animate the SwiftUI shape inside it.
- **Hit-testing.** `.contentShape(NotchShape())` keeps clicks on the transparent
  area passing through to the menu bar behind. Skip it and you'll block the clock.
- **External displays.** `safeAreaInsets.top` is 0 there. Decide early whether
  you hide, or draw a floating pill.
- **AppleScript on a background queue.** `NSAppleScript` blocks; a 1s poll on the
  main thread will make the animation stutter.
- **Don't poll every second.** That was most of the app's idle cost. Spotify
  and Music both broadcast `DistributedNotificationCenter` events on every
  change (`com.spotify.client.PlaybackStateChanged`,
  `com.apple.iTunes.playerInfo`); listen for those and poll only as a slow
  safety net. Interpolate the playhead in between.

## Now-playing for every player

`MediaRemote.swift` runs the vendored [mediaremote-adapter](Vendor/mediaremote-adapter)
(`/usr/bin/perl` loading a small framework built by `build.sh`) and streams
MediaRemote's own now-playing state: title, artist, album, position, play
state and artwork for *any* app — a YouTube tab, VLC, a podcast player. The
transport buttons and the scrubber go through it too, so they work for those
apps. If the adapter can't start or MediaRemote doesn't answer on a given
macOS, the app falls back to the AppleScript source automatically and behaves
as before. Verified on macOS 26.5.

## Done

- Live progress bar interpolated between syncs — `Track.position(at:)`
- Click-and-drag scrubbing
- Synced lyric flash in place of beat detection (the audio visualiser was
  removed on purpose — no listening)
- Synced lyrics: LRCLIB `/get` with an exact match, falling back to `/search`
  on title and artist; the expanded panel grows a three-line row when a song
  has them. Cached under `~/Library/Caches/com.local.resonata/lyrics/`.

## Next steps

