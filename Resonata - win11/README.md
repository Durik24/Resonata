# Resonata for Windows

The Windows version of [Resonata](<../Resonata - macOS/README.md>): now playing,
synced lyrics, an album-coloured wave, notes, app shortcuts, a timer and a file
shelf. Windows has no notch and its windows use the top of the screen, so here
Resonata is **completely hidden until wanted**. Rest the pointer at the top
centre of the screen and the pill slides out. In Hover mode, staying on it opens
the whole panel and moving away closes it; in Click mode a click opens it and
another closes it. A click on that edge, on the pill, the shortcut (Ctrl + Shift +
Space, or Alt + Shift + N) or the tray
icon opens the panel at once. It slides out by itself for a moment when a new
song starts or the timer ends.

The interface is in English by default, with Czech in Settings.

It doesn't listen to the computer's sound. It reads what Windows' own media
flyout shows, so it works with Spotify, browser tabs and most other players.

See [`NAVOD.md`](NAVOD.md) for the Czech step-by-step.

## Building

Needs the .NET 10 SDK and Inno Setup 6.

```
.\build.ps1
```

runs the tests, publishes a self-contained build and writes
`out\Resonata-Setup-<version>.exe`. The version is `<Version>` in
`src\Resonata.csproj`.

For everyday work:

```
dotnet run --project src
dotnet run --project tests
```

`RESONATA_DEMO=1` shows a made-up song instead of what's playing.
`RESONATA_SNAP=<folder>` drives every state, photographs it and quits.

## Install, update, uninstall

Setup installs into `C:\Program Files\Resonata`, which needs an administrator's
confirmation. **An update is just the next Setup run over the top**: the same
`AppId` finds the installed copy and replaces it. Notes and settings live in
`%APPDATA%\Resonata`, so they aren't touched.

Resonata checks this repository's GitHub Releases once a day and offers to fetch
and run the new Setup. It takes the newest release with an asset named
`Resonata-Setup*.exe`. Tag Windows releases `win-v1.2.3` and publish them with
"Set as latest" off (`gh release create --latest=false`): the Mac app reads the
repository's latest release, so that has to stay the Mac's.

`.\build.ps1 -TestInstall` also builds a variant that installs into the user's
own folder without admin rights, for trying upgrade and uninstall. Never publish
that one.

Setup isn't code-signed (that needs a paid certificate), so SmartScreen can warn
about it, and an update is trusted on HTTPS plus a check that the download is a
newer Resonata Setup, not on a signature as on the Mac.

## What each part does

| Path | Job |
|---|---|
| `src/Logic/Core.cs` | Everything with no UI: playhead, LRC, motion, Pomodoro, accent colour, spring, rules. Tested |
| `src/Model/` | The panel's state and the settings file |
| `src/Services/MediaService.cs` | Now playing and transport, via Windows' media sessions |
| `src/Services/Stores.cs` | Lyrics, notes, shelf, app shortcuts, login item |
| `src/Services/System.cs` | Battery, headphones, Spotify's volume, hot key, calendar, updater, icons |
| `src/UI/NotchWindow.xaml.cs` | The window: the shape's spring, pointer watching, clicks outside, pages |
| `src/UI/` | The pages, the settings window, the tray icon, demo mode |
| `installer/Resonata.iss` | The installer and uninstaller |
| `tests/` | The logic tests, in the plain style of the Mac's |

## Lyrics

Looked up on LRCLIB only with *Lyrics* switched on in Settings, and only for
songs: something with an artist that runs 30 s – 15 min, so not a podcast, a
film or a live stream. When the exact match misses, the search result nearest
the song's length is used, and none if the nearest is more than 10 s out.
Click the lyric line for five lines of the song at once; click a line to jump
there. A stream with no length shows **LIVE** instead of a bar stuck at 0:00.

## Differences from the Mac

- Retracts fully instead of sitting in a notch, so nothing covers the top of the
  screen. While hidden the pointer is watched by position, with no window there
  to get in the way. Only the top two rows of pixels in the middle of the
  screen react to a click; that click opens the panel and goes no further.
- The timer's countdown shows in the pill when it's out and in the tray tooltip,
  not permanently.
- The calendar reads private `.ics` links. Windows has nothing a desktop app can
  simply ask for your events.
- No Apple Music heart: nothing on Windows to talk to.
- Spotify's volume moves the slider in Spotify's own window, as AppleScript's
  `sound volume` does on the Mac, through UI Automation (Windows' interface for
  screen readers; Spotify has no other way in). It works with the window
  minimised and for a device Spotify plays on through Connect. Spotify's slider
  takes tenths, so the level moves in steps of 10. A minimised window reports a
  change only when next asked something, so the last level is sent once more
  when a drag stops. With no Spotify window, the Windows mixer's level for
  Spotify instead, which is this PC's alone.

## Cost

Measured on this development PC: about 0.4 % of one core while hidden and 3.9 %
open with the wave moving. The bars and wave stop when nothing plays or nothing
is on screen.

## License

MIT — see `LICENSE` in the repository root. Uses
[Ical.Net](https://github.com/ical-org/ical.net) and
[NAudio](https://github.com/naudio/NAudio), under their own MIT licenses.
