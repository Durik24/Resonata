# Resonata — the notch that hears the music

A Dynamic-Island-style music player pinned over the MacBook notch. Collapsed, it
shows the album art and a spectrum; hover and it expands to the title, a
scrubber, transport controls, and the full spectrum.

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
| `NotchView.swift` | Collapsed and expanded SwiftUI states with a spring between them; spectrum bars; beat pulse |
| `ResonataApp.swift` | Wires it together, sets `.accessory` activation policy |
| `setup-signing.sh` | One-time: creates the "Resonata Dev" signing identity |

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
counter the view keys a 3% scale pulse and a colour-wash bloom off.

The bands are deliberately *not* `@Published`. They change 50 times a second;
the views pull the newest frame inside their own `TimelineView` tick instead,
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

## Done

- Live progress bar interpolated between syncs — `Track.position(at:)`
- Click-and-drag scrubbing
- Real audio-reactive visualizer, with beat detection

## Next steps

- Synced lyrics (LRCLIB is free and keyless; the interpolated playhead is
  exactly what makes line-by-line highlighting stay in time)
- Swap in `mediaremote-adapter` for titles and artwork from every source
- Core Audio process taps (macOS 14.4+) instead of ScreenCaptureKit: tap only
  the player's audio, under the lighter audio-recording permission
