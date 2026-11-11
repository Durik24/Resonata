using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Resonata;

/// `RESONATA_DEMO=1`: a made-up song instead of whatever is playing, for
/// screenshots. Nothing is read from the players or the calendar.
public static class Demo
{
    public static bool IsOn => Environment.GetEnvironmentVariable("RESONATA_DEMO") == "1";

    public static void Install(PanelModel model)
    {
        model.Artwork = Cover();
        model.Accent = Artwork.AccentOf(model.Artwork);
        model.Track = new Track
        {
            Title = "Neon Rain", Artist = "Midnight Notes", Album = "Afterglow", Duration = 214,
            SampledPosition = 83, SampledAt = DateTime.Now, IsPlaying = true, Source = "Spotify.exe",
        };
        model.Lyrics =
        [
            new(0, "♪"),
            new(70, "Streetlights hum a quiet tune"),
            new(78, "Every window holds a light for you"),
            new(120, "City glowing in the rain"),
            new(140, "Neon rain, neon rain"),
        ];
        var day = DateTime.Today;
        CalendarStore.Shared.ShowDemo(
        [
            new("demo-1", "Studio session", day.AddHours(14), day.AddHours(16), false),
            new("demo-2", "Concert with friends", day.AddHours(19.5), day.AddHours(22), false),
        ]);
    }

    /// A dusk gradient, a low sun and a row of blocks, drawn here.
    private static BitmapSource Cover()
    {
        const int size = 600;
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            var sky = new LinearGradientBrush(new GradientStopCollection
            {
                new(Color.FromRgb(41, 26, 82), 0),
                new(Color.FromRgb(184, 64, 122), 0.5),
                new(Color.FromRgb(250, 140, 92), 1),
            }, 90);
            dc.DrawRectangle(sky, null, new Rect(0, 0, size, size));
            dc.DrawEllipse(new SolidColorBrush(Color.FromRgb(255, 209, 140)), null, new Point(size / 2.0, size * 0.6), size * 0.22, size * 0.22);
            double[] x = [0, 0.12, 0.22, 0.34, 0.48, 0.58, 0.72, 0.84, 1];
            double[] h = [0.22, 0.34, 0.26, 0.42, 0.30, 0.38, 0.24, 0.32];
            var city = new SolidColorBrush(Color.FromRgb(26, 15, 51));
            for (var i = 0; i < h.Length; i++)
                dc.DrawRectangle(city, null, new Rect(x[i] * size, size * (1 - h[i]), (x[i + 1] - x[i]) * size + 1, h[i] * size));
        }
        var bitmap = new RenderTargetBitmap(size, size, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(visual);
        bitmap.Freeze();
        return bitmap;
    }
}

/// `RESONATA_SNAP=<folder>`: drives each state and photographs the window's own
/// content, so the layout can be checked without touching the real screen.
public static class Snapshots
{
    public static bool IsOn { get; } = Environment.GetEnvironmentVariable("RESONATA_SNAP") is { Length: > 0 };

    /// `RESONATA_ANIMTEST=1`: opens and closes a few times; the window logs how
    /// evenly the frames came.
    public static async Task RunAnimationTestAsync(NotchWindow window)
    {
        await Task.Delay(1500);
        for (var i = 0; i < 5; i++)
        {
            window.Expand();
            await Task.Delay(1500);
            window.Collapse();
            await Task.Delay(2200);
        }
        ((App)Application.Current).Quit();
    }

    /// `RESONATA_VOLUMETEST=1`: reads Spotify's volume the way the panel does,
    /// moves it a tenth and back, and logs each step with Spotify's level in
    /// the Windows mixer beside it. The real Spotify, which the logic tests
    /// can't reach.
    public static async Task RunVolumeTestAsync()
    {
        static string Mixer()
        {
            using var enumerator = new NAudio.CoreAudioApi.MMDeviceEnumerator();
            var levels = new List<string>();
            foreach (var device in enumerator.EnumerateAudioEndPoints(NAudio.CoreAudioApi.DataFlow.Render, NAudio.CoreAudioApi.DeviceState.Active))
            {
                var sessions = device.AudioSessionManager;
                sessions.RefreshSessions();
                for (var i = 0; i < sessions.Sessions.Count; i++)
                {
                    var session = sessions.Sessions[i];
                    try
                    {
                        using var process = System.Diagnostics.Process.GetProcessById((int)session.GetProcessID);
                        if (process.ProcessName == "Spotify") levels.Add($"{session.SimpleAudioVolume.Volume:F2}");
                    }
                    catch (ArgumentException) { }
                }
            }
            return levels.Count == 0 ? "none" : string.Join(", ", levels);
        }

        await Task.Delay(1000);
        var before = await SpotifyVolume.ReadAsync();
        Log.Write($"volume test: read {before?.ToString() ?? "nothing"}, Spotify's own slider: {SpotifyVolume.InTenths}, mixer {Mixer()}");
        if (before is { } level)
        {
            var moved = level >= 10 ? level - 10 : level + 10;
            SpotifyVolume.Set((int)moved);
            await Task.Delay(1500);
            Log.Write($"volume test: set {moved}, mixer now {Mixer()}");
            SpotifyVolume.Set((int)level);
            await Task.Delay(1500);
            Log.Write($"volume test: set {level} again, mixer now {Mixer()}");
            // As the panel would when opened next: it should read back the last level.
            Log.Write($"volume test: read back {(await SpotifyVolume.ReadAsync())?.ToString() ?? "nothing"}");
        }
        ((App)Application.Current).Quit();
    }

    public static async Task RunAsync(PanelModel m, NotchWindow window, SongPeek songPeek, ActivityPeek activity, string dir)
    {
        Log.Write($"snapshots into {dir}");
        Directory.CreateDirectory(dir);
        await Task.Delay(800);
        songPeek.Show();
        await Task.Delay(900);
        Save(window, dir, "peek");
        m.SongPeeking = false;
        await Task.Delay(900);
        activity.Show(new NotchActivity.TimerDone(25));
        await Task.Delay(900);
        Save(window, dir, "activity");
        await Task.Delay(6800);

        window.Expand();
        await Task.Delay(1200);
        foreach (var tab in Enum.GetValues<PanelTab>())
        {
            m.Tab = tab;
            await Task.Delay(700);
            Save(window, dir, "page-" + tab.ToString().ToLowerInvariant());
        }
        await NewerStatesAsync(m, window, dir);
        window.Collapse();
        await Task.Delay(900);

        SettingsWindow.ShowShared(window);
        await Task.Delay(1200);
        var settings = Application.Current.Windows.OfType<SettingsWindow>().First();
        SaveFromScreen(settings, dir, "settings");
        settings.Close();
        ((App)Application.Current).Quit();
    }

    /// What the pages grew later: five lines of the lyrics, a live stream, and
    /// the timer's buttons kept across its ticks. Driven the way a click is.
    private static async Task NewerStatesAsync(PanelModel m, NotchWindow window, string dir)
    {
        m.Tab = PanelTab.Music;
        await Task.Delay(700);
        if (Find<LyricsLine>(window) is { } line)
        {
            line.RaiseEvent(new MouseButtonEventArgs(Mouse.PrimaryDevice, 0, MouseButton.Left) { RoutedEvent = UIElement.MouseLeftButtonUpEvent });
            await Task.Delay(700);
            Save(window, dir, "page-music-lyrics");
            var back = Find<Button>(window, b => AutomationProperties.GetName(b) == L.T("Back to the player", "Zpět k přehrávači"));
            Log.Write($"snapshot: the lyrics list has its way back: {back is { IsVisible: true }}");
            Click(back);
            await Task.Delay(500);
        }
        else Log.Write("snapshot: no lyric line to click");

        var song = m.Track;
        m.Track = song is null ? null : song with { Title = "Radio Afterglow", Duration = 0, SampledPosition = 0, SampledAt = DateTime.Now };
        // Past the moment in which a song's length may still arrive.
        await Task.Delay(2200);
        Save(window, dir, "page-music-live");
        m.Track = song;
        await Task.Delay(500);

        m.Tab = PanelTab.Timer;
        CountdownTimer.Shared.Start(25);
        await Task.Delay(700);
        Save(window, dir, "page-timer-running");
        var pause = Labelled(window, L.T("Pause", "Pozastavit"));
        await Task.Delay(1300);
        var kept = pause is not null && ReferenceEquals(pause, Labelled(window, L.T("Pause", "Pozastavit")));
        Log.Write($"snapshot: the timer's Pause button outlived a tick: {kept}");
        Click(pause);
        await Task.Delay(600);
        Save(window, dir, "page-timer-paused");
        CountdownTimer.Shared.Cancel();
        await Task.Delay(400);
    }

    private static void Click(Button? button) => button?.RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));

    /// The button with this text on it.
    private static Button? Labelled(DependencyObject root, string text) =>
        Find<Button>(root, b => Find<TextBlock>(b, t => t.Text == text) is not null);

    private static T? Find<T>(DependencyObject root, Func<T, bool>? match = null) where T : DependencyObject
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            if (child is T found && (match is null || match(found))) return found;
            if (Find(child, match) is { } deeper) return deeper;
        }
        return null;
    }

    /// For a window with a system backdrop, which rendering it ourselves can't
    /// see. Only that window's own rectangle of the screen.
    private static void SaveFromScreen(Window window, string dir, string name)
    {
        var source = (System.Windows.Interop.HwndSource)PresentationSource.FromVisual(window)!;
        Native.GetWindowRect(source.Handle, out var r);
        using var bitmap = new System.Drawing.Bitmap(r.Right - r.Left, r.Bottom - r.Top);
        using (var g = System.Drawing.Graphics.FromImage(bitmap))
            g.CopyFromScreen(r.Left, r.Top, 0, 0, bitmap.Size);
        bitmap.Save(Path.Combine(dir, name + ".png"), System.Drawing.Imaging.ImageFormat.Png);
    }

    private static void Save(Window window, string dir, string name)
    {
        var dpi = VisualTreeHelper.GetDpi(window);
        var content = (FrameworkElement)window.Content;
        var bitmap = new RenderTargetBitmap(
            (int)(content.ActualWidth * dpi.DpiScaleX), (int)(content.ActualHeight * dpi.DpiScaleY),
            dpi.PixelsPerInchX, dpi.PixelsPerInchY, PixelFormats.Pbgra32);
        bitmap.Render(content);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var file = File.Create(Path.Combine(dir, name + ".png"));
        encoder.Save(file);
        Log.Write($"snapshot {name}");
    }
}
