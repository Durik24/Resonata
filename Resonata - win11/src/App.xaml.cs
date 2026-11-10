using System.ComponentModel;
using System.Windows;
using System.Windows.Threading;

namespace Resonata;

public partial class App : Application
{
    private const string MutexName = @"Local\Resonata.SingleInstance";
    private const string ShowEvent = @"Local\Resonata.Show";
    private const string QuitEvent = @"Local\Resonata.Quit";

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
            Signal(ShowEvent);
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
            _ = Snapshots.RunAsync(_model, _window, _songPeek, _activityPeek, dir);
        if (Environment.GetEnvironmentVariable("RESONATA_ANIMTEST") == "1")
            _ = Snapshots.RunAnimationTestAsync(_window);
    }

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
        _instance?.Dispose();
        base.OnExit(e);
    }

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
