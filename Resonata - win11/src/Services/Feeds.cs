using System.Collections.Specialized;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;

namespace Resonata;

// What the Mac's 1.0.15 added, the parts that touch the PC: the fade at a
// timer's end, the folders watched for a new file, GitHub asked now and
// then, and the clipboard looked at. The rules they follow are in
// Logic/Feeds.cs, where they are tested.

/// The timer's "stop the music at the end". Spotify has a volume of its own
/// to fade; any other player is simply paused.
public static class MusicFade
{
    /// The fade in progress; a newer one, or a cancel, makes an older one stop.
    private static int _generation;

    /// Stops a fade in progress — the timer was started again.
    public static void Cancel() => _generation++;

    /// Fades out and pauses whatever is playing. Called on the UI thread.
    public static async void Run(PanelModel model)
    {
        try { await RunAsync(model); }
        catch (Exception e) { Log.Write($"the fade at the timer's end failed: {e.GetType().Name}: {e.Message}"); }
    }

    private static async Task RunAsync(PanelModel model)
    {
        if (model.Track is not { IsPlaying: true } started || MediaService.Active is not { } media) return;
        var mine = ++_generation;
        var volume = started.IsSpotify ? await SpotifyVolume.ReadAsync() : null;
        if (mine != _generation) return;
        if (volume is not > 0)
        {
            media.Pause();
            return;
        }
        var original = (int)volume.Value;
        foreach (var level in MusicSleep.Levels(original, MusicSleep.Steps))
        {
            // Paused by hand, or another player took over: hands off, and
            // the volume back as it was.
            if (mine != _generation || model.Track is not { IsPlaying: true } now || now.Source != started.Source)
            {
                SpotifyVolume.Set(original);
                return;
            }
            SpotifyVolume.Set(level);
            await Task.Delay(TimeSpan.FromSeconds(MusicSleep.FadeSeconds / MusicSleep.Steps));
        }
        media.Pause();
        // Once it is quiet, back up: the pause has to land first, or the
        // last second of the song comes back at full volume.
        await Task.Delay(1200);
        SpotifyVolume.Set(original);
    }
}

/// Watches Downloads and the screenshots' folder for new files.
public sealed class FileWatcher
{
    /// A download has finished, or a screenshot was saved. Called on the UI thread.
    public Action<FileArrival>? OnArrival { get; set; }

    private readonly Dictionary<string, FolderWatch> _watches = new(StringComparer.OrdinalIgnoreCase);

    /// Starts, stops or re-aims the watching, to match the settings. Called
    /// on every settings change; does nothing when nothing changed.
    public void Apply(bool downloads, bool screenshots)
    {
        var wanted = new Dictionary<string, HashSet<FileKind>>(StringComparer.OrdinalIgnoreCase);
        void Want(string? folder, FileKind kind)
        {
            if (folder is null || !Directory.Exists(folder)) return;
            if (!wanted.TryGetValue(folder, out var kinds)) wanted[folder] = kinds = [];
            kinds.Add(kind);
        }
        if (downloads) Want(DownloadsFolder, FileKind.Download);
        if (screenshots) Want(ScreenshotsFolder, FileKind.Screenshot);

        foreach (var (folder, watch) in _watches.ToList())
        {
            if (wanted.TryGetValue(folder, out var kinds) && kinds.SetEquals(watch.Kinds)) continue;
            watch.Stop();
            _watches.Remove(folder);
        }
        var dispatcher = Dispatcher.CurrentDispatcher;
        foreach (var (folder, kinds) in wanted)
        {
            if (_watches.ContainsKey(folder)) continue;
            var watch = new FolderWatch(folder, kinds, arrival => dispatcher.BeginInvoke(() => OnArrival?.Invoke(arrival)));
            _watches[folder] = watch;
            watch.Start();
        }
    }

    /// Where Windows says a folder of the user's is, when it was moved.
    private static string? ShellFolder(string id)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders");
            return key?.GetValue(id) is string path && path.Length > 0 ? Path.GetFullPath(path) : null;
        }
        catch (Exception e) when (e is System.Security.SecurityException or IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            return null;
        }
    }

    public static string DownloadsFolder => ShellFolder("{374DE290-123F-4565-9164-39C4925E467B}")
        ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");

    /// Where Win + PrtSc and the Snipping Tool save: Pictures\Screenshots.
    public static string ScreenshotsFolder => ShellFolder("{B7BEDE81-DF94-4682-A7D8-57A52620B86F}")
        ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyPictures), "Screenshots");
}

/// One folder, watched for new names. Windows says when the folder's list
/// changes; nothing is read otherwise.
public sealed class FolderWatch(string folder, HashSet<FileKind> kinds, Action<FileArrival> onArrival)
{
    public HashSet<FileKind> Kinds => kinds;

    private readonly object _gate = new();
    private FileSystemWatcher? _watcher;
    private System.Threading.Timer? _scanSoon;
    /// The names already there, or already dealt with.
    private readonly HashSet<string> _known = new(StringComparer.OrdinalIgnoreCase);
    /// New names whose file is still growing, with its size at the last look.
    private readonly Dictionary<string, long> _settling = new(StringComparer.OrdinalIgnoreCase);
    private bool _stopped;

    private IEnumerable<string> Names() =>
        Directory.EnumerateFileSystemEntries(folder).Select(Path.GetFileName).Where(name => !string.IsNullOrEmpty(name))!;

    public void Start()
    {
        try
        {
            lock (_gate) foreach (var name in Names()) _known.Add(name);
            var watcher = new FileSystemWatcher(folder)
            {
                NotifyFilter = NotifyFilters.FileName | NotifyFilters.Size | NotifyFilters.LastWrite,
                IncludeSubdirectories = false,
            };
            watcher.Created += (_, _) => Scan(after: 0.4);
            watcher.Renamed += (_, _) => Scan(after: 0.4);
            watcher.Changed += (_, _) => Scan(after: 0.4);
            watcher.Error += (_, e) => Log.Write($"watching {folder} stopped: {e.GetException().Message}");
            watcher.EnableRaisingEvents = true;
            _watcher = watcher;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException)
        {
            Log.Write($"can't watch {folder}: {e.Message}");
        }
    }

    public void Stop()
    {
        lock (_gate)
        {
            _stopped = true;
            _scanSoon?.Dispose();
            _scanSoon = null;
        }
        _watcher?.Dispose();
        _watcher = null;
    }

    /// A browser finishing a download renames, deletes and touches in a
    /// burst; one look after it has gone quiet sees the result.
    private void Scan(double after)
    {
        lock (_gate)
        {
            if (_stopped) return;
            _scanSoon?.Dispose();
            _scanSoon = new System.Threading.Timer(_ => Scan(), null, TimeSpan.FromSeconds(after), Timeout.InfiniteTimeSpan);
        }
    }

    private void Scan()
    {
        FileArrival? arrived = null;
        var growing = false;
        lock (_gate)
        {
            if (_stopped) return;
            HashSet<string> now;
            try { now = new HashSet<string>(Names(), StringComparer.OrdinalIgnoreCase); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return; }
            // Names that have gone can come again — the same file downloaded twice.
            _known.IntersectWith(now);
            foreach (var gone in _settling.Keys.Where(name => !now.Contains(name)).ToList()) _settling.Remove(gone);
            foreach (var name in FileArrival.Candidates(now, _known))
            {
                var path = Path.Combine(folder, name);
                long size;
                DateTime newest;
                try
                {
                    // A new folder is somebody tidying up, not a file arriving.
                    if (Directory.Exists(path))
                    {
                        _known.Add(name);
                        continue;
                    }
                    var info = new FileInfo(path);
                    size = info.Length;
                    newest = info.CreationTime > info.LastWriteTime ? info.CreationTime : info.LastWriteTime;
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException) { continue; }
                // Firefox puts the final name there first, empty, beside its
                // part-file. Not yet: the rename that finishes it changes
                // the folder again, and that look finds it whole.
                if (size == 0 || File.Exists(path + ".part") || File.Exists(path + ".crdownload"))
                {
                    _settling.Remove(name);
                    continue;
                }
                // Anything else is looked at twice: still growing, it is
                // still being written.
                if (!_settling.TryGetValue(name, out var last) || last != size)
                {
                    _settling[name] = size;
                    growing = true;
                    continue;
                }
                _settling.Remove(name);
                _known.Add(name);
                if (FileArrival.KindOf(kinds, kinds.Contains(FileKind.Screenshot), kinds.Contains(FileKind.Download),
                        (DateTime.Now - newest).TotalSeconds) is { } kind)
                    arrived = new FileArrival(kind, path, size);
            }
        }
        // Several at once — an archive unpacked, a batch saved: one message,
        // for the last of them.
        if (arrived is not null) onArrival(arrived);
        if (growing) Scan(after: 0.8);
    }
}

/// Asks GitHub about the followed repositories, now and then: three small
/// questions a repository. Through the `gh` command when it is installed and
/// signed in — it does the signing in itself, so Resonata never sees a token,
/// and private repositories work — and otherwise straight from
/// api.github.com without signing in, which only sees public ones and is
/// asked less often.
public sealed class GitHubWatcher
{
    /// Something worth saying happened in a followed repository. Called on the UI thread.
    public Action<NotchActivity>? OnEvent { get; set; }

    private DispatcherTimer? _timer;
    private IReadOnlyList<string> _repos = [];
    private Dictionary<string, GitHubSnapshot> _snapshots = new(StringComparer.OrdinalIgnoreCase);
    private bool _asking;

    /// Starts, stops or re-aims the asking, to match the settings.
    public void Apply(bool enabled, string text)
    {
        var wanted = enabled ? GitHubFeed.Repos(text) : [];
        if (wanted.SequenceEqual(_repos, StringComparer.OrdinalIgnoreCase)) return;
        _repos = wanted;
        _snapshots = _snapshots.Where(s => wanted.Contains(s.Key, StringComparer.OrdinalIgnoreCase))
            .ToDictionary(s => s.Key, s => s.Value, StringComparer.OrdinalIgnoreCase);
        _timer?.Stop();
        _timer = null;
        if (wanted.Count == 0) return;
        _timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(GitHubFeed.Interval(wanted.Count, GitHubClient.Gh is not null)) };
        _timer.Tick += (_, _) => Ask();
        _timer.Start();
        Ask();
    }

    private void Ask()
    {
        if (_asking || _repos.Count == 0) return;
        _asking = true;
        var repos = _repos;
        var before = new Dictionary<string, GitHubSnapshot>(_snapshots, StringComparer.OrdinalIgnoreCase);
        var dispatcher = Dispatcher.CurrentDispatcher;
        Task.Run(() =>
        {
            var results = new List<(string Repo, IReadOnlyList<NotchActivity> Events, GitHubSnapshot Snapshot)>();
            try
            {
                var me = GitHubClient.Me();
                foreach (var repo in repos)
                {
                    var commit = GitHubClient.Get($"repos/{repo}/commits?per_page=1") is { } c ? GitHubFeed.CommitFrom(c) : null;
                    var runs = GitHubClient.Get($"repos/{repo}/actions/runs?per_page=10") is { } r ? GitHubFeed.RunsFrom(r) : [];
                    var release = GitHubClient.Get($"repos/{repo}/releases?per_page=1") is { } l ? GitHubFeed.ReleaseFrom(l) : null;
                    // Nothing came back at all: offline, or no such
                    // repository. What was known stays known.
                    if (commit is null && runs.Count == 0 && release is null) continue;
                    var news = GitHubFeed.News(repo, before.GetValueOrDefault(repo), commit, runs, release, me);
                    results.Add((repo, news.Events, news.Snapshot));
                }
            }
            catch (Exception e) { Log.Write($"GitHub: {e.GetType().Name}: {e.Message}"); }
            dispatcher.BeginInvoke(() =>
            {
                _asking = false;
                foreach (var (repo, events, snapshot) in results)
                {
                    if (!_repos.Contains(repo, StringComparer.OrdinalIgnoreCase)) continue;
                    _snapshots[repo] = snapshot;
                    // One at a time; the tab shows one message.
                    if (events.Count > 0) OnEvent?.Invoke(events[0]);
                }
            });
        });
    }
}

/// The two ways of asking GitHub a question.
public static class GitHubClient
{
    /// The `gh` command, where it is installed.
    public static string? Gh { get; } = LocateGh();

    private static readonly object Gate = new();
    private static string? _login;
    private static bool _askedLogin;
    /// `gh` is there but isn't signed in: straight to the public address.
    private static volatile bool _ghRefused;

    private static readonly HttpClient Http = MakeHttp();

    private static HttpClient MakeHttp()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
        client.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
        client.DefaultRequestHeaders.UserAgent.ParseAdd($"Resonata/{Updater.CurrentVersion}");
        return client;
    }

    private static string? LocateGh()
    {
        var places = new List<string> { Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "GitHub CLI", "gh.exe") };
        places.AddRange((Environment.GetEnvironmentVariable("PATH") ?? "")
            .Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Select(folder => Path.Combine(folder, "gh.exe")));
        foreach (var file in places)
        {
            try { if (File.Exists(file)) return file; }
            catch (ArgumentException) { }
        }
        return null;
    }

    /// The user's own GitHub name, from `gh`; null without it. Asked once.
    public static string? Me()
    {
        lock (Gate)
        {
            if (_askedLogin) return _login;
            _askedLogin = true;
            var name = RunGh(["api", "user", "--jq", ".login"])?.Trim();
            _login = string.IsNullOrEmpty(name) ? null : name;
            return _login;
        }
    }

    /// The answer to `path` under api.github.com; null when there is none.
    public static string? Get(string path)
    {
        if (Gh is not null && !_ghRefused)
        {
            if (RunGh(["api", path]) is { } answer) return answer;
            // Not signed in is a failure every time; a repository that isn't
            // there is one too — the public address answers which.
            if (RunGh(["auth", "status"]) is null) _ghRefused = true;
            else return null;
        }
        try
        {
            using var response = Http.GetAsync("https://api.github.com/" + path).GetAwaiter().GetResult();
            return response.IsSuccessStatusCode ? response.Content.ReadAsStringAsync().GetAwaiter().GetResult() : null;
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or IOException)
        {
            return null;
        }
    }

    /// Runs `gh` and hands back what it printed; null if it failed or took
    /// longer than twenty seconds.
    private static string? RunGh(string[] arguments)
    {
        if (Gh is not { } gh) return null;
        var start = new ProcessStartInfo(gh)
        {
            UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = Path.GetTempPath(),
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
        };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        // Its answers are read by a program: no colours, no pager, no
        // "a new version is out", no questions.
        start.Environment["NO_COLOR"] = "1";
        start.Environment["GH_PAGER"] = "cat";
        start.Environment["GH_NO_UPDATE_NOTIFIER"] = "1";
        start.Environment["GH_PROMPT_DISABLED"] = "1";
        try
        {
            using var process = Process.Start(start);
            if (process is null) return null;
            process.StandardInput.Close();
            process.ErrorDataReceived += (_, _) => { };
            process.BeginErrorReadLine();
            var output = process.StandardOutput.ReadToEndAsync();
            if (!process.WaitForExit(20_000))
            {
                try { process.Kill(entireProcessTree: true); }
                catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception) { }
                return null;
            }
            return process.ExitCode == 0 && output.Wait(2000) ? output.Result : null;
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException or IOException)
        {
            return null;
        }
    }
}

/// One thing that was copied. `Text` for text, a link and a colour;
/// `Picture` whole, to be put back, with a small copy to show; `Files` for
/// files copied in Explorer.
public sealed record Clip(ClipKind Kind, string Text, BitmapSource? Picture, BitmapSource? Thumbnail, string? PictureHash,
    IReadOnlyList<string> Files, string? App, DateTime Date)
{
    public Guid Id { get; } = Guid.NewGuid();

    /// The same thing, copied again.
    public static bool Same(Clip a, Clip b) => a.Kind == b.Kind && a.Kind switch
    {
        ClipKind.Image => a.PictureHash == b.PictureHash,
        ClipKind.Files => a.Files.SequenceEqual(b.Files, StringComparer.OrdinalIgnoreCase),
        _ => a.Text == b.Text,
    };
}

/// The clipboard's page: the last things copied, newest first, each a click
/// away from being on the clipboard again. Windows counts the clipboard's
/// changes; that number is looked at a little more than once a second, and
/// only when it has moved is anything read. Kept in memory and nowhere
/// else — quitting Resonata forgets it all — and what a password manager
/// marks as not to be kept is never taken.
public sealed class ClipboardStore
{
    public static ClipboardStore Shared { get; } = new();

    /// Newest first.
    public IReadOnlyList<Clip> Clips { get; private set; } = [];
    /// The clip that is on the clipboard right now, if it is one of these.
    public Guid? Current { get; private set; }
    public event Action? Changed;

    private DispatcherTimer? _timer;
    private uint _lastChange;
    /// A clipboard another program still holds open is asked again, a few times.
    private int _retries;

    public void SetEnabled(bool enabled)
    {
        if (enabled && _timer is null)
        {
            // What is on the clipboard when the page is switched on isn't
            // history yet: only what is copied from here on.
            _lastChange = Native.GetClipboardSequenceNumber();
            _timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(750) };
            _timer.Tick += (_, _) => Look();
            _timer.Start();
        }
        else if (!enabled && _timer is not null)
        {
            _timer.Stop();
            _timer = null;
            Clear();
        }
    }

    public void Clear()
    {
        Clips = [];
        Current = null;
        Changed?.Invoke();
    }

    private void Look()
    {
        var change = Native.GetClipboardSequenceNumber();
        if (change == _lastChange) return;
        Clip? clip;
        try
        {
            clip = Read();
        }
        catch (Exception e) when (e is ExternalException or InvalidOperationException or OutOfMemoryException or NotSupportedException or IOException)
        {
            // Still held by the program that copied: once more next time.
            if (++_retries < 5) return;
            clip = null;
        }
        _retries = 0;
        _lastChange = change;
        if (clip is null)
        {
            if (Current is null) return;
            Current = null;
            Changed?.Invoke();
            return;
        }
        Take(clip);
    }

    /// Adds a clip, for the page — or shows it again at the front if the
    /// same thing is already there.
    public void Take(Clip clip)
    {
        Clips = ClipRules.Adding(clip, Clips, Clip.Same, c => c.Kind == ClipKind.Image);
        Current = Clips[0].Id;
        Changed?.Invoke();
    }

    /// Puts a clip back on the clipboard, and at the front of the page.
    public void Copy(Clip clip)
    {
        try
        {
            switch (clip.Kind)
            {
                case ClipKind.Image when clip.Picture is { } picture:
                    Clipboard.SetImage(picture);
                    break;
                case ClipKind.Files:
                    var files = new StringCollection();
                    files.AddRange(clip.Files.ToArray());
                    Clipboard.SetFileDropList(files);
                    break;
                default:
                    Clipboard.SetText(clip.Text);
                    break;
            }
        }
        catch (Exception e) when (e is ExternalException or InvalidOperationException or ArgumentException)
        {
            Log.Write($"could not copy again: {e.Message}");
            return;
        }
        // Our own writing isn't a new copying.
        _lastChange = Native.GetClipboardSequenceNumber();
        var moved = clip with { Date = DateTime.Now };
        Clips = ClipRules.Adding(moved, Clips.Where(c => c.Id != clip.Id), Clip.Same, c => c.Kind == ClipKind.Image);
        Current = Clips[0].Id;
        Changed?.Invoke();
    }

    private static Clip? Read()
    {
        if (Clipboard.GetDataObject() is not { } data) return null;
        int? history = null;
        if (data.GetDataPresent("CanIncludeInClipboardHistory") && data.GetData("CanIncludeInClipboardHistory") is MemoryStream stream && stream.Length >= 4)
            history = BitConverter.ToInt32(stream.ToArray(), 0);
        if (ClipRules.IsSecret(data.GetFormats(false), history)) return null;

        var app = FrontApp();
        if (Clipboard.ContainsFileDropList())
        {
            var files = Clipboard.GetFileDropList().Cast<string?>().Where(f => !string.IsNullOrEmpty(f)).Select(f => f!).ToList();
            if (files.Count > 0) return new Clip(ClipKind.Files, "", null, null, null, files, app, DateTime.Now);
        }
        if (Clipboard.ContainsText() && ClipRules.Classify(Clipboard.GetText()) is { } text)
            return new Clip(text.Kind, text.Text, null, null, null, [], app, DateTime.Now);
        if (Clipboard.ContainsImage() && Clipboard.GetImage() is { } image
            && image.PixelWidth > 0 && (long)image.PixelWidth * image.PixelHeight <= ClipRules.PicturePixels)
        {
            // A copy of our own: the clipboard's goes when the clipboard changes.
            var whole = new FormatConvertedBitmap(image, PixelFormats.Bgr32, null, 0);
            var stride = whole.PixelWidth * 4;
            var pixels = new byte[stride * whole.PixelHeight];
            whole.CopyPixels(pixels, stride, 0);
            var picture = BitmapSource.Create(whole.PixelWidth, whole.PixelHeight, 96, 96, PixelFormats.Bgr32, null, pixels, stride);
            picture.Freeze();
            var (width, height) = ClipRules.Fitted(picture.PixelWidth, picture.PixelHeight, 160, 160);
            var small = new TransformedBitmap(picture, new ScaleTransform(width / picture.PixelWidth, height / picture.PixelHeight));
            small.Freeze();
            return new Clip(ClipKind.Image, "", picture, small, Convert.ToHexString(SHA256.HashData(pixels)), [], app, DateTime.Now);
        }
        return null;
    }

    /// The app that was in front when it was copied; null for Resonata itself.
    private static string? FrontApp()
    {
        try
        {
            var window = Native.GetForegroundWindow();
            if (window == IntPtr.Zero) return null;
            Native.GetWindowThreadProcessId(window, out var pid);
            if (pid == 0 || pid == Environment.ProcessId) return null;
            using var process = Process.GetProcessById((int)pid);
            string? described = null;
            try { described = process.MainModule?.FileVersionInfo.FileDescription; }
            catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException) { }
            return string.IsNullOrWhiteSpace(described) ? process.ProcessName : described.Trim();
        }
        catch (Exception e) when (e is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            return null;
        }
    }
}
