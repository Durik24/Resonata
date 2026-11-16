using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Resonata;

// What the Mac's 1.0.15 added, the parts that need no window to be tested:
// a file that has just arrived (FileWatch.swift), GitHub's news of the
// repositories followed (GitHub.swift), what was copied (Clipboard.swift)
// and the fade at a timer's end (MusicSleep.swift). Each is off until
// switched on in Settings.

/// The timer's "stop the music at the end": the music fades and pauses.
public static class MusicSleep
{
    public const double FadeSeconds = 10;
    public const int Steps = 20;

    /// The levels to step through from `start` down to silence, the last
    /// one 0. Even steps: a player's volume is already a perceptual scale.
    public static IReadOnlyList<int> Levels(int start, int steps)
    {
        if (start <= 0 || steps <= 0) return [];
        return Enumerable.Range(1, steps)
            .Select(step => (int)Math.Round((double)start * (steps - step) / steps, MidpointRounding.AwayFromZero)).ToList();
    }
}

public enum FileKind { Download, Screenshot }

/// A file that has just arrived: a download that has finished, or a screenshot.
public sealed record FileArrival(FileKind Kind, string Path, long? Bytes)
{
    public string Title => Kind == FileKind.Download
        ? L.T("Download finished", "Stažení dokončeno") : L.T("Screenshot", "Snímek obrazovky");

    /// "invoice.pdf · 2.4 MB" for a download; a screenshot's name is a date
    /// nobody reads, so it says where it went: "in Screenshots".
    public string Detail => DetailOf(Kind, System.IO.Path.GetFileName(Path), Bytes,
        System.IO.Path.GetFileName(System.IO.Path.GetDirectoryName(Path) ?? ""), L.Culture, L.T("in", "ve složce"));

    public static string DetailOf(FileKind kind, string name, long? bytes, string folder, CultureInfo culture, string inWord) => kind switch
    {
        FileKind.Download => bytes is > 0 ? $"{name} · {Size(bytes.Value, culture)}" : name,
        _ => $"{inWord} {folder}",
    };

    /// "812 B", "24 kB", "2.4 MB", "1.2 GB", in thousands as Explorer's
    /// rivals count them, one decimal from megabytes up.
    public static string Size(long bytes, CultureInfo culture)
    {
        if (bytes < 1000) return $"{bytes} B";
        if (bytes < 1_000_000) return $"{Math.Round(bytes / 1000.0)} kB";
        var (value, unit) = bytes < 1_000_000_000 ? (bytes / 1e6, "MB") : (bytes / 1e9, "GB");
        return value.ToString("0.#", culture) + " " + unit;
    }

    private static readonly HashSet<string> Temporary = new(StringComparer.OrdinalIgnoreCase)
        { ".download", ".crdownload", ".part", ".partial", ".opdownload", ".tmp" };

    /// A name that is a download still on its way, or nothing to announce:
    /// the browsers' part-files, Office's lock files, anything hidden.
    public static bool IsTemporary(string name) =>
        name.StartsWith('.') || name.StartsWith("~$", StringComparison.Ordinal)
        || name.Equals("desktop.ini", StringComparison.OrdinalIgnoreCase)
        || Temporary.Contains(System.IO.Path.GetExtension(name));

    /// The names in `now` that weren't there before and could be a finished
    /// file, in the order of their names.
    public static IReadOnlyList<string> Candidates(IEnumerable<string> now, IReadOnlySet<string> known) =>
        now.Where(name => !known.Contains(name) && !IsTemporary(name)).OrderBy(name => name, StringComparer.Ordinal).ToList();

    /// What a new file in a watched folder is — null when it is nothing to
    /// say: one of a kind that isn't watched, or an old file moved in.
    public static FileKind? KindOf(IReadOnlySet<FileKind> watching, bool inScreenshots, bool inDownloads, double ageSeconds)
    {
        if (ageSeconds >= 600) return null;
        if (inScreenshots && watching.Contains(FileKind.Screenshot)) return FileKind.Screenshot;
        if (inDownloads && watching.Contains(FileKind.Download)) return FileKind.Download;
        return null;
    }
}

/// What GitHub last said of one repository: the newest commit, the newest
/// finished run of its checks, the newest release.
public sealed record GitHubSnapshot(string? Commit = null, long? Run = null, long? Release = null);

public static class GitHubFeed
{
    public sealed record Commit(string Sha, string? Login, string Name, string Message, string? Url);
    public sealed record Run(long Id, string Name, string Branch, string? Conclusion, string? Url);
    public sealed record Release(long Id, string Tag, string? Author, bool Draft, string? Url);

    private static readonly Regex Allowed = new("^[A-Za-z0-9._-]+$", RegexOptions.Compiled);

    /// The repositories named in the settings' field: "owner/name", several
    /// apart by commas, spaces or lines; a pasted github.com address counts
    /// too. At most `limit`, each once.
    public static IReadOnlyList<string> Repos(string text, int limit = 4)
    {
        var found = new List<string>();
        foreach (var raw in text.Split([',', ' ', '\n', '\r', '\t', ';'], StringSplitOptions.RemoveEmptyEntries))
        {
            var piece = raw;
            foreach (var prefix in new[] { "https://github.com/", "http://github.com/", "github.com/" })
                if (piece.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) piece = piece[prefix.Length..];
            if (piece.EndsWith(".git", StringComparison.OrdinalIgnoreCase)) piece = piece[..^4];
            var parts = piece.Split('/', StringSplitOptions.RemoveEmptyEntries);
            // Letters, digits, dots, dashes — and never a name that is only
            // dots: the two go into an address as they are.
            if (parts.Length < 2 || !Allowed.IsMatch(parts[0]) || !Allowed.IsMatch(parts[1])
                || parts[0].All(c => c == '.') || parts[1].All(c => c == '.')) continue;
            var repo = parts[0] + "/" + parts[1];
            if (!found.Contains(repo, StringComparer.OrdinalIgnoreCase)) found.Add(repo);
            if (found.Count == limit) break;
        }
        return found;
    }

    private static string? Text(JsonElement element, string name) =>
        element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString() : null;

    private static JsonElement? Inside(JsonElement element, string name) =>
        element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Object
            ? value : null;

    private static long? Number(JsonElement element, string name) =>
        element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out var value) && value.TryGetInt64(out var number)
            ? number : null;

    private static JsonDocument? Document(string json)
    {
        try { return JsonDocument.Parse(json); }
        catch (JsonException) { return null; }
    }

    /// The newest commit, from `repos/…/commits?per_page=1`.
    public static Commit? CommitFrom(string json)
    {
        using var document = Document(json);
        if (document is null || document.RootElement.ValueKind != JsonValueKind.Array || document.RootElement.GetArrayLength() == 0) return null;
        var first = document.RootElement[0];
        if (Text(first, "sha") is not { } sha) return null;
        var commit = Inside(first, "commit");
        var message = (commit is { } c ? Text(c, "message") : null) ?? "";
        var name = commit is { } c2 && Inside(c2, "author") is { } author ? Text(author, "name") : null;
        return new Commit(sha, Inside(first, "author") is { } account ? Text(account, "login") : null, name ?? "",
            message.Split('\n', '\r')[0].Trim(), Text(first, "html_url"));
    }

    /// The latest runs of the checks, newest first, from `repos/…/actions/runs`.
    public static IReadOnlyList<Run> RunsFrom(string json)
    {
        using var document = Document(json);
        if (document is null || document.RootElement.ValueKind != JsonValueKind.Object
            || !document.RootElement.TryGetProperty("workflow_runs", out var list) || list.ValueKind != JsonValueKind.Array) return [];
        var runs = new List<Run>();
        foreach (var run in list.EnumerateArray())
            if (Number(run, "id") is { } id)
                runs.Add(new Run(id, Text(run, "name") ?? "", Text(run, "head_branch") ?? "", Text(run, "conclusion"), Text(run, "html_url")));
        return runs;
    }

    /// The newest release, from `repos/…/releases?per_page=1`.
    public static Release? ReleaseFrom(string json)
    {
        using var document = Document(json);
        if (document is null || document.RootElement.ValueKind != JsonValueKind.Array || document.RootElement.GetArrayLength() == 0) return null;
        var first = document.RootElement[0];
        if (Number(first, "id") is not { } id) return null;
        var draft = first.TryGetProperty("draft", out var d) && d.ValueKind == JsonValueKind.True;
        return new Release(id, Text(first, "tag_name") ?? "", Inside(first, "author") is { } author ? Text(author, "login") : null,
            draft, Text(first, "html_url"));
    }

    /// What is worth saying, given what the repository looked like last time
    /// (`before`, null the first time — which says nothing: everything is new
    /// then) and what it looks like now. A part that couldn't be read is null
    /// and keeps what was known. `me` is the user's own GitHub name: their
    /// own pushes and releases are no news to them.
    public static (IReadOnlyList<NotchActivity> Events, GitHubSnapshot Snapshot) News(
        string repo, GitHubSnapshot? before, Commit? commit, IReadOnlyList<Run> runs, Release? release, string? me)
    {
        var name = repo.Split('/').LastOrDefault(part => part.Length > 0) ?? repo;
        bool Mine(string? who) => who is not null && me is not null && string.Equals(who, me, StringComparison.OrdinalIgnoreCase);
        var events = new List<NotchActivity>();
        var snapshot = before ?? new GitHubSnapshot();

        // Failed checks first: of everything here, that is the one to act on.
        var finished = runs.Where(run => run.Conclusion is not null).ToList();
        if (finished.Count > 0)
        {
            if (before?.Run is { } seen
                && finished.Where(run => run.Id > seen && run.Conclusion == "failure").MaxBy(run => run.Id) is { } failed)
            {
                var detail = string.Join(" · ", new[] { failed.Branch, failed.Name }.Where(part => part.Length > 0));
                events.Add(new NotchActivity.GitHubChecksFailed(name, detail, failed.Url));
            }
            snapshot = snapshot with { Run = Math.Max(finished.Max(run => run.Id), before?.Run ?? 0) };
        }
        if (commit is not null)
        {
            if (before?.Commit is { } seen && seen != commit.Sha && !Mine(commit.Login))
                events.Add(new NotchActivity.GitHubPush(commit.Login ?? (commit.Name.Length == 0 ? "?" : commit.Name), name, commit.Message, commit.Url));
            snapshot = snapshot with { Commit = commit.Sha };
        }
        if (release is { Draft: false })
        {
            if (before?.Release is { } seen && seen != release.Id && !Mine(release.Author))
                events.Add(new NotchActivity.GitHubRelease(name, release.Tag, release.Url));
            snapshot = snapshot with { Release = release.Id };
        }
        // A repository with no release or no checks yet: remembered as
        // "none so far" rather than "never looked", so its first one is news.
        if (before is null)
        {
            if (snapshot.Run is null) snapshot = snapshot with { Run = 0 };
            if (snapshot.Release is null && release is null) snapshot = snapshot with { Release = 0 };
        }
        return (events, snapshot);
    }

    /// Every two minutes through `gh`; without it, GitHub allows sixty
    /// questions an hour, and three a repository have to fit.
    public static double Interval(int repos, bool signedIn) => signedIn ? 120 : Math.Max(300, repos * 240);
}

public enum ClipKind { Text, Link, Colour, Image, Files }

/// What the clipboard page knows of the things copied, the parts with no
/// clipboard in them.
public static class ClipRules
{
    public const int Limit = 20;
    /// Pictures are kept whole, to be put back; only so many, and none huge.
    public const int PictureLimit = 6;
    public const int PicturePixels = 3_000_000;
    public const int TextLength = 200_000;

    private static readonly Regex ColourPattern = new("^#[0-9A-Fa-f]{6}$", RegexOptions.Compiled);
    private static readonly Regex LinkPattern = new(@"^(https?://|www\.)\S+$", RegexOptions.Compiled | RegexOptions.IgnoreCase);

    /// What a copied string is: an address, a colour, or just text. Null
    /// for nothing but blank space.
    public static (ClipKind Kind, string Text)? Classify(string text)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0) return null;
        if (ColourPattern.IsMatch(trimmed)) return (ClipKind.Colour, trimmed.ToUpperInvariant());
        if (LinkPattern.IsMatch(trimmed)) return (ClipKind.Link, trimmed);
        return (ClipKind.Text, text.Length > TextLength ? text[..TextLength] : text);
    }

    /// What password managers and Windows' own settings put beside
    /// something that shouldn't be kept: `historyAllowed` is what the
    /// "CanIncludeInClipboardHistory" format says, when it is there.
    public static bool IsSecret(IEnumerable<string> formats, int? historyAllowed) =>
        historyAllowed == 0 || formats.Contains("ExcludeClipboardContentFromMonitorProcessing");

    /// `clips` with `clip` at the front: the same thing copied again moves
    /// up rather than appearing twice, and the oldest fall off the end.
    public static IReadOnlyList<T> Adding<T>(T clip, IEnumerable<T> clips, Func<T, T, bool> same, Func<T, bool> isPicture)
    {
        var rest = clips.Where(other => !same(other, clip)).ToList();
        rest.Insert(0, clip);
        // Pictures hold their data: past the few newest, they go.
        var pictures = 0;
        return rest.Where(item => !isPicture(item) || ++pictures <= PictureLimit).Take(Limit).ToList();
    }

    /// "now", "4 min ago", "2 h ago" — and the day, from yesterday back.
    public static string Age(DateTime date, DateTime now, bool czech)
    {
        var seconds = (now - date).TotalSeconds;
        if (seconds < 60) return czech ? "teď" : "now";
        var minutes = (int)(seconds / 60);
        if (minutes < 60) return czech ? $"před {minutes} min" : $"{minutes} min ago";
        var hours = minutes / 60;
        if (hours < 24) return czech ? $"před {hours} h" : $"{hours} h ago";
        return date.ToString(czech ? "d. M." : "d MMM", CultureInfo.GetCultureInfo(czech ? "cs-CZ" : "en-GB"));
    }

    /// The text as a card shows it: its lines run together, so two lines of
    /// the card are two lines of words, not one and a blank.
    public static string Shown(string text) =>
        string.Join(' ', (text.Length > 300 ? text[..300] : text).Split('\n', '\r').Select(line => line.Trim()).Where(line => line.Length > 0));

    /// An address without its "https://": the part that tells them apart.
    public static string Shortened(string address)
    {
        foreach (var prefix in new[] { "https://", "http://", "www." })
            if (address.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) address = address[prefix.Length..];
        return address;
    }

    /// `width` × `height` scaled to fit the box, keeping its shape; never
    /// scaled up past it.
    public static (double Width, double Height) Fitted(double width, double height, double boxWidth, double boxHeight)
    {
        if (width <= 0 || height <= 0) return (boxWidth, boxHeight);
        var scale = Math.Min(1, Math.Min(boxWidth / width, boxHeight / height));
        return (Math.Round(width * scale), Math.Round(height * scale));
    }
}
