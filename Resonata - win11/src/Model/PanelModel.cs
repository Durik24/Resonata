using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace Resonata;

public enum PanelTab { Music, Notes, Apps, Timer, Shelf }

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
        _ => Glyph.Shelf,
    };

    public static string Title(this PanelTab tab) => tab switch
    {
        PanelTab.Music => L.T("Music", "Hudba"),
        PanelTab.Notes => L.T("Notes and to-dos", "Poznámky a úkoly"),
        PanelTab.Apps => L.T("Apps", "Aplikace"),
        PanelTab.Timer => L.T("Timer", "Časovač"),
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

    /// The pointer has brought the pill out and is still on it.
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

    private bool _canSwitchScreens;
    public bool CanSwitchScreens { get => _canSwitchScreens; set => Set(ref _canSwitchScreens, value); }

    public double ExpandedWidth => Settings.Current.ShowCalendar ? 640 : 470;
    public const double ExpandedHeight = 204;
    public const double PillWidth = 300;
    public const double PillHeight = 42;

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

    public double Duration => this is Charging or LowBattery or Headphones ? 3 : 6;

    /// Worth showing late: with the panel open a reminder waits for it to
    /// close, while "headphones connected" is old news by then.
    public bool WaitsForClose => this is not (Charging or Headphones);

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
        _ => throw new InvalidOperationException(),
    };
}

public sealed record ActivityLook(string Symbol, Color Tint, string Title, string Detail, string Trailing)
{
    public static readonly Color Green = Color.FromRgb(51, 214, 102);
    public static readonly Color Red = Color.FromRgb(255, 82, 77);
    public static readonly Color Blue = Color.FromRgb(92, 158, 255);
    public static readonly Color Orange = Color.FromRgb(255, 158, 64);
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
