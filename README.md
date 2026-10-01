# Resonata — the notch that hears the music

A Dynamic-Island-style music player pinned over the MacBook notch. Collapsed, it
shows the album art and a spectrum; click it and it expands to the title, a
scrubber, transport controls, and the full spectrum. Click anywhere else to
close it.

The difference from every other notch app: **it listens.** The bars are a real
FFT of the audio leaving the machine, not an animation, and the notch itself
breathes on each beat. That also means it reacts to a YouTube tab or VLC —
anything the Mac plays — even though only Spotify and Music supply a title.

macOS 14+, Swift 6, no Xcode project needed. See `NAVOD.txt` for the
step-by-step (Czech).

## Getting it running

```
./setup-signing.sh   # once: a stable signing identity, so permissions stick
./build.sh run
```

Then grant two permissions when asked (System Settings → Privacy & Security
if the dialogs don't appear):

- **Automation** for Spotify / Music — reading what's playing and the buttons.
- **Screen Recording** — the audio tap. ScreenCaptureKit is the only public,
  supported way to capture system audio, and it lives under this permission
  even though the video side is discarded at 2×2 pixels. Without it the bars
  fall back to a synthetic bounce.

Why the signing step matters: an ad-hoc signature is a hash of the binary, so
every rebuild gave the app a new identity and macOS silently revoked both
permissions. `setup-signing.sh` makes a self-signed certificate in your login
keychain; `build.sh` uses it when present.

## What each file does

| File | Job |
|---|---|
| `ScreenGeometry.swift` | Finds the notch's real size via `safeAreaInsets` and `auxiliaryTopLeftArea` |
| `NotchShape.swift` | The silhouette — concave top corners, rounded bottom, animatable radii |
| `NotchPanel.swift` | Borderless `NSPanel` above the menu bar, repositions on display changes |
| `NowPlaying.swift` | Reads Spotify/Music over AppleScript, driven by their change notifications; interpolates the playhead between syncs |
| `AudioSpectrum.swift` | ScreenCaptureKit audio tap → Hann window → `vDSP_fft_zrip` → 32 log-spaced bands → beat detection |
| `Lyrics.swift` | Synced lyrics from LRCLIB, LRC parsing, on-disk cache |
| `MediaRemote.swift` | System-wide now-playing via the vendored adapter; transport and seek for any player; AppleScript fallback |
| `Vendor/mediaremote-adapter/` | BSD-3 sources of the adapter, built into the bundle by `build.sh` |
| `NotchView.swift` | Collapsed and expanded SwiftUI states with a spring between them; spectrum bars and beat flash on Core Animation layers; lyrics row; volume meter |
| `Volume.swift` | Output volume via Core Audio, and the scroll-to-volume mapping |
| `ResonataApp.swift` | Wires it together, sets `.accessory` activation policy |
| `setup-signing.sh` | One-time: creates the "Resonata Dev" signing identity |

## Cost

Measured on an M4 with `RESONATA_DEBUG_FORCE_LIVE=1` (animate as if playing)
and `RESONATA_DEBUG_FAKE_BEATS=1` (a beat every 0.5 s):

| | before | after |
|---|---|---|
| nothing playing | 0.7% | 0.0% |
| playing | 4.5% | 1.2% |
| playing, 120 BPM | 8.7% | 1.6% |

Two changes did it. The bars and the beat flash used to be SwiftUI animations,
which re-ran the view graph and re-rasterised on every frame; they are now
`CALayer`s moved by a display link and a `CABasicAnimation` that runs in the
render server. And audio capture now runs only while something is playing:
ScreenCaptureKit keeps `coreaudiod` streaming the mix to the app even in
silence, which cost 1.5–7% of a core in *coreaudiod* — invisible in the app's
own numbers.

## Listening without Screen Recording

On macOS 14.2 and later the spectrum comes from a Core Audio process tap
(`ProcessTap.swift`), not ScreenCaptureKit. It needs only the "System Audio
Recording" permission, is aimed at the playing app's own processes (so
notification sounds and calls don't move the bars), isn't attached to a
display, and sits before the output volume and mute. A tap idles at no cost
while its app is silent. Older macOS keeps the ScreenCaptureKit backend.

When something is playing but no sound reaches the Mac for 2.5 s — Spotify
playing on a phone, say — the bars and the wave show their fake motion
instead of sitting flat.

## Settings, shortcut, heart

Right-click → Nastavení… opens a settings window: open at login, a global
shortcut to open the notch (⇧⌘Space by default; Carbon hot keys, so no
Accessibility permission), how long after a pause the notch shrinks,
animation speed, lyrics on/off, and the wave's colour (album, white, or your
own). Animation choices: how the panel opens (zoom, a bouncing spring, a smooth
glide, a snap, or "pour" — content revealed top-down like a curtain), what
the closed notch shows (bars, a mini wave, pulsing dots, or a ring round the
cover that ripples on each beat), how the cover changes with the song (fade,
flip, slide), a push-in for the title and artist, and an optional flash of
the new cover's colour. The ripple and the flash are Core Animation, so they
cost the app nothing between events. Apple Music tracks get a heart button (`favorited` over AppleScript);
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
parser and line lookup, the FFT's band layout and tone placement, the beat
detector on a synthetic 120 BPM kick, and the MediaRemote stream parser fed
recorded `stream --micros` output — including a track change where the new
artwork arrives in a later diff than the new title. Exits non-zero on any
failure.

## How the spectrum works

`SpectrumAnalyzer` in `AudioSpectrum.swift`, every ~21 ms:

1. The newest 2048 samples (43 ms at 48 kHz) are Hann-windowed — without it a
   steady note smears across every bin and all the bars move together.
2. `vDSP_fft_zrip` from Accelerate does the real-to-complex FFT in place.
3. 1024 bins are collapsed into 32 bands spaced **logarithmically** from 40 Hz
   to 16 kHz. Linear spacing is the classic mistake: half of a linear spectrum
   is above 12 kHz where music has almost nothing, so the right-hand bars never
   move. We hear pitch in octaves; the bands have to be spaced the same way.
4. Peak per band → dB → mapped from −68…−12 dB onto 0…1.
5. Attack/release smoothing (rise fast, fall slow) so a transient hits its
   full height at once and then decays, instead of flickering.

Beat detection is energy-based: the unsmoothed energy in bands 2–8
(~58–215 Hz, the kick and bass) is compared to its own running average over
the last ~0.8 s. A frame that clears the average by 32% and by an absolute
margin, with at least 160 ms since the last beat, is a beat. Each one bumps a
counter that flashes a brighter copy of the colour wash.

The bands are deliberately *not* `@Published`. They change 50 times a second;
the bars pull the newest frame inside their own display-link tick instead,
so the display decides how often it redraws.

To see the numbers: `RESONATA_DEBUG_BANDS=1 ./Resonata.app/Contents/MacOS/Resonata`
prints a sparkline twice a second with a dot per beat.

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
- Real audio-reactive visualizer, with beat detection
- Synced lyrics: LRCLIB `/get` with an exact match, falling back to `/search`
  on title and artist; the expanded panel grows a three-line row when a song
  has them. Cached under `~/Library/Caches/com.local.resonata/lyrics/`.

## Next steps

- Core Audio process taps (macOS 14.4+) instead of ScreenCaptureKit: tap only
  the player's audio, under the lighter audio-recording permission
