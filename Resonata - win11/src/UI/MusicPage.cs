using System.ComponentModel;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace Resonata;

/// The player, and under it the days and their events.
public sealed class MusicPage : Grid, IPage
{
    /// The cover alone above the song, and beside nothing; smaller with the
    /// calendar under the player, to leave it room.
    public const double CoverSize = 190, CoverSizeWithCalendar = 84;
    private static readonly Color FallbackAccent = Color.FromRgb(92, 153, 255);

    private readonly PanelModel _m;
    private readonly CoverView _cover = new(CoverSize);
    private readonly Button _badge;
    private readonly Image _badgeImage = new() { Width = 24, Height = 24 };
    private readonly TextBlock _title = Ui.Label("", 15, FontWeights.Bold, Brushes.White);
    private readonly TextBlock _artist = Ui.Label("", 12, FontWeights.SemiBold, Ui.White(0.55));
    private readonly LyricsLine _lyric;
    private readonly ThinBar _progress = new() { Height = 12 };
    private readonly TextBlock _elapsed = Ui.Label("0:00", 9, FontWeights.Medium, Ui.White(0.45));
    private readonly TextBlock _total = Ui.Label("0:00", 9, FontWeights.Medium, Ui.White(0.45));
    private readonly TextBlock _playIcon = Ui.Icon(Glyph.Play, 19, Brushes.White);
    private readonly SpotifyVolumeControl _volume = new();
    private readonly StackPanel _textColumn = new();
    private readonly Rectangle _divider = new() { Fill = Ui.White(0.1), Height = 1, Margin = new Thickness(8, 10, 8, 10) };
    private readonly CalendarColumn _calendar;
    /// Claude Code's and Vibe's limits, in the song's place while nothing plays.
    private readonly UsagePage _usage;
    private Grid _column = null!;
    private readonly DispatcherTimer _clock = new();
    private readonly Delay _releaseScrub = new();
    private double? _scrubFraction;
    private bool _open;
    private readonly LyricsList _lyricsList;
    private readonly Button _lyricsBack;
    private FrameworkElement _progressBlock = null!, _controlsBlock = null!;
    private readonly Delay _liveDelay = new();
    private bool _liveSettled;
    private string? _songKey;
    /// The bigger lyrics view was asked for; shown while there are lyrics.
    private bool _lyricsMode;

    public MusicPage(PanelModel model)
    {
        _m = model;
        _calendar = new CalendarColumn { Margin = new Thickness(0, 2, 0, 0) };
        _lyric = new LyricsLine(model);
        // A click on the line being sung brings up more of the song.
        _lyric.Background = Brushes.Transparent;
        _lyric.Cursor = Cursors.Hand;
        _lyric.ToolTip = L.T("Show more of the lyrics", "Zobrazit víc textu");
        _lyric.MouseLeftButtonUp += (_, e) =>
        {
            if (_m.Lyrics is null) return;
            SetLyricsMode(true);
            e.Handled = true;
        };
        _lyricsList = new LyricsList(model) { Visibility = Visibility.Collapsed, VerticalAlignment = VerticalAlignment.Bottom };
        _lyricsBack = Ui.Button(Ui.Icon(Glyph.Back, 10, Ui.White(0.6)), () => SetLyricsMode(false),
            L.T("Back to the player", "Zpět k přehrávači"), 22, 18);
        _lyricsBack.HorizontalAlignment = HorizontalAlignment.Right;
        _lyricsBack.VerticalAlignment = VerticalAlignment.Top;
        _lyricsBack.Visibility = Visibility.Collapsed;

        // One under the other, the panel standing along the screen's edge:
        // the cover, the song and its buttons, then the calendar.
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var coverHost = new Grid { Width = CoverSize, Height = CoverSize, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top };
        CoverHost = coverHost;
        coverHost.Children.Add(_cover);
        _badge = Ui.Button(new Border
        {
            Width = 28, Height = 28, CornerRadius = new CornerRadius(14), Background = Brushes.Black,
            Child = _badgeImage,
        }, OpenPlayer);
        _badge.HorizontalAlignment = HorizontalAlignment.Right;
        _badge.VerticalAlignment = VerticalAlignment.Bottom;
        _badge.Margin = new Thickness(0, 0, -7, -7);
        coverHost.Children.Add(_badge);
        Children.Add(coverHost);

        var column = _column = BuildColumn();
        SetRow(column, 1);
        Children.Add(column);

        _usage = new UsagePage(model) { Visibility = Visibility.Collapsed };
        SetRowSpan(_usage, 2);
        Children.Add(_usage);

        SetRow(_divider, 2);
        Children.Add(_divider);
        SetRow(_calendar, 3);
        Children.Add(_calendar);

        _clock.Tick += (_, _) => UpdateProgress();
        _progress.Scrubbing = f => { _scrubFraction = f; _releaseScrub.Cancel(); UpdateTimes(); };
        _progress.Scrubbed = OnScrubbed;

        _m.PropertyChanged += OnModelChanged;
        Settings.Current.PropertyChanged += OnSettingsChanged;
        Refresh();
    }

    /// Where the cover sits, for the one flying between the pill and the panel to land on.
    public FrameworkElement CoverHost { get; }

    /// The flying cover stands in for this one, badge and all, while it's in
    /// the air; the player's badge comes back once it has landed.
    public void CoverInFlight(bool flying)
    {
        _cover.Opacity = flying ? 0 : 1;
        _badge.BeginAnimation(OpacityProperty, flying ? null : Anim.To(1, 0.2, Anim.EaseOut));
        if (flying) _badge.Opacity = 0;
    }

    private Grid BuildColumn()
    {
        // As tall as its tallest state, so nothing under it moves when the
        // lyrics take the bar's and the buttons' place.
        var column = new Grid { Height = 136, Margin = new Thickness(0, 14, 0, 0), VerticalAlignment = VerticalAlignment.Top };
        column.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        column.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        column.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        column.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        _artist.Margin = new Thickness(0, 1, 0, 0);
        _lyric.Margin = new Thickness(0, 2, 0, 0);
        _textColumn.Margin = new Thickness(0, -3, 0, 0);
        _textColumn.Children.Add(_title);
        _textColumn.Children.Add(_artist);
        _textColumn.Children.Add(_lyric);
        column.Children.Add(_textColumn);

        var progress = new StackPanel();
        progress.Children.Add(_progress);
        var times = new Grid { Margin = new Thickness(0, 1, 0, 0) };
        _total.HorizontalAlignment = HorizontalAlignment.Right;
        times.Children.Add(_elapsed);
        times.Children.Add(_total);
        progress.Children.Add(times);
        SetRow(progress, 2);
        column.Children.Add(progress);
        _progressBlock = progress;

        // The buttons in the middle, under the cover; the volume under them.
        var controls = new StackPanel { Margin = new Thickness(0, 4, 0, 0) };
        // Each button has 14 to its right; as much to the left of the first centres the three.
        var transport = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(14, 0, 0, 0) };
        transport.Children.Add(Transport(Ui.Icon(Glyph.Previous, 15, Brushes.White), TransportCommand.Previous));
        transport.Children.Add(Transport(_playIcon, TransportCommand.PlayPause));
        transport.Children.Add(Transport(Ui.Icon(Glyph.Next, 15, Brushes.White), TransportCommand.Next));
        controls.Children.Add(transport);
        _volume.HorizontalAlignment = HorizontalAlignment.Center;
        _volume.Margin = new Thickness(0, 2, 0, 0);
        controls.Children.Add(_volume);
        SetRow(controls, 3);
        column.Children.Add(controls);
        _controlsBlock = controls;

        // The bigger lyrics view, in the bar's and the buttons' place.
        SetRow(_lyricsList, 1);
        SetRowSpan(_lyricsList, 3);
        column.Children.Add(_lyricsList);
        column.Children.Add(_lyricsBack);
        return column;
    }

    private static Button Transport(UIElement icon, TransportCommand command)
    {
        var button = Ui.Button(icon, () => MediaService.Active?.Send(command), null, 30, 26);
        // No tooltip on these, but a name for a screen reader.
        System.Windows.Automation.AutomationProperties.SetName(button, command switch
        {
            TransportCommand.Previous => L.T("Previous", "Předchozí"),
            TransportCommand.Next => L.T("Next", "Další"),
            _ => L.T("Play or pause", "Přehrát nebo pozastavit"),
        });
        button.Margin = new Thickness(0, 0, 14, 0);
        return button;
    }

    private void OpenPlayer()
    {
        if (_m.Track is { } track) PlayerApp.Open(track.Source);
        _m.Close?.Invoke();
    }

    private void OnModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(PanelModel.Track): Refresh(); break;
            case nameof(PanelModel.Artwork): _cover.SetImage(_m.Artwork); break;
            case nameof(PanelModel.Accent): UpdateAccent(); break;
            case nameof(PanelModel.Lyrics): ApplyLyricsMode(); break;
            case nameof(PanelModel.Claude):
            case nameof(PanelModel.Vibe): UpdateLayoutForSettings(); break;
        }
    }

    /// Nothing playing, and Claude Code or Vibe has something to say: the
    /// limits take the place of the empty cover and "Nothing playing".
    private bool UsageShown => _m.Track is null && _m.AiHasSomething;

    private void OnSettingsChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(Settings.ShowCalendar) or nameof(Settings.ShowLyrics)) ApplyLyricsMode();
    }

    /// The bigger lyrics view is up: asked for, switched on, and there are lyrics.
    private bool LyricsShown => _lyricsMode && Settings.Current.ShowLyrics && _m.Lyrics is not null;

    /// A few lines of the song at once, in the bar's and the buttons' place;
    /// a click on a line jumps the song there. Kept from song to song until
    /// the arrow in the corner is clicked; a song without lyrics shows the player.
    private void SetLyricsMode(bool on)
    {
        _lyricsMode = on;
        ApplyLyricsMode();
    }

    private void ApplyLyricsMode()
    {
        var list = LyricsShown;
        _lyricsList.Visibility = _lyricsBack.Visibility = list ? Visibility.Visible : Visibility.Collapsed;
        _progressBlock.Visibility = _controlsBlock.Visibility = _artist.Visibility =
            list ? Visibility.Collapsed : Visibility.Visible;
        _lyricsList.SetActive(list && _open);
        UpdateLayoutForSettings();
    }

    private void UpdateLayoutForSettings()
    {
        var calendar = Settings.Current.ShowCalendar;
        _divider.Visibility = _calendar.Visibility = calendar ? Visibility.Visible : Visibility.Collapsed;
        var usage = UsageShown;
        // Under the song's place there is the wave: with both tools' cards
        // there, the sessions are left to the limits' own page.
        var sessions = _m.Claude is not null && _m.Vibe is not null ? 0 : 3;
        if (usage != (_usage.Visibility == Visibility.Visible) || _usage.Compact != calendar || _usage.MaxSessions != sessions)
        {
            _usage.Compact = calendar;
            _usage.MaxSessions = sessions;
            _usage.Visibility = usage ? Visibility.Visible : Visibility.Collapsed;
            CoverHost.Visibility = _column.Visibility = usage ? Visibility.Collapsed : Visibility.Visible;
            _usage.PanelVisibilityChanged(_open && usage);
        }
        var size = calendar ? CoverSizeWithCalendar : CoverSize;
        if (CoverHost.Width != size)
        {
            CoverHost.Width = CoverHost.Height = size;
            _cover.SetSize(size);
        }
        // Centred under the cover.
        _title.TextAlignment = _artist.TextAlignment = TextAlignment.Center;
        _lyric.Alignment = TextAlignment.Center;
        _lyricsList.Alignment = TextAlignment.Center;
        var list = LyricsShown;
        // Clear of the arrow in the corner, and still in the middle.
        _title.Margin = new Thickness(list ? 26 : 0, 0, list ? 26 : 0, 0);
        // Only for something lyrics are looked up for: under a podcast or a
        // film "no lyrics found" was just noise.
        _lyric.Visibility = !list && Settings.Current.ShowLyrics && _m.Track is { } track && LyricsRules.ShouldLookUp(track)
            ? Visibility.Visible : Visibility.Collapsed;
    }

    private void Refresh()
    {
        var track = _m.Track;
        _title.Text = track?.Title ?? L.T("Nothing playing", "Nic nehraje");
        _artist.Text = track?.Artist ?? "";
        _playIcon.Text = track?.IsPlaying == true ? Glyph.Pause : Glyph.Play;
        _total.Text = TimeText.Clock(track?.Duration ?? 0);
        _progress.Visibility = Visibility.Visible;
        _volume.SetTrack(track);
        _badgeImage.Source = track is null ? null : PlayerApp.Icon(track.Source);
        _badge.Visibility = _badgeImage.Source is null ? Visibility.Collapsed : Visibility.Visible;
        _badge.ToolTip = L.T("Open the player", "Otevřít přehrávač");
        _cover.SetImage(_m.Artwork);
        UpdateAccent();
        UpdateLayoutForSettings();

        var song = track is null ? null : $"{track.Title}\u001F{track.Artist}\u001F{track.Source}";
        if (song != _songKey)
        {
            // A song's length can arrive a beat after its title; only one
            // still without it after this long is a live stream.
            _songKey = song;
            _liveSettled = false;
            _liveDelay.After(1.5, () => { _liveSettled = true; UpdateProgress(); });
        }

        UpdateClock();
        UpdateProgress();
    }

    /// A radio station, a live stream: nowhere to scrub to, and a bar stuck
    /// at the start over "0:00 / 0:00" read as broken.
    private bool IsLive => _m.Track is { } track && LiveRules.IsLive(track.Duration, _liveSettled);

    private void UpdateAccent()
    {
        var text = Ui.AccentText(_m.Accent);
        _artist.Foreground = text is { } c ? Ui.Solid(c) : Ui.White(0.55);
        _lyricsList.Accent = text is { } l ? Ui.Solid(l) : Brushes.White;
        _progress.Fill = text is { } p ? Ui.Solid(p) : Brushes.White;
        _calendar.Accent = text ?? FallbackAccent;
        _volume.Tint = text is { } v ? Ui.Solid(v) : Brushes.White;
    }

    public void PanelVisibilityChanged(bool panelOpen)
    {
        _open = panelOpen;
        _lyric.SetActive(panelOpen);
        _lyricsList.SetActive(panelOpen && LyricsShown);
        UpdateClock();
        UpdateProgress();
        _usage.PanelVisibilityChanged(panelOpen && UsageShown);
        if (panelOpen) { _calendar.GoToToday(); _volume.Reread(); }
    }

    /// As often as the bar moves a device pixel, not thirty times a second:
    /// each redraw is a layout pass, and that was most of the open panel's cost.
    private void UpdateClock()
    {
        var run = _open && _m.Track?.IsPlaying == true;
        _clock.Interval = TimeSpan.FromSeconds(TimeText.ProgressInterval(_m.Track?.Duration ?? 0));
        if (run) _clock.Start(); else _clock.Stop();
    }

    private double Fraction(DateTime at) =>
        _m.Track is { Duration: > 0 } t ? Math.Clamp(t.Position(at) / t.Duration, 0, 1) : 0;

    private void UpdateProgress()
    {
        if (_progress.IsDragging) return;
        var live = IsLive;
        _progress.IsEmpty = live;
        _progress.IsHitTestVisible = !live;
        _progress.Value = live ? 0 : _scrubFraction ?? Fraction(DateTime.Now);
        UpdateTimes();
    }

    private void UpdateTimes()
    {
        if (IsLive)
        {
            _elapsed.Text = L.T("● LIVE", "● ŽIVĚ");
            _total.Text = "";
            return;
        }
        var duration = _m.Track?.Duration ?? 0;
        _elapsed.Text = TimeText.Clock((_scrubFraction ?? Fraction(DateTime.Now)) * duration);
        _total.Text = TimeText.Clock(duration);
    }

    private void OnScrubbed(double fraction)
    {
        _scrubFraction = fraction;
        if (_m.Track is { Duration: > 0 } track) MediaService.Active?.Seek(fraction * track.Duration);
        // Handed back once the player has had time to report the new position;
        // releasing at once makes the knob snap backwards.
        _releaseScrub.After(1.4, () => { _scrubFraction = null; UpdateProgress(); });
    }
}

/// The lyric being sung: the old line leaves upward as the next rises in.
public sealed class LyricsLine : Grid
{
    private const double LineHeight = 15;

    private readonly PanelModel _m;
    private readonly TextBlock _a = Make(), _b = Make();
    private readonly Delay _next = new();
    private TextBlock _front;
    private int _row = -2;
    private bool _active;

    private static TextBlock Make()
    {
        var text = Ui.Label("", 11, FontWeights.Medium, Ui.White(0.85));
        text.RenderTransform = new TranslateTransform();
        text.Height = LineHeight;
        return text;
    }

    public LyricsLine(PanelModel model)
    {
        _m = model;
        _front = _a;
        Height = LineHeight;
        ClipToBounds = true;
        Children.Add(_a);
        Children.Add(_b);
        _b.Opacity = 0;
        model.PropertyChanged += (_, e) =>
        {
            // Another song's line can share this one's number.
            if (e.PropertyName == nameof(PanelModel.Lyrics)) _row = -2;
            if (e.PropertyName is nameof(PanelModel.Track) or nameof(PanelModel.Lyrics) or nameof(PanelModel.LyricsPending))
                Update();
        };
    }

    public TextAlignment Alignment
    {
        set => _a.TextAlignment = _b.TextAlignment = value;
    }

    public void SetActive(bool active)
    {
        _active = active;
        Update();
    }

    private void Update()
    {
        _next.Cancel();
        if (!_active) return;
        if (_m.Lyrics is not { } lines)
        {
            _row = -2;
            Show(_m.LyricsPending ? "…" : L.T("No lyrics found", "Text nenalezen"), 0.35, animate: false);
            return;
        }

        var now = DateTime.Now;
        var position = _m.Track?.Position(now) ?? 0;
        var index = Lrc.Index(lines, position);
        var row = (index ?? -1) + 1;
        var text = row == 0 || lines[row - 1].Text.Length == 0 ? "♪" : lines[row - 1].Text;
        if (row != _row)
        {
            var animate = _row >= 0 && row == _row + 1;
            _row = row;
            Show(text, 0.85, animate);
        }

        // Redrawn when a line begins, not ten times a second.
        if (_m.Track is { IsPlaying: true } && row < lines.Count)
            _next.After(Math.Max(0.02, lines[row].Time - position), Update);
    }

    private void Show(string text, double opacity, bool animate)
    {
        var back = _front == _a ? _b : _a;
        var brush = Ui.White(opacity);
        if (!animate)
        {
            _front.Text = text;
            _front.Foreground = brush;
            _front.BeginAnimation(OpacityProperty, null);
            _front.Opacity = 1;
            ((TranslateTransform)_front.RenderTransform).BeginAnimation(TranslateTransform.YProperty, null);
            ((TranslateTransform)_front.RenderTransform).Y = 0;
            back.BeginAnimation(OpacityProperty, null);
            back.Opacity = 0;
            return;
        }

        back.Text = text;
        back.Foreground = brush;
        const double duration = 0.4;
        back.BeginAnimation(OpacityProperty, Anim.To(1, duration, Anim.EaseOut));
        ((TranslateTransform)back.RenderTransform).BeginAnimation(TranslateTransform.YProperty,
            new DoubleAnimation(LineHeight, 0, TimeSpan.FromSeconds(duration)) { EasingFunction = Anim.EaseOut });
        _front.BeginAnimation(OpacityProperty, Anim.To(0, duration, Anim.EaseOut));
        ((TranslateTransform)_front.RenderTransform).BeginAnimation(TranslateTransform.YProperty,
            Anim.To(-LineHeight, duration, Anim.EaseOut));
        _front = back;
    }
}

/// A few lines of the song at once, the one being sung picked out and kept
/// in the middle; a click on a line jumps the song there. Redrawn only as a
/// line begins, like the single line it stands in for.
public sealed class LyricsList : StackPanel
{
    public const int Lines = 5;
    private const double RowHeight = 17;

    private readonly PanelModel _m;
    private readonly TextBlock[] _rows = new TextBlock[Lines];
    private readonly Border[] _slots = new Border[Lines];
    /// Which line of the song each row is showing; -1 for none.
    private readonly int[] _lineOf = new int[Lines];
    private readonly Delay _next = new();
    private Brush _accent = Brushes.White;
    private bool _active;

    public LyricsList(PanelModel model)
    {
        _m = model;
        for (var i = 0; i < Lines; i++)
        {
            var slot = i;
            var text = Ui.Label("", 12, FontWeights.Medium, Ui.White(0.4));
            text.VerticalAlignment = VerticalAlignment.Center;
            _rows[i] = text;
            _lineOf[i] = -1;
            // Transparent, not null: the whole row takes the click, not just the letters.
            var row = new Border
            {
                Height = RowHeight, Background = Brushes.Transparent, Cursor = Cursors.Hand, Child = text,
                ToolTip = L.T("Jump to this line", "Skočit na tenhle řádek"),
            };
            row.MouseLeftButtonUp += (_, e) => { Seek(slot); e.Handled = true; };
            _slots[i] = row;
            Children.Add(row);
        }
        model.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(PanelModel.Track) or nameof(PanelModel.Lyrics)) Update();
        };
    }

    public Brush Accent { set { _accent = value; Update(); } }

    public TextAlignment Alignment
    {
        set { foreach (var row in _rows) row.TextAlignment = value; }
    }

    public void SetActive(bool active)
    {
        _active = active;
        Update();
    }

    private void Seek(int slot)
    {
        var index = _lineOf[slot];
        if (_m.Lyrics is { } lines && index >= 0 && index < lines.Count)
            MediaService.Active?.Seek(lines[index].Time);
    }

    private void Update()
    {
        _next.Cancel();
        if (!_active || _m.Lyrics is not { } lines) return;

        var position = _m.Track?.Position(DateTime.Now) ?? 0;
        var current = Lrc.Index(lines, position);
        var (start, count) = LyricsRules.Window(lines.Count, current, Lines);
        for (var slot = 0; slot < Lines; slot++)
        {
            var index = slot < count ? start + slot : -1;
            _lineOf[slot] = index;
            _slots[slot].Visibility = index < 0 ? Visibility.Hidden : Visibility.Visible;
            if (index < 0) continue;
            var sung = index == current;
            _rows[slot].Text = lines[index].Text.Length == 0 ? "♪" : lines[index].Text;
            _rows[slot].FontWeight = sung ? FontWeights.SemiBold : FontWeights.Medium;
            _rows[slot].Foreground = sung ? _accent : Ui.White(0.4);
        }

        var next = (current ?? -1) + 1;
        if (_m.Track is { IsPlaying: true } && next < lines.Count)
            _next.After(Math.Max(0.02, lines[next].Time - position), Update);
    }
}

/// A speaker and a short slider, for Spotify's own level in the Windows mixer.
public sealed class SpotifyVolumeControl : StackPanel
{
    private readonly TextBlock _icon = Ui.Icon(Glyph.Volume3, 12, Ui.White(0.7));
    private readonly ThinBar _bar = new() { Height = 16, RestHeight = 4, ActiveHeight = 4, ShowKnobOnlyWhenActive = false };
    private double? _volume = SpotifyVolume.LastKnown;
    private bool _moved;
    private bool _isSpotify;

    public SpotifyVolumeControl()
    {
        Orientation = Orientation.Horizontal;
        VerticalAlignment = VerticalAlignment.Center;
        var mute = Ui.Button(_icon, ToggleMute, null, 18, 22);
        Children.Add(mute);
        _bar.MinWidth = 40;
        _bar.Width = 76;
        _bar.Margin = new Thickness(6, 0, 0, 0);
        _bar.Scrubbing = f => SetVolume(f * 100);
        _bar.Scrubbed = f => SetVolume(f * 100);
        Children.Add(_bar);
        ToolTip = L.T("Spotify's volume — Spotify only, not the whole PC", "Hlasitost Spotify — jen Spotify, ne celého počítače");
        Visibility = Visibility.Collapsed;
    }

    public Brush Tint { set => _bar.Fill = value; }

    public void SetTrack(Track? track)
    {
        var spotify = track?.IsSpotify == true;
        if (spotify == _isSpotify) { Refresh(); return; }
        _isSpotify = spotify;
        Reread();
    }

    /// Spotify's own slider may have moved since the panel last looked.
    public void Reread()
    {
        if (!_isSpotify) { Visibility = Visibility.Collapsed; return; }
        _moved = false;
        Refresh();
        _ = ReadAsync();
    }

    private async Task ReadAsync()
    {
        var value = await SpotifyVolume.ReadAsync();
        if (_moved) return;
        _volume = value;
        SpotifyVolume.LastKnown = value;
        Refresh();
    }

    private void Refresh()
    {
        Visibility = _isSpotify && _volume is not null ? Visibility.Visible : Visibility.Collapsed;
        if (_volume is not { } volume) return;
        _icon.Text = Glyph.Volume(volume);
        if (!_bar.IsDragging) _bar.Value = volume / 100;
        _icon.ToolTip = volume < 1 ? L.T("Unmute Spotify", "Zapnout zvuk Spotify") : L.T("Mute Spotify", "Ztlumit Spotify");
    }

    private void ToggleMute()
    {
        if (_volume is { } volume) SetVolume(SpotifyVolume.ToggledMute(volume, SpotifyVolume.BeforeMute));
    }

    private void SetVolume(double value)
    {
        _moved = true;
        // Where Spotify will really put it: its own slider goes in tenths.
        value = SpotifyVolume.Snap(value, SpotifyVolume.InTenths);
        if (value < 1 && _volume is >= 1) SpotifyVolume.BeforeMute = _volume;
        _volume = value;
        SpotifyVolume.LastKnown = value;
        SpotifyVolume.Set((int)Math.Round(value));
        Refresh();
    }
}

/// Five days around today, today in the album's colour, and the picked day's events.
public sealed class CalendarColumn : StackPanel
{
    private readonly TextBlock _month = Ui.Label("", 15, FontWeights.Bold, Brushes.White);
    private readonly TextBlock _year = Ui.Label("", 11, FontWeights.Medium, Ui.White(0.45));
    private readonly UniformGrid5 _daysRow = new();
    private readonly StackPanel _events = new() { Margin = new Thickness(0, 10, 0, 0) };
    private DateTime _selected = DateTime.Today;
    private Color _accent = Color.FromRgb(92, 153, 255);

    public CalendarColumn()
    {
        var header = new Grid();
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(40) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var label = new StackPanel();
        label.Children.Add(_month);
        label.Children.Add(_year);
        header.Children.Add(label);
        Grid.SetColumn(_daysRow, 1);
        header.Children.Add(_daysRow);
        Children.Add(header);
        Children.Add(_events);

        CalendarStore.Shared.Changed += Rebuild;
        Settings.Current.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(Settings.CalendarUrls)) { _ = CalendarStore.Shared.ReloadAsync(); Rebuild(); }
        };
        Rebuild();
    }

    public Color Accent { set { _accent = value; Rebuild(); } }

    public void GoToToday()
    {
        _selected = DateTime.Today;
        Rebuild();
    }

    private void Rebuild()
    {
        _month.Text = _selected.ToString("MMM", L.Culture).TrimEnd('.');
        _year.Text = _selected.ToString("yyyy", L.Culture);
        _daysRow.Children.Clear();
        foreach (var day in CalendarRules.Days(DateTime.Now)) _daysRow.Children.Add(DayButton(day));
        BuildEvents();
    }

    private Button DayButton(DateTime date)
    {
        var today = date.Date == DateTime.Today;
        var selected = date.Date == _selected;
        var busy = CalendarRules.On(CalendarStore.Shared.Events, date).Any();
        var stack = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center };

        var name = Ui.Label(date.ToString("ddd", L.Culture), 9, FontWeights.SemiBold, Ui.White(today ? 0.9 : 0.4));
        name.HorizontalAlignment = HorizontalAlignment.Center;
        stack.Children.Add(name);

        var number = Ui.Label(date.Day.ToString(), 12, FontWeights.SemiBold, today ? Brushes.Black : Ui.White(0.85));
        number.HorizontalAlignment = HorizontalAlignment.Center;
        number.VerticalAlignment = VerticalAlignment.Center;
        stack.Children.Add(new Border
        {
            Width = 24, Height = 24, CornerRadius = new CornerRadius(12), Margin = new Thickness(0, 3, 0, 3),
            Background = today ? Ui.Solid(_accent) : selected ? Ui.White(0.14) : Brushes.Transparent,
            Child = number,
        });
        // A dot for days with something on, so the strip says where to look.
        stack.Children.Add(new Ellipse { Width = 3, Height = 3, Fill = Ui.White(busy ? 0.5 : 0) });

        return Ui.Button(stack, () => { _selected = date.Date; Rebuild(); });
    }

    private void BuildEvents()
    {
        _events.Children.Clear();
        var store = CalendarStore.Shared;
        if (!CalendarStore.IsConnected && !store.IsDemo)
        {
            _events.Children.Add(Hint(L.T("Your events will appear here.", "Uvidíš tu své události.")));
            var label = Ui.Label(L.T("Connect a calendar", "Připojit kalendář"), 11, FontWeights.SemiBold, Brushes.White);
            label.Margin = new Thickness(10, 0, 10, 0);
            label.VerticalAlignment = VerticalAlignment.Center;
            var button = Ui.Button(Ui.Capsule(label, 0.12, 24), () => SettingsWindow.ShowShared(Window.GetWindow(this)));
            button.HorizontalAlignment = HorizontalAlignment.Left;
            button.Margin = new Thickness(2, 6, 0, 0);
            _events.Children.Add(button);
            return;
        }

        var list = CalendarRules.On(store.Events, _selected).ToList();
        if (list.Count == 0)
        {
            _events.Children.Add(Hint(store.Failed ? L.T("Couldn't load the calendar.", "Kalendář se nepodařilo načíst.") : L.T("No events", "Žádné události")));
            return;
        }
        foreach (var ev in list.Take(2)) _events.Children.Add(Row(ev));
        if (list.Count > 2)
        {
            var more = Ui.Label(L.More(list.Count - 2), 10, FontWeights.Medium, Ui.White(0.4));
            more.Margin = new Thickness(11, 0, 0, 0);
            _events.Children.Add(more);
        }
    }

    private static TextBlock Hint(string text)
    {
        var hint = Ui.Label(text, 11, FontWeights.Normal, Ui.White(0.4));
        hint.Margin = new Thickness(2, 0, 0, 0);
        return hint;
    }

    private Grid Row(CalendarEvent ev)
    {
        var row = new Grid { Margin = new Thickness(0, 0, 0, 8) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(11) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.Children.Add(new Border { Width = 3, Height = 26, CornerRadius = new CornerRadius(1.5), Background = Ui.Solid(_accent), HorizontalAlignment = HorizontalAlignment.Left });
        var text = new StackPanel();
        text.Children.Add(Ui.Label(ev.Title, 12, FontWeights.SemiBold, Brushes.White));
        var time = ev.IsAllDay ? L.T("All day", "Celý den") : $"{ev.Start.ToString("H:mm", L.Culture)} – {ev.End.ToString("H:mm", L.Culture)}";
        text.Children.Add(Ui.Label(time, 10, FontWeights.Normal, Ui.White(0.5)));
        Grid.SetColumn(text, 1);
        row.Children.Add(text);
        return row;
    }
}

public sealed class UniformGrid5 : System.Windows.Controls.Primitives.UniformGrid
{
    public UniformGrid5() { Rows = 1; Columns = 5; }
}
