using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows.Threading;

namespace Resonata;

public abstract class Observable : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        Raise(name);
        return true;
    }

    protected void Raise([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

public enum OpenMode { Hover, Click }

/// Anything but "Click" reads as Hover: a settings file from before the modes
/// were cut to two still says "Nook", and that must not cost the whole file.
public sealed class OpenModeConverter : JsonConverter<OpenMode>
{
    public override OpenMode Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options) =>
        reader.TokenType == JsonTokenType.String && reader.GetString() == nameof(OpenMode.Click) ? OpenMode.Click : OpenMode.Hover;

    public override void Write(Utf8JsonWriter writer, OpenMode value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.ToString());
}
public enum AnimationSpeed { Fast, Normal, Slow }
public enum WaveColour { Album, White, Custom }
/// The second one was Ctrl + Alt + N. Windows reads AltGr as Ctrl + Alt, and
/// on a Czech keyboard AltGr + N is how "}" is typed — the shortcut took the
/// brace away. Alt + Shift + N types nothing on any layout.
public enum HotKeyChoice { Off, CtrlShiftSpace, AltShiftN }

/// A settings file from before still says "CtrlAltN": read as the shortcut
/// that took its place, and anything unknown as Off, rather than a name this
/// version doesn't know costing the whole file.
public sealed class HotKeyChoiceConverter : JsonConverter<HotKeyChoice>
{
    public override HotKeyChoice Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options)
    {
        if (reader.TokenType != JsonTokenType.String)
        {
            reader.Skip();
            return HotKeyChoice.Off;
        }
        var text = reader.GetString();
        if (text == "CtrlAltN") return HotKeyChoice.AltShiftN;
        return Enum.TryParse<HotKeyChoice>(text, out var value) && Enum.IsDefined(value) ? value : HotKeyChoice.Off;
    }

    public override void Write(Utf8JsonWriter writer, HotKeyChoice value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.ToString());
}
public enum PageSwipe { WithFingers, Reversed, Off }
public enum AppLanguage { English, Czech }

/// The interface's two languages, side by side where each string is used.
public static class L
{
    public static string T(string english, string czech) =>
        Settings.Current.Language == AppLanguage.Czech ? czech : english;

    /// "+ 3 more" under a list cut short.
    public static string More(int count) => More(count, Settings.Current.Language == AppLanguage.Czech);

    /// Czech counts differently from five up: 2 další, but 5 dalších.
    public static string More(int count, bool czech) =>
        czech ? $"+ {count} {(count >= 5 ? "dalších" : "další")}" : $"+ {count} more";

    public static System.Globalization.CultureInfo Culture =>
        System.Globalization.CultureInfo.GetCultureInfo(Settings.Current.Language == AppLanguage.Czech ? "cs-CZ" : "en-GB");
}

public static class Paths
{
    /// Roaming, and outside Program Files: an update must never touch it.
    public static string Data => Ensure(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Resonata"));

    public static string Lyrics => Ensure(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Resonata", "Cache", "lyrics"));

    public static string UpdateDownloads => Ensure(Path.Combine(Path.GetTempPath(), "Resonata-update"));

    private static string Ensure(string path)
    {
        Directory.CreateDirectory(path);
        return path;
    }
}

/// Everything the settings window can change, plus the little state that has
/// to survive a restart. Written to settings.json half a second after a change.
public sealed class Settings : Observable
{
    public static Settings Current { get; private set; } = new();

    private static string FilePath => Path.Combine(Paths.Data, "settings.json");

    private static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
    };

    private DispatcherTimer? _save;

    public static void Load()
    {
        try
        {
            if (File.Exists(FilePath))
                Current = JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath), Json) ?? new Settings();
        }
        catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException)
        {
            // There, but unreadable: kept beside it rather than overwritten.
            NotesStore.SetAside(FilePath);
        }
        Current.PropertyChanged += (_, _) => Current.ScheduleSave();
    }

    private void ScheduleSave()
    {
        _save ??= new DispatcherTimer { Interval = TimeSpan.FromSeconds(0.5) };
        _save.Stop();
        _save.Tick -= OnSave;
        _save.Tick += OnSave;
        _save.Start();
    }

    private void OnSave(object? sender, EventArgs e) => SaveNow();

    public void SaveNow()
    {
        _save?.Stop();
        try
        {
            AtomicFile.Write(FilePath, JsonSerializer.Serialize(this, Json));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Log.Write($"could not save settings: {e.Message}");
        }
    }

    private AppLanguage _language = AppLanguage.English;
    public AppLanguage Language { get => _language; set => Set(ref _language, value); }

    private OpenMode _openMode = OpenMode.Hover;
    [JsonConverter(typeof(OpenModeConverter))]
    public OpenMode OpenMode { get => _openMode; set => Set(ref _openMode, value); }

    /// With nothing playing and nothing going on, the tab slides away
    /// altogether, and comes back when the pointer goes to its place on the edge.
    private bool _hideWhenIdle = true;
    public bool HideWhenIdle { get => _hideWhenIdle; set => Set(ref _hideWhenIdle, value); }

    // Off until asked for: they read another app's files and run it.
    private bool _showClaude;
    public bool ShowClaude { get => _showClaude; set => Set(ref _showClaude, value); }

    private bool _showVibe;
    public bool ShowVibe { get => _showVibe; set => Set(ref _showVibe, value); }

    private AnimationSpeed _animationSpeed = AnimationSpeed.Normal;
    public AnimationSpeed AnimationSpeed { get => _animationSpeed; set => Set(ref _animationSpeed, value); }

    private WaveColour _waveColour = WaveColour.Album;
    public WaveColour WaveColour { get => _waveColour; set => Set(ref _waveColour, value); }

    private string _customWaveColour = "#FFFFFF";
    public string CustomWaveColour { get => _customWaveColour; set => Set(ref _customWaveColour, value); }

    private bool _showLyrics = true;
    public bool ShowLyrics { get => _showLyrics; set => Set(ref _showLyrics, value); }

    private HotKeyChoice _hotKey = HotKeyChoice.CtrlShiftSpace;
    [JsonConverter(typeof(HotKeyChoiceConverter))]
    public HotKeyChoice HotKey { get => _hotKey; set => Set(ref _hotKey, value); }

    private bool _showSongPeek = true;
    public bool ShowSongPeek { get => _showSongPeek; set => Set(ref _showSongPeek, value); }

    private bool _showCalendar = true;
    public bool ShowCalendar { get => _showCalendar; set => Set(ref _showCalendar, value); }

    private bool _showChargingPeek = true;
    public bool ShowChargingPeek { get => _showChargingPeek; set => Set(ref _showChargingPeek, value); }

    private bool _showHeadphonesPeek = true;
    public bool ShowHeadphonesPeek { get => _showHeadphonesPeek; set => Set(ref _showHeadphonesPeek, value); }

    private bool _meetingReminder = true;
    public bool MeetingReminder { get => _meetingReminder; set => Set(ref _meetingReminder, value); }

    private int _pomodoroWork = 25;
    public int PomodoroWork { get => _pomodoroWork; set => Set(ref _pomodoroWork, value); }

    private int _pomodoroRest = 5;
    public int PomodoroRest { get => _pomodoroRest; set => Set(ref _pomodoroRest, value); }

    private int _pomodoroLongRest = 15;
    public int PomodoroLongRest { get => _pomodoroLongRest; set => Set(ref _pomodoroLongRest, value); }

    private int _pomodoroRounds = 4;
    public int PomodoroRounds { get => _pomodoroRounds; set => Set(ref _pomodoroRounds, value); }

    [JsonIgnore]
    public PomodoroPlan PomodoroPlan =>
        new PomodoroPlan(PomodoroWork, PomodoroRest, PomodoroLongRest, PomodoroRounds).Clamped;

    private PageSwipe _pageSwipe = PageSwipe.WithFingers;
    public PageSwipe PageSwipe { get => _pageSwipe; set => Set(ref _pageSwipe, value); }

    private bool _checkForUpdates = true;
    public bool CheckForUpdates { get => _checkForUpdates; set => Set(ref _checkForUpdates, value); }

    private List<string>? _quickApps;
    /// Null until first set, so the defaults are worked out once, on this PC.
    public List<string>? QuickApps { get => _quickApps; set { _quickApps = value; Raise(); } }

    private List<string> _shelfItems = [];
    public List<string> ShelfItems { get => _shelfItems; set { _shelfItems = value; Raise(); } }

    private string _calendarUrls = "";
    public string CalendarUrls { get => _calendarUrls; set => Set(ref _calendarUrls, value); }

    private string? _pinnedScreen;
    public string? PinnedScreen { get => _pinnedScreen; set => Set(ref _pinnedScreen, value); }

    private bool _registeredLoginItem;
    public bool RegisteredLoginItem { get => _registeredLoginItem; set => Set(ref _registeredLoginItem, value); }

    private DateTime _updateLastCheck;
    public DateTime UpdateLastCheck { get => _updateLastCheck; set => Set(ref _updateLastCheck, value); }

    private string? _updateAnnounced;
    public string? UpdateAnnounced { get => _updateAnnounced; set => Set(ref _updateAnnounced, value); }

    // The timer, kept across restarts.
    private DateTime? _timerEnd;
    public DateTime? TimerEnd { get => _timerEnd; set => Set(ref _timerEnd, value); }

    private double? _timerPausedRemaining;
    public double? TimerPausedRemaining { get => _timerPausedRemaining; set => Set(ref _timerPausedRemaining, value); }

    private double _timerTotal = 25 * 60;
    public double TimerTotal { get => _timerTotal; set => Set(ref _timerTotal, value); }

    private int _timerChosen = 25;
    public int TimerChosen { get => _timerChosen; set => Set(ref _timerChosen, value); }

    private PomodoroPhase? _timerPhase;
    public PomodoroPhase? TimerPhase { get => _timerPhase; set => Set(ref _timerPhase, value); }

    private int _timerRound = 1;
    public int TimerRound { get => _timerRound; set => Set(ref _timerRound, value); }
}

public static class AtomicFile
{
    /// Via a temporary file, so a crash mid-write can't leave half a notes file.
    public static void Write(string path, string text)
    {
        var temp = path + ".tmp";
        File.WriteAllText(temp, text);
        File.Move(temp, path, overwrite: true);
    }
}

public static class Log
{
    public static void Write(string message)
    {
        System.Diagnostics.Trace.WriteLine("Resonata: " + message);
        try
        {
            var path = Path.Combine(Paths.Data, "resonata.log");
            if (File.Exists(path) && new FileInfo(path).Length > 256 * 1024) File.Delete(path);
            File.AppendAllText(path, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {message}{Environment.NewLine}");
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Logging must never take the app down.
        }
    }
}
