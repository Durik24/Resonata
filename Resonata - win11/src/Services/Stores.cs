using System.Diagnostics;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows.Threading;
using Microsoft.Win32;

namespace Resonata;

/// Synced lyrics from LRCLIB: free, no key, and already timestamped.
public sealed class LyricsStore(PanelModel model)
{
    private const string Endpoint = "https://lrclib.net/api/";
    private static readonly HttpClient Http = MakeClient();

    private string? _current;
    private CancellationTokenSource? _task;
    private readonly HashSet<string> _misses = [];

    private static HttpClient MakeClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromSeconds(8) };
        // LRCLIB asks for one; it's how they tell clients apart in their logs.
        client.DefaultRequestHeaders.UserAgent.ParseAdd("Resonata-Windows/1.0 (https://github.com/Durik24/Resonata)");
        return client;
    }

    private static string KeyFor(Track t)
    {
        var raw = string.Join('\u001F', t.Title, t.Artist, t.Album, ((int)t.Duration).ToString());
        return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(raw)))[..24];
    }

    /// Same song as last time is a no-op; null clears the lines. With lyrics
    /// switched off, or for what isn't a song, LRCLIB isn't asked at all.
    public void Load(Track? track)
    {
        if (track is null || !Settings.Current.ShowLyrics || !LyricsRules.ShouldLookUp(track))
        {
            _current = null;
            _task?.Cancel();
            model.Lyrics = null;
            model.LyricsPending = false;
            return;
        }

        var key = KeyFor(track);
        if (key == _current) return;
        _current = key;
        _task?.Cancel();
        model.Lyrics = null;

        if (_misses.Contains(key)) { model.LyricsPending = false; return; }
        if (ReadCache(key) is { } cached)
        {
            model.Lyrics = cached;
            model.LyricsPending = false;
            return;
        }

        model.LyricsPending = true;
        var cts = new CancellationTokenSource();
        _task = cts;
        _ = RunAsync(track, key, cts.Token);
    }

    private async Task RunAsync(Track track, string key, CancellationToken token)
    {
        // No answer at all isn't LRCLIB saying no: asked again, less and less
        // often, for as long as the song is the current one.
        var wait = TimeSpan.FromSeconds(15);
        try
        {
            while (true)
            {
                var (found, lines) = await FetchAsync(track, token);
                if (token.IsCancellationRequested || _current != key) return;
                if (found == Outcome.Lines)
                {
                    model.LyricsPending = false;
                    model.Lyrics = lines;
                    WriteCache(key, lines!);
                    return;
                }
                if (found == Outcome.None)
                {
                    model.LyricsPending = false;
                    _misses.Add(key);
                    return;
                }
                model.LyricsPending = false;
                await Task.Delay(wait, token);
                wait = TimeSpan.FromSeconds(Math.Min(wait.TotalSeconds * 2, 240));
                model.LyricsPending = true;
            }
        }
        catch (OperationCanceledException)
        {
            // A newer song took over.
        }
    }

    private enum Outcome { Lines, None, Failed }

    private sealed class Record
    {
        [JsonPropertyName("syncedLyrics")] public string? SyncedLyrics { get; set; }
        /// The recording's length in seconds, as LRCLIB has it.
        [JsonPropertyName("duration")] public double? Duration { get; set; }
    }

    /// Exact match first; a looser search if that misses, since a title with
    /// "(Deluxe Edition)" on the album is enough to miss.
    private static async Task<(Outcome, IReadOnlyList<LyricLine>?)> FetchAsync(Track t, CancellationToken token)
    {
        static string E(string s) => Uri.EscapeDataString(s);
        var exact = await RequestAsync(
            $"{Endpoint}get?track_name={E(t.Title)}&artist_name={E(t.Artist)}&album_name={E(t.Album)}&duration={(int)Math.Round(t.Duration)}", token);
        if (exact.failed) return (Outcome.Failed, null);
        if (exact.body is not null && Parse(exact.body) is { } lines) return (Outcome.Lines, lines);

        var search = await RequestAsync($"{Endpoint}search?track_name={E(t.Title)}&artist_name={E(t.Artist)}", token);
        if (search.failed) return (Outcome.Failed, null);
        if (search.body is null) return (Outcome.None, null);
        try
        {
            // Those that really have timed lyrics, then the nearest in length.
            var timed = (JsonSerializer.Deserialize<Record[]>(search.body) ?? [])
                .Select(r => (r.Duration, Lines: r.SyncedLyrics is { } synced ? Lrc.Parse(synced) : null))
                .Where(r => r.Lines is not null)
                .ToList();
            return LyricsRules.Closest(timed.Select(r => r.Duration).ToList(), t.Duration) is { } best
                ? (Outcome.Lines, timed[best].Lines)
                : (Outcome.None, null);
        }
        catch (JsonException)
        {
            return (Outcome.None, null);
        }
    }

    private static IReadOnlyList<LyricLine>? Parse(string body)
    {
        try
        {
            return JsonSerializer.Deserialize<Record>(body)?.SyncedLyrics is { } synced ? Lrc.Parse(synced) : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static async Task<(string? body, bool failed)> RequestAsync(string url, CancellationToken token)
    {
        try
        {
            using var response = await Http.GetAsync(url, token);
            if (response.StatusCode == HttpStatusCode.NotFound) return (null, false);
            if (!response.IsSuccessStatusCode) return (null, true);
            return (await response.Content.ReadAsStringAsync(token), false);
        }
        catch (HttpRequestException)
        {
            return (null, true);
        }
        catch (TaskCanceledException) when (!token.IsCancellationRequested)
        {
            return (null, true); // timed out
        }
    }

    private static IReadOnlyList<LyricLine>? ReadCache(string key)
    {
        var path = Path.Combine(Paths.Lyrics, key + ".lrc");
        try
        {
            return File.Exists(path) ? Lrc.Parse(File.ReadAllText(path)) : null;
        }
        catch (IOException)
        {
            return null;
        }
    }

    private static void WriteCache(string key, IEnumerable<LyricLine> lines)
    {
        try
        {
            File.WriteAllText(Path.Combine(Paths.Lyrics, key + ".lrc"), Lrc.Serialize(lines));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Log.Write($"could not cache lyrics: {e.Message}");
        }
    }
}

public sealed class TodoItem : Observable
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Text { get; set; } = "";

    private bool _done;
    public bool Done { get => _done; set => Set(ref _done, value); }
}

/// The note and the to-do list, in one small JSON file that stays on this PC.
public sealed class NotesStore
{
    public static NotesStore Shared { get; } = new();

    private sealed class Saved
    {
        public string Note { get; set; } = "";
        public List<TodoItem> Todos { get; set; } = [];
    }

    private static string FilePath => Path.Combine(Paths.Data, "notes.json");

    private string _note = "";
    private readonly DispatcherTimer _save = new() { Interval = TimeSpan.FromSeconds(0.5) };

    public event Action? Changed;
    public List<TodoItem> Todos { get; private set; } = [];

    private NotesStore()
    {
        _save.Tick += (_, _) => Save();
        Load();
    }

    public string Note
    {
        get => _note;
        set { _note = value; _save.Stop(); _save.Start(); }
    }

    public void Add(string text)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0) return;
        Todos.Add(new TodoItem { Text = trimmed });
        Touch();
    }

    public void Toggle(TodoItem item) { item.Done = !item.Done; Touch(); }

    public void Remove(TodoItem item) { Todos.Remove(item); Touch(); }

    private void Touch()
    {
        _save.Stop();
        _save.Start();
        Changed?.Invoke();
    }

    private void Load()
    {
        if (!File.Exists(FilePath)) return;
        try
        {
            var saved = JsonSerializer.Deserialize<Saved>(File.ReadAllText(FilePath));
            if (saved is null) return;
            _note = saved.Note;
            Todos = saved.Todos;
        }
        catch (Exception e) when (e is JsonException or IOException)
        {
            // There, but unreadable. Overwriting it with the first keystroke
            // would lose the notes for good, so it's set aside first.
            SetAside(FilePath);
        }
    }

    public static void SetAside(string path)
    {
        try
        {
            var stamp = DateTime.Now.ToString("yyyy-MM-ddTHH-mm-ss");
            var kept = Path.Combine(Path.GetDirectoryName(path)!,
                $"{Path.GetFileNameWithoutExtension(path)}-unreadable-{stamp}{Path.GetExtension(path)}");
            File.Move(path, kept);
            Log.Write($"unreadable file kept as {kept}");
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Log.Write($"unreadable file could not be kept: {e.Message}");
        }
    }

    /// Quitting within that half second must not lose the last keystrokes.
    public void SaveIfPending()
    {
        if (_save.IsEnabled) Save();
    }

    private void Save()
    {
        _save.Stop();
        try
        {
            AtomicFile.Write(FilePath, JsonSerializer.Serialize(new Saved { Note = _note, Todos = Todos }));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Log.Write($"could not save notes: {e.Message}");
        }
    }
}

/// Files parked on the panel. Paths, not copies; files moved since are forgotten.
public sealed class ShelfStore
{
    public static ShelfStore Shared { get; } = new();
    public const int Limit = 30;

    public event Action? Changed;
    public List<string> Items { get; private set; }

    private ShelfStore()
    {
        Items = Settings.Current.ShelfItems.ToList();
        Prune();
    }

    private void Save()
    {
        Settings.Current.ShelfItems = Items.ToList();
        Changed?.Invoke();
    }

    public void Add(IEnumerable<string> paths)
    {
        foreach (var path in paths)
            if (!Items.Contains(path, StringComparer.OrdinalIgnoreCase)) Items.Add(path);
        Items = Items.TakeLast(Limit).ToList();
        Save();
    }

    public void Remove(string path) { Items.Remove(path); Save(); }

    public void Clear() { Items.Clear(); Save(); }

    public void Prune()
    {
        var kept = Items.Where(p => File.Exists(p) || Directory.Exists(p)).ToList();
        if (kept.Count == Items.Count) return;
        Items = kept;
        Save();
    }
}

public static class QuickApps
{
    /// Two rows of six, one tile kept for "add".
    public const int Limit = 11;

    public static event Action? Changed;

    public static IReadOnlyList<string> Current
    {
        get
        {
            Settings.Current.QuickApps ??= Defaults();
            return Settings.Current.QuickApps;
        }
    }

    public static void Save(IEnumerable<string> paths)
    {
        Settings.Current.QuickApps = paths.Take(Limit).ToList();
        Changed?.Invoke();
    }

    /// Worth having from the first launch, where they exist here.
    public static List<string> Defaults()
    {
        string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        string programs = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        string programsX86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
        string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string roaming = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        string[] candidates =
        [
            Path.Combine(windows, "explorer.exe"),
            Path.Combine(programsX86, @"Microsoft\Edge\Application\msedge.exe"),
            Path.Combine(programs, @"Google\Chrome\Application\chrome.exe"),
            Path.Combine(local, @"Google\Chrome\Application\chrome.exe"),
            Path.Combine(programs, @"Mozilla Firefox\firefox.exe"),
            Path.Combine(roaming, @"Spotify\Spotify.exe"),
            Path.Combine(windows, @"System32\notepad.exe"),
            Path.Combine(windows, @"System32\calc.exe"),
            Path.Combine(windows, @"System32\Taskmgr.exe"),
        ];
        return candidates.Where(File.Exists).ToList();
    }

    public static void Add(string path)
    {
        var list = Current.ToList();
        if (list.Contains(path, StringComparer.OrdinalIgnoreCase) || list.Count >= Limit) return;
        list.Add(path);
        Save(list);
    }

    public static void Remove(string path) => Save(Current.Where(p => p != path));

    public static string Name(string path) => FileVersionName(path) ?? Path.GetFileNameWithoutExtension(path);

    private static string? FileVersionName(string path)
    {
        if (!path.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) || !File.Exists(path)) return null;
        try
        {
            var info = FileVersionInfo.GetVersionInfo(path);
            var name = string.IsNullOrWhiteSpace(info.FileDescription) ? info.ProductName : info.FileDescription;
            return string.IsNullOrWhiteSpace(name) || name.Length > 22 ? null : name;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    public static void Launch(string path) => Shell.Open(path);

    public static void ChooseAndAdd()
    {
        var dialog = new OpenFileDialog
        {
            Title = L.T("Add an app", "Přidat aplikaci"),
            Filter = L.T("Apps and shortcuts|*.exe;*.lnk;*.url", "Aplikace a zástupci|*.exe;*.lnk;*.url"),
            Multiselect = true,
            InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.CommonPrograms),
            DereferenceLinks = false,
        };
        if (dialog.ShowDialog() != true) return;
        foreach (var file in dialog.FileNames) Add(file);
    }
}

public static class Shell
{
    public static void Open(string path)
    {
        try
        {
            Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException or FileNotFoundException)
        {
            Log.Write($"could not open {path}: {e.Message}");
        }
    }
}

public static class LoginItem
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string Name = "Resonata";

    private static string Command => $"\"{Environment.ProcessPath}\" --autostart";

    public static bool IsEnabled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(Name) is not null;
        }
    }

    public static void Set(bool on)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey);
        if (on) key.SetValue(Name, Command);
        else key.DeleteValue(Name, throwOnMissingValue: false);
    }

    /// Only the installed copy, and only once: switching it off is a choice,
    /// and a test run from the project folder must not claim the login item.
    public static void RegisterOnce()
    {
        if (!Updater.IsInstalled || Settings.Current.RegisteredLoginItem) return;
        Set(true);
        Settings.Current.RegisteredLoginItem = true;
    }
}
