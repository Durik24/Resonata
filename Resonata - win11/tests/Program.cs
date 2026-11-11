// The logic that doesn't need a screen, in the same plain style as the Mac's
// Tests/main.swift: no framework, non-zero exit on any failure.
using Resonata;

var passed = 0;
var failed = 0;

void Check(bool condition, string name)
{
    if (condition) { passed++; return; }
    failed++;
    Console.WriteLine($"FAIL: {name}");
}

void Near(double a, double b, string name, double tolerance = 0.001) =>
    Check(Math.Abs(a - b) <= tolerance, $"{name} (got {a}, wanted {b})");

// The interpolated playhead
var t0 = new DateTime(2026, 1, 1, 12, 0, 0);
var playing = new Track { Title = "A", Artist = "B", Album = "C", Duration = 100, SampledPosition = 10, SampledAt = t0, IsPlaying = true };
Near(playing.Position(t0.AddSeconds(5)), 15, "position runs while playing");
Near((playing with { IsPlaying = false }).Position(t0.AddSeconds(5)), 10, "position stands while paused");
Near(playing.Position(t0.AddSeconds(500)), 100, "position stops at the end");
Near((playing with { SampledPosition = 0 }).Position(t0.AddSeconds(-5)), 0, "position never negative");
Check(playing.IsSameTrack(playing with { SampledPosition = 50, IsPlaying = false }), "same song ignores what moves");
Check(!playing.IsSameTrack(playing with { Title = "Z" }), "another title is another song");
Check((playing with { Source = "Spotify.exe" }).IsSpotify, "Spotify from its exe name");
Check((playing with { Source = "SpotifyAB.SpotifyMusic_zpdnekdrzrea0!Spotify" }).IsSpotify, "Spotify from the Store");
Check(!(playing with { Source = "chrome" }).IsSpotify, "a browser isn't Spotify");

// LRC
const string lrc = "[ar:Someone]\n[00:01.00] one\n[00:02.50][00:09.00] two\n[00:03.00] three\n[00:04.00] four\n";
var lines = Lrc.Parse(lrc);
Check(lines is { Count: 5 }, "a line with two stamps counts twice, metadata none");
Near(lines![1].Time, 2.5, "fractions of a second");
Check(lines[4].Text == "two", "sorted by time");
Check(Lrc.Parse("[00:01.00] one\n[00:02.00]\n[00:03.00]\n") is null, "a placeholder isn't lyrics");
Check(Lrc.Parse("🎵 [00:01.00] a\n[00:02.00] b\n[00:03.00] c\n[00:04.00] d") is { Count: 4 }, "an emoji before the stamp doesn't break it");
Check(Lrc.Index(lines, 0.5) is null, "nothing before the first line");
Check(Lrc.Index(lines, 1.0) == 0, "a line begins exactly on its stamp");
Check(Lrc.Index(lines, 3.5) == 2, "the last line that has passed");
Check(Lrc.Index(lines, 99) == 4, "stays on the last line");
var roundTrip = Lrc.Parse(Lrc.Serialize(lines));
Check(roundTrip is { Count: 5 } && Math.Abs(roundTrip[1].Time - 2.5) < 0.01, "the cache format reads back");

// Motion
var inRange = true;
for (var i = 0; i < 500; i++)
{
    var level = Motion.Level(i % 30, i * 0.13);
    if (level is < 0 or > 1) inRange = false;
}
Check(inRange, "motion stays within 0...1");
var wave = Motion.WaveLevels(true, 12.5);
Check(wave.Length == 24 && wave[0] < wave[12] * 0.7 && wave[^1] < wave[12] * 0.7, "the wave tapers at both ends");
Check(Motion.WaveLevels(false, 3).All(v => v <= 0.06), "at rest the wave is a calm line");

// Timer and Pomodoro
var plan = PomodoroPlan.Standard;
Check(plan.Next(PomodoroPhase.Work, 1) == (PomodoroPhase.Rest, 5, 1), "work is followed by a break");
Check(plan.Next(PomodoroPhase.Work, 4) == (PomodoroPhase.Rest, 15, 4), "every fourth break is long");
Check(plan.Next(PomodoroPhase.Rest, 4) == (PomodoroPhase.Work, 25, 5), "a break is followed by the next round");
Check(new PomodoroPlan(0, 999, -1, 50).Clamped == new PomodoroPlan(1, 240, 1, 12), "lengths are kept sensible");
Check(TimeText.ClampMinutes(0) == 1 && TimeText.ClampMinutes(999) == 240, "minutes clamp");
Check(TimeText.Countdown(1499.2) == "25:00", "countdown rounds up");
Check(TimeText.Countdown(3900) == "65 min", "from an hour up, in minutes");
Check(TimeText.Clock(93.4) == "1:33" && TimeText.Clock(double.NaN) == "0:00", "clock text");
Near(TimeText.ProgressInterval(240), 0.4, "a four-minute song moves a pixel every 0.4 s");
Near(TimeText.ProgressInterval(1), 1.0 / 30, "never faster than 30 fps");
Near(TimeText.ProgressInterval(0), 0.5, "no duration, slow tick");

// Versions and releases
Check(Versions.IsNewer("1.0.10", "1.0.9"), "numbers, not text");
Check(!Versions.IsNewer("1.0.0", "1.0"), "missing parts count as 0");
Check(!Versions.IsNewer("1.0.0", "1.0.1"), "older isn't newer");
Check(Versions.FromTag("win-v1.2.0") == "1.2.0" && Versions.FromTag("v1.2.0") == "1.2.0", "tags");
const string release = """{"tag_name":"win-v1.2.0","html_url":"https://x/y","draft":false,"prerelease":false,"assets":[{"name":"Resonata-Setup-1.2.0.exe","browser_download_url":"https://x/s.exe"}]}""";
const string macRelease = """{"tag_name":"v1.0.9","html_url":"h","assets":[{"name":"Resonata-AppleSilicon.zip","browser_download_url":"u"}]}""";
Check(Updater.NewestSetup($"[{release}]") is { Version: "1.2.0", Setup: "https://x/s.exe" }, "a release with a Setup");
Check(Updater.NewestSetup($"[{macRelease}]") is null, "a Mac release is nothing to install here");
Check(Updater.NewestSetup($"[{macRelease},{release}]") is { Version: "1.2.0" }, "a newer Mac release doesn't hide the Windows one");
Check(Updater.NewestSetup($"[{release.Replace("1.2.0", "1.1.0")},{release}]") is { Version: "1.2.0" }, "the newest Setup wins, whatever the order");
Check(Updater.NewestSetup($"[{release.Replace("\"prerelease\":false", "\"prerelease\":true")}]") is null, "prereleases are skipped");
Check(Updater.NewestSetup("[]") is null, "no releases at all");
Check(Updater.NewestSetup("not json") is null, "garbage is nothing");
// The ARM64 Setup listed first, as GitHub may list it.
const string both = """{"tag_name":"win-v1.2.0","html_url":"h","draft":false,"prerelease":false,"assets":[{"name":"Resonata-ARM64-Setup-1.2.0.exe","browser_download_url":"https://x/arm.exe"},{"name":"Resonata-Setup-1.2.0.exe","browser_download_url":"https://x/x64.exe"}]}""";
Check(Updater.NewestSetup($"[{both}]", arm64: false) is { Setup: "https://x/x64.exe" }, "an x64 PC takes the x64 Setup");
Check(Updater.NewestSetup($"[{both}]", arm64: true) is { Setup: "https://x/arm.exe" }, "an ARM64 PC takes the ARM64 Setup");
Check(Updater.NewestSetup($"[{release}]", arm64: true) is { Setup: "https://x/s.exe" }, "with no ARM64 Setup, an ARM64 PC still gets the x64 one");
Check(Updater.NewestSetup($"[{both.Replace("Resonata-Setup-1.2.0.exe", "notes.txt")}]", arm64: false) is null, "an x64 PC never takes the ARM64 Setup");
// CI says which Windows it is, and runs this on ARM64 natively and emulated as
// x64 too. Run natively, the process's own processor is Windows'.
var expectArm64 = Environment.GetEnvironmentVariable("RESONATA_EXPECT_ARM64");
Check(Updater.OnArm64 == (expectArm64 is { Length: > 0 }
    ? expectArm64 == "1"
    : System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture == System.Runtime.InteropServices.Architecture.Arm64),
    $"Windows on ARM64 is recognised, from a {System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture} process");
Check(Updater.IsNewerSetup("Resonata".PadRight(60), "1.2.0".PadRight(50), "1.0.0"), "a Setup's padded version fields are read");
Check(!Updater.IsNewerSetup("Resonata".PadRight(60), "1.0.0".PadRight(50), "1.0.0"), "the same version isn't an update");
Check(!Updater.IsNewerSetup("Something else", "9.9.9", "1.0.0"), "another program's Setup is refused");
Check(!Updater.IsNewerSetup(null, null, "1.0.0"), "a file with no version fields is refused");

// The album colour
byte[] Image(byte r, byte g, byte b)
{
    var pixels = new byte[AccentPicker.Grid * AccentPicker.Grid * 4];
    for (var i = 0; i < pixels.Length; i += 4) { pixels[i] = r; pixels[i + 1] = g; pixels[i + 2] = b; pixels[i + 3] = 255; }
    return pixels;
}
Check(AccentPicker.Pick(Image(128, 128, 128)) is null, "a grey cover has no colour");
Check(AccentPicker.Pick(Image(5, 5, 5)) is null, "a black cover has no colour");
Check(AccentPicker.Pick(Image(200, 40, 60)) is { R: > 0.7, G: < 0.3 }, "a red cover is red");
Check(AccentPicker.Pick(Image(60, 10, 10)) is { R: > 0.54 }, "too dark is lifted");

// The spring
var spring = new Spring(0) { Target = 100 };
var peak = 0.0;
for (var i = 0; i < 300 && !spring.Settled; i++) { spring.Step(1.0 / 60, 0.38, 0.8); peak = Math.Max(peak, spring.Value); }
Check(spring.Settled, "the spring settles");
Near(spring.Value, 100, "on its target", 0.1);
Check(peak is > 100 and < 110, "with a hint of overshoot");
var bouncy = new Spring(0) { Target = 100 };
var bouncyPeak = 0.0;
var settleSteps = 0;
for (; settleSteps < 300 && !bouncy.Settled; settleSteps++) { bouncy.Step(1.0 / 60, 0.44, 0.66); bouncyPeak = Math.Max(bouncyPeak, bouncy.Value); }
Check(bouncyPeak is > 104 and < 110, $"the panel's spring has a visible bounce (peak {bouncyPeak:0.0})");
Check(settleSteps < 90, $"and comes to rest within a second and a half ({settleSteps} frames)");
var stutter = new Spring(0) { Target = 100 };
stutter.Step(1.0, 0.38, 0.8);
Check(Math.Abs(stutter.Value) < 1000, "a long frame doesn't blow it up");

// The shape against the right edge, and the cover flying across it
System.Windows.Rect Box(double edge, double far = 12) => EdgeGeometry.Build(400, 100, 300, 42, edge, far).Bounds;
Check(Box(0) == new System.Windows.Rect(400, 100, 300, 42), $"the pill fills its box ({Box(0)})");
Check(Box(-8) == Box(0) && Box(24) == Box(0), "flared or round, the shape stays in its box");
Check(Box(-500, 500).Width > 0 && Box(500, 500).Width > 0, "corners too big for it are made to fit");
bool Covers(double edge, double x, double y) => EdgeGeometry.Build(400, 100, 300, 42, edge, 12).FillContains(new System.Windows.Point(x, y));
Check(Covers(0, 699.5, 100.5), "square at the edge: its corner is filled");
Check(!Covers(24, 699.5, 100.5), "round off the edge: its corner is not");
Check(Covers(0, 695, 104) && !Covers(-8, 695, 104) && Covers(-8, 699.8, 104), "flared: it runs into the edge in a thinning point");
Check(!Covers(0, 400.5, 100.5) && Covers(0, 412, 121), "the far corners are round");
var pillCover = new System.Windows.Rect(429, 129, 32, 32);
var panelCover = new System.Windows.Rect(258, 94, 110, 110);
Check(CoverFlight.Frame(pillCover, panelCover, 0) == pillCover, "the flying cover starts on the pill's");
Check(CoverFlight.Frame(pillCover, panelCover, 1) == panelCover, "and lands on the panel's");
var half = CoverFlight.Frame(pillCover, panelCover, 0.5);
Check(half == new System.Windows.Rect(343.5, 111.5, 71, 71), $"a straight line in between ({half})");
Check(CoverFlight.Frame(pillCover, panelCover, 1.05).Width > 110, "it overshoots with the panel's bounce");
Check(CoverFlight.Frame(pillCover, panelCover, -1).Width == 0, "and never turns inside out");

// Rules
Check(PowerRules.CrossesWarning(21, 20), "down past 20");
Check(!PowerRules.CrossesWarning(20, 20) && !PowerRules.CrossesWarning(19, 20), "sitting there or rising isn't news");
Check(PowerRules.CrossesWarning(11, 9), "down past 10");
Check(!PowerRules.CrossesWarning(null, 15), "on launch there's no change");
Check(PowerRules.IsPlugIn(false, true) && !PowerRules.IsPlugIn(null, true) && !PowerRules.IsPlugIn(true, true), "plugged in means a change");
var other = playing with { Title = "Other" };
Check(SongPeekRules.ShouldPeek(playing, other, false, true), "a new song peeks");
Check(!SongPeekRules.ShouldPeek(null, other, false, true), "not the first song seen");
Check(!SongPeekRules.ShouldPeek(playing, playing with { SampledPosition = 3 }, false, true), "not the same song");
Check(!SongPeekRules.ShouldPeek(playing, other, true, true), "not over the open panel");
Check(!SongPeekRules.ShouldPeek(playing, other with { IsPlaying = false }, false, true), "not when paused");
Check(!SongPeekRules.ShouldPeek(playing, other, false, false), "not when switched off");
Check(SpotifyVolume.ToggledMute(40, null) == 0, "mute from any level");
Check(SpotifyVolume.ToggledMute(0, 40) == 40, "back to the level before");
Check(SpotifyVolume.ToggledMute(0, null) == 50, "halfway when there was none");
Check(SpotifyVolume.Snap(37, tenths: true) == 40 && SpotifyVolume.Snap(34, tenths: true) == 30, "Spotify's own slider goes in tenths");
Check(SpotifyVolume.Snap(35, tenths: true) == 40 && SpotifyVolume.Snap(5, tenths: true) == 10, "halfway between two goes up");
Check(SpotifyVolume.Snap(0, tenths: true) == 0 && SpotifyVolume.Snap(100, tenths: true) == 100, "both ends stay");
Check(SpotifyVolume.Snap(37.4, tenths: false) == 37, "the mixer takes any whole level");
Check(SpotifyVolume.Snap(130, tenths: false) == 100 && SpotifyVolume.Snap(-5, tenths: true) == 0, "never outside 0–100");
// What Spotify's window had: the side panels' widths, the place in a song, the volume.
Check(SpotifyVolume.PickVolume([(72, 420), (0, 219857), (0, 1), (280, 420)]) == 2, "the volume is the slider from 0 to 1");
Check(SpotifyVolume.PickVolume([(72, 420), (0, 219857)]) is null, "no volume slider, none picked");
Check(SpotifyVolume.PickVolume([]) is null, "no sliders at all");

// Settings files from older versions
Check(System.Text.Json.JsonSerializer.Deserialize<Settings>("""{"OpenMode":"Nook"}""")!.OpenMode == OpenMode.Hover, "the removed mode reads as Hover");
Check(System.Text.Json.JsonSerializer.Deserialize<Settings>("""{"OpenMode":"Click"}""")!.OpenMode == OpenMode.Click, "Click stays Click");

Check(System.Text.Json.JsonSerializer.Deserialize<Settings>("""{"HotKey":"CtrlAltN"}""")!.HotKey == HotKeyChoice.AltShiftN, "the old AltGr shortcut reads as the one that replaced it");
Check(System.Text.Json.JsonSerializer.Deserialize<Settings>("""{"HotKey":"CtrlShiftSpace"}""")!.HotKey == HotKeyChoice.CtrlShiftSpace, "the default shortcut stays");
Check(System.Text.Json.JsonSerializer.Deserialize<Settings>("""{"HotKey":"Nonsense","ShowLyrics":false}""") is { HotKey: HotKeyChoice.Off, ShowLyrics: false }, "an unknown shortcut doesn't cost the file");

// What lyrics are looked up for, and which search result is used
var song = playing with { Duration = 214, Artist = "B" };
Check(LyricsRules.ShouldLookUp(song), "a song is looked up");
Check(!LyricsRules.ShouldLookUp(song with { Duration = 0 }), "no length - a live stream, or not known yet - isn't");
Check(!LyricsRules.ShouldLookUp(song with { Duration = 3600 }), "an hour-long episode isn't");
Check(!LyricsRules.ShouldLookUp(song with { Artist = "  " }), "nothing without an artist");
Check(LyricsRules.Closest([263, 214.4, 198], 214) == 1, "the result nearest in length, not the first");
Check(LyricsRules.Closest([263, 301], 214) is null, "none within ten seconds, none used");
Check(LyricsRules.Closest([null, 215], 214) == 1, "a result with a length beats one without");
Check(LyricsRules.Closest([null, null], 214) == 0, "no lengths to go by, the first as before");
Check(LyricsRules.Closest([], 214) is null, "no results, none used");
Check(LyricsRules.Window(40, 10, 5) == (8, 5), "the sung line in the middle");
Check(LyricsRules.Window(40, null, 5) == (0, 5) && LyricsRules.Window(40, 39, 5) == (35, 5), "the first and the last five at the ends");
Check(LyricsRules.Window(4, 2, 5) == (0, 4), "a short song shows whole");

// Live streams, plurals, and an update found before a restart
Check(LiveRules.IsLive(0, true) && !LiveRules.IsLive(0, false) && !LiveRules.IsLive(214, true), "live is no length after a moment");
Check(L.More(4, czech: true) == "+ 4 další" && L.More(5, czech: true) == "+ 5 dalších", "Czech counts differently from five up");
Check(L.More(5, czech: false) == "+ 5 more", "English has the one form");
var day = TimeSpan.FromHours(24);
Check(!UpdateRules.ShouldCheck(true, t0, t0.AddHours(1), null, "1.0.0", day), "checked an hour ago, nothing found, not again");
Check(UpdateRules.ShouldCheck(true, t0, t0.AddHours(1), "1.0.1", "1.0.0", day), "one found before the restart is looked up again at launch");
Check(!UpdateRules.ShouldCheck(false, t0, t0.AddHours(1), "1.0.1", "1.0.0", day), "but only at launch, not every hour");
Check(!UpdateRules.ShouldCheck(true, t0, t0.AddHours(1), "1.0.0", "1.0.0", day), "once it's installed there's nothing to look up");
Check(UpdateRules.ShouldCheck(false, t0, t0.AddHours(25), null, "1.0.0", day), "and once a day regardless");

// Page swipes
var swipe = new PageSwipeTracker();
Check(swipe.Add(40, t0) == 0, "not far enough yet");
Check(swipe.Add(50, t0.AddMilliseconds(10)) == 1, "far enough turns one page");
Check(swipe.Add(500, t0.AddMilliseconds(20)) == 0, "one page per gesture");
Check(swipe.Add(-120, t0.AddMilliseconds(600)) == -1, "a pause starts a new gesture");

// Calendar
var noon = new DateTime(2026, 3, 10, 12, 0, 0);
var days = CalendarRules.Days(noon);
Check(days.Length == 5 && days[0] == new DateTime(2026, 3, 8) && days[4] == new DateTime(2026, 3, 12), "two days either side");
var late = new CalendarEvent("x", "Party", new DateTime(2026, 3, 10, 23, 0, 0), new DateTime(2026, 3, 11, 1, 0, 0), false);
Check(CalendarRules.On([late], new DateTime(2026, 3, 11)).Any(), "past midnight it shows on both days");
Check(!CalendarRules.On([late], new DateTime(2026, 3, 12)).Any(), "but not the day after");
var soon = new CalendarEvent("y", "Call", noon.AddMinutes(4), noon.AddMinutes(30), false);
var allDay = new CalendarEvent("z", "Holiday", noon.AddMinutes(3), noon.AddHours(5), true);
Check(CalendarRules.Due([soon, allDay, late], noon, TimeSpan.FromMinutes(5)).Single() == soon, "timed events about to start");
Check(CalendarRules.MeetingDetail(noon.AddMinutes(5), noon) == "in 5 min · 12:05", "meeting text");
Check(CalendarRules.MeetingDetail(noon, noon) == "now · 12:00", "meeting started");

const string ics = """
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//test//EN
BEGIN:VEVENT
UID:weekly
DTSTAMP:20260101T000000Z
DTSTART:20260105T100000Z
DTEND:20260105T110000Z
RRULE:FREQ=WEEKLY;BYDAY=MO
SUMMARY:Weekly
END:VEVENT
BEGIN:VEVENT
UID:day
DTSTAMP:20260101T000000Z
DTSTART;VALUE=DATE:20260310
DTEND;VALUE=DATE:20260311
SUMMARY:Whole day
END:VEVENT
BEGIN:VEVENT
UID:far
DTSTAMP:20260101T000000Z
DTSTART:20270101T100000Z
DTEND:20270101T110000Z
SUMMARY:Next year
END:VEVENT
END:VCALENDAR
""";
var parsed = CalendarStore.Parse(ics.Replace("\r\n", "\n").Replace("\n", "\r\n"), new DateTime(2026, 3, 8), new DateTime(2026, 3, 13)).ToList();
Check(parsed.Count(e => e.Title == "Weekly") == 1, $"a recurring event falls in the window once (got {parsed.Count(e => e.Title == "Weekly")})");
Check(parsed.Any(e => e.Title == "Whole day" && e.IsAllDay && e.Start.Date == new DateTime(2026, 3, 10)), "an all-day event keeps its date");
Check(parsed.All(e => e.Title != "Next year"), "outside the window isn't included");

Console.WriteLine($"{passed} passed, {failed} failed");
return failed == 0 ? 0 : 1;
