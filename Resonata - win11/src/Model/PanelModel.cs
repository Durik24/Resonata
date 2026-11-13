using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace Resonata;

public enum PanelTab { Music, Notes, Apps, Timer, Shelf, Usage }

public static class Glyph
{
    /// A chevron pointing back (Segoe's ChevronLeft).
    public const string Back = "\uE76B";
    public const string Music = "", Notes = "", Apps = "", Timer = "", Shelf = "";
    public const string Play = "", Pause = "", Previous = "", Next = "";
    public const string Settings = "", Screens = "", Add = "", Close = "", Minus = "";
    public const string Bolt = "", Warning = "", Headphones = "", Speaker = "";
    public const string Calendar = "", Clock = "", Bell = "", Moon = "";
    public const string Download = "", Repeat = "", Circle = "", CircleCheck = "";
    public const string Mute = "", Volume1 = "", Volume2 = "", Volume3 = "";

    /// A gauge (SpeedHigh), a question mark in a circle (Help).
    public const string Usage = "", Asking = "";

    public static string Battery(int percent, bool charging)
    {
        var tenth = Math.Clamp(percent / 10, 0, 10);
        if (charging) return tenth switch { 10 => "", 9 => "", _ => ((char)(0xE85A + tenth)).ToString() };
        return tenth == 10 ? "" : ((char)(0xE850 + tenth)).ToString();
    }

    public static string Volume(double volume) => volume switch
    {
        < 1 => Mute,
        < 34 => Volume1,
        < 67 => Volume2,
        _ => Volume3,
    };
}

public static class TabInfo
{
    public static string Symbol(this PanelTab tab) => tab switch
    {
        PanelTab.Music => Glyph.Music,
        PanelTab.Notes => Glyph.Notes,
        PanelTab.Apps => Glyph.Apps,
        PanelTab.Timer => Glyph.Timer,
        PanelTab.Usage => Glyph.Usage,
        _ => Glyph.Shelf,
    };

    /// The pages there are right now: the limits only while Claude Code or
    /// Mistral Vibe is switched on in Settings.
    public static IReadOnlyList<PanelTab> Shown =>
        Enum.GetValues<PanelTab>().Where(t => t != PanelTab.Usage || Settings.Current.ShowClaude || Settings.Current.ShowVibe || Demo.ShowsAi).ToList();

    public static string Title(this PanelTab tab) => tab switch
    {
        PanelTab.Music => L.T("Music", "Hudba"),
        PanelTab.Notes => L.T("Notes and to-dos", "Poznámky a úkoly"),
        PanelTab.Apps => L.T("Apps", "Aplikace"),
        PanelTab.Timer => L.T("Timer", "Časovač"),
        PanelTab.Usage => (Settings.Current.ShowClaude, Settings.Current.ShowVibe) switch
        {
            (true, true) => L.T("Claude Code and Vibe limits", "Limity Claude Code a Vibe"),
            (false, true) => L.T("Mistral Vibe limits", "Limity Mistral Vibe"),
            _ => L.T("Claude Code limits", "Limity Claude Code"),
        },
        _ => L.T("Shelf", "Police"),
    };
}

public sealed class PanelModel : Observable
{
    private bool _isExpanded;
    public bool IsExpanded { get => _isExpanded; set => Set(ref _isExpanded, value); }

    private Track? _track;
    public Track? Track { get => _track; set => Set(ref _track, value); }

    private BitmapSource? _artwork;
    public BitmapSource? Artwork { get => _artwork; set => Set(ref _artwork, value); }

    private Color? _accent;
    public Color? Accent { get => _accent; set => Set(ref _accent, value); }

    private IReadOnlyList<LyricLine>? _lyrics;
    public IReadOnlyList<LyricLine>? Lyrics { get => _lyrics; set => Set(ref _lyrics, value); }

    private bool _lyricsPending;
    public bool LyricsPending { get => _lyricsPending; set => Set(ref _lyricsPending, value); }

    /// The pointer is resting on the tab, or on the pill that's out.
    private bool _edgeHeld;
    public bool EdgeHeld { get => _edgeHeld; set => Set(ref _edgeHeld, value); }

    private bool _hovering;
    public bool Hovering { get => _hovering; set => Set(ref _hovering, value); }

    private bool _songPeeking;
    public bool SongPeeking
    {
        get => _songPeeking;
        set { if (Set(ref _songPeeking, value)) Raise(nameof(Peeking)); }
    }

    /// The activity is out. Separate from Activity itself, which stays set
    /// while the pill slides away, so the text leaving is still the activity's.
    private bool _activityShown;
    public bool ActivityShown
    {
        get => _activityShown;
        set { if (Set(ref _activityShown, value)) Raise(nameof(Peeking)); }
    }

    public bool Peeking => SongPeeking || ActivityShown;

    private NotchActivity? _activity;
    public NotchActivity? Activity { get => _activity; set => Set(ref _activity, value); }

    private bool _timerRunning;
    public bool TimerRunning { get => _timerRunning; set => Set(ref _timerRunning, value); }

    private PanelTab _tab = PanelTab.Music;
    public PanelTab Tab { get => _tab; set => Set(ref _tab, value); }

    /// Claude Code's limits and what its sessions are doing; null while
    /// that is switched off, or it isn't on this PC (see `ClaudeMonitor`).
    private ClaudeStatus? _claude;
    public ClaudeStatus? Claude { get => _claude; set { if (!Equals(_claude, value)) { _claude = value; Raise(); } } }

    /// Mistral Vibe's, the same way (see `VibeMonitor`).
    private VibeStatus? _vibe;
    public VibeStatus? Vibe { get => _vibe; set { if (!Equals(_vibe, value)) { _vibe = value; Raise(); } } }

    /// A session of either is working or waiting.
    public bool AiActive => Claude?.IsActive == true || Vibe?.IsActive == true;

    /// Either has something to say where the song would be.
    public bool AiHasSomething => Claude?.HasSomething == true || Vibe?.HasSomething == true;

    /// How many rings the tab carries: one for each tool that is switched on and found.
    public int AiRings => (Claude is null ? 0 : 1) + (Vibe is null ? 0 : 1);

    private bool _canSwitchScreens;
    public bool CanSwitchScreens { get => _canSwitchScreens; set => Set(ref _canSwitchScreens, value); }

    /// The panel stands along the screen's edge, taller than it is wide: the
    /// pages, and beside them the column of icons that turns them.
    public double ExpandedWidth => 320;
    public const double RailWidth = 38;
    public const double ExpandedHeight = 440;
    /// The tab on the screen's edge, long enough to say what's playing; its
    /// height takes in the flare at each end.
    public const double NubWidth = 20;
    public const double NubBaseHeight = 275;
    /// Each ring on it makes it this much longer.
    public const double NubRingStep = 22;
    public double NubHeight => NubBaseHeight + AiRings * NubRingStep;
    /// The strip the tab grows into to say what's playing: along the edge,
    /// not out from it: the tab, as long as it is, grown wider.
    public const double PillWidth = 44;
    public double PillHeight => NubHeight;

    public Action? SwitchScreen { get; set; }
    public Action? Open { get; set; }
    public Action? Close { get; set; }
    public Action? Toggle { get; set; }
}

/// A moment that isn't the song: it slides out like the song peek, with its own
/// symbol in the cover's place and the bars'.
public abstract record NotchActivity
{
    public sealed record Charging(int Percent) : NotchActivity;
    public sealed record LowBattery(int Percent) : NotchActivity;
    public sealed record Headphones(string Name) : NotchActivity;
    public sealed record Meeting(string Title, DateTime Start) : NotchActivity;
    public sealed record TimerDone(int Minutes) : NotchActivity;
    public sealed record Pomodoro(bool Rest, int Minutes) : NotchActivity;
    public sealed record Update(string Version) : NotchActivity;
    /// A Claude Code or Vibe session has stopped to ask you something.
    public sealed record AiWaiting(string Tool, string Session, string? Wants, int Pid) : NotchActivity;
    /// A session has finished what it was doing.
    public sealed record AiDone(string Tool, string Session, int Pid) : NotchActivity;

    public double Duration => this is Charging or LowBattery or Headphones ? 3 : 6;

    /// Worth showing late: with the panel open a reminder waits for it to
    /// close, while "headphones connected" is old news by then, and a
    /// session that finished while you were here was seen.
    public bool WaitsForClose => this is not (Charging or Headphones or AiDone);

    /// The process of the session this is about, for a click to go to.
    public int? SessionPid => this switch { AiWaiting w => w.Pid, AiDone d => d.Pid, _ => null };

    public ActivityLook Look => this switch
    {
        Charging c => new(Glyph.Bolt, ActivityLook.Green, L.T("Charging", "Nabíjení"), $"{c.Percent} %", Glyph.Battery(c.Percent, false)),
        LowBattery l => new(Glyph.Warning, ActivityLook.Red, L.T("Low battery", "Slabá baterie"), $"{l.Percent} %", Glyph.Battery(l.Percent, false)),
        Headphones h => new(Glyph.Headphones, ActivityLook.Blue, h.Name, L.T("Connected", "Připojeno"), Glyph.Speaker),
        Meeting m => new(Glyph.Calendar, ActivityLook.Orange, m.Title, CalendarRules.MeetingDetail(m.Start, DateTime.Now), Glyph.Clock),
        TimerDone t => new(Glyph.Timer, ActivityLook.Orange, L.T("Time's up", "Čas vypršel"), $"{t.Minutes} min", Glyph.Bell),
        Pomodoro { Rest: true } p => new(Glyph.Moon, ActivityLook.Green, L.T("Break", "Pauza"), $"{p.Minutes} min", Glyph.Bell),
        Pomodoro p => new(Glyph.Timer, ActivityLook.Orange, L.T("Back to work", "Zpátky do práce"), $"{p.Minutes} min", Glyph.Bell),
        Update u => new(Glyph.Download, ActivityLook.Blue, L.T($"New version {u.Version}", $"Nová verze {u.Version}"), L.T("Right-click", "Klikni pravým"), Glyph.Download),
        AiWaiting w => new(Glyph.Asking, ActivityLook.Amber, L.T($"{w.Tool} is waiting", $"{w.Tool} čeká"),
            w.Session + (string.IsNullOrEmpty(w.Wants) ? "" : " · " + w.Wants), ""),
        AiDone d => new(Glyph.CircleCheck, ActivityLook.Green, L.T($"{d.Tool} has finished", $"{d.Tool} dokončil"), d.Session, ""),
        _ => throw new InvalidOperationException(),
    };
}

public sealed record ActivityLook(string Symbol, Color Tint, string Title, string Detail, string Trailing)
{
    public static readonly Color Green = Color.FromRgb(51, 214, 102);
    public static readonly Color Red = Color.FromRgb(255, 82, 77);
    public static readonly Color Blue = Color.FromRgb(92, 158, 255);
    public static readonly Color Orange = Color.FromRgb(255, 158, 64);
    public static readonly Color Amber = Color.FromRgb(245, 166, 36);
    /// Claude Code's orange, its week's blue, a model's violet, Mistral's redder orange.
    public static readonly Color Claude = Color.FromRgb(232, 135, 92), Week = Color.FromRgb(128, 179, 255),
        Violet = Color.FromRgb(186, 168, 255), Vibe = Color.FromRgb(250, 79, 15);
}

/// A one-shot, cancellable delay on the UI thread.
public sealed class Delay
{
    private DispatcherTimer? _timer;

    public void After(double seconds, Action action)
    {
        Cancel();
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(seconds) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            if (_timer == timer) _timer = null;
            action();
        };
        _timer = timer;
        timer.Start();
    }

    public void Cancel()
    {
        _timer?.Stop();
        _timer = null;
    }
}

public sealed class SongPeek(PanelModel model)
{
    public const double Duration = 3.5;

    private Track? _previous;
    private readonly Delay _hide = new();

    public void TrackChanged(Track? track)
    {
        if (SongPeekRules.ShouldPeek(_previous, track, model.IsExpanded, Settings.Current.ShowSongPeek)) Show();
        _previous = track;
    }

    public void Show()
    {
        model.SongPeeking = true;
        _hide.After(Duration, () => model.SongPeeking = false);
    }
}

public sealed class ActivityPeek
{
    private readonly PanelModel _model;
    private readonly Delay _hide = new();
    private readonly Delay _afterClose = new();
    private NotchActivity? _waiting;

    public ActivityPeek(PanelModel model)
    {
        _model = model;
        // Once the close has played, so it slides out of a settled pill.
        model.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(PanelModel.IsExpanded) && !model.IsExpanded)
                _afterClose.After(0.6, ShowWaiting);
        };
    }

    public void Show(NotchActivity activity)
    {
        if (_model.IsExpanded)
        {
            if (activity.WaitsForClose) _waiting = activity;
            return;
        }
        _model.Activity = activity;
        _model.ActivityShown = true;
        _hide.After(activity.Duration, SlideBack);
    }

    private void ShowWaiting()
    {
        if (_waiting is not { } activity || _model.IsExpanded) return;
        _waiting = null;
        Show(activity);
    }

    private void SlideBack()
    {
        _model.ActivityShown = false;
        if (_model.SongPeeking) { _model.Activity = null; return; }
        _hide.After(0.6, () => { if (!_model.ActivityShown) _model.Activity = null; });
    }
}
