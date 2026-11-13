using System.ComponentModel;
using System.Windows;
using System.Windows.Threading;

namespace Resonata;

public partial class App : Application
{
    private const string MutexName = @"Local\Resonata.SingleInstance";
    private const string ShowEvent = @"Local\Resonata.Show";
    private const string QuitEvent = @"Local\Resonata.Quit";
    private const string SettingsEvent = @"Local\Resonata.Settings";

    private Mutex? _instance;
    private PanelModel _model = null!;
    private NotchWindow _window = null!;
    private Tray _tray = null!;
    private MediaService? _media;
    private SongPeek _songPeek = null!;
    private ActivityPeek _activityPeek = null!;
    private LyricsStore _lyrics = null!;
    private readonly PowerWatcher _power = new();
    private readonly OutputWatcher _output = new();
    private readonly MeetingReminder _reminder = new();
    private ClaudeMonitor _claude = null!;
    private VibeMonitor _vibe = null!;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        // Setup runs `--quit` before it replaces the files.
        if (e.Args.Contains("--quit"))
        {
            // Non-zero tells Setup it's still running and needs closing the hard way.
            Shutdown(AskRunningCopyToQuit() ? 0 : 1);
            return;
        }

        _instance = new Mutex(true, MutexName, out var first);
        if (!first)
        {
            // `--settings`: the running copy opens its settings instead of the panel.
            Signal(e.Args.Contains("--settings") ? SettingsEvent : ShowEvent);
            Shutdown();
            return;
        }

        DispatcherUnhandledException += (_, args) =>
        {
            Log.Write($"unhandled: {args.Exception}");
            args.Handled = true;
        };

        Settings.Load();
        ListenFor(ShowEvent, () => _model.Open?.Invoke());
        ListenFor(QuitEvent, Quit);
        ListenFor(SettingsEvent, () => SettingsWindow.ShowShared(MainWindow));

        _model = new PanelModel();
        _songPeek = new SongPeek(_model);
        _activityPeek = new ActivityPeek(_model);
        _lyrics = new LyricsStore(_model);
        _window = new NotchWindow(_model);
        _tray = new Tray(_model, _window);
        _window.ShowMenu = _tray.ShowMenu;
        _window.Prepare();

        LoginItem.RegisterOnce();
        Wire();

        if (Demo.IsOn) Demo.Install(_model);
        else
        {
            _media = new MediaService(_model);
            _media.Start();
        }
        if (Environment.GetEnvironmentVariable("RESONATA_SNAP") is { Length: > 0 } dir)
            Logged(Snapshots.RunAsync(_model, _window, _songPeek, _activityPeek, dir), "snapshots");
        if (Environment.GetEnvironmentVariable("RESONATA_ANIMTEST") == "1")
            Logged(Snapshots.RunAnimationTestAsync(_window), "animation test");
        if (Environment.GetEnvironmentVariable("RESONATA_VOLUMETEST") == "1")
            Logged(Snapshots.RunVolumeTestAsync(), "volume test");
    }

    /// A test run that fails says so in the log rather than stopping unseen.
    private static void Logged(Task run, string what) =>
        run.ContinueWith(t => Log.Write($"{what} failed: {t.Exception}"), TaskContinuationOptions.OnlyOnFaulted);

    private void Wire()
    {
        var timer = CountdownTimer.Shared;
        _model.TimerRunning = timer.IsActive;
        timer.PropertyChanged += (_, _) => _model.TimerRunning = timer.IsActive;
        timer.Finished += minutes => _activityPeek.Show(new NotchActivity.TimerDone(minutes));
        timer.PhaseStarted += (phase, minutes) =>
            _activityPeek.Show(new NotchActivity.Pomodoro(phase == PomodoroPhase.Rest, minutes));

        _model.PropertyChanged += OnModelChanged;
        // Lyrics switched on are fetched for the song already playing;
        // switched off, they're dropped and nothing more is asked.
        Settings.Current.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(Settings.ShowLyrics) && !Demo.IsOn) _lyrics.Load(_model.Track);
        };

        _power.OnPlugIn = b => { if (Settings.Current.ShowChargingPeek) _activityPeek.Show(new NotchActivity.Charging(b.Percent)); };
        _power.OnLow = b => { if (Settings.Current.ShowChargingPeek) _activityPeek.Show(new NotchActivity.LowBattery(b.Percent)); };
        _power.Start();

        _output.OnHeadphones = name => { if (Settings.Current.ShowHeadphonesPeek) _activityPeek.Show(new NotchActivity.Headphones(name)); };
        _output.Start();

        CalendarStore.Shared.Start();
        _reminder.OnReminder = ev => _activityPeek.Show(new NotchActivity.Meeting(ev.Title, ev.Start));
        _reminder.Start();

        // Claude Code and Mistral Vibe, each only while switched on.
        _claude = new ClaudeMonitor(_model) { OnEvent = _activityPeek.Show };
        _vibe = new VibeMonitor(_model) { OnEvent = _activityPeek.Show };
        if (!Demo.IsOn)
        {
            // `RESONATA_DEBUG_CLAUDE=1`: what Claude Code's monitor reads on
            // this PC, in the log, without switching it on in Settings.
            var debugClaude = Environment.GetEnvironmentVariable("RESONATA_DEBUG_CLAUDE") == "1";
            if (debugClaude)
            {
                _model.PropertyChanged += (_, e) =>
                {
                    if (e.PropertyName == nameof(PanelModel.Claude) && _model.Claude is { } c)
                        Log.Write($"claude: {c.State}, {c.Session}, limits {(c.Usage is null ? "unread" : c.Usage.SessionPercent + " %")}, "
                                  + string.Join("; ", c.Sessions.Select(s => $"{s.Name} {s.State} in {s.App}")));
                };
            }
            _claude.SetEnabled(Settings.Current.ShowClaude || debugClaude);
            _vibe.SetEnabled(Settings.Current.ShowVibe);
            Settings.Current.PropertyChanged += (_, e) =>
            {
                if (e.PropertyName == nameof(Settings.ShowClaude)) _claude.SetEnabled(Settings.Current.ShowClaude || debugClaude);
                if (e.PropertyName == nameof(Settings.ShowVibe)) _vibe.SetEnabled(Settings.Current.ShowVibe);
            };
            // The panel opening is a good moment to have the limits fresh.
            _model.PropertyChanged += (_, e) =>
            {
                if (e.PropertyName != nameof(PanelModel.IsExpanded) || !_model.IsExpanded) return;
                _claude.RefreshUsage(60);
                _vibe.RefreshUsage(60);
            };
        }

        Updater.Shared.OnFound = version => _activityPeek.Show(new NotchActivity.Update(version));
        Updater.Shared.Start();
    }

    private void OnModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(PanelModel.Track)) return;
        _songPeek.TrackChanged(_model.Track);
        if (!Demo.IsOn) _lyrics.Load(_model.Track);
    }

    public void Quit()
    {
        NotesStore.Shared.SaveIfPending();
        Settings.Current.SaveNow();
        _tray?.Dispose();
        Shutdown();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        // `RESONATA_HANG_ON_EXIT`: stays after quitting, as 1.1.0 did on one PC.
        // "1" tries what ends it, "forever" what Setup does with it.
        var hang = Environment.GetEnvironmentVariable("RESONATA_HANG_ON_EXIT");
        if (hang != "forever") EndIfStuck();
        _instance?.Dispose();
        base.OnExit(e);
        if (hang is "1" or "forever") Thread.Sleep(Timeout.Infinite);
    }

    /// A call into another process that never returns could keep Resonata from
    /// ending after it had quit, with no window and its files still held, so
    /// Setup couldn't replace them. Its notes and settings are saved by then.
    private static void EndIfStuck() => new Thread(() =>
    {
        Thread.Sleep(5000);
        Log.Write("still running 5 s after quitting; ending it");
        Native.TerminateProcess(Native.GetCurrentProcess(), 0);
    }) { IsBackground = true }.Start();

    private void ListenFor(string name, Action action)
    {
        var handle = new EventWaitHandle(false, EventResetMode.AutoReset, name);
        var dispatcher = Dispatcher;
        var thread = new Thread(() =>
        {
            while (true)
            {
                handle.WaitOne();
                dispatcher.BeginInvoke(action, DispatcherPriority.Normal);
            }
        }) { IsBackground = true };
        thread.Start();
    }

    private static void Signal(string name)
    {
        if (EventWaitHandle.TryOpenExisting(name, out var handle))
            using (handle) handle.Set();
    }

    /// Returns once the running copy has gone, so Setup can replace its files.
    private static bool AskRunningCopyToQuit()
    {
        Signal(QuitEvent);
        for (var i = 0; i < 50; i++)
        {
            if (!Mutex.TryOpenExisting(MutexName, out var mutex)) return true;
            mutex.Dispose();
            Thread.Sleep(100);
        }
        return false;
    }
}
