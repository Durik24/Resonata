using System.Globalization;
using System.Text;
using System.Text.Json;

namespace Resonata;

// Claude Code and Mistral Vibe on the tab: how much of their limits is used,
// and whether a session is working or waiting for you. The Mac version's
// (Claude.swift, Vibe.swift), read the same way from the tools themselves:
// their session files, `claude /usage`, and Vibe's own Python for Mistral's
// billing. No token or account is touched, and both are off until switched
// on in Settings. This file is what can be tested without either installed.

public enum AiState { Idle, Working, Waiting }

/// One running session, as the limits page lists it.
public sealed record AiSession(int Pid, string Name, AiState State, string? App = null, string? Key = null)
{
    public string Id => Key ?? Pid.ToString(CultureInfo.InvariantCulture);
}

/// One model's own week: "Fable".
public sealed record ModelWeek(string Name, int Percent, DateTime? Resets);

/// The limits `claude /usage` prints.
public sealed record ClaudeUsage(int SessionPercent, DateTime? SessionResets, int? WeekPercent, DateTime? WeekResets)
{
    public IReadOnlyList<ModelWeek> Models { get; init; } = [];

    public bool Equals(ClaudeUsage? other) => other is not null && SessionPercent == other.SessionPercent
        && SessionResets == other.SessionResets && WeekPercent == other.WeekPercent && WeekResets == other.WeekResets
        && Models.SequenceEqual(other.Models);

    public override int GetHashCode() => HashCode.Combine(SessionPercent, SessionResets, WeekPercent, WeekResets, Models.Count);

    /// Reads the text of `/usage`:
    ///
    ///     Current session: 6% used · resets Nov 12 at 6:39pm (Europe/Prague)
    ///     Current week (all models): 1% used · resets Nov 13 at 6:59pm (Europe/Prague)
    ///
    /// Null when there is no session line: a signed-out CLI, an API-key
    /// account with no limits, or wording this doesn't know.
    public static ClaudeUsage? Parse(string text, DateTime? now = null)
    {
        var at = now ?? DateTime.Now;
        (int Percent, DateTime? Resets)? session = null, week = null;
        var models = new List<ModelWeek>();
        foreach (var raw in text.Split('\n', '\r'))
        {
            var line = raw.Trim();
            if (line.StartsWith("Current session", StringComparison.Ordinal))
            {
                session = Window(line, at) ?? session;
            }
            else if (line.StartsWith("Current week", StringComparison.Ordinal) && Window(line, at) is { } read)
            {
                // "Current week (Fable): …" is one model's; the name is in
                // the brackets. Any other week line is everything together.
                int open = line.IndexOf('('), close = line.IndexOf(')');
                if (!line.Contains("all models") && open >= 0 && close > open)
                    models.Add(new ModelWeek(line[(open + 1)..close], read.Percent, read.Resets));
                else
                    week = read;
            }
        }
        if (session is not { } s) return null;
        // Only a model's own week said: that is the week, then.
        if (week is null && models.Count > 0)
        {
            week = (models[0].Percent, models[0].Resets);
            models.RemoveAt(0);
        }
        return new ClaudeUsage(s.Percent, s.Resets, week?.Percent, week?.Resets) { Models = models };
    }

    /// "…: 6% used · resets Nov 12 at 6:39pm (Europe/Prague)" → 6 and the date.
    private static (int Percent, DateTime? Resets)? Window(string line, DateTime now)
    {
        var sign = line.IndexOf('%');
        if (sign < 0 || !line[(sign + 1)..].TrimStart().StartsWith("used", StringComparison.Ordinal)) return null;
        var start = sign;
        while (start > 0 && char.IsAsciiDigit(line[start - 1])) start--;
        if (start == sign || !int.TryParse(line[start..sign], NumberStyles.None, CultureInfo.InvariantCulture, out var percent)) return null;
        var resets = line.IndexOf("resets ", StringComparison.Ordinal);
        return (percent, resets < 0 ? null : ResetDate(line[(resets + 7)..], now));
    }

    private static readonly (string Format, bool HasDate)[] Formats =
    [
        ("MMM d h:mmtt", true), ("MMM d htt", true), ("MMM d H:mm", true),
        ("h:mmtt", false), ("htt", false), ("H:mm", false),
    ];

    /// "Nov 12 at 6:39pm (Europe/Prague)", "Nov 13, 12:10pm" as newer versions
    /// write it, or just "6:39pm" for later today.
    /// The year is never said: it is the next such moment from `now`. The
    /// answer is in this PC's own time.
    public static DateTime? ResetDate(string text, DateTime now)
    {
        text = text.Trim();
        var zone = TimeZoneInfo.Local;
        if (text.EndsWith(')') && text.LastIndexOf('(') is var open and >= 0)
        {
            try { zone = TimeZoneInfo.FindSystemTimeZoneById(text[(open + 1)..^1]); }
            catch (Exception e) when (e is TimeZoneNotFoundException or InvalidTimeZoneException) { }
            text = text[..open].Trim();
        }
        // "6:39 pm" and "6:39pm" alike.
        if (text.EndsWith("am", StringComparison.OrdinalIgnoreCase) || text.EndsWith("pm", StringComparison.OrdinalIgnoreCase))
            text = text[..^2].TrimEnd() + text[^2..].ToUpperInvariant();
        // The date and the time are joined by " at " or by a comma.
        text = string.Join(' ', text.Replace(",", " ").Split(' ', StringSplitOptions.RemoveEmptyEntries).Where(word => word != "at"));
        var there = TimeZoneInfo.ConvertTime(now, zone);
        foreach (var (format, hasDate) in Formats)
        {
            if (!DateTime.TryParseExact(text, format, CultureInfo.InvariantCulture, DateTimeStyles.AllowWhiteSpaces, out var read)) continue;
            // The parts the text leaves out, the year or the whole date, are now's.
            var date = hasDate
                ? new DateTime(there.Year, read.Month, read.Day, read.Hour, read.Minute, 0)
                : new DateTime(there.Year, there.Month, there.Day, read.Hour, read.Minute, 0);
            // Already past: it means the next one, tomorrow for a bare time,
            // next year for a date read in the last days of December. A
            // minute's grace, for a reset that is happening as it's read.
            if (hasDate ? date < there.AddHours(-12) : date < there.AddMinutes(-1))
                date = hasDate ? date.AddYears(1) : date.AddDays(1);
            return TimeZoneInfo.ConvertTime(DateTime.SpecifyKind(date, DateTimeKind.Unspecified), zone, TimeZoneInfo.Local);
        }
        return null;
    }
}

/// What the tab shows of Claude Code.
public sealed record ClaudeStatus(AiState State = AiState.Idle, string? Session = null, string? Wants = null, ClaudeUsage? Usage = null)
{
    public IReadOnlyList<AiSession> Sessions { get; init; } = [];

    public bool Equals(ClaudeStatus? other) => other is not null && State == other.State && Session == other.Session
        && Wants == other.Wants && Equals(Usage, other.Usage) && Sessions.SequenceEqual(other.Sessions);

    public override int GetHashCode() => HashCode.Combine(State, Session, Wants, Usage, Sessions.Count);

    /// A session is working or waiting.
    public bool IsActive => State != AiState.Idle;

    /// There is something to show: a session at work, or limits to read.
    public bool HasSomething => IsActive || Usage is not null;

    /// How full the session's ring is, 0...1; null until the limits are known.
    public double? Fraction => Usage is { } u ? Math.Clamp(u.SessionPercent / 100.0, 0, 1) : null;

    public double? WeekFraction => Usage?.WeekPercent is { } w ? Math.Clamp(w / 100.0, 0, 1) : null;
}

public static class AiText
{
    public static string State(AiState state) => state switch
    {
        AiState.Working => L.T("working", "pracuje"),
        AiState.Waiting => L.T("waiting for you", "čeká na tebe"),
        _ => L.T("idle", "volno"),
    };

    /// "resets in 2 h 18 min" ("reset za 2 h 18 min"); under a minute, "now".
    public static string Countdown(DateTime to, DateTime now)
    {
        var minutes = (int)Math.Ceiling((to - now).TotalMinutes);
        if (minutes <= 0) return L.T("resets now", "reset teď");
        int h = minutes / 60, m = minutes % 60;
        var length = h >= 48 ? $"{h / 24} d" : h > 0 ? (m > 0 ? $"{h} h {m} min" : $"{h} h") : $"{m} min";
        return L.T($"resets in {length}", $"reset za {length}");
    }

    /// "resets Fri 18:59" ("reset pá 18:59").
    public static string Day(DateTime date)
    {
        var culture = CultureInfo.GetCultureInfo(Settings.Current.Language == AppLanguage.Czech ? "cs-CZ" : "en-GB");
        var when = date.ToString("ddd H:mm", culture);
        return L.T($"resets {when}", $"reset {when}");
    }

    /// "resets 1 Dec" ("reset 1. 12.").
    public static string Date(DateTime date) =>
        L.T($"resets {date.ToString("d MMM", CultureInfo.GetCultureInfo("en-GB"))}", $"reset {date.Day}. {date.Month}.");

    /// The tab's one line while nothing plays: "Claude 6 % · week 1 %   Vibe 3 %".
    public static string TabLine(ClaudeStatus? claude, VibeStatus? vibe)
    {
        var parts = new List<string>();
        if (claude is { HasSomething: true })
        {
            var text = "Claude" + Short(claude.State);
            if (claude.Usage is { } u) text += $" · {u.SessionPercent} %";
            parts.Add(text);
        }
        if (vibe is { HasSomething: true })
        {
            var text = "Vibe" + Short(vibe.State);
            if (vibe.Usage is { } u) text += $" · {u.Percent} %";
            parts.Add(text);
        }
        return string.Join("   ", parts);
    }

    /// The state in a word, for the tab, which has room for little: the
    /// rings under it say the rest.
    private static string Short(AiState state) => state switch
    {
        AiState.Working => L.T(" working", " pracuje"),
        AiState.Waiting => L.T(" waiting", " čeká"),
        _ => "",
    };
}

/// One file in `~/.claude/sessions/`: a running Claude Code and its state.
public sealed record ClaudeSessionRecord(int Pid, string Name, AiState State, string? Wants, string Cwd, bool IsHelper)
{
    public static ClaudeSessionRecord? FromJson(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return null;
            string? Text(string name) => root.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
            if (!root.TryGetProperty("pid", out var pidValue) || !pidValue.TryGetInt32(out var pid) || Text("cwd") is not { } cwd) return null;
            // Two spellings of the same thing, depending on the version:
            // `tempo` where it is written, else `status`.
            var state = (Text("tempo"), Text("status")) switch
            {
                ("blocked", _) or (_, "waiting") => AiState.Waiting,
                ("active", _) or (_, "busy") => AiState.Working,
                _ => AiState.Idle,
            };
            // A name Claude Code made up from the folder says less than the
            // folder itself; one the user gave is kept.
            var folder = Path.GetFileName(cwd.TrimEnd(Path.DirectorySeparatorChar, '/'));
            if (folder.Length == 0) folder = cwd;
            var given = Text("nameSource") is { } source && source != "derived";
            return new ClaudeSessionRecord(pid, given ? Text("name") ?? folder : folder, state,
                Text("waitingFor") ?? Text("needs"), cwd, Text("entrypoint")?.StartsWith("sdk-", StringComparison.Ordinal) == true);
        }
        catch (JsonException) { return null; }
    }

    /// A piece of work shorter than this ends without a word, or every
    /// one-line answer would slide out of the tab.
    public const double MinimumWork = 10;

    /// What is worth saying when a session goes from `old` to this: it has
    /// stopped to ask something, or it has finished. Only leaving work counts.
    public NotchActivity? Event(AiState? old, double workedFor) => AiSummary.Event("Claude Code", old, State, Name, Wants, Pid, workedFor);
}

public static class AiSummary
{
    public static NotchActivity? Event(string tool, AiState? old, AiState now, string name, string? wants, int pid, double workedFor)
    {
        if (old != AiState.Working) return null;
        return now switch
        {
            AiState.Waiting => new NotchActivity.AiWaiting(tool, name, wants, pid),
            AiState.Idle when workedFor >= ClaudeSessionRecord.MinimumWork => new NotchActivity.AiDone(tool, name, pid),
            _ => null,
        };
    }

    /// The state shown for all the sessions together, and which one it is
    /// about: one waiting for you comes before one still working.
    public static (AiState State, string? Session, string? Wants) Of(IEnumerable<(AiState State, string Name, string? Wants)> records)
    {
        var all = records.ToList();
        foreach (var r in all) if (r.State == AiState.Waiting) return (AiState.Waiting, r.Name, r.Wants);
        foreach (var r in all) if (r.State == AiState.Working) return (AiState.Working, r.Name, null);
        return (AiState.Idle, null, null);
    }

    /// Both tools' sessions in one list, the ones waiting or at work first.
    public static IReadOnlyList<(AiSession Session, bool IsVibe)> Rows(ClaudeStatus? claude, VibeStatus? vibe)
    {
        static int Rank(AiState state) => state switch { AiState.Waiting => 0, AiState.Working => 1, _ => 2 };
        var all = new List<(AiSession Session, bool IsVibe)>();
        foreach (var s in claude?.Sessions ?? []) all.Add((s, false));
        foreach (var s in vibe?.Sessions ?? []) all.Add((s, true));
        // A stable sort: OrderBy keeps the order of equals.
        return all.OrderBy(row => Rank(row.Session.State)).ToList();
    }
}

/// The month's Vibe allowance, as Mistral's billing reports it.
public sealed record VibeUsage(int Percent, DateTime? Resets, string? Plan, bool PayAsYouGo)
{
    /// Reads the line the helper prints (see `VibeMonitor.Helper`):
    ///
    ///     {"percent": 2.97, "resets": "2026-12-01T00:00:00Z", "plan": "EDU", "payg": false}
    ///
    /// Null when there is no such line: a signed-out Vibe, a plan with no
    /// allowance.
    public static VibeUsage? Parse(string text)
    {
        // The last line that is an object: anything a library chose to
        // print on the way comes before it.
        foreach (var raw in text.Split('\n', '\r').Reverse())
        {
            var line = raw.Trim();
            if (!line.StartsWith('{')) continue;
            try
            {
                using var document = JsonDocument.Parse(line);
                var root = document.RootElement;
                if (!root.TryGetProperty("percent", out var p) || p.ValueKind != JsonValueKind.Number) continue;
                var percent = p.GetDouble();
                if (!double.IsFinite(percent)) continue;
                DateTime? resets = root.TryGetProperty("resets", out var r) && r.ValueKind == JsonValueKind.String
                    && DateTimeOffset.TryParse(r.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var when)
                    ? when.LocalDateTime : null;
                var plan = root.TryGetProperty("plan", out var n) && n.ValueKind == JsonValueKind.String ? n.GetString() : null;
                // Whole per cents, the part over dropped: that is how Vibe's
                // own status bar says it.
                return new VibeUsage((int)Math.Floor(Math.Max(percent, 0)), resets, PlanTitle(plan),
                    root.TryGetProperty("payg", out var g) && g.ValueKind == JsonValueKind.True);
            }
            catch (JsonException) { }
        }
        return null;
    }

    /// Billing's name for the plan, as Vibe's own account view words it.
    public static string? PlanTitle(string? name)
    {
        name = name?.Trim();
        if (string.IsNullOrEmpty(name)) return null;
        return name.ToUpperInvariant() switch { "FREE" => "Free", "INDIVIDUAL" => "Pro", "EDU" => "Student", "TEAM" => "Team", _ => name };
    }
}

/// What the tab shows of Mistral Vibe.
public sealed record VibeStatus(AiState State = AiState.Idle, string? Session = null, string? Wants = null, VibeUsage? Usage = null)
{
    public IReadOnlyList<AiSession> Sessions { get; init; } = [];

    public bool Equals(VibeStatus? other) => other is not null && State == other.State && Session == other.Session
        && Wants == other.Wants && Equals(Usage, other.Usage) && Sessions.SequenceEqual(other.Sessions);

    public override int GetHashCode() => HashCode.Combine(State, Session, Wants, Usage, Sessions.Count);

    public bool IsActive => State != AiState.Idle;
    public bool HasSomething => IsActive || Usage is not null;
    public double? Fraction => Usage is { } u ? Math.Clamp(u.Percent / 100.0, 0, 1) : null;
}

/// What a Vibe session's journal says it is doing.
///
/// The journal is a line of JSON per step, and three kinds matter here:
///   - `projection_delta` with a `set_envelope`: the session as Vibe shows
///     it, its status (running, idle) and its title;
///   - `callback_registered`: it has stopped to ask for an approval;
///   - `callback_resolved`: the approval was answered.
/// While it waits the status still says "running": a question registered and
/// not yet resolved is what waiting looks like.
public sealed class VibeJournal
{
    public string? Status { get; private set; }
    public string? Title { get; private set; }
    /// Somebody named the session; Vibe's own titles are a guess at the task.
    public bool TitleGiven { get; private set; }
    /// Asked and not answered, oldest first.
    private readonly List<(string Id, string? Wants)> _asks = [];

    public AiState State => _asks.Count > 0 || Status == "blocked" ? AiState.Waiting
        : Status == "running" ? AiState.Working : AiState.Idle;

    /// What the oldest open question asks for.
    public string? Wants => _asks.Count > 0 ? _asks[0].Wants : null;

    /// A new journal file: Vibe starts one each time the session comes to
    /// rest, so whatever was going on is over. Its name stays.
    public void StartOver()
    {
        Status = null;
        _asks.Clear();
    }

    /// Takes in whole lines of the journal, in order. Only lines that can
    /// matter are parsed: a line carrying a tool's output runs to hundreds
    /// of kilobytes, and there is one envelope after every step.
    public void Read(string text)
    {
        var envelopes = new List<(int Index, string Line)>();
        var lastAsk = -1;
        var index = 0;
        foreach (var line in text.Split('\n'))
        {
            index++;
            if (line.Contains("callback_re", StringComparison.Ordinal) && TakeCallback(line, index, ref lastAsk)) continue;
            if (line.Contains("set_envelope", StringComparison.Ordinal)) envelopes.Add((index, line));
        }
        // The newest envelope is the one that counts. A line that merely
        // quotes the word is passed over.
        for (var i = envelopes.Count - 1; i >= 0; i--)
        {
            if (!TakeEnvelope(envelopes[i].Line)) continue;
            // At rest after the question was put: the turn was stopped, and
            // the question went with it.
            if (Status != "running" && Status != "blocked" && envelopes[i].Index > lastAsk) _asks.Clear();
            break;
        }
    }

    private bool TakeCallback(string line, int index, ref int lastAsk)
    {
        using var document = Object(line);
        if (document is null) return false;
        var root = document.RootElement;
        if (Text(root, "type") is not { } type || !type.StartsWith("callback_", StringComparison.Ordinal)
            || Inside(root, "payload") is not { } payload || Text(payload, "callback_id") is not { } id) return false;
        _asks.RemoveAll(a => a.Id == id);
        if (type == "callback_registered")
        {
            _asks.Add((id, WantsOf(payload)));
            lastAsk = index;
        }
        return true;
    }

    private bool TakeEnvelope(string line)
    {
        using var document = Object(line);
        if (document is null) return false;
        var root = document.RootElement;
        if (Text(root, "type") != "projection_delta" || Inside(root, "payload") is not { } payload
            || !payload.TryGetProperty("delta", out var deltas) || deltas.ValueKind != JsonValueKind.Array) return false;
        JsonElement? session = null;
        foreach (var delta in deltas.EnumerateArray())
            if (delta.ValueKind == JsonValueKind.Object && Text(delta, "op") == "set_envelope"
                && Inside(Inside(delta, "state"), "session") is { } s)
                session = s;
        if (session is not { } found) return false;
        Status = Inside(found, "status") is { } status ? Text(status, "type") : null;
        Title = Text(found, "title") is { Length: > 0 } title ? title : null;
        TitleGiven = Title is not null && Text(found, "titleSource") is { } source && source != "auto";
        return true;
    }

    private static JsonDocument? Object(string line)
    {
        try
        {
            var document = JsonDocument.Parse(line);
            if (document.RootElement.ValueKind == JsonValueKind.Object) return document;
            document.Dispose();
        }
        catch (JsonException) { }
        return null;
    }

    private static string? Text(JsonElement element, string name) =>
        element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    private static JsonElement? Inside(JsonElement? element, string name) =>
        element is { ValueKind: JsonValueKind.Object } e && e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Object ? v : null;

    /// What an approval is for, short enough for the tab: the command, the
    /// file, or failing those the tool.
    public static string? WantsOf(JsonElement payload)
    {
        var routing = Inside(payload, "routing");
        var effect = Inside(Inside(routing, "detail"), "effect");
        var input = Inside(effect, "input");
        string? text = null;
        if (input is { } i && Text(i, "command") is { } command)
            text = command.Split('\n', '\r').FirstOrDefault(l => l.Length > 0);
        else if (input is { } j && (Text(j, "path") ?? Text(j, "file_path")) is { } path)
            text = Path.GetFileName(path.TrimEnd(Path.DirectorySeparatorChar, '/'));
        else if (effect is { } e && Text(e, "toolName") is { } tool)
            text = tool.Split('.').Last();      // "file_system.write_file" → "write_file"
        else if (routing is { } r && Text(r, "title") is { } title)
            text = title;
        text = text?.Trim();
        if (string.IsNullOrEmpty(text)) return null;
        return text.Length > 60 ? text[..59] + "…" : text;
    }

    /// The name the tab uses, as for Claude Code: the folder it runs in,
    /// unless somebody gave the session a name of its own.
    public static string Name(string? title, bool given, string? folder)
    {
        if (given && title is not null) return title;
        if (!string.IsNullOrEmpty(folder) && Path.GetFileName(folder.TrimEnd(Path.DirectorySeparatorChar, '/')) is { Length: > 0 } last) return last;
        return title ?? "Vibe";
    }

    /// Letters, digits, dash and underscore: the id goes into a path.
    public static bool IsSessionId(string id) =>
        id.Length is > 0 and <= 128 && id[0] != '-' && id[0] != '_'
        && id.All(c => char.IsAsciiLetterOrDigit(c) || c == '-' || c == '_');

    /// "#!C:\…\mistral-vibe\Scripts\python.exe" in a launcher → that path.
    /// Null for anything that isn't a Python by its full path.
    public static string? Interpreter(string launcherText)
    {
        var at = launcherText.LastIndexOf("#!", StringComparison.Ordinal);
        if (at < 0) return null;
        var line = launcherText[(at + 2)..].Split('\n', '\r', '\0')[0].Trim().Trim('"');
        if (!Path.IsPathFullyQualified(line)) return null;
        return Path.GetFileName(line).StartsWith("python", StringComparison.OrdinalIgnoreCase) ? line : null;
    }
}
