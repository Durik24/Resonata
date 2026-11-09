using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace Resonata;

/// Small factories, so the pages read as layout rather than as property lists.
public static class Ui
{
    public static readonly FontFamily IconFont = new("Segoe Fluent Icons, Segoe MDL2 Assets");
    public static readonly FontFamily TextFont = new("Segoe UI");

    private static readonly Dictionary<int, SolidColorBrush> Whites = [];

    public static SolidColorBrush White(double opacity)
    {
        var key = (int)Math.Round(opacity * 100);
        if (Whites.TryGetValue(key, out var brush)) return brush;
        brush = new SolidColorBrush(Color.FromArgb((byte)(opacity * 255), 255, 255, 255));
        brush.Freeze();
        return Whites[key] = brush;
    }

    public static SolidColorBrush Solid(Color color)
    {
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }

    public static TextBlock Label(string text, double size, FontWeight weight, Brush foreground) => new()
    {
        Text = text,
        FontFamily = TextFont,
        FontSize = size,
        FontWeight = weight,
        Foreground = foreground,
        TextTrimming = TextTrimming.CharacterEllipsis,
    };

    public static TextBlock Icon(string glyph, double size, Brush foreground) => new()
    {
        Text = glyph,
        FontFamily = IconFont,
        FontSize = size,
        Foreground = foreground,
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
    };

    public static Button Button(UIElement content, Action click, string? tip = null, double width = double.NaN, double height = double.NaN)
    {
        var button = new Button
        {
            Style = (Style)Application.Current.Resources["Plain"],
            Content = content,
            Width = width,
            Height = height,
        };
        if (tip is not null) button.ToolTip = tip;
        button.Click += (_, _) => click();
        return button;
    }

    public static Border Capsule(UIElement child, double opacity, double height) => new()
    {
        Child = child,
        Height = height,
        CornerRadius = new CornerRadius(height / 2),
        Background = White(opacity),
    };

    /// The album accent lifted to read on near-black: bright, a touch less saturated.
    public static Color? AccentText(Color? accent)
    {
        if (accent is not { } c) return null;
        double r = c.R / 255.0, g = c.G / 255.0, b = c.B / 255.0;
        double high = Math.Max(r, Math.Max(g, b)), low = Math.Min(r, Math.Min(g, b)), chroma = high - low;
        double hue = 0;
        if (chroma > 0)
        {
            if (high == r) hue = (g - b) / chroma / 6;
            else if (high == g) hue = ((b - r) / chroma + 2) / 6;
            else hue = ((r - g) / chroma + 4) / 6;
            if (hue < 0) hue += 1;
        }
        var saturation = high <= 0 ? 0 : Math.Min(chroma / high, 0.6);
        var value = Math.Max(high, 0.92);
        return FromHsv(hue, saturation, value);
    }

    public static Color FromHsv(double h, double s, double v)
    {
        var i = (int)Math.Floor(h * 6) % 6;
        var f = h * 6 - Math.Floor(h * 6);
        double p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s);
        var (r, g, b) = i switch
        {
            0 => (v, t, p), 1 => (q, v, p), 2 => (p, v, t), 3 => (p, q, v), 4 => (t, p, v), _ => (v, p, q),
        };
        return Color.FromRgb((byte)(r * 255), (byte)(g * 255), (byte)(b * 255));
    }

    public static Color? ParseHex(string text)
    {
        var hex = text.Trim().TrimStart('#');
        if (hex.Length != 6 || !uint.TryParse(hex, System.Globalization.NumberStyles.HexNumber, null, out var v)) return null;
        return Color.FromRgb((byte)(v >> 16), (byte)(v >> 8), (byte)v);
    }

    /// The panel's page turn: quick off the mark, settling without a crawl.
    public static readonly IEasingFunction PageEase = new Bezier(0.2, 0.75, 0.25, 1);

    public sealed class Bezier(double x1, double y1, double x2, double y2) : IEasingFunction
    {
        public double Ease(double t)
        {
            double lo = 0, hi = 1, u = t;
            for (var i = 0; i < 12; i++)
            {
                u = (lo + hi) / 2;
                if (Curve(u, x1, x2) < t) lo = u; else hi = u;
            }
            return Curve(u, y1, y2);
        }

        private static double Curve(double u, double a, double b)
        {
            var v = 1 - u;
            return 3 * v * v * u * a + 3 * v * u * u * b + u * u * u;
        }
    }
}

/// Redraws thirty times a second, and only while there's something to animate
/// and it's on screen: nothing playing costs nothing.
public abstract class AnimatedElement : FrameworkElement
{
    private static readonly Stopwatch Clock = Stopwatch.StartNew();
    private readonly DispatcherTimer _timer = new(DispatcherPriority.Render) { Interval = TimeSpan.FromMilliseconds(33) };
    private bool _isAnimating;

    protected AnimatedElement()
    {
        IsHitTestVisible = false;
        _timer.Tick += (_, _) => InvalidateVisual();
        IsVisibleChanged += (_, _) => Update();
    }

    protected static double Time => Clock.Elapsed.TotalSeconds;

    public bool IsAnimating
    {
        get => _isAnimating;
        set
        {
            if (_isAnimating == value) return;
            _isAnimating = value;
            Update();
            InvalidateVisual();
        }
    }

    private void Update()
    {
        if (_isAnimating && IsVisible) _timer.Start(); else _timer.Stop();
    }
}

public sealed class MusicBars : AnimatedElement
{
    private const int Count = 3;
    private const double BarWidth = 4, Spacing = 3;

    private Brush _tint = Ui.White(0.35);
    public Brush Tint { get => _tint; set { _tint = value; InvalidateVisual(); } }

    protected override void OnRender(DrawingContext dc)
    {
        var total = BarWidth * Count + Spacing * (Count - 1);
        var x = (ActualWidth - total) / 2;
        for (var i = 0; i < Count; i++)
        {
            var level = IsAnimating ? Math.Max(Motion.BarLevel(i, Time), 0.16) : 0.35;
            var height = ActualHeight * level;
            dc.DrawRoundedRectangle(_tint, null, new Rect(x, (ActualHeight - height) / 2, BarWidth, height), BarWidth / 2, BarWidth / 2);
            x += BarWidth + Spacing;
        }
    }
}

public sealed class MusicWave : AnimatedElement
{
    private double[] _shown = [];
    private Brush _fill = Brushes.Transparent;
    private Pen _line = new(Brushes.White, 1.5);

    public MusicWave() => SetColor(null);

    /// A colourless cover gets a quieter white: at full strength it would be
    /// the brightest thing in the panel.
    public void SetColor(Color? color)
    {
        var c = color ?? Colors.White;
        var strength = color is null ? 0.6 : 1;
        var fill = new LinearGradientBrush(
            Color.FromArgb((byte)(255 * 0.6 * strength), c.R, c.G, c.B),
            Color.FromArgb((byte)(255 * 0.05), c.R, c.G, c.B), 90);
        fill.Freeze();
        _fill = fill;
        var stroke = Ui.Solid(Color.FromArgb((byte)(255 * 0.85 * strength), c.R, c.G, c.B));
        _line = new Pen(stroke, 1.5) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round };
        _line.Freeze();
        InvalidateVisual();
    }

    protected override void OnRender(DrawingContext dc)
    {
        var target = Motion.WaveLevels(IsAnimating, Time);
        if (_shown.Length != target.Length) _shown = target;
        for (var i = 0; i < _shown.Length; i++) _shown[i] += (target[i] - _shown[i]) * 0.35;
        if (ActualWidth <= 0 || ActualHeight <= 0) return;

        var baseline = ActualHeight - 1;
        var amplitude = ActualHeight - 2.5;
        var step = ActualWidth / (_shown.Length - 1);
        var points = _shown.Select((level, i) => new Point(i * step, baseline - level * amplitude)).ToArray();
        Point Clamp(Point p) => new(p.X, Math.Clamp(p.Y, baseline - amplitude, baseline));

        StreamGeometry Curve(bool closed)
        {
            var geometry = new StreamGeometry();
            using (var g = geometry.Open())
            {
                g.BeginFigure(points[0], closed, closed);
                // Catmull-Rom: through every point, control points kept in range.
                for (var i = 0; i < points.Length - 1; i++)
                {
                    Point p0 = points[Math.Max(i - 1, 0)], p1 = points[i], p2 = points[i + 1], p3 = points[Math.Min(i + 2, points.Length - 1)];
                    var c1 = Clamp(new Point(p1.X + (p2.X - p0.X) / 6, p1.Y + (p2.Y - p0.Y) / 6));
                    var c2 = Clamp(new Point(p2.X - (p3.X - p1.X) / 6, p2.Y - (p3.Y - p1.Y) / 6));
                    g.BezierTo(c1, c2, p2, true, true);
                }
                if (closed)
                {
                    g.LineTo(new Point(points[^1].X, ActualHeight), false, false);
                    g.LineTo(new Point(points[0].X, ActualHeight), false, false);
                }
            }
            geometry.Freeze();
            return geometry;
        }

        dc.DrawGeometry(_fill, null, Curve(true));
        dc.DrawGeometry(null, _line, Curve(false));
    }
}

/// A thin bar with a value: the song's progress, Spotify's volume.
public sealed class ThinBar : FrameworkElement
{
    private double _value;
    private Brush _fill = Brushes.White;
    private bool _hover, _dragging;

    public bool ShowKnobOnlyWhenActive { get; init; } = true;
    public double RestHeight { get; init; } = 4;
    public double ActiveHeight { get; init; } = 6;

    public Action<double>? Scrubbing { get; set; }
    public Action<double>? Scrubbed { get; set; }

    public bool IsDragging => _dragging;

    public double Value
    {
        get => _value;
        set { _value = Math.Clamp(value, 0, 1); InvalidateVisual(); }
    }

    public Brush Fill { get => _fill; set { _fill = value; InvalidateVisual(); } }

    protected override void OnRender(DrawingContext dc)
    {
        // The whole element takes the mouse: a 4 px target is unusable.
        dc.DrawRectangle(Brushes.Transparent, null, new Rect(RenderSize));
        var active = _hover || _dragging;
        var height = active ? ActiveHeight : RestHeight;
        var top = (ActualHeight - height) / 2;
        var radius = height / 2;
        dc.DrawRoundedRectangle(Ui.White(0.22), null, new Rect(0, top, ActualWidth, height), radius, radius);
        // At least a dot, so position zero isn't a rendering artifact.
        dc.DrawRoundedRectangle(_fill, null, new Rect(0, top, Math.Max(height, ActualWidth * _value), height), radius, radius);
        if (active || !ShowKnobOnlyWhenActive)
            dc.DrawEllipse(Brushes.White, null, new Point(Math.Clamp(ActualWidth * _value, 4.5, Math.Max(4.5, ActualWidth - 4.5)), ActualHeight / 2), 4.5, 4.5);
    }

    private double FractionAt(MouseEventArgs e) =>
        ActualWidth <= 0 ? 0 : Math.Clamp(e.GetPosition(this).X / ActualWidth, 0, 1);

    protected override void OnMouseEnter(MouseEventArgs e) { _hover = true; InvalidateVisual(); }
    protected override void OnMouseLeave(MouseEventArgs e) { _hover = false; InvalidateVisual(); }

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        _dragging = true;
        CaptureMouse();
        Value = FractionAt(e);
        Scrubbing?.Invoke(Value);
        e.Handled = true;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        if (!_dragging) return;
        Value = FractionAt(e);
        Scrubbing?.Invoke(Value);
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        if (!_dragging) return;
        _dragging = false;
        ReleaseMouseCapture();
        Value = FractionAt(e);
        Scrubbed?.Invoke(Value);
        e.Handled = true;
    }
}

public sealed class Ring : FrameworkElement
{
    private double _remaining;
    private Brush _tint = Brushes.White;

    /// The share of the circle still drawn, 0...1.
    public double Remaining { get => _remaining; set { _remaining = Math.Clamp(value, 0, 1); InvalidateVisual(); } }
    public Brush Tint { get => _tint; set { _tint = value; InvalidateVisual(); } }

    protected override void OnRender(DrawingContext dc)
    {
        const double thickness = 6;
        var radius = Math.Min(ActualWidth, ActualHeight) / 2 - thickness / 2;
        var center = new Point(ActualWidth / 2, ActualHeight / 2);
        dc.DrawEllipse(null, new Pen(Ui.White(0.12), thickness), center, radius, radius);
        if (_remaining <= 0) return;
        var pen = new Pen(_tint, thickness) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round };
        if (_remaining >= 0.9999) { dc.DrawEllipse(null, pen, center, radius, radius); return; }
        var angle = 2 * Math.PI * _remaining - Math.PI / 2;
        var end = new Point(center.X + radius * Math.Cos(angle), center.Y + radius * Math.Sin(angle));
        var geometry = new StreamGeometry();
        using (var g = geometry.Open())
        {
            g.BeginFigure(new Point(center.X, center.Y - radius), false, false);
            g.ArcTo(end, new Size(radius, radius), 0, _remaining > 0.5, SweepDirection.Clockwise, true, false);
        }
        dc.DrawGeometry(null, pen, geometry);
    }
}

/// The cover, or a placeholder of the same shape, so nothing shifts when it lands.
public sealed class CoverView : Grid
{
    private readonly Border _picture;
    private readonly TextBlock _note;
    private readonly ImageBrush _brush = new() { Stretch = Stretch.UniformToFill };

    public CoverView(double size)
    {
        Width = Height = size;
        var radius = new CornerRadius(size * 0.09);
        Children.Add(new Border { CornerRadius = radius, Background = Ui.White(0.1) });
        _note = Ui.Icon(Glyph.Music, size * 0.36, Ui.White(0.5));
        Children.Add(_note);
        _picture = new Border { CornerRadius = radius, Background = _brush };
        Children.Add(_picture);
        // A hairline edge stops dark artwork dissolving into the panel.
        Children.Add(new Border { CornerRadius = radius, BorderThickness = new Thickness(0.5), BorderBrush = Ui.White(0.12) });
        RenderOptions.SetBitmapScalingMode(_picture, BitmapScalingMode.HighQuality);
        SetImage(null);
    }

    public void SetImage(BitmapSource? image)
    {
        _brush.ImageSource = image;
        _picture.Visibility = image is null ? Visibility.Collapsed : Visibility.Visible;
        _note.Visibility = image is null ? Visibility.Visible : Visibility.Collapsed;
    }
}

public static class Anim
{
    public static System.Windows.Media.Animation.DoubleAnimation To(double to, double seconds,
        System.Windows.Media.Animation.IEasingFunction? ease = null, double delay = 0) => new(to, TimeSpan.FromSeconds(seconds))
    {
        EasingFunction = ease,
        BeginTime = TimeSpan.FromSeconds(delay),
    };

    public static readonly System.Windows.Media.Animation.IEasingFunction EaseOut =
        new System.Windows.Media.Animation.CubicEase { EasingMode = System.Windows.Media.Animation.EasingMode.EaseOut };

    public static readonly System.Windows.Media.Animation.IEasingFunction EaseInOut =
        new System.Windows.Media.Animation.CubicEase { EasingMode = System.Windows.Media.Animation.EasingMode.EaseInOut };

    public static double Fade => Settings.Current.AnimationSpeed switch
    {
        AnimationSpeed.Fast => 0.2,
        AnimationSpeed.Slow => 0.65,
        _ => 0.4,
    };

    public static (double Response, double Damping) Spring => Settings.Current.AnimationSpeed switch
    {
        // Damped below 0.7 for a visible bounce at the end of every change of size.
        AnimationSpeed.Fast => (0.3, 0.68),
        AnimationSpeed.Slow => (0.72, 0.66),
        _ => (0.44, 0.66),
    };
}
