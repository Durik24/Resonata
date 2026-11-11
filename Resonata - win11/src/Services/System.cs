using System.Diagnostics;
using System.Net.Http;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;
using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;
using IcalCalendar = Ical.Net.Calendar;
using IcalDateTime = Ical.Net.DataTypes.CalDateTime;
using IcalEvent = Ical.Net.CalendarComponents.CalendarEvent;
using Forms = System.Windows.Forms;

namespace Resonata;

public readonly record struct Battery(int Percent, bool Charging, bool OnPower)
{
    public static Battery? Read()
    {
        var status = Forms.SystemInformation.PowerStatus;
        if (status.BatteryChargeStatus.HasFlag(Forms.BatteryChargeStatus.NoSystemBattery)) return null;
        if (status.BatteryChargeStatus == Forms.BatteryChargeStatus.Unknown) return null;
        var plugged = status.PowerLineStatus == Forms.PowerLineStatus.Online;
        return new Battery(Math.Clamp((int)Math.Round(status.BatteryLifePercent * 100), 0, 100),
            plugged || status.BatteryChargeStatus.HasFlag(Forms.BatteryChargeStatus.Charging), plugged);
    }

    public bool IsLow => !Charging && Percent <= 20;
    public string Symbol => Glyph.Battery(Percent, Charging);
}

public sealed class PowerWatcher
{
    private readonly DispatcherTimer _poll = new() { Interval = TimeSpan.FromSeconds(60) };
    private bool? _wasOnPower;
    private int? _lastPercent;

    public Action<Battery>? OnPlugIn { get; set; }
    public Action<Battery>? OnLow { get; set; }

    public void Start()
    {
        // No battery, nothing to watch: a desktop PC does no work here at all.
        if (Battery.Read() is not { } now) return;
        _wasOnPower = now.OnPower;
        _lastPercent = now.Percent;
        SystemEvents.PowerModeChanged += (_, e) =>
        {
            if (e.Mode == PowerModes.StatusChange) _poll.Dispatcher.BeginInvoke(Changed);
        };
        // The charge ticking down doesn't reliably raise that event.
        _poll.Tick += (_, _) => Changed();
        _poll.Start();
    }

    private void Changed()
    {
        if (Battery.Read() is not { } battery) return;
        if (PowerRules.IsPlugIn(_wasOnPower, battery.OnPower)) OnPlugIn?.Invoke(battery);
        if (!battery.OnPower && PowerRules.CrossesWarning(_lastPercent, battery.Percent)) OnLow?.Invoke(battery);
        _wasOnPower = battery.OnPower;
        _lastPercent = battery.Percent;
    }
}

/// Tells Resonata when sound moves to Bluetooth headphones. Only the output
/// device's name and kind are read; nothing is recorded.
public sealed class OutputWatcher : IMMNotificationClient
{
    private static readonly PropertyKey EnumeratorName =
        new(new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), 24);

    private readonly Dispatcher _dispatcher = Dispatcher.CurrentDispatcher;
    private MMDeviceEnumerator? _enumerator;
    private string? _last;

    public Action<string>? OnHeadphones { get; set; }

    public void Start()
    {
        try
        {
            _enumerator = new MMDeviceEnumerator();
            _last = _enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia).ID;
        }
        catch (COMException e)
        {
            Log.Write($"no default output: {e.Message}");
        }
        _enumerator?.RegisterEndpointNotificationCallback(this);
    }

    public void OnDefaultDeviceChanged(DataFlow flow, Role role, string defaultDeviceId)
    {
        if (flow != DataFlow.Render || role != Role.Multimedia) return;
        // Off this callback: asking the device anything from inside it can deadlock.
        _dispatcher.BeginInvoke(() => Changed(defaultDeviceId));
    }

    private void Changed(string id)
    {
        if (id == _last || _enumerator is null) return;
        _last = id;
        try
        {
            var device = _enumerator.GetDevice(id);
            var bus = device.Properties.Contains(EnumeratorName) ? device.Properties[EnumeratorName].Value as string : null;
            if (bus?.StartsWith("BTH", StringComparison.OrdinalIgnoreCase) == true)
                OnHeadphones?.Invoke(device.FriendlyName);
        }
        catch (COMException e)
        {
            Log.Write($"output device unreadable: {e.Message}");
        }
    }

    public void OnDeviceStateChanged(string deviceId, DeviceState newState) { }
    public void OnDeviceAdded(string pwstrDeviceId) { }
    public void OnDeviceRemoved(string deviceId) { }
    public void OnPropertyValueChanged(string pwstrDeviceId, PropertyKey key) { }
}

/// Spotify's own volume: the slider in Spotify's window, the one the Mac
/// reaches through AppleScript's `sound volume`. So Spotify's slider moves
/// with it, the rest of the PC's sound stays where it is, and it also works
/// for a phone or a speaker Spotify plays on through Connect.
///
/// Spotify has no way in on Windows but the one screen readers use, UI
/// Automation, which works with its window minimised too, not closed. When
/// that window can't be reached, Spotify's level in Windows' volume mixer.
public static class SpotifyVolume
{
    private static readonly SemaphoreSlim Gate = new(1, 1);

    public static double? LastKnown { get; set; }
    public static double? BeforeMute { get; set; }

    /// Spotify's own slider takes tenths: anything else lands on the nearest.
    /// True when the last look found it, so the knob here lands there too.
    public static bool InTenths { get; private set; }

    /// Found afresh each time the panel opens, then kept for the drag.
    private static RangeValuePattern? _slider;

    /// The speaker click: down to 0 from any level, and back to the level before.
    public static double ToggledMute(double volume, double? before) =>
        volume >= 1 ? 0 : before is >= 1 ? before.Value : 50;

    /// The level `volume` will really be: Spotify's slider rounds to tenths.
    public static double Snap(double volume, bool tenths) =>
        Math.Clamp(tenths ? Math.Round(volume / 10, MidpointRounding.AwayFromZero) * 10 : Math.Round(volume), 0, 100);

    /// Which of the sliders in Spotify's window is its volume: the one from 0
    /// to 1. The others are the place in the song (0 to its length in ms) and
    /// the side panels' widths. Their names are in Spotify's language.
    public static int? PickVolume(IReadOnlyList<(double Minimum, double Maximum)> ranges)
    {
        for (var i = 0; i < ranges.Count; i++)
            if (ranges[i] is (0d, 1d)) return i;
        return null;
    }

    /// Spotify's volume slider, or null when no Spotify window has one.
    private static RangeValuePattern? AppSlider()
    {
        if (_slider is not null) return _slider;
        var sliders = new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Slider);
        foreach (var process in Process.GetProcessesByName("Spotify"))
        {
            using (process)
            {
                IntPtr window;
                try
                {
                    window = process.MainWindowHandle;
                }
                catch (InvalidOperationException)
                {
                    continue; // That process has just gone.
                }
                if (window == IntPtr.Zero) continue;

                var patterns = new List<RangeValuePattern>();
                var ranges = new List<(double, double)>();
                foreach (AutomationElement slider in AutomationElement.FromHandle(window).FindAll(TreeScope.Descendants, sliders))
                {
                    if (!slider.TryGetCurrentPattern(RangeValuePattern.Pattern, out var found)) continue;
                    var range = (RangeValuePattern)found;
                    patterns.Add(range);
                    ranges.Add((range.Current.Minimum, range.Current.Maximum));
                }
                if (PickVolume(ranges) is { } index) return _slider = patterns[index];
            }
        }
        return null;
    }

    private static bool IsGone(Exception e) =>
        e is ElementNotAvailableException or ElementNotEnabledException or InvalidOperationException
            or ArgumentException or COMException;

    /// Spotify's sessions on every output, the one playing first. Not only the
    /// default output's: Spotify can be set to play on another one. None while
    /// Spotify hasn't played on this PC yet, or plays elsewhere via Connect.
    private static List<SimpleAudioVolume> Sessions()
    {
        var found = new List<(SimpleAudioVolume Volume, bool Active)>();
        using var enumerator = new MMDeviceEnumerator();
        foreach (var device in enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active))
        {
            var manager = device.AudioSessionManager;
            manager.RefreshSessions();
            var sessions = manager.Sessions;
            for (var i = 0; i < sessions.Count; i++)
            {
                var session = sessions[i];
                try
                {
                    using var process = Process.GetProcessById((int)session.GetProcessID);
                    if (process.ProcessName.Equals("Spotify", StringComparison.OrdinalIgnoreCase))
                        found.Add((session.SimpleAudioVolume, session.State == AudioSessionState.AudioSessionStateActive));
                }
                catch (ArgumentException)
                {
                    // That process has just gone.
                }
            }
        }
        return found.OrderByDescending(s => s.Active).Select(s => s.Volume).ToList();
    }

    /// 0–100, or null with no Spotify to ask. Spotify's slider while its window
    /// is minimised can be a step behind what Spotify was last told, since a
    /// window not being drawn passes changes on late; it catches up when used.
    public static Task<double?> ReadAsync() => Task.Run<double?>(async () =>
    {
        await Gate.WaitAsync();
        try
        {
            _slider = null;
            try
            {
                if (AppSlider() is { } slider)
                {
                    InTenths = true;
                    return Math.Round(slider.Current.Value * 100);
                }
            }
            catch (Exception e) when (IsGone(e))
            {
                _slider = null;
                Log.Write($"Spotify's slider unreadable: {e.Message}");
            }
            InTenths = false;
            var first = Sessions().FirstOrDefault();
            return first is null ? null : first.Mute ? 0 : Math.Round(first.Volume * 100);
        }
        catch (COMException e)
        {
            Log.Write($"Spotify volume unreadable: {e.Message}");
            return null;
        }
        finally
        {
            Gate.Release();
        }
    });

    /// Drops any older value still waiting: a drag sends dozens a second.
    public static void Set(int volume)
    {
        Interlocked.Exchange(ref _pendingBoxed, Math.Clamp(volume, 0, 100) + 1);
        _ = Task.Run(async () =>
        {
            await Gate.WaitAsync();
            try
            {
                var value = Interlocked.Exchange(ref _pendingBoxed, 0) - 1;
                if (value < 0) return;
                try
                {
                    if (AppSlider() is { } slider)
                    {
                        var level = Snap(value, tenths: true) / 100;
                        slider.SetValue(level);
                        _lastLevel = level;
                        _ = SettleAsync(Interlocked.Increment(ref _burst));
                        return;
                    }
                }
                catch (Exception e) when (IsGone(e))
                {
                    // Spotify redrew its bar or closed: looked for again next time.
                    _slider = null;
                    Log.Write($"Spotify's slider failed: {e.Message}");
                    return;
                }
                foreach (var session in Sessions())
                {
                    session.Volume = value / 100f;
                    session.Mute = false;
                }
            }
            catch (COMException e)
            {
                Log.Write($"Spotify volume failed: {e.Message}");
            }
            finally
            {
                Gate.Release();
            }
        });
    }

    // 0 means nothing waiting, otherwise the level plus one.
    private static int _pendingBoxed;

    /// Counts the levels sent to Spotify's slider, so only the last one settles.
    private static int _burst;
    private static double _lastLevel;

    /// Once the levels stop coming, the last one once more. A minimised
    /// Spotify passes a change on only when the next thing is asked of it, so
    /// without this the panel read the level before last when it next opened.
    /// The same level again changes nothing in Spotify.
    private static async Task SettleAsync(int burst)
    {
        await Task.Delay(600);
        if (burst != Volatile.Read(ref _burst)) return;
        await Gate.WaitAsync();
        try
        {
            if (burst == _burst && _slider is { } slider) slider.SetValue(_lastLevel);
        }
        catch (Exception e) when (IsGone(e))
        {
            _slider = null;
        }
        finally
        {
            Gate.Release();
        }
    }
}

public sealed class HotKey
{
    private const int Id = 0x524E;
    private IntPtr _hwnd;

    public Action? Pressed { get; set; }

    public void Attach(IntPtr hwnd) => _hwnd = hwnd;

    /// False when another app already has that combination.
    public bool Apply(HotKeyChoice choice)
    {
        Native.UnregisterHotKey(_hwnd, Id);
        const uint alt = 1, control = 2, shift = 4, noRepeat = 0x4000;
        (uint mods, uint key)? combo = choice switch
        {
            HotKeyChoice.CtrlShiftSpace => (control | shift, 0x20),
            HotKeyChoice.AltShiftN => (alt | shift, 0x4E),
            _ => null,
        };
        if (combo is not { } c) return true;
        var ok = Native.RegisterHotKey(_hwnd, Id, c.mods | noRepeat, c.key);
        if (!ok) Log.Write($"shortcut {choice} unavailable");
        return ok;
    }

    public static string Title(HotKeyChoice choice) => choice switch
    {
        HotKeyChoice.CtrlShiftSpace => L.T("Ctrl + Shift + Space", "Ctrl + Shift + Mezerník"),
        HotKeyChoice.AltShiftN => "Alt + Shift + N",
        _ => L.T("Off", "Vypnuto"),
    };
}

/// A calendar read from `.ics` links: Windows has no calendar a desktop app can
/// simply ask, and a private link works the same for Google and Outlook.
public sealed class CalendarStore
{
    public static CalendarStore Shared { get; } = new();

    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(20) };
    private readonly DispatcherTimer _refresh = new() { Interval = TimeSpan.FromMinutes(15) };
    private DateTime _lastLoad;
    private bool _demo;
    private int _generation;

    public event Action? Changed;
    public IReadOnlyList<CalendarEvent> Events { get; private set; } = [];
    public bool Failed { get; private set; }

    public static bool IsConnected => Urls.Length > 0;

    private static string[] Urls => Settings.Current.CalendarUrls
        .Split('\n', '\r', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

    public void Start()
    {
        _refresh.Tick += (_, _) => _ = ReloadAsync();
        _refresh.Start();
        _ = ReloadAsync();
    }

    /// When the panel opens; no need to fetch more than once a minute for that.
    public void ReloadIfStale()
    {
        if (DateTime.Now - _lastLoad > TimeSpan.FromMinutes(1)) _ = ReloadAsync();
    }

    public void ShowDemo(IReadOnlyList<CalendarEvent> events)
    {
        _demo = true;
        Events = events;
        Changed?.Invoke();
    }

    public bool IsDemo => _demo;

    public async Task ReloadAsync()
    {
        if (_demo) return;
        _lastLoad = DateTime.Now;
        var generation = ++_generation;
        var urls = Urls;
        var failed = false;
        var events = new List<CalendarEvent>();
        var days = CalendarRules.Days(DateTime.Now);
        foreach (var url in urls)
        {
            try
            {
                var address = url.StartsWith("webcal://", StringComparison.OrdinalIgnoreCase)
                    ? "https://" + url["webcal://".Length..]
                    : url;
                var text = await Http.GetStringAsync(address);
                events.AddRange(await Task.Run(() => Parse(text, days[0], days[^1].AddDays(1))));
            }
            catch (Exception e) when (e is HttpRequestException or TaskCanceledException or UriFormatException
                                          or InvalidOperationException or FormatException or ArgumentException)
            {
                // The address itself is left out of the log: it's a private link.
                Log.Write($"calendar not loaded: {e.GetType().Name}");
                failed = true;
            }
        }
        if (generation != _generation) return;
        Failed = failed;
        // A failed fetch keeps what we had: being offline shouldn't empty the week.
        if (!failed || events.Count > 0 || urls.Length == 0)
            Events = events.OrderBy(e => e.IsAllDay ? 0 : 1).ThenBy(e => e.Start).ToList();
        Changed?.Invoke();
    }

    public static IEnumerable<CalendarEvent> Parse(string ics, DateTime from, DateTime to)
    {
        var calendar = IcalCalendar.Load(ics) ?? throw new FormatException("empty calendar");
        var start = new IcalDateTime(from.ToUniversalTime(), "UTC");
        var results = new List<CalendarEvent>();
        foreach (var occurrence in calendar.GetOccurrences(start))
        {
            var period = occurrence.Period;
            var begin = period.StartTime.HasTime ? period.StartTime.AsUtc.ToLocalTime() : period.StartTime.Value;
            if (begin >= to) break;
            if (occurrence.Source is not IcalEvent e) continue;
            var endValue = period.EffectiveEndTime ?? period.StartTime;
            var end = endValue.HasTime ? endValue.AsUtc.ToLocalTime() : endValue.Value;
            results.Add(new CalendarEvent($"{e.Uid}-{begin:O}", e.Summary ?? "", begin, end, !period.StartTime.HasTime));
        }
        return results;
    }
}

public sealed class MeetingReminder
{
    private static readonly TimeSpan Lead = TimeSpan.FromMinutes(5);
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(60) };
    private readonly HashSet<string> _reminded = [];

    public Action<CalendarEvent>? OnReminder { get; set; }

    public void Start()
    {
        _timer.Tick += (_, _) => Check();
        _timer.Start();
    }

    private void Check()
    {
        if (!Settings.Current.MeetingReminder) return;
        var next = CalendarRules.Due(CalendarStore.Shared.Events, DateTime.Now, Lead)
            .FirstOrDefault(e => !_reminded.Contains(e.Id));
        if (next is null) return;
        _reminded.Add(next.Id);
        OnReminder?.Invoke(next);
    }
}

public abstract record UpdateState
{
    public sealed record Idle : UpdateState;
    public sealed record Checking : UpdateState;
    public sealed record UpToDate : UpdateState;
    public sealed record Available(string Version, string Page, string Setup) : UpdateState;
    public sealed record Installing : UpdateState;
    public sealed record Failed(string Message) : UpdateState;
}

/// Looks for a newer Resonata on GitHub and, when asked, fetches its Setup and
/// runs it. There is no separate update mechanism: an update is simply the next
/// installer going over the top. Nothing is downloaded until you click.
public sealed class Updater : Observable
{
    public static Updater Shared { get; } = new();

    public const string Repo = "Durik24/Resonata";
    public const string ReleasesPage = $"https://github.com/{Repo}/releases";
    // The whole list: the repository's "latest" is always the Mac's release.
    private const string ReleasesApi = $"https://api.github.com/repos/{Repo}/releases?per_page=100";
    private static readonly TimeSpan Interval = TimeSpan.FromHours(24);

    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromHours(1) };
    private static readonly HttpClient Http = MakeClient();

    private UpdateState _state = new UpdateState.Idle();
    public UpdateState State { get => _state; private set => Set(ref _state, value); }

    public Action<string>? OnFound { get; set; }

    public static string CurrentVersion
    {
        get
        {
            var version = Assembly.GetExecutingAssembly().GetName().Version;
            return version is null ? "0" : $"{version.Major}.{version.Minor}.{version.Build}";
        }
    }

    private static HttpClient MakeClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromMinutes(5) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd($"Resonata-Windows/{CurrentVersion}");
        return client;
    }

    /// Only the copy Setup put in Program Files replaces itself; a build in the
    /// project folder just links to the page.
    public static bool IsInstalled =>
        Environment.ProcessPath is { } path
        && path.StartsWith(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), StringComparison.OrdinalIgnoreCase);

    public static string? Uninstaller
    {
        get
        {
            var path = Path.Combine(AppContext.BaseDirectory, "unins000.exe");
            return IsInstalled && File.Exists(path) ? path : null;
        }
    }

    public void Start()
    {
        var first = new Delay();
        first.After(30, () => CheckIfDue(atLaunch: true));
        _timer.Tick += (_, _) => CheckIfDue(atLaunch: false);
        _timer.Start();
    }

    private void CheckIfDue(bool atLaunch)
    {
        var s = Settings.Current;
        if (s.CheckForUpdates && UpdateRules.ShouldCheck(atLaunch, s.UpdateLastCheck, DateTime.Now,
                s.UpdateAnnounced, CurrentVersion, Interval))
            _ = CheckAsync();
    }

    public async Task CheckAsync()
    {
        if (State is UpdateState.Checking or UpdateState.Installing) return;
        State = new UpdateState.Checking();
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, ReleasesApi);
            request.Headers.Accept.ParseAdd("application/vnd.github+json");
            using var response = await Http.SendAsync(request);
            response.EnsureSuccessStatusCode();
            // Only an answer counts as a check. Stamped before this, a refusal
            // from GitHub — its rate limit, say — wasn't tried again for a day.
            Settings.Current.UpdateLastCheck = DateTime.Now;
            var release = NewestSetup(await response.Content.ReadAsStringAsync(), OnArm64);
            if (release is null || !Versions.IsNewer(release.Version, CurrentVersion))
            {
                State = new UpdateState.UpToDate();
                return;
            }
            State = release;
            if (Settings.Current.UpdateAnnounced != release.Version)
            {
                Settings.Current.UpdateAnnounced = release.Version;
                OnFound?.Invoke(release.Version);
            }
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException)
        {
            Log.Write($"update check failed: {e.Message}");
            State = new UpdateState.Failed(L.T("Couldn't reach GitHub.", "Nepodařilo se spojit s GitHubem."));
        }
    }

    private sealed class Asset
    {
        [JsonPropertyName("name")] public string Name { get; set; } = "";
        [JsonPropertyName("browser_download_url")] public string Url { get; set; } = "";
    }

    private sealed class ReleaseJson
    {
        [JsonPropertyName("tag_name")] public string Tag { get; set; } = "";
        [JsonPropertyName("html_url")] public string Page { get; set; } = "";
        [JsonPropertyName("draft")] public bool Draft { get; set; }
        [JsonPropertyName("prerelease")] public bool Prerelease { get; set; }
        [JsonPropertyName("assets")] public List<Asset> Assets { get; set; } = [];
    }

    private const string X64Setup = "Resonata-Setup";
    private const string Arm64Setup = "Resonata-ARM64-Setup";

    /// Whether Windows itself runs on ARM64, asked of Windows: the x64 build,
    /// emulated there, is an x64 process, and only Windows knows better.
    public static bool OnArm64
    {
        get
        {
            try
            {
                return Native.IsWow64Process2(Native.GetCurrentProcess(), out _, out var machine)
                       && machine == Native.ImageFileMachineArm64;
            }
            catch (EntryPointNotFoundException)
            {
                return false;
            }
        }
    }

    /// The newest release in GitHub's list that has a Setup to run. Null when
    /// there is none; a release for the Mac has no Setup, so it's passed over.
    /// An ARM64 PC takes the ARM64 Setup, which also moves a copy of the x64
    /// build over to its own; with none in a release, the x64 one still runs.
    public static UpdateState.Available? NewestSetup(string json, bool arm64 = false)
    {
        List<ReleaseJson>? releases;
        try
        {
            releases = JsonSerializer.Deserialize<List<ReleaseJson>>(json);
        }
        catch (JsonException)
        {
            return null;
        }

        UpdateState.Available? newest = null;
        foreach (var release in releases ?? [])
        {
            if (release.Draft || release.Prerelease) continue;
            Asset? Named(string prefix) => release.Assets.FirstOrDefault(a =>
                a.Name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)
                && a.Name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase));
            var setup = (arm64 ? Named(Arm64Setup) : null) ?? Named(X64Setup);
            if (setup is null) continue;
            var version = Versions.FromTag(release.Tag);
            if (newest is null || Versions.IsNewer(version, newest.Version))
                newest = new UpdateState.Available(version, release.Page, setup.Url);
        }
        return newest;
    }

    /// Whether a downloaded file's version fields describe a newer Resonata.
    /// Inno Setup pads them with spaces to a fixed length.
    public static bool IsNewerSetup(string? product, string? version, string current) =>
        product?.Trim() == "Resonata" && Versions.IsNewer(version?.Trim().Split('+')[0] ?? "0", current);

    public async Task InstallAsync()
    {
        if (State is not UpdateState.Available release) return;
        if (!IsInstalled) { Shell.Open(release.Page); return; }
        State = new UpdateState.Installing();
        try
        {
            var path = Path.Combine(Paths.UpdateDownloads, $"Resonata-Setup-{release.Version}.exe");
            using (var response = await Http.GetAsync(release.Setup, HttpCompletionOption.ResponseHeadersRead))
            {
                response.EnsureSuccessStatusCode();
                await using var file = File.Create(path);
                await response.Content.CopyToAsync(file);
            }

            var info = FileVersionInfo.GetVersionInfo(path);
            if (!IsNewerSetup(info.ProductName, info.ProductVersion, CurrentVersion))
            {
                File.Delete(path);
                State = new UpdateState.Failed(L.T("The download isn't a newer Resonata.", "Stažený soubor není novější Resonata."));
                return;
            }

            // Setup closes this copy itself and starts the new one afterwards.
            using var setup = Process.Start(new ProcessStartInfo(path, "/SILENT /SP-") { UseShellExecute = true });
            // Still here once Setup has gone: it was cancelled part-way. The
            // update is offered again; it used to say "installing" until the
            // next restart, with no way to try again.
            try
            {
                if (setup is not null) await setup.WaitForExitAsync();
                else await Task.Delay(TimeSpan.FromMinutes(2));
            }
            catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception)
            {
                // Setup runs elevated and may not let itself be waited on.
                await Task.Delay(TimeSpan.FromMinutes(2));
            }
            State = release;
        }
        catch (System.ComponentModel.Win32Exception e) when (e.NativeErrorCode == 1223)
        {
            State = release; // Windows' "are you sure" was answered no.
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or IOException
                                      or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            Log.Write($"update failed: {e.Message}");
            State = new UpdateState.Failed(L.T("The update failed.", "Aktualizace se nepovedla."));
        }
    }
}

/// Icons from the shell: 48 px ones, for files, shortcuts and Store apps alike.
public static class ShellIcons
{
    [ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItemImageFactory
    {
        [PreserveSig] int GetImage(SIZE size, int flags, out IntPtr bitmap);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SIZE { public int cx, cy; }

    [StructLayout(LayoutKind.Sequential)]
    private struct BITMAP
    {
        public int bmType, bmWidth, bmHeight, bmWidthBytes;
        public ushort bmPlanes, bmBitsPixel;
        public IntPtr bmBits;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    private static extern void SHCreateItemFromParsingName(string path, IntPtr context, ref Guid iid,
        [MarshalAs(UnmanagedType.Interface)] out IShellItemImageFactory item);

    [DllImport("gdi32.dll")] private static extern int GetObject(IntPtr handle, int size, out BITMAP bitmap);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(IntPtr handle);

    private static readonly Dictionary<string, BitmapSource?> Cache = new(StringComparer.OrdinalIgnoreCase);

    public static BitmapSource? Get(string path, int size = 48)
    {
        var key = $"{size}|{path}";
        if (Cache.TryGetValue(key, out var cached)) return cached;
        return Cache[key] = Load(path, size);
    }

    private static BitmapSource? Load(string path, int size)
    {
        const int biggerSizeOk = 1, iconOnly = 4;
        var iid = typeof(IShellItemImageFactory).GUID;
        var bitmap = IntPtr.Zero;
        try
        {
            SHCreateItemFromParsingName(path, IntPtr.Zero, ref iid, out var factory);
            if (factory.GetImage(new SIZE { cx = size, cy = size }, biggerSizeOk | iconOnly, out bitmap) != 0) return null;
            if (GetObject(bitmap, Marshal.SizeOf<BITMAP>(), out var info) == 0 || info.bmBits == IntPtr.Zero) return null;

            // The shell's bitmaps are bottom-up, and their alpha is real: going
            // through Imaging.CreateBitmapSourceFromHBitmap would lose it.
            var stride = info.bmWidthBytes;
            var height = Math.Abs(info.bmHeight);
            var pixels = new byte[stride * height];
            for (var row = 0; row < height; row++)
                Marshal.Copy(info.bmBits + stride * (height - 1 - row), pixels, row * stride, stride);
            var source = BitmapSource.Create(info.bmWidth, height, 96, 96, PixelFormats.Pbgra32, null, pixels, stride);
            source.Freeze();
            return source;
        }
        catch (Exception e) when (e is COMException or FileNotFoundException or ArgumentException or InvalidCastException)
        {
            Log.Write($"no icon for {Path.GetFileName(path)}: {e.GetType().Name}");
            return null;
        }
        finally
        {
            if (bitmap != IntPtr.Zero) DeleteObject(bitmap);
        }
    }
}

/// The app a track came from: its icon, and a way to bring it forward.
public static class PlayerApp
{
    private static string? ExecutablePath(string source)
    {
        var name = Path.GetFileNameWithoutExtension(source);
        foreach (var process in Process.GetProcessesByName(name))
        {
            using (process)
            {
                try
                {
                    if (process.MainModule?.FileName is { } file) return file;
                }
                catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException)
                {
                    // Elevated or gone; another of its processes may answer.
                }
            }
        }
        return null;
    }

    private static string? ParsingName(string source) => source.Contains('!')
        ? $@"shell:AppsFolder\{source}"
        : ExecutablePath(source);

    public static BitmapSource? Icon(string source) =>
        string.IsNullOrEmpty(source) || ParsingName(source) is not { } name ? null : ShellIcons.Get(name);

    public static void Open(string source)
    {
        if (ParsingName(source) is { } name) Shell.Open(name);
    }
}

public static class Screens
{
    public static Forms.Screen Target
    {
        get
        {
            var pinned = Settings.Current.PinnedScreen;
            return Forms.Screen.AllScreens.FirstOrDefault(s => s.DeviceName == pinned) ?? Forms.Screen.PrimaryScreen!;
        }
    }

    public static bool HasSeveral => Forms.Screen.AllScreens.Length > 1;

    public static void PinNext()
    {
        var all = Forms.Screen.AllScreens;
        if (all.Length < 2) return;
        var current = Array.FindIndex(all, s => s.DeviceName == Target.DeviceName);
        Settings.Current.PinnedScreen = all[(current + 1) % all.Length].DeviceName;
    }
}

public static class DpiInfo
{
    public static double Of(Visual visual) => VisualTreeHelper.GetDpi(visual).DpiScaleX;
}
