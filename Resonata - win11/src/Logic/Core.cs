using System.Globalization;
using System.Text.RegularExpressions;

namespace Resonata;

public sealed record Track
{
    public required string Title { get; init; }
    public string Artist { get; init; } = "";
    public string Album { get; init; } = "";
    public double Duration { get; init; }

    /// Where the playhead was as of SampledAt — not where it is now; read Position(at).
    public double SampledPosition { get; init; }
    public DateTime SampledAt { get; init; }
    public bool IsPlaying { get; init; }

    /// The player's app id, e.g. "Spotify.exe" or "SpotifyAB.SpotifyMusic_...!Spotify".
    public string Source { get; init; } = "";

    public bool IsSpotify => Source.Contains("spotify", StringComparison.OrdinalIgnoreCase);

    public double Position(DateTime at)
    {
        if (!IsPlaying) return SampledPosition;
        var live = SampledPosition + (at - SampledAt).TotalSeconds;
        // A track can finish between syncs, and 4:31 of 3:58 looks broken.
        return Math.Min(Math.Max(live, 0), Duration > 0 ? Duration : live);
    }

    /// Same song, ignoring everything that moves.
    public bool IsSameTrack(Track other) =>
        Title == other.Title && Artist == other.Artist && Album == other.Album && Source == other.Source;
}

public readonly record struct LyricLine(double Time, string Text);

/// What to ask LRCLIB about, and which of its answers to use.
public static class LyricsRules
{
    /// Song lengths: half a minute to a quarter of an hour.
    public const double ShortestSong = 30, LongestSong = 15 * 60;

    /// How far a search result's length may be from the song's and still be
    /// taken for the same recording.
    public const double LengthTolerance = 10;

    /// Only something with an artist that runs as long as a song. A video's,
    /// a podcast's or a film's title went to LRCLIB too, and none of those have
    /// synced lyrics. It also waits out the moment at a song change when the
    /// title has arrived and the length hasn't, which cost a second lookup.
    public static bool ShouldLookUp(Track track) =>
        !string.IsNullOrWhiteSpace(track.Artist) && track.Duration is >= ShortestSong and <= LongestSong;

    /// Which search result to use for a song `duration` seconds long, given each
    /// result's own length; null for none of them. The search goes by title and
    /// artist alone, so it also returns the live version and the remix, and the
    /// first one's lyrics drifted out of time. The nearest in length is the same
    /// recording; one more than LengthTolerance out isn't, and none beats wrong.
    public static int? Closest(IReadOnlyList<double?> durations, double duration)
    {
        if (durations.Count == 0) return null;
        if (duration <= 0) return 0;
        int? best = null;
        var bestGap = double.PositiveInfinity;
        for (var i = 0; i < durations.Count; i++)
        {
            if (durations[i] is not { } length || length <= 0) continue;
            var gap = Math.Abs(length - duration);
            if (gap < bestGap) (best, bestGap) = (i, gap);
        }
        if (best is null) return 0;
        return bestGap <= LengthTolerance ? best : null;
    }
}

public static partial class Lrc
{
    [GeneratedRegex(@"\[(\d+):(\d{1,2}(?:\.\d+)?)\]")]
    private static partial Regex Stamp();

    /// `[mm:ss.xx] text`, one or more timestamps per line. Lines without one
    /// (metadata like `[ar:Artist]`) are dropped. Null when it isn't really lyrics.
    public static IReadOnlyList<LyricLine>? Parse(string lrc)
    {
        var result = new List<LyricLine>();
        foreach (var line in lrc.Split('\n', '\r'))
        {
            var matches = Stamp().Matches(line);
            if (matches.Count == 0) continue;
            var last = matches[^1];
            var text = line[(last.Index + last.Length)..].Trim();
            foreach (Match m in matches)
            {
                var minutes = double.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture);
                var seconds = double.Parse(m.Groups[2].Value, CultureInfo.InvariantCulture);
                result.Add(new LyricLine(minutes * 60 + seconds, text));
            }
        }
        var sorted = result.OrderBy(l => l.Time).ToList();
        // A handful of timestamps with no words between them is a placeholder.
        return sorted.Count(l => l.Text.Length > 0) >= 4 ? sorted : null;
    }

    /// The last line whose timestamp has passed; null before the first.
    public static int? Index(IReadOnlyList<LyricLine> lines, double time)
    {
        int lo = 0, hi = lines.Count;
        while (lo < hi)
        {
            var mid = (lo + hi) / 2;
            if (lines[mid].Time <= time) lo = mid + 1; else hi = mid;
        }
        return lo == 0 ? null : lo - 1;
    }

    public static string Serialize(IEnumerable<LyricLine> lines) =>
        string.Join("\n", lines.Select(l =>
        {
            var m = (int)l.Time / 60;
            return string.Format(CultureInfo.InvariantCulture, "[{0:00}:{1:00.00}] {2}", m, l.Time - m * 60, l.Text);
        }));
}

/// The made-up motion behind the bars and the wave. Resonata doesn't listen to
/// the sound: three slow sines at unrelated speeds, so it never visibly repeats.
public static class Motion
{
    public static double Level(int index, double time)
    {
        double i = index;
        var slow = 0.24 * Math.Sin(time * 1.3 + i * 0.71);
        var middle = 0.15 * Math.Sin(time * 2.9 + i * 1.87 + 1.0);
        var quick = 0.09 * Math.Sin(time * 5.3 + i * 3.13 + 2.0);
        return Math.Clamp(0.5 + slow + middle + quick, 0, 1);
    }

    /// Further apart in phase than the wave's points, so three bars don't move as one.
    public static double BarLevel(int bar, double time) => 0.2 + 0.8 * Level(bar * 3, time);

    /// Tapered to nothing at both ends, so the wave rises out of the baseline.
    public static double[] WaveLevels(bool animating, double time, int count = 24)
    {
        var levels = new double[count];
        for (var i = 0; i < count; i++)
        {
            var level = animating ? 0.15 + 0.75 * Level(i, time) : 0.06;
            var edge = Math.Sin(Math.PI * (i + 0.5) / count);
            levels[i] = Math.Clamp(level, 0, 1) * Math.Pow(edge, 0.6);
        }
        return levels;
    }
}

public enum PomodoroPhase { Work, Rest }

public readonly record struct PomodoroPlan(int Work, int Rest, int LongRest, int Rounds)
{
    public static readonly PomodoroPlan Standard = new(25, 5, 15, 4);

    public PomodoroPlan Clamped => new(Math.Clamp(Work, 1, 240), Math.Clamp(Rest, 1, 240),
        Math.Clamp(LongRest, 1, 240), Math.Clamp(Rounds, 1, 12));

    public (PomodoroPhase Phase, int Minutes, int Round) Next(PomodoroPhase phase, int round) => phase switch
    {
        PomodoroPhase.Work => (PomodoroPhase.Rest, round % Rounds == 0 ? LongRest : Rest, round),
        _ => (PomodoroPhase.Work, Work, round + 1),
    };
}

public static class TimeText
{
    public static int ClampMinutes(int minutes) => Math.Clamp(minutes, 1, 240);

    /// "24:59", or "65 min" from an hour up — narrow enough for the pill.
    public static string Countdown(double seconds)
    {
        var s = (int)Math.Ceiling(seconds);
        return s >= 3600 ? $"{s / 60} min" : $"{s / 60}:{s % 60:00}";
    }

    public static string Clock(double seconds)
    {
        if (double.IsNaN(seconds) || double.IsInfinity(seconds) || seconds <= 0) return "0:00";
        var total = (int)Math.Round(seconds);
        return $"{total / 60}:{total % 60:00}";
    }

    /// Seconds per device pixel of progress bar, within 1/30 s and 1/2 s.
    public static double ProgressInterval(double duration) =>
        duration <= 0 ? 0.5 : Math.Min(Math.Max(duration / 600, 1.0 / 30), 0.5);
}

public static class Versions
{
    /// "1.0.10" is newer than "1.0.9"; missing parts count as 0.
    public static bool IsNewer(string candidate, string current)
    {
        static int[] Parts(string s) => s.Split('.').Select(p => int.TryParse(p, out var n) ? n : 0).ToArray();
        var a = Parts(candidate);
        var b = Parts(current);
        for (var i = 0; i < Math.Max(a.Length, b.Length); i++)
        {
            var x = i < a.Length ? a[i] : 0;
            var y = i < b.Length ? b[i] : 0;
            if (x != y) return x > y;
        }
        return false;
    }

    /// "win-v1.2.0" and "v1.2.0" both mean 1.2.0: the repository's tags also hold the Mac's.
    public static string FromTag(string tag)
    {
        var t = tag.StartsWith("win-", StringComparison.OrdinalIgnoreCase) ? tag[4..] : tag;
        return t.StartsWith('v') ? t[1..] : t;
    }
}

/// Picks the colour the artwork is about, rather than averaging it: pixels vote
/// for a hue-and-lightness bin weighted by how colourful they are, and the
/// winner is the average of the real pixels in it. Null for a colourless cover.
public static class AccentPicker
{
    private struct Bin { public double Weight, R, G, B; }

    public const int Grid = 32;

    /// RGBA bytes of a Grid×Grid image.
    public static (double R, double G, double B)? Pick(byte[] pixels)
    {
        const int hueBins = 24, levelBins = 3;
        var bins = new Bin[hueBins * levelBins];
        for (var i = 0; i + 3 < pixels.Length; i += 4)
        {
            double r = pixels[i] / 255.0, g = pixels[i + 1] / 255.0, b = pixels[i + 2] / 255.0;
            double high = Math.Max(r, Math.Max(g, b)), low = Math.Min(r, Math.Min(g, b));
            var chroma = high - low;
            var saturation = high <= 0 ? 0 : chroma / high;
            if (!(saturation > 0.15 && high > 0.12 && high < 0.98)) continue;

            double hue;
            if (high == r) hue = (g - b) / chroma / 6;
            else if (high == g) hue = ((b - r) / chroma + 2) / 6;
            else hue = ((r - g) / chroma + 4) / 6;
            if (hue < 0) hue += 1;

            var level = Math.Min(levelBins - 1, (int)(high * levelBins));
            var index = Math.Min(hueBins - 1, (int)(hue * hueBins)) * levelBins + level;
            var weight = saturation * high;
            bins[index].Weight += weight;
            bins[index].R += r * weight;
            bins[index].G += g * weight;
            bins[index].B += b * weight;
        }

        var best = bins.MaxBy(b => b.Weight);
        if (best.Weight <= 1.5) return null;

        double rr = best.R / best.Weight, gg = best.G / best.Weight, bb = best.B / best.Weight;
        // Too dark to register on black: scaled along its own ratios, so the hue stays.
        var peak = Math.Max(rr, Math.Max(gg, bb));
        if (peak > 0 && peak < 0.55)
        {
            var lift = 0.55 / peak;
            rr = Math.Min(1, rr * lift);
            gg = Math.Min(1, gg * lift);
            bb = Math.Min(1, bb * lift);
        }
        return (rr, gg, bb);
    }
}

/// A damped spring, parameterised like SwiftUI's: response in seconds, damping
/// as a fraction of critical. WPF has none built in.
public struct Spring
{
    public double Value, Target, Velocity;

    public Spring(double value) { Value = Target = value; Velocity = 0; }

    public readonly bool Settled => Math.Abs(Value - Target) < 0.05 && Math.Abs(Velocity) < 0.5;

    public void Step(double dt, double response, double damping)
    {
        var omega = 2 * Math.PI / response;
        var stiffness = omega * omega;
        var friction = 2 * damping * omega;
        // Small fixed steps: a long frame must not make the spring blow up.
        var remaining = dt;
        while (remaining > 0)
        {
            var h = Math.Min(remaining, 1.0 / 240);
            Velocity += (-stiffness * (Value - Target) - friction * Velocity) * h;
            Value += Velocity * h;
            remaining -= h;
        }
    }

    public void Snap() { Value = Target; Velocity = 0; }
}

public static class PowerRules
{
    public static readonly int[] Warnings = [20, 10];

    /// Down past a warning level — 21 % to 20 %. Sitting at 20 % isn't news.
    public static bool CrossesWarning(int? old, int now) =>
        old is { } was && now < was && Warnings.Any(w => was > w && now <= w);

    /// Battery to charger and nothing else: on launch the state isn't a change.
    public static bool IsPlugIn(bool? was, bool now) => was == false && now;
}

public static class SongPeekRules
{
    /// A different song that is playing, with the panel closed: not on launch,
    /// not when the same song resumes.
    public static bool ShouldPeek(Track? old, Track? now, bool expanded, bool enabled) =>
        enabled && !expanded && old is not null && now is { IsPlaying: true } && !now.IsSameTrack(old);
}

public sealed record CalendarEvent(string Id, string Title, DateTime Start, DateTime End, bool IsAllDay);

public static class CalendarRules
{
    /// Two days either side of today, each at its midnight.
    public static DateTime[] Days(DateTime around)
    {
        var today = around.Date;
        return Enumerable.Range(-2, 5).Select(offset => today.AddDays(offset)).ToArray();
    }

    /// Events that touch `day` at all: one running past midnight shows on both.
    public static IEnumerable<CalendarEvent> On(IEnumerable<CalendarEvent> events, DateTime day)
    {
        var start = day.Date;
        var end = start.AddDays(1);
        return events.Where(e => e.Start < end && e.End > start);
    }

    /// Timed events starting within `lead` from now, soonest first.
    public static IEnumerable<CalendarEvent> Due(IEnumerable<CalendarEvent> events, DateTime now, TimeSpan lead) =>
        events.Where(e => !e.IsAllDay && e.Start > now && e.Start - now <= lead).OrderBy(e => e.Start);

    /// "in 5 min · 14:00", or "now · 14:00" once it has started.
    public static string MeetingDetail(DateTime start, DateTime now)
    {
        var minutes = (int)Math.Round((start - now).TotalMinutes);
        var time = start.ToString("H:mm", CultureInfo.InvariantCulture);
        return minutes > 0 ? L.T($"in {minutes} min · {time}", $"za {minutes} min · {time}") : L.T($"now · {time}", $"teď · {time}");
    }
}

/// One page per sideways gesture, however long it runs or however many events
/// a touchpad sends; a silence of `Gap` ends the gesture.
public sealed class PageSwipeTracker
{
    public const double Reach = 80;
    public static readonly TimeSpan Gap = TimeSpan.FromMilliseconds(260);

    private double _travel;
    private bool _turned;
    private DateTime _last = DateTime.MinValue;

    /// `delta` as WM_MOUSEHWHEEL reports it, positive meaning scrolling right.
    /// Returns +1 or -1 once when the gesture has gone far enough, else 0.
    public int Add(double delta, DateTime now)
    {
        if (now - _last > Gap) { _travel = 0; _turned = false; }
        _last = now;
        if (_turned) return 0;
        _travel += delta;
        if (Math.Abs(_travel) < Reach) return 0;
        _turned = true;
        return _travel > 0 ? 1 : -1;
    }
}
