using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Threading;
using Microsoft.Win32;

namespace Resonata;

/// The one window: transparent, always on top, against the right edge of the
/// screen a third of the way down. The pill comes out of that edge as a tab;
/// the panel opens from it as a little window of its own, standing just off
/// the edge. The shape inside grows and shrinks; the window never resizes.
///
/// Transparent pixels of a layered window don't take clicks, so only the drawn
/// shape blocks anything. And while Resonata is retracted the window is hidden
/// outright: the pointer is watched by position instead, so the edge of the
/// screen stays completely clickable.
public partial class NotchWindow : Window
{
    private const double RetractedX = PanelModel.PillWidth + 34;
    /// How tall the stretch of the edge is that brings the pill out: as tall
    /// as the panel it opens.
    private const double EdgeZoneHeight = PanelModel.ExpandedHeight;
    /// Where the pill comes out: this share of the way down the screen.
    private const double AnchorShare = 0.3;
    /// The open panel stands this far off the edge, with every corner round.
    private const double OpenGap = 12, OpenCorner = 24, PillCorner = 12;
    /// How long the pointer rests on the edge before the pill comes out; in
    /// Hover mode, how much longer on the pill before the panel opens; and how
    /// long after leaving before it goes away.
    private const double DwellSeconds = 0.3, HoldSeconds = 0.8, LeaveSeconds = 0.25;
    /// How long the pill stays once the panel has finished shrinking into it.
    private const double LingerPauseSeconds = 0.6;

    private readonly PanelModel _m;
    private readonly HotKey _hotKey = new();
    private readonly CoverView _pillCover = new(32);
    private readonly TextBlock _pillSymbol = Ui.Icon("", 16, Brushes.White);
    private readonly MusicBars _bars = new() { Height = 16 };
    private readonly TextBlock _trailSymbol = Ui.Icon("", 14, Brushes.White);
    private readonly TextBlock _timerBadge;
    private readonly DispatcherTimer _pointer = new() { Interval = TimeSpan.FromMilliseconds(50) };
    private readonly BlurEffect _focusBlur = new() { Radius = 0, RenderingBias = RenderingBias.Performance };
    private readonly BlurEffect _pillBlur = new() { Radius = 0, RenderingBias = RenderingBias.Performance };
    private readonly LinearGradientBrush _wash = new(
        new GradientStopCollection { new(Colors.Transparent, 0), new(Colors.Transparent, 0.45), new(Colors.Transparent, 1) },
        new Point(0, 0), new Point(1, 1)) { MappingMode = BrushMappingMode.Absolute };
    private bool _waveShown;
    private readonly PageSwipeTracker _pageSwipe = new(), _pillSwipe = new(), _wheelStrip = new(), _pillWheel = new();

    private readonly Dictionary<PanelTab, FrameworkElement> _pages = [];
    private readonly Dictionary<PanelTab, Button> _tabButtons = [];
    private readonly Border _tabHighlight = new() { Background = Ui.White(0.14), Height = 20, CornerRadius = new CornerRadius(10), Width = 28 };
    private readonly TranslateTransform _tabHighlightShift = new();
    private TextBlock? _batteryText;
    private TextBlock? _batteryIcon;
    private StackPanel? _batteryPanel;
    private Button? _screenButton;
    private FrameworkElement? _shownPage;

    private IntPtr _hwnd;
    /// `_edge` is the corners against the screen's edge: square on the pill,
    /// round once the panel has stood off it; `_far` the ones away from it.
    private Spring _width = new(PanelModel.PillWidth), _height = new(PanelModel.PillHeight),
        _edge = new(0), _far = new(PillCorner), _gap = new(0), _x = new(RetractedX);
    /// The cover flying between the pill and the panel (see `StartFlight`).
    private readonly CoverView _flyingCover = new(32) { HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top, IsHitTestVisible = false, Visibility = Visibility.Collapsed };
    private readonly TranslateTransform _flyingShift = new();
    private bool _flying;
    private Rect _flightFrom, _flightTo;
    private static readonly bool Trace = Environment.GetEnvironmentVariable("RESONATA_TRACE") == "1";
    private bool _animating;
    private TimeSpan _lastFrame;
    private bool _windowShown;
    private bool _peekSuppressed;

    private DateTime? _dwellStart, _holdStart, _leftAt;
    private bool _pointerInside;
    /// The pointer has been on the open panel. Until then, being off it means
    /// nothing: the shortcut or the tray icon opens it from across the screen.
    private bool _pointerReachedPanel;
    /// Just closed with the pointer still up there: it has to leave the edge
    /// before resting on it counts again, or the panel would reopen by itself.
    private bool _needsLeave;
    private IntPtr _hook, _edgeHook;
    private Native.HookProc? _hookProc, _edgeHookProc;
    private bool _swallowUp;
    /// The panel has just shrunk back: the pill stays a moment before it leaves.
    private bool _lingering;
    private readonly Delay _linger = new();
    private static readonly bool LogFrames = Environment.GetEnvironmentVariable("RESONATA_ANIMTEST") == "1";
    private readonly List<double> _frameTimes = [];
    private IntPtr _previousForeground;

    public Action? ShowMenu { get; set; }

    public NotchWindow(PanelModel model)
    {
        _m = model;
        InitializeComponent();
        Wash.Fill = _wash;

        _timerBadge = Ui.Label("", 11, FontWeights.SemiBold, Ui.Solid(ActivityLook.Orange));
        _timerBadge.HorizontalAlignment = HorizontalAlignment.Center;
        _timerBadge.VerticalAlignment = VerticalAlignment.Center;
        _timerBadge.TextTrimming = TextTrimming.None;

        _flyingCover.RenderTransform = _flyingShift;
        Shape.Children.Add(_flyingCover);
        CoverSlot.Children.Add(_pillCover);
        CoverSlot.Children.Add(_pillSymbol);
        TrailSlot.Children.Add(_bars);
        TrailSlot.Children.Add(_trailSymbol);
        TrailSlot.Children.Add(_timerBadge);

        BuildTopBar();

        _m.Open = () => Expand();
        _m.Close = Collapse;
        _m.Toggle = () => { if (_m.IsExpanded) Collapse(); else Expand(); };
        _m.SwitchScreen = () => { Screens.PinNext(); Collapse(); PlaceOnScreen(); };
        _m.PropertyChanged += OnModelChanged;
        Settings.Current.PropertyChanged += OnSettingsChanged;
        CountdownTimer.Shared.Ticked += UpdatePill;

        SourceInitialized += OnSourceInitialized;
        PreviewMouseLeftButtonDown += OnPreviewLeftDown;
        PreviewMouseRightButtonUp += (_, e) =>
        {
            // Right-click in a note is the usual copy and paste.
            if (ClickedTextBox(e.OriginalSource as DependencyObject)) return;
            ShowMenu?.Invoke();
            e.Handled = true;
        };
        PreviewMouseDown += OnPreviewAnyDown;
        PreviewMouseWheel += OnWheel;
        DragEnter += OnFileDragEnter;
        DragOver += OnFileDragOver;
        Drop += OnFileDrop;

        _pointer.Tick += (_, _) => PointerTick();
        SystemEvents.DisplaySettingsChanged += (_, _) => Dispatcher.BeginInvoke(ScreensChanged);

        Expanded.Effect = null;
        ApplyFrame();
        UpdatePill();
        UpdateWash();
        UpdateWaveColour();
        UpdateExpandedWidth();
    }

    /// Creates the window handle without showing anything.
    public void Prepare()
    {
        new WindowInteropHelper(this).EnsureHandle();
        ScreensChanged();
        _pointer.Start();
        // Built ahead of time: creating them during the first open is a stutter.
        ShowTab(_m.Tab, animate: false);
        Dispatcher.BeginInvoke(() => { foreach (var tab in Enum.GetValues<PanelTab>()) Page(tab); }, DispatcherPriority.ApplicationIdle);
    }

    private void OnSourceInitialized(object? sender, EventArgs e)
    {
        _hwnd = new WindowInteropHelper(this).Handle;
        var style = (long)Native.GetWindowLongPtr(_hwnd, Native.GWL_EXSTYLE);
        Native.SetWindowLongPtr(_hwnd, Native.GWL_EXSTYLE, (IntPtr)(style | Native.WS_EX_NOACTIVATE | Native.WS_EX_TOOLWINDOW));
        HwndSource.FromHwnd(_hwnd)?.AddHook(WndProc);
        _hotKey.Attach(_hwnd);
        _hotKey.Pressed = () => _m.Toggle?.Invoke();
        ApplyHotKey();
    }

    public bool ApplyHotKey() => _hotKey.Apply(Settings.Current.HotKey);

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == Native.WM_HOTKEY)
        {
            _hotKey.Pressed?.Invoke();
            handled = true;
        }
        else if (msg == Native.WM_MOUSEHWHEEL)
        {
            var delta = (short)((wParam.ToInt64() >> 16) & 0xFFFF);
            OnSidewaysScroll(delta);
            handled = true;
        }
        else if (msg == Native.WM_MOUSEWHEEL && !_m.IsExpanded)
        {
            // On the pill, straight from Windows rather than through WPF: the
            // pill comes out under a pointer that's standing still, WPF hasn't
            // seen it arrive, and drops a wheel it thinks is over nothing.
            var delta = (short)((wParam.ToInt64() >> 16) & 0xFFFF);
            var shift = (wParam.ToInt64() & Native.MK_SHIFT) != 0;
            TraceLog($"wheel {delta}{(shift ? " with Shift" : "")} on the pill");
            if (shift) OnSidewaysScroll(-delta);
            else OnPillWheel(delta);
            handled = true;
        }
        return IntPtr.Zero;
    }

    // MARK: Model

    /// `RESONATA_TRACE=1`: what the pointer and the wheel did, in the log, for
    /// a test that drives them to read back.
    private static void TraceLog(string what)
    {
        if (Trace) Log.Write("trace: " + what);
    }

    private void OnModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(PanelModel.IsExpanded) or nameof(PanelModel.EdgeHeld) or nameof(PanelModel.Tab))
            TraceLog($"{e.PropertyName} {typeof(PanelModel).GetProperty(e.PropertyName)!.GetValue(_m)}");
        switch (e.PropertyName)
        {
            case nameof(PanelModel.IsExpanded):
                OnExpandedChanged();
                UpdateTargets();
                break;
            case nameof(PanelModel.EdgeHeld):
            case nameof(PanelModel.Hovering):
                UpdateTargets();
                break;
            case nameof(PanelModel.Peeking):
                // Automatic slide-outs keep out of a game or a film.
                _peekSuppressed = _m.Peeking && IsFullScreenNow();
                UpdateTargets();
                break;
            case nameof(PanelModel.Track):
            case nameof(PanelModel.Activity):
            case nameof(PanelModel.TimerRunning):
                UpdatePill();
                Wave.IsAnimating = _m.Track?.IsPlaying == true;
                break;
            case nameof(PanelModel.Artwork):
                _pillCover.SetImage(_m.Artwork);
                break;
            case nameof(PanelModel.Accent):
                UpdateWash();
                UpdateWaveColour();
                break;
            case nameof(PanelModel.Tab):
                ShowTab(_m.Tab);
                break;
        }
    }

    private void OnSettingsChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(Settings.ShowCalendar):
                UpdateExpandedWidth();
                UpdateTargets();
                break;
            case nameof(Settings.WaveColour):
            case nameof(Settings.CustomWaveColour):
                UpdateWaveColour();
                break;
        }
    }

    private void UpdateExpandedWidth()
    {
        Expanded.Width = _m.ExpandedWidth - 40;
        Wave.Width = _m.ExpandedWidth - 44;
    }

    private void UpdateWaveColour()
    {
        Wave.SetColor(Settings.Current.WaveColour switch
        {
            WaveColour.Album => _m.Accent,
            WaveColour.Custom => Ui.ParseHex(Settings.Current.CustomWaveColour),
            _ => null,
        });
    }

    /// Colour bleeding out of the top-left, over solid black, fading before the
    /// opposite corner. Stronger open, where it reads as deliberate.
    private void UpdateWash()
    {
        var tint = _m.Accent ?? Colors.Transparent;
        var open = _m.IsExpanded;
        Color At(double opacity) => Color.FromArgb((byte)(255 * opacity * (_m.Accent is null ? 0 : 1)), tint.R, tint.G, tint.B);
        Color[] targets = [At(open ? 0.55 : 0.38), At(open ? 0.16 : 0.18), At(open ? 0 : 0.06)];
        // Glides to the new strength or the new song's colour, rather than jumping.
        for (var i = 0; i < targets.Length; i++)
            _wash.GradientStops[i].BeginAnimation(GradientStop.ColorProperty,
                new ColorAnimation(targets[i], TimeSpan.FromSeconds(0.45)) { EasingFunction = Anim.EaseInOut });
    }

    private void UpdatePill()
    {
        var look = _m.Activity?.Look;
        var timer = CountdownTimer.Shared;
        var showTimer = look is null && _m.TimerRunning;

        PillTitle.Text = look?.Title ?? _m.Track?.Title ?? "Resonata";
        PillDetail.Text = look?.Detail ?? (_m.Track is { } t ? t.Artist : L.T("Nothing playing", "Nic nehraje"));
        PillDetail.Foreground = look is not null ? Ui.Solid(look.Tint) : Ui.White(0.55);
        PillDetail.FontWeight = look is not null ? FontWeights.SemiBold : FontWeights.Normal;

        _pillSymbol.Text = look?.Symbol ?? (_m.Track is null && _m.TimerRunning ? Glyph.Timer : "");
        _pillSymbol.Foreground = look is not null ? Ui.Solid(look.Tint) : Ui.Solid(ActivityLook.Orange);
        _pillCover.Visibility = _pillSymbol.Text.Length > 0 ? Visibility.Hidden : Visibility.Visible;

        var live = _m.Track?.IsPlaying == true || NowForcedLive;
        _bars.Visibility = look is null && !showTimer ? Visibility.Visible : Visibility.Collapsed;
        _bars.IsAnimating = live;
        _bars.Tint = Ui.White(live ? 0.85 : 0.35);

        _trailSymbol.Visibility = look is not null ? Visibility.Visible : Visibility.Collapsed;
        _trailSymbol.Text = look?.Trailing ?? "";
        _trailSymbol.Foreground = look is not null ? Ui.Solid(look.Tint) : Brushes.White;

        _timerBadge.Visibility = showTimer ? Visibility.Visible : Visibility.Collapsed;
        if (showTimer)
        {
            _timerBadge.Text = TimeText.Countdown(timer.Remaining(DateTime.Now));
            _timerBadge.Foreground = Ui.Solid(timer.Phase == PomodoroPhase.Rest ? ActivityLook.Green : ActivityLook.Orange);
            _timerBadge.Opacity = timer.IsPaused ? 0.5 : 1;
        }
    }

    private static bool NowForcedLive => Environment.GetEnvironmentVariable("RESONATA_DEBUG_FORCE_LIVE") == "1";

    // MARK: Shape

    private bool Wanted => _m.IsExpanded || _m.EdgeHeld || _lingering || (_m.Peeking && !_peekSuppressed);

    private void UpdateTargets()
    {
        var hover = _m.Hovering && !_m.IsExpanded;
        if (_m.IsExpanded)
        {
            _width.Target = _m.ExpandedWidth;
            _height.Target = PanelModel.ExpandedHeight;
            _edge.Target = OpenCorner;
            _far.Target = OpenCorner;
            _gap.Target = OpenGap;
        }
        else
        {
            _width.Target = PanelModel.PillWidth + (hover ? 8 : 0);
            _height.Target = PanelModel.PillHeight + (hover ? 2 : 0);
            _edge.Target = 0;
            _far.Target = PillCorner;
            _gap.Target = 0;
        }
        _x.Target = Wanted ? 0 : RetractedX;

        if (Wanted) ShowWindowQuietly();
        StartAnimating();
    }

    private void ShowWindowQuietly()
    {
        if (_windowShown) return;
        _windowShown = true;
        Visibility = Visibility.Visible;
        PlaceOnScreen();
        // Another always-on-top window may have come along since.
        Native.SetWindowPos(_hwnd, Native.HWND_TOPMOST, 0, 0, 0, 0, Native.SWP_NOMOVE | Native.SWP_NOSIZE | Native.SWP_NOACTIVATE);
    }

    private void StartAnimating()
    {
        if (_animating) return;
        _animating = true;
        // Slides as one picture, so its text isn't redrawn at each fraction of a pixel.
        Pill.CacheMode = new BitmapCache();
        _lastFrame = TimeSpan.Zero;
        CompositionTarget.Rendering += OnFrame;
    }

    private void OnFrame(object? sender, EventArgs e)
    {
        var time = ((RenderingEventArgs)e).RenderingTime;
        if (time == _lastFrame) return;
        var dt = _lastFrame == TimeSpan.Zero ? 1.0 / 60 : Math.Min((time - _lastFrame).TotalSeconds, 1.0 / 20);
        _lastFrame = time;

        if (LogFrames) _frameTimes.Add(dt);

        var (response, damping) = Anim.Spring;
        _width.Step(dt, response, damping);
        _height.Step(dt, response, damping);
        _edge.Step(dt, response, damping);
        _far.Step(dt, response, damping);
        _gap.Step(dt, response, damping);
        // Coming out it bounces; leaving, a bounce would only be a hesitation.
        _x.Step(dt, response, _x.Target > 0 ? 1 : damping);
        ApplyFrame();
        if (_flying && _height.Settled) EndFlight();

        if (!(_width.Settled && _height.Settled && _edge.Settled && _far.Settled && _gap.Settled && _x.Settled)) return;
        _width.Snap(); _height.Snap(); _edge.Snap(); _far.Snap(); _gap.Snap(); _x.Snap();
        ApplyFrame();
        CompositionTarget.Rendering -= OnFrame;
        _animating = false;
        // Crisp text again, now that nothing is being scaled.
        Expanded.CacheMode = null;
        Pill.CacheMode = null;
        if (LogFrames) LogFrameStats();
        if (!Wanted) HideWindow();
    }

    private void LogFrameStats()
    {
        if (_frameTimes.Count == 0) return;
        Log.Write($"animation: {_frameTimes.Count} frames, {_frameTimes.Sum():0.00} s, average {_frameTimes.Average() * 1000:0.0} ms, " +
                  $"worst {_frameTimes.Max() * 1000:0.0} ms, over 25 ms: {_frameTimes.Count(t => t > 0.025)}");
        _frameTimes.Clear();
    }

    private void HideWindow()
    {
        if (!_windowShown) return;
        _windowShown = false;
        Visibility = Visibility.Hidden;
    }

    /// Everything the shape is, from one set of numbers, so the clip, the
    /// shadow and the size can never disagree mid-spring.
    private void ApplyFrame()
    {
        // Bouncing past the end of its slide out would open a gap beside the
        // edge of the screen; instead the shape stretches, and springs back.
        var stretch = Math.Max(-_x.Value, 0);
        var shift = Math.Max(_x.Value, 0);
        var w = Math.Max(_width.Value + stretch, 1);
        var h = Math.Max(_height.Value, 1);
        var right = Width - Math.Max(_gap.Value, 0);
        var left = right - w;
        var top = (Height - h) / 2;
        ShapeShift.X = shift;
        Shape.Clip = EdgeGeometry.Build(left, top, w, h, _edge.Value, _far.Value);
        ShadowShape.Data = EdgeGeometry.Build(left + shift, top, w, h, _edge.Value, _far.Value);
        // The colour's gradient runs corner to corner of the shape, not the window.
        _wash.StartPoint = new Point(left, top);
        _wash.EndPoint = new Point(right, top + h);
        var scale = Math.Clamp(h / PanelModel.ExpandedHeight, 0.05, 1);
        ExpandedScale.ScaleX = ExpandedScale.ScaleY = scale;
        if (_flying) PlaceFlyingCover();
    }

    // MARK: The flying cover

    /// The cover grows out of the pill into the panel and shrinks back as one
    /// picture, as the Mac's does, instead of the small one fading with the
    /// pill while the big one is scaled in with the rest. A third cover, seen
    /// only in flight: the pill's and the panel's are hidden for as long, and
    /// it starts and lands on their places, so the swaps change nothing on
    /// screen. Only with a cover at both ends: something playing, and the
    /// panel on the music page.
    private void StartFlight()
    {
        var music = _pages.GetValueOrDefault(PanelTab.Music) as MusicPage;
        if (music is null || _m.Tab != PanelTab.Music || _m.Track is null || _pillSymbol.Text.Length > 0)
        {
            EndFlight();
            return;
        }
        try
        {
            Expanded.UpdateLayout();
            // Where the cover is in the panel at its full size: the panel's
            // place in the shape, which its scale leaves alone, and the
            // cover's in the panel.
            var panel = VisualTreeHelper.GetOffset(Expanded);
            var inPanel = music.CoverHost.TransformToAncestor(Expanded).Transform(new Point());
            _flightTo = new Rect(panel.X + inPanel.X, panel.Y + inPanel.Y, MusicPage.CoverSize, MusicPage.CoverSize);
            var pill = VisualTreeHelper.GetOffset(Pill);
            _flightFrom = new Rect(pill.X, pill.Y, _pillCover.Width, _pillCover.Height);
        }
        catch (InvalidOperationException)
        {
            EndFlight();
            return;
        }
        _flying = true;
        _flyingCover.SetImage(_m.Artwork);
        _flyingCover.Visibility = Visibility.Visible;
        _pillCover.Opacity = 0;
        music.CoverInFlight(true);
        PlaceFlyingCover();
    }

    /// As far between its two places as the shape is between the pill and the
    /// panel, overshoot and all, so it keeps its place in the box all the way.
    private void PlaceFlyingCover()
    {
        var progress = (_height.Value - PanelModel.PillHeight) / (PanelModel.ExpandedHeight - PanelModel.PillHeight);
        var frame = CoverFlight.Frame(_flightFrom, _flightTo, progress);
        _flyingCover.SetSize(Math.Max(1, frame.Width));
        _flyingShift.X = frame.X;
        _flyingShift.Y = frame.Y;
    }

    private void EndFlight()
    {
        if (!_flying) return;
        _flying = false;
        _flyingCover.Visibility = Visibility.Collapsed;
        _pillCover.Opacity = 1;
        (_pages.GetValueOrDefault(PanelTab.Music) as MusicPage)?.CoverInFlight(false);
    }

    /// Fades an element in or out while it comes into or goes out of focus, so
    /// one view melts into the other in both directions. Interrupted half way,
    /// it carries on from where it had got to.
    private void Transition(FrameworkElement element, BlurEffect blur, bool showing, double seconds, double delay = 0)
    {
        const double maxBlur = 12;
        var opacity = element.Opacity;
        var radius = ReferenceEquals(element.Effect, blur) ? blur.Radius : showing ? maxBlur : 0;
        element.BeginAnimation(OpacityProperty, null);
        element.Opacity = opacity;
        blur.BeginAnimation(BlurEffect.RadiusProperty, null);
        blur.Radius = radius;
        element.Effect = blur;
        element.Visibility = Visibility.Visible;

        var fade = Anim.To(showing ? 1 : 0, seconds, Anim.EaseOut, delay);
        fade.Completed += (_, _) =>
        {
            if (showing != (ReferenceEquals(element, Expanded) ? _m.IsExpanded : !_m.IsExpanded)) return;
            // The blur goes once it's done: it would otherwise cost every frame.
            element.Effect = null;
            // Hidden, not collapsed, so the next open needn't lay it all out first.
            if (!showing) element.Visibility = Visibility.Hidden;
        };
        element.BeginAnimation(OpacityProperty, fade);
        blur.BeginAnimation(BlurEffect.RadiusProperty, Anim.To(showing ? 0 : maxBlur, seconds, Anim.EaseOut, delay));
    }

    private void OnExpandedChanged()
    {
        UpdateWash();
        // Scaled as a picture while the shape moves, not re-laid-out text.
        Expanded.CacheMode = new BitmapCache();
        if (_m.IsExpanded)
        {
            Transition(Pill, _pillBlur, false, 0.14);
            Transition(Expanded, _focusBlur, true, 0.36);
            ShowTab(_m.Tab, animate: false);
            CalendarStore.Shared.ReloadIfStale();
            InstallOutsideClickHook();
        }
        else
        {
            RemoveOutsideClickHook();
            ReleaseKeyboard();
            Transition(Expanded, _focusBlur, false, 0.2);
            Transition(Pill, _pillBlur, true, 0.32, 0.1);
        }
        StartFlight();
        UpdateWave();
        foreach (var page in _pages.Values) (page as IPage)?.PanelVisibilityChanged(_m.IsExpanded);
    }

    private void UpdateWave()
    {
        Wave.IsAnimating = _m.Track?.IsPlaying == true;
        var show = _m.IsExpanded && _m.Tab == PanelTab.Music;
        if (show == _waveShown) return;
        _waveShown = show;
        if (show) Wave.Visibility = Visibility.Visible;
        var fade = Anim.To(show ? 1 : 0, show ? 0.36 : 0.18, Anim.EaseOut);
        if (!show) fade.Completed += (_, _) => { if (!_waveShown) Wave.Visibility = Visibility.Collapsed; };
        Wave.BeginAnimation(OpacityProperty, fade);
    }

    public void Expand(PanelTab? tab = null)
    {
        if (tab is { } t) _m.Tab = t;
        if (_m.IsExpanded) return;
        _m.SongPeeking = false;
        _m.ActivityShown = false;
        _m.Activity = null;
        _m.Hovering = false;
        _m.EdgeHeld = false;
        _pointerReachedPanel = false;
        _linger.Cancel();
        _lingering = false;
        _m.IsExpanded = true;
    }

    public void Collapse()
    {
        if (!_m.IsExpanded) return;
        // Set first: closing shrinks it to the pill, and only this keeps it
        // there instead of sliding away in the same motion.
        _lingering = true;
        _linger.After(Anim.Spring.Response * 1.1 + LingerPauseSeconds, () =>
        {
            _lingering = false;
            UpdateTargets();
        });
        _m.IsExpanded = false;
        _pointerInside = false;
        _leftAt = null;
        _holdStart = null;
        _needsLeave = true;
    }

    // MARK: Pointer

    private System.Drawing.Rectangle ScreenBounds => Screens.Target.Bounds;

    // Snapshots photograph every state, and the pointer test drives them,
    // whatever is in front: on CI's ARM64 machine that's Windows' first-run
    // screen, which counts as full screen.
    private bool IsFullScreenNow() => !Snapshots.IsOn && !Trace && Native.IsFullScreen(ScreenBounds, _hwnd);

    /// The stretch of the right edge that brings the pill out, around the line
    /// it comes out on.
    private bool InEdgeZone(Native.POINT p)
    {
        var bounds = ScreenBounds;
        var half = EdgeZoneHeight * CurrentDpi / 2;
        return p.X >= bounds.Right - 1 && p.X <= bounds.Right && Math.Abs(p.Y - AnchorY) <= half;
    }

    private double CurrentDpi => _hwnd == IntPtr.Zero ? 1 : DpiInfo.Of(this);

    /// The line the pill comes out on and the panel is centred on, in screen
    /// pixels: a third of the way down, clear of the buttons in the corner of
    /// a maximized window, and never so high the panel would leave the screen.
    private double AnchorY
    {
        get
        {
            var bounds = ScreenBounds;
            return Math.Max(bounds.Top + bounds.Height * AnchorShare, bounds.Top + Height * CurrentDpi / 2);
        }
    }

    /// Where the shape is heading, in screen pixels. The target rather than the
    /// current size: mid-spring the shape is about to be there anyway. The gap
    /// between the open panel and the edge counts as the panel, so the
    /// pointer can go on to the edge without it closing.
    private bool InsideShape(Native.POINT p)
    {
        var bounds = ScreenBounds;
        var scale = CurrentDpi;
        var w = (_width.Target + _gap.Target) * scale;
        var h = _height.Target * scale;
        var mid = AnchorY;
        // A hair of slack: the pointer stops dead at the very edge.
        return p.X >= bounds.Right - w - 2 && p.X <= bounds.Right + 2 && p.Y >= mid - h / 2 - 2 && p.Y <= mid + h / 2 + 2;
    }

    private void PointerTick()
    {
        if (!Native.GetCursorPos(out var p)) return;
        var now = DateTime.Now;
        var shapeOut = _windowShown && Wanted;
        var inside = shapeOut && InsideShape(p);
        var inZone = InEdgeZone(p);

        if (!inZone && !inside) _needsLeave = false;
        UpdateEdgeClickHook(inZone && !inside && !_m.IsExpanded && Settings.Current.EdgeTrigger && !IsFullScreenNow());

        if (inside != _pointerInside)
        {
            _pointerInside = inside;
            // Hover mode's feedback is the panel opening; a swell on top reads as a wobble.
            _m.Hovering = inside && !_m.IsExpanded && Settings.Current.OpenMode == OpenMode.Click;
        }

        if (_m.IsExpanded)
        {
            if (inside) _pointerReachedPanel = true;
            if (Settings.Current.OpenMode == OpenMode.Hover && _pointerReachedPanel && !inside && !IsTyping && !Native.AnyButtonDown)
            {
                _leftAt ??= now;
                if ((now - _leftAt.Value).TotalSeconds >= LeaveSeconds) Collapse();
            }
            else
            {
                _leftAt = null;
            }
            return;
        }

        if (_m.EdgeHeld)
        {
            if (inside || inZone)
            {
                _leftAt = null;
                // In Hover mode, stay on the pill and the whole panel follows.
                // In Click mode it waits for the click.
                if (Settings.Current.OpenMode != OpenMode.Hover || Native.AnyButtonDown) { _holdStart = null; return; }
                _holdStart ??= now;
                if ((now - _holdStart.Value).TotalSeconds >= HoldSeconds) { _holdStart = null; Expand(); }
                return;
            }
            _holdStart = null;
            _leftAt ??= now;
            if ((now - _leftAt.Value).TotalSeconds >= LeaveSeconds)
            {
                _leftAt = null;
                _m.EdgeHeld = false;
                _m.Hovering = false;
            }
            return;
        }

        // A hand on a window's title bar or a selection must not bring it out;
        // a file being carried up here is exactly what should.
        // Already out and the pointer is on it: there's nothing to wait for. It
        // stays, and in Hover mode grows back into the panel like any other pill.
        if (inside && !_needsLeave && (_lingering || _m.Peeking))
        {
            _dwellStart = null;
            _m.EdgeHeld = true;
            return;
        }
        var armed = Settings.Current.EdgeTrigger && inZone && !_needsLeave && (!Native.AnyButtonDown || Native.IsDraggingFile());
        if (!armed) { _dwellStart = null; return; }
        _dwellStart ??= now;
        if ((now - _dwellStart.Value).TotalSeconds < DwellSeconds) return;
        _dwellStart = null;
        if (IsFullScreenNow() && !_m.Peeking) return;
        _m.EdgeHeld = true;
    }

    private void OnPreviewLeftDown(object sender, MouseButtonEventArgs e)
    {
        if (!_m.IsExpanded)
        {
            Expand();
            e.Handled = true;
            return;
        }
        // The bare strip along the top closes it, the same place a click opened it.
        if (e.GetPosition(TopBar).Y is >= 0 and <= 38 && !IsInside<ButtonBase>(e.OriginalSource as DependencyObject))
        {
            Collapse();
            e.Handled = true;
        }
    }

    // MARK: A click on the edge

    /// Hidden, there's no window at the edge to click, so while the pointer is
    /// in that strip (and only then) a mouse hook watches for the button.
    private void UpdateEdgeClickHook(bool wanted)
    {
        if (wanted && _edgeHook == IntPtr.Zero)
        {
            _edgeHookProc = OnEdgeHook;
            _edgeHook = Native.SetWindowsHookEx(Native.WH_MOUSE_LL, _edgeHookProc, Native.GetModuleHandle(null), 0);
        }
        else if (!wanted && !_swallowUp && _edgeHook != IntPtr.Zero)
        {
            Native.UnhookWindowsHookEx(_edgeHook);
            _edgeHook = IntPtr.Zero;
        }
    }

    /// The click opens the panel and stops there: it isn't passed on, or it
    /// would also press whatever happens to be underneath the panel.
    private IntPtr OnEdgeHook(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0)
        {
            var message = (int)wParam;
            if (message == Native.WM_LBUTTONDOWN)
            {
                var point = Marshal.PtrToStructure<Native.MSLLHOOKSTRUCT>(lParam).pt;
                if (!_m.IsExpanded && InEdgeZone(point) && !(_windowShown && InsideShape(point)))
                {
                    _swallowUp = true;
                    Dispatcher.BeginInvoke(() => Expand());
                    return 1;
                }
            }
            else if (message == Native.WM_LBUTTONUP && _swallowUp)
            {
                _swallowUp = false;
                return 1;
            }
        }
        return Native.CallNextHookEx(_edgeHook, code, wParam, lParam);
    }

    // MARK: Clicks outside

    private void InstallOutsideClickHook()
    {
        if (_hook != IntPtr.Zero) return;
        _hookProc = OnMouseHook;
        _hook = Native.SetWindowsHookEx(Native.WH_MOUSE_LL, _hookProc, Native.GetModuleHandle(null), 0);
    }

    private void RemoveOutsideClickHook()
    {
        if (_hook == IntPtr.Zero) return;
        Native.UnhookWindowsHookEx(_hook);
        _hook = IntPtr.Zero;
    }

    /// Only while the panel is open. It reads where a click landed and nothing
    /// else, and always passes the click on: closing must not eat it.
    private IntPtr OnMouseHook(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0 && (int)wParam is Native.WM_LBUTTONDOWN or Native.WM_RBUTTONDOWN or Native.WM_MBUTTONDOWN)
        {
            var info = Marshal.PtrToStructure<Native.MSLLHOOKSTRUCT>(lParam);
            Dispatcher.BeginInvoke(() => OnGlobalClick(info.pt));
        }
        return Native.CallNextHookEx(_hook, code, wParam, lParam);
    }

    private void OnGlobalClick(Native.POINT p)
    {
        if (!_m.IsExpanded || InsideShape(p)) return;
        // Our own dialogs and menus aren't "outside": the file picker sits on top.
        var under = Native.WindowFromPoint(p);
        Native.GetWindowThreadProcessId(under, out var process);
        if (process == Environment.ProcessId && under != _hwnd) return;
        Collapse();
    }

    // MARK: Keyboard

    private bool IsTyping => Keyboard.FocusedElement is TextBoxBase;

    /// The window never takes focus by itself, so clicking it can't steal the
    /// keyboard from what you're working in. Typing into a note is the one time
    /// it has to.
    private void OnPreviewAnyDown(object sender, MouseButtonEventArgs e)
    {
        if (!_m.IsExpanded || !ClickedTextBox(e.OriginalSource as DependencyObject)) return;
        var style = (long)Native.GetWindowLongPtr(_hwnd, Native.GWL_EXSTYLE);
        if ((style & Native.WS_EX_NOACTIVATE) == 0) return;
        _previousForeground = Native.GetForegroundWindow();
        Native.SetWindowLongPtr(_hwnd, Native.GWL_EXSTYLE, (IntPtr)(style & ~Native.WS_EX_NOACTIVATE));
        Native.SetForegroundWindow(_hwnd);
        Activate();
    }

    private static bool ClickedTextBox(DependencyObject? element) => IsInside<TextBoxBase>(element);

    private static bool IsInside<T>(DependencyObject? element) where T : DependencyObject
    {
        for (; element is not null; element = element is Visual ? VisualTreeHelper.GetParent(element) : LogicalTreeHelper.GetParent(element))
            if (element is T) return true;
        return false;
    }

    private void ReleaseKeyboard()
    {
        Keyboard.ClearFocus();
        var style = (long)Native.GetWindowLongPtr(_hwnd, Native.GWL_EXSTYLE);
        if ((style & Native.WS_EX_NOACTIVATE) != 0) return;
        Native.SetWindowLongPtr(_hwnd, Native.GWL_EXSTYLE, (IntPtr)(style | Native.WS_EX_NOACTIVATE));
        // Hand it back, unless the click that closed us already gave it elsewhere.
        if (Native.GetForegroundWindow() == _hwnd && _previousForeground != IntPtr.Zero)
            Native.SetForegroundWindow(_previousForeground);
        _previousForeground = IntPtr.Zero;
    }

    // MARK: Scrolling

    private void OnWheel(object sender, MouseWheelEventArgs e)
    {
        var now = DateTime.Now;
        TraceLog($"wheel {e.Delta}{(Keyboard.Modifiers.HasFlag(ModifierKeys.Shift) ? " with Shift" : "")}");
        // Shift turns the wheel sideways, as it does in most of Windows; some
        // ways of streaming Windows to a Mac send a trackpad's sideways
        // swipe like that.
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Shift))
        {
            e.Handled = true;
            OnSidewaysScroll(-e.Delta);
            return;
        }
        if (!_m.IsExpanded)
        {
            e.Handled = true;
            OnPillWheel(e.Delta);
            return;
        }
        // Along the strip of icons, the wheel turns the page; a mouse has no
        // sideways scroll. Elsewhere it belongs to whatever's under the pointer.
        if (e.GetPosition(TopBar).Y is >= 0 and <= 38)
        {
            e.Handled = true;
            var step = _wheelStrip.Add(-e.Delta, now);
            if (step != 0) TurnPage(step);
        }
    }

    /// The wheel turned down on the pill opens the panel.
    private void OnPillWheel(int delta)
    {
        if (_pillWheel.Add(-delta, DateTime.Now) > 0) Expand();
    }

    private void OnSidewaysScroll(int delta)
    {
        var now = DateTime.Now;
        TraceLog($"sideways {delta}");
        if (_m.IsExpanded)
        {
            if (Settings.Current.PageSwipe == PageSwipe.Off) return;
            var step = _pageSwipe.Add(delta, now);
            if (step == 0) return;
            // Fingers to the right scroll the content left: a negative delta.
            TurnPage(Settings.Current.PageSwipe == PageSwipe.Reversed ? step : -step);
        }
        else
        {
            // Swiping songs is staying on the pill too; the panel waits for the
            // hand to rest, or it would open in the middle of the next swipe.
            if (_holdStart is not null) _holdStart = now;
            var step = _pillSwipe.Add(delta, now);
            if (step == 0) return;
            var command = step < 0 ? TransportCommand.Next : TransportCommand.Previous;
            TraceLog($"pill swipe {command}");
            MediaService.Active?.Send(command);
        }
    }

    private void TurnPage(int step)
    {
        var next = (int)_m.Tab + step;
        if (Enum.IsDefined(typeof(PanelTab), next)) _m.Tab = (PanelTab)next;
    }

    // MARK: Pages

    private void BuildTopBar()
    {
        const double step = 31;
        var index = 0;
        _tabHighlight.RenderTransform = _tabHighlightShift;
        PageStrip.Children.Add(_tabHighlight);
        foreach (var tab in Enum.GetValues<PanelTab>())
        {
            var icon = Ui.Icon(tab.Symbol(), 13, Ui.White(0.4));
            var captured = tab;
            var button = Ui.Button(icon, () => _m.Tab = captured, tab.Title(), 28, 20);
            Canvas.SetLeft(button, index * step);
            PageStrip.Children.Add(button);
            _tabButtons[tab] = button;
            index++;
        }

        _screenButton = StatusButton(Glyph.Screens, L.T("Move to the next display", "Přepnout na další monitor"), () => _m.SwitchScreen?.Invoke());
        StatusItems.Children.Add(_screenButton);
        StatusItems.Children.Add(StatusButton(Glyph.Settings, L.T("Settings", "Nastavení"), () => SettingsWindow.ShowShared(this)));

        _batteryText = Ui.Label("", 11, FontWeights.SemiBold, Ui.White(0.85));
        _batteryText.VerticalAlignment = VerticalAlignment.Center;
        _batteryIcon = Ui.Icon("", 14, Ui.White(0.85));
        _batteryIcon.Margin = new Thickness(4, 0, 0, 0);
        _batteryPanel = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        _batteryPanel.Children.Add(_batteryText);
        _batteryPanel.Children.Add(_batteryIcon);
        StatusItems.Children.Add(_batteryPanel);
        UpdateStatusItems();
        HighlightTab(_m.Tab, animate: false);
    }

    private Button StatusButton(string glyph, string tip, Action action)
    {
        var button = Ui.Button(Ui.Icon(glyph, 13, Ui.White(0.55)), action, tip, 24, 22);
        button.Margin = new Thickness(6, 0, 0, 0);
        return button;
    }

    private void UpdateStatusItems()
    {
        _screenButton!.Visibility = Screens.HasSeveral ? Visibility.Visible : Visibility.Collapsed;
        if (Battery.Read() is { } battery)
        {
            _batteryPanel!.Visibility = Visibility.Visible;
            _batteryText!.Text = $"{battery.Percent} %";
            _batteryIcon!.Text = battery.Symbol;
            _batteryIcon.Foreground = battery.IsLow ? Ui.Solid(ActivityLook.Red) : Ui.White(0.85);
        }
        else
        {
            _batteryPanel!.Visibility = Visibility.Collapsed;
        }
    }

    private FrameworkElement Page(PanelTab tab)
    {
        if (_pages.TryGetValue(tab, out var page)) return page;
        page = tab switch
        {
            PanelTab.Music => new MusicPage(_m),
            PanelTab.Notes => new NotesPage(),
            PanelTab.Apps => new AppsPage(() => _m.Close?.Invoke()),
            PanelTab.Timer => new TimerPage(),
            _ => new ShelfPage(),
        };
        page.RenderTransform = new TranslateTransform();
        page.Visibility = Visibility.Collapsed;
        _pages[tab] = page;
        Pages.Children.Add(page);
        return page;
    }

    private void HighlightTab(PanelTab tab, bool animate)
    {
        var x = (int)tab * 31.0;
        if (animate) _tabHighlightShift.BeginAnimation(TranslateTransform.XProperty, Anim.To(x, 0.34, Ui.PageEase));
        else { _tabHighlightShift.BeginAnimation(TranslateTransform.XProperty, null); _tabHighlightShift.X = x; }
        foreach (var (key, button) in _tabButtons)
            ((TextBlock)button.Content).Foreground = Ui.White(key == tab ? 0.95 : 0.4);
    }

    private PanelTab? _tabShown;

    private void ShowTab(PanelTab tab, bool animate = true)
    {
        var page = Page(tab);
        var previous = _shownPage;
        var forward = _tabShown is not { } was || (int)tab >= (int)was;
        animate = animate && previous is not null && previous != page && _m.IsExpanded;
        _tabShown = tab;
        _shownPage = page;
        HighlightTab(tab, animate);
        UpdateStatusItems();
        Pages.Margin = new Thickness(0, 46, 0, tab == PanelTab.Music ? 36 : 18);
        UpdateWave();

        var distance = _m.ExpandedWidth - 40 + 24;
        var shift = (TranslateTransform)page.RenderTransform;
        page.Visibility = Visibility.Visible;
        (page as IPage)?.PanelVisibilityChanged(_m.IsExpanded);

        if (!animate)
        {
            shift.BeginAnimation(TranslateTransform.XProperty, null);
            shift.X = 0;
            foreach (var other in _pages.Values)
                if (other != page) other.Visibility = Visibility.Collapsed;
            return;
        }

        // Both by the same fixed distance, so they travel side by side.
        shift.BeginAnimation(TranslateTransform.XProperty,
            new DoubleAnimation(forward ? distance : -distance, 0, TimeSpan.FromSeconds(0.34)) { EasingFunction = Ui.PageEase });
        var oldShift = (TranslateTransform)previous!.RenderTransform;
        var leave = Anim.To(forward ? -distance : distance, 0.34, Ui.PageEase);
        var leaving = previous;
        leave.Completed += (_, _) => { if (_shownPage != leaving) leaving.Visibility = Visibility.Collapsed; };
        oldShift.BeginAnimation(TranslateTransform.XProperty, leave);
    }

    // MARK: Files

    private void OnFileDragEnter(object sender, DragEventArgs e)
    {
        if (!e.Data.GetDataPresent(DataFormats.FileDrop)) { e.Effects = DragDropEffects.None; e.Handled = true; return; }
        // Our own tile being dragged out mustn't count as arriving.
        if (e.Data.GetDataPresent(ShelfPage.OwnDragFormat)) return;
        e.Effects = DragDropEffects.Copy;
        e.Handled = true;
        Expand(PanelTab.Shelf);
    }

    private void OnFileDragOver(object sender, DragEventArgs e)
    {
        e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop) ? DragDropEffects.Copy : DragDropEffects.None;
        e.Handled = true;
    }

    private void OnFileDrop(object sender, DragEventArgs e)
    {
        if (e.Data.GetDataPresent(ShelfPage.OwnDragFormat)) return;
        if (e.Data.GetData(DataFormats.FileDrop) is string[] files) ShelfStore.Shared.Add(files);
        _m.Tab = PanelTab.Shelf;
        e.Handled = true;
    }

    // MARK: Screens

    private void ScreensChanged()
    {
        Collapse();
        _m.CanSwitchScreens = Screens.HasSeveral;
        PlaceOnScreen();
        if (_screenButton is not null) UpdateStatusItems();
    }

    /// Twice over, the first time only to get onto the right monitor: its DPI
    /// decides how many pixels wide the window is.
    private void PlaceOnScreen()
    {
        if (_hwnd == IntPtr.Zero) return;
        var bounds = ScreenBounds;
        for (var pass = 0; pass < 2; pass++)
        {
            var width = Width * CurrentDpi;
            var x = (int)Math.Round(bounds.Right - width);
            var y = (int)Math.Round(AnchorY - Height * CurrentDpi / 2);
            Native.SetWindowPos(_hwnd, IntPtr.Zero, x, y, 0, 0, Native.SWP_NOSIZE | Native.SWP_NOZORDER | Native.SWP_NOACTIVATE);
        }
        TraceLog($"placed: screen {bounds.Left},{bounds.Top} {bounds.Width}x{bounds.Height}, edge at x {bounds.Right - 1}, line at y {AnchorY:0}, scale {CurrentDpi:0.##}");
    }
}

/// The silhouette, against the screen's right edge. The far corners are
/// ordinary rounds. The edge's own corners follow `edge`: square at 0, round
/// above it (the panel standing off the edge), and below it flaring out along
/// the edge (the Mac notch's corners, turned on their side), so the shape
/// morphs from one to the other without a jump.
public static class EdgeGeometry
{
    public static StreamGeometry Build(double x, double y, double w, double h, double edge, double far)
    {
        var geometry = new StreamGeometry();
        var right = x + w;
        var bottom = y + h;
        using (var g = geometry.Open())
        {
            if (edge <= 0)
            {
                var f = Math.Min(-edge, Math.Min(h / 2, w));
                var r = Math.Max(0, Math.Min(far, Math.Min((h - 2 * f) / 2, w - f)));
                g.BeginFigure(new Point(right, y), true, true);
                g.QuadraticBezierTo(new Point(right, y + f), new Point(right - f, y + f), true, true);
                g.LineTo(new Point(x + r, y + f), true, true);
                g.QuadraticBezierTo(new Point(x, y + f), new Point(x, y + f + r), true, true);
                g.LineTo(new Point(x, bottom - f - r), true, true);
                g.QuadraticBezierTo(new Point(x, bottom - f), new Point(x + r, bottom - f), true, true);
                g.LineTo(new Point(right - f, bottom - f), true, true);
                g.QuadraticBezierTo(new Point(right, bottom - f), new Point(right, bottom), true, true);
            }
            else
            {
                var c = Math.Min(edge, Math.Min(h, w) / 2);
                var r = Math.Min(far, Math.Min(h, w) / 2);
                g.BeginFigure(new Point(right - c, y), true, true);
                g.LineTo(new Point(x + r, y), true, true);
                g.QuadraticBezierTo(new Point(x, y), new Point(x, y + r), true, true);
                g.LineTo(new Point(x, bottom - r), true, true);
                g.QuadraticBezierTo(new Point(x, bottom), new Point(x + r, bottom), true, true);
                g.LineTo(new Point(right - c, bottom), true, true);
                g.QuadraticBezierTo(new Point(right, bottom), new Point(right, bottom - c), true, true);
                g.LineTo(new Point(right, y + c), true, true);
                g.QuadraticBezierTo(new Point(right, y), new Point(right - c, y), true, true);
            }
        }
        geometry.Freeze();
        return geometry;
    }
}

public interface IPage
{
    void PanelVisibilityChanged(bool panelOpen);
}
