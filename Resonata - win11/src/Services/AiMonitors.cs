using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Windows.Threading;

namespace Resonata;

/// Which app a session runs in, and its window to bring forward.
public static class HostApp
{
    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessBasicInformation
    {
        public IntPtr ExitStatus, Peb, AffinityMask, BasePriority;
        public UIntPtr Pid;
        public IntPtr ParentPid;
    }

    [DllImport("ntdll.dll")]
    private static extern int NtQueryInformationProcess(IntPtr process, int kind, ref ProcessBasicInformation info, int size, out int returned);

    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hwnd, int command);

    public static bool IsRunning(int pid)
    {
        try
        {
            using var process = Process.GetProcessById(pid);
            return !process.HasExited;
        }
        catch (ArgumentException) { return false; }
        // There, but not ours to look at.
        catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception) { return true; }
    }

    /// The first process up the tree from `pid` that has a window of its own:
    /// the terminal, the editor, Claude's desktop app. A session says its pid
    /// and nothing about its window, so this is as near as "where is it" gets.
    public static (string Name, IntPtr Window)? Of(int pid)
    {
        var current = pid;
        for (var i = 0; i < 16 && current > 4; i++)
        {
            try
            {
                using var process = Process.GetProcessById(current);
                if (process.MainWindowHandle != IntPtr.Zero) return (NameOf(process), process.MainWindowHandle);
                var info = new ProcessBasicInformation();
                if (NtQueryInformationProcess(process.Handle, 0, ref info, Marshal.SizeOf<ProcessBasicInformation>(), out _) != 0) return null;
                var parent = (int)info.ParentPid;
                if (parent == current) return null;
                current = parent;
            }
            catch (Exception e) when (e is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception)
            {
                return null;
            }
        }
        return null;
    }

    private static string NameOf(Process process)
    {
        try
        {
            if (process.MainModule?.FileVersionInfo.FileDescription is { Length: > 0 } description) return description;
        }
        catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception) { }
        return process.ProcessName;
    }

    /// Brings the app a session runs in to the front.
    public static void BringForward(int pid)
    {
        if (Of(pid) is not { } app) return;
        if (IsIconic(app.Window)) ShowWindow(app.Window, 9 /* restore */);
        Native.SetForegroundWindow(app.Window);
    }

    /// Runs a command without a window and hands back what it printed; null
    /// if it couldn't be run or took longer than twenty seconds.
    public static string? Run(string file, IEnumerable<string> arguments, string folder, Action<ProcessStartInfo>? prepare = null)
    {
        var start = new ProcessStartInfo(file)
        {
            UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = folder,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
        };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        prepare?.Invoke(start);
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
                try { process.Kill(entireProcessTree: true); } catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception) { }
                return null;
            }
            return output.Wait(2000) ? output.Result : null;
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException or IOException)
        {
            Log.Write($"could not run {Path.GetFileName(file)}: {e.Message}");
            return null;
        }
    }
}

/// A session as a monitor reads it, before it is compared with the last look.
public sealed record SeenSession(string Key, int Pid, string Name, AiState State, string? Wants);

/// What Claude Code's and Vibe's monitors share: a look every second at the
/// sessions, off the UI thread, a message when one stops to ask or finishes,
/// and the limits asked for now and then.
public abstract class AiMonitor
{
    /// A session has stopped to ask something, or has finished.
    public Action<NotchActivity>? OnEvent { get; set; }

    private DispatcherTimer? _timer;
    private Dictionary<string, (AiState State, DateTime? Since)> _known = [];
    private Dictionary<string, string?> _apps = [];
    private DateTime? _lastAsked;
    private bool _asking, _looking;

    /// How often the limits are asked for: they only move while something
    /// is working. Each asking starts a process, a second or so.
    private const double BusyInterval = 120, QuietInterval = 900;

    protected static string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    protected bool IsOn => _timer is not null;

    protected abstract string Tool { get; }
    /// The tool's folder in the user's profile; without it, it isn't on this PC.
    protected abstract string Folder { get; }
    /// Off the UI thread.
    protected abstract IReadOnlyList<SeenSession> ReadSessions();
    protected abstract void Publish(AiState state, string? session, string? wants, IReadOnlyList<AiSession> sessions);
    protected abstract void Clear();
    /// Off the UI thread: the limits, or null when they couldn't be read.
    protected abstract object? ReadUsage();
    protected abstract void TakeUsage(object usage);
    protected virtual bool RolledOver(DateTime now) => false;

    public void SetEnabled(bool enabled)
    {
        if (enabled && _timer is null)
        {
            if (!Directory.Exists(Path.Combine(Home, Folder))) return;
            _timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
            _timer.Tick += (_, _) => Look();
            _timer.Start();
            Publish(AiState.Idle, null, null, []);
            Look();
        }
        else if (!enabled && _timer is not null)
        {
            _timer.Stop();
            _timer = null;
            _known = [];
            Clear();
        }
    }

    /// Has the session files read; a look still under way is not started twice.
    private void Look()
    {
        if (_looking) return;
        _looking = true;
        var dispatcher = Dispatcher.CurrentDispatcher;
        Task.Run(() =>
        {
            IReadOnlyList<SeenSession> records;
            // Another program's files, in whatever state it left them: a look
            // that fails is one look lost, never the end of looking.
            try { records = ReadSessions(); }
            catch (Exception e) { Log.Write($"{Tool}: could not read the sessions: {e.GetType().Name}: {e.Message}"); records = []; }
            dispatcher.BeginInvoke(() =>
            {
                _looking = false;
                if (IsOn) Take(records);
            });
        });
    }

    private void Take(IReadOnlyList<SeenSession> records)
    {
        var now = DateTime.Now;
        var events = new List<NotchActivity>();
        var seen = new Dictionary<string, (AiState State, DateTime? Since)>();
        var finished = false;
        foreach (var record in records)
        {
            (AiState State, DateTime? Since)? before = _known.TryGetValue(record.Key, out var b) ? b : null;
            seen[record.Key] = (record.State, record.State == AiState.Working ? before?.Since ?? now : null);
            var worked = before?.Since is { } since ? (now - since).TotalSeconds : 0;
            if (AiSummary.Event(Tool, before?.State, record.State, record.Name, record.Wants, record.Pid, worked) is { } e) events.Add(e);
            if (before?.State == AiState.Working && record.State != AiState.Working) finished = true;
        }
        _known = seen;

        var summary = AiSummary.Of(records.Select(r => (r.State, r.Name, r.Wants)));
        var apps = new Dictionary<string, string?>();
        var sessions = new List<AiSession>();
        foreach (var record in records)
        {
            // Looked up once per session: it never moves to another app.
            var app = _apps.TryGetValue(record.Key, out var known) ? known : HostApp.Of(record.Pid)?.Name;
            apps[record.Key] = app;
            sessions.Add(new AiSession(record.Pid, record.Name, record.State, app, record.Key));
        }
        _apps = apps;
        Publish(summary.State, summary.Session, summary.Wants, sessions);

        // One at a time: a session waiting for you is said before one that
        // has merely finished.
        if ((events.FirstOrDefault(e => e is NotchActivity.AiWaiting) ?? events.FirstOrDefault()) is { } said) OnEvent?.Invoke(said);

        // The limits: just after a piece of work ends, when the window they
        // were read for has rolled over, and otherwise now and then.
        RefreshUsage(finished || RolledOver(now) ? 20 : summary.State != AiState.Idle ? BusyInterval : QuietInterval);
    }

    /// Asks for the limits, unless they were asked for less than `age` seconds ago.
    public void RefreshUsage(double age = 0)
    {
        if (!IsOn || _asking) return;
        if (_lastAsked is { } last && (DateTime.Now - last).TotalSeconds < age) return;
        _asking = true;
        _lastAsked = DateTime.Now;
        var dispatcher = Dispatcher.CurrentDispatcher;
        Task.Run(() =>
        {
            object? usage = null;
            try { usage = ReadUsage(); }
            catch (Exception e) { Log.Write($"{Tool}: could not read the limits: {e.GetType().Name}: {e.Message}"); }
            dispatcher.BeginInvoke(() =>
            {
                _asking = false;
                // A failed asking keeps the last answer rather than emptying the ring.
                if (usage is not null && IsOn) TakeUsage(usage);
            });
        });
    }
}

/// Claude Code: each running session keeps a small file in
/// `~/.claude/sessions/` with its state, and `claude /usage` prints the
/// limits, the same text you get by typing /usage in a session.
public sealed class ClaudeMonitor(PanelModel model) : AiMonitor
{
    private ClaudeUsage? _usage;

    protected override string Tool => "Claude Code";
    protected override string Folder => ".claude";

    /// Where `claude /usage` is run from: a folder of its own, so the run
    /// never shows up as a session in a project of yours.
    private static string Scratch => Path.Combine(Paths.Data, "claude-usage");

    protected override IReadOnlyList<SeenSession> ReadSessions()
    {
        var directory = Path.Combine(Home, Folder, "sessions");
        if (!Directory.Exists(directory)) return [];
        var ours = Path.GetFullPath(Scratch);
        var records = new List<SeenSession>();
        foreach (var file in Directory.GetFiles(directory, "*.json").Order(StringComparer.Ordinal))
        {
            string text;
            try { text = File.ReadAllText(file); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { continue; }
            // A session that was killed leaves its file behind, still saying "busy".
            if (ClaudeSessionRecord.FromJson(text) is not { IsHelper: false } record
                || string.Equals(Path.GetFullPath(record.Cwd), ours, StringComparison.OrdinalIgnoreCase)
                || !HostApp.IsRunning(record.Pid)) continue;
            records.Add(new SeenSession(record.Pid.ToString(), record.Pid, record.Name, record.State, record.Wants));
        }
        return records;
    }

    protected override void Publish(AiState state, string? session, string? wants, IReadOnlyList<AiSession> sessions) =>
        model.Claude = new ClaudeStatus(state, session, wants, _usage) { Sessions = sessions };

    protected override void Clear() => model.Claude = null;

    protected override bool RolledOver(DateTime now) => _usage?.SessionResets is { } resets && resets < now;

    protected override void TakeUsage(object usage)
    {
        _usage = (ClaudeUsage)usage;
        if (model.Claude is { } status) model.Claude = status with { Usage = _usage };
    }

    protected override object? ReadUsage()
    {
        if (LocateCli() is not { } cli) return null;
        Directory.CreateDirectory(Scratch);
        // Print and leave: no transcript kept, none of your MCP servers started.
        string[] arguments = ["--print", "--no-session-persistence", "--strict-mcp-config", "/usage"];
        var batch = cli.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase);
        var text = HostApp.Run(batch ? Environment.GetEnvironmentVariable("ComSpec") ?? "cmd.exe" : cli,
            batch ? ["/d", "/c", cli, .. arguments] : arguments, Scratch, start =>
            {
                // Started from inside a Claude Code session, Resonata would
                // hand that session's own settings on to this one.
                foreach (var name in start.Environment.Keys.Where(k => k.StartsWith("CLAUDE_CODE_", StringComparison.OrdinalIgnoreCase)
                             || k.Equals("CLAUDECODE", StringComparison.OrdinalIgnoreCase)).ToList())
                    start.Environment.Remove(name);
            });
        return text is null ? null : ClaudeUsage.Parse(text);
    }

    /// Where `claude` is installed, trying the usual places and then the PATH.
    public static string? LocateCli()
    {
        var roaming = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        string[] usual =
        [
            Path.Combine(Home, ".local", "bin", "claude.exe"), Path.Combine(Home, ".claude", "local", "claude.exe"),
            Path.Combine(roaming, "npm", "claude.cmd"), Path.Combine(Home, ".bun", "bin", "claude.exe"),
        ];
        var along = (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .SelectMany(folder => new[] { Path.Combine(folder, "claude.exe"), Path.Combine(folder, "claude.cmd") });
        foreach (var file in usual.Concat(along))
        {
            try { if (File.Exists(file)) return file; }
            catch (ArgumentException) { }
        }
        return null;
    }
}

/// Mistral Vibe: a running session holds a lease in
/// `~/.vibe/logs/session/active/` and writes what it does to its journal
/// under `…/unified/<session>/`; the month's allowance is what Vibe shows in
/// its own status bar, asked for the way Vibe asks: by Vibe's Python, with
/// the sign-in Vibe keeps. Resonata never sees the key.
public sealed class VibeMonitor(PanelModel model) : AiMonitor
{
    private sealed class Tail
    {
        public string File = "";
        public long Offset;
        public VibeJournal Journal = new();
    }

    private VibeUsage? _usage;
    // Both only ever touched by the one look that is under way.
    private Dictionary<string, Tail> _tails = [];
    private Dictionary<string, (string? Folder, bool IsChild)> _metas = [];

    protected override string Tool => "Vibe";
    protected override string Folder => ".vibe";

    private static string Root => Path.Combine(Home, ".vibe", "logs", "session");

    protected override IReadOnlyList<SeenSession> ReadSessions()
    {
        var active = Path.Combine(Root, "active");
        if (!Directory.Exists(active))
        {
            _tails = [];
            return [];
        }
        var records = new List<SeenSession>();
        foreach (var file in Directory.GetFiles(active, "*.lock.json").Order(StringComparer.Ordinal))
        {
            // The lease beside the lock: which session, held by which
            // process. A session that was killed leaves it behind.
            if (Lease(file) is not { } lease || !HostApp.IsRunning(lease.Pid)) continue;
            var folder = Path.Combine(Root, "unified", lease.Id);
            var meta = Meta(lease.Id, folder);
            // A session another session started to do part of its work.
            if (meta?.IsChild == true) continue;
            var journal = Journal(lease.Id, folder);
            records.Add(new SeenSession(lease.Id, lease.Pid, VibeJournal.Name(journal.Title, journal.TitleGiven, meta?.Folder),
                journal.State, journal.Wants));
        }
        var live = records.Select(r => r.Key).ToHashSet();
        _tails = _tails.Where(t => live.Contains(t.Key)).ToDictionary(t => t.Key, t => t.Value);
        _metas = _metas.Where(m => live.Contains(m.Key)).ToDictionary(m => m.Key, m => m.Value);
        return records;
    }

    private static (string Id, int Pid)? Lease(string file)
    {
        try
        {
            using var document = JsonDocument.Parse(File.ReadAllText(file));
            var root = document.RootElement;
            if (root.ValueKind == JsonValueKind.Object
                && root.TryGetProperty("session_id", out var id) && id.ValueKind == JsonValueKind.String
                && id.GetString() is { } session && VibeJournal.IsSessionId(session)
                && root.TryGetProperty("process_id", out var pid) && pid.TryGetInt32(out var process) && process > 0)
                return (session, process);
        }
        catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException) { }
        return null;
    }

    /// Where the session runs, read once: it is written when the session
    /// starts and doesn't move.
    private (string? Folder, bool IsChild)? Meta(string id, string folder)
    {
        if (_metas.TryGetValue(id, out var known)) return known;
        try
        {
            using var document = JsonDocument.Parse(File.ReadAllText(Path.Combine(folder, "meta.json")));
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return null;
            string? where = root.TryGetProperty("environment", out var environment) && environment.ValueKind == JsonValueKind.Object
                && environment.TryGetProperty("working_directory", out var directory) && directory.ValueKind == JsonValueKind.String
                ? directory.GetString() : null;
            var meta = (where, root.TryGetProperty("parent_session_id", out var parent) && parent.ValueKind == JsonValueKind.String);
            _metas[id] = meta;
            return meta;
        }
        catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException) { return null; }
    }

    /// The newest journal file, read from where the last look left off:
    /// journals grow to megabytes.
    private VibeJournal Journal(string id, string folder)
    {
        var directory = Path.Combine(folder, "journal");
        var tail = _tails.TryGetValue(id, out var known) ? known : new Tail();
        // Named by the step each starts at, zero-padded: the last by name is the newest.
        var file = Directory.Exists(directory)
            ? Directory.GetFiles(directory, "*.jsonl").Select(Path.GetFileName).Max(StringComparer.Ordinal) : null;
        if (file is null) return tail.Journal;
        if (tail.File != file)
        {
            tail.File = file;
            tail.Offset = 0;
            tail.Journal.StartOver();
        }
        try
        {
            using var stream = new FileStream(Path.Combine(directory, file), FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            if (stream.Length < tail.Offset)
            {
                // Shorter than what was read: written afresh.
                tail.Offset = 0;
                tail.Journal.StartOver();
            }
            if (stream.Length > tail.Offset)
            {
                stream.Seek(tail.Offset, SeekOrigin.Begin);
                var data = new byte[stream.Length - tail.Offset];
                var read = stream.ReadAtLeast(data, data.Length, throwOnEndOfStream: false);
                // Up to the last whole line; one half written waits a second.
                var end = Array.LastIndexOf(data, (byte)'\n', read - 1);
                if (end >= 0)
                {
                    tail.Journal.Read(Encoding.UTF8.GetString(data, 0, end));
                    tail.Offset += end + 1;
                }
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        _tails[id] = tail;
        return tail.Journal;
    }

    protected override void Publish(AiState state, string? session, string? wants, IReadOnlyList<AiSession> sessions) =>
        model.Vibe = new VibeStatus(state, session, wants, _usage) { Sessions = sessions };

    protected override void Clear() => model.Vibe = null;

    protected override void TakeUsage(object usage)
    {
        _usage = (VibeUsage)usage;
        if (model.Vibe is { } status) model.Vibe = status with { Usage = _usage };
    }

    protected override object? ReadUsage()
    {
        if (LocatePython() is not { } python) return null;
        // Isolated: nothing but Vibe's own packages on its path, and not the
        // folder it happens to be run from.
        var text = HostApp.Run(python, ["-I", "-c", Helper], Path.GetTempPath());
        return text is null ? null : VibeUsage.Parse(text);
    }

    /// The Python Vibe is installed into: in the usual places of `uv tool`
    /// and `pipx`, or the one its `vibe` launcher names.
    public static string? LocatePython()
    {
        var roaming = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string[] usual =
        [
            Path.Combine(roaming, "uv", "tools", "mistral-vibe", "Scripts", "python.exe"),
            Path.Combine(Home, "pipx", "venvs", "mistral-vibe", "Scripts", "python.exe"),
            Path.Combine(local, "pipx", "pipx", "venvs", "mistral-vibe", "Scripts", "python.exe"),
        ];
        foreach (var python in usual) if (File.Exists(python)) return python;
        var launcher = Path.Combine(Home, ".local", "bin", "vibe.exe");
        try
        {
            if (!File.Exists(launcher)) return null;
            // A launcher made by pip carries "#!…python.exe" near its end.
            using var stream = new FileStream(launcher, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            var take = (int)Math.Min(stream.Length, 64 * 1024);
            stream.Seek(-take, SeekOrigin.End);
            var data = new byte[take];
            var read = stream.ReadAtLeast(data, take, throwOnEndOfStream: false);
            return VibeJournal.Interpreter(Encoding.Latin1.GetString(data, 0, read)) is { } path && File.Exists(path) ? path : null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
    }

    /// What Vibe's Python is given to run. It asks Mistral's billing for the
    /// Vibe allowance through the code behind Vibe's own status bar, and
    /// prints one line (see `VibeUsage.Parse`). Should that code have moved
    /// in a newer Vibe, the same two addresses are asked directly, with the
    /// key Vibe looks up for itself. Nothing is printed on any failure.
    public const string Helper = """
        import asyncio, json, logging
        logging.disable(logging.CRITICAL)
        BASE = "https://api.mistral.ai/v1"
        KEY = "MISTRAL_API_KEY"

        def say(budget, plan):
            if not budget or (budget.get("initial_budget") or 0) <= 0:
                return False
            print(json.dumps({"percent": budget.get("usage_percentage"), "resets": budget.get("reset_at"),
                              "payg": bool(budget.get("payg_enabled")), "plan": plan}))
            return True

        def vibes_own():
            from vibe.app_server._billing import HttpBillingGateway
            from vibe.core.platform_auth._mistral import api_key_credentials
            read = asyncio.run(HttpBillingGateway().read(
                api_base=BASE, credentials=api_key_credentials(KEY), with_budget=True))
            detail = read.budget.vibe_budget if read.budget else None
            plan = read.subscription.plan_name if read.subscription else None
            return say(detail.model_dump() if detail else None, plan)

        def direct():
            import urllib.request
            from vibe.utils.api_keys import resolve_api_key
            key = resolve_api_key(KEY)
            if not key:
                return False
            def get(path):
                request = urllib.request.Request(BASE + "/billing/" + path,
                                                 headers={"Authorization": "Bearer " + key})
                with urllib.request.urlopen(request, timeout=8) as answer:
                    return json.load(answer)
            budget = get("budget").get("vibe_budget")
            try:
                plan = get("subscription").get("plan_name")
            except Exception:
                plan = None
            return say(budget, plan)

        for way in (vibes_own, direct):
            try:
                if way():
                    break
            except Exception:
                pass
        """;
}
