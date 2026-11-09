using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Windows.Media.Control;
using SessionManager = Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager;
using Session = Windows.Media.Control.GlobalSystemMediaTransportControlsSession;

namespace Resonata;

public enum TransportCommand { PlayPause, Next, Previous }

/// What's playing, from the same place Windows' own media flyout reads it, so
/// it covers Spotify, a browser tab, a podcast app and the rest.
public sealed class MediaService
{
    /// Past this we believe the player over our own interpolation: a real jump.
    private const double DriftTolerance = 1.5;

    private readonly PanelModel _model;
    private readonly DispatcherTimer _debounce;
    private readonly DispatcherTimer _safetyNet;
    private readonly List<Session> _wired = [];

    private SessionManager? _manager;
    private Session? _current;
    private bool _propertiesDirty = true;
    private bool _refreshing, _refreshAgain;
    private string? _artworkHash;

    public static MediaService? Active { get; private set; }

    public MediaService(PanelModel model)
    {
        _model = model;
        Active = this;
        _debounce = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(120) };
        _debounce.Tick += (_, _) => { _debounce.Stop(); _ = RefreshAsync(); };
        // Only for what events miss: a player quitting, drift in the playhead.
        _safetyNet = new DispatcherTimer { Interval = TimeSpan.FromSeconds(10) };
        _safetyNet.Tick += (_, _) => _ = StartOrRefreshAsync();
    }

    public void Start()
    {
        _safetyNet.Start();
        _ = StartOrRefreshAsync();
    }

    private async Task StartOrRefreshAsync()
    {
        if (_manager is not null) { await RefreshAsync(); return; }
        try
        {
            _manager = await SessionManager.RequestAsync();
        }
        catch (Exception e) when (e is COMException or UnauthorizedAccessException)
        {
            Log.Write($"media sessions unavailable: {e.Message}");
            return;
        }
        _manager.SessionsChanged += (_, _) => Post(() => { WireSessions(); Schedule(propertiesChanged: true); });
        _manager.CurrentSessionChanged += (_, _) => Post(() => Schedule(propertiesChanged: true));
        WireSessions();
        await RefreshAsync();
    }

    private void Post(Action action) => _debounce.Dispatcher.BeginInvoke(action);

    private void Schedule(bool propertiesChanged)
    {
        if (propertiesChanged) _propertiesDirty = true;
        _debounce.Stop();
        _debounce.Start();
    }

    private void WireSessions()
    {
        foreach (var s in _wired)
        {
            s.MediaPropertiesChanged -= OnProperties;
            s.PlaybackInfoChanged -= OnPlayback;
            s.TimelinePropertiesChanged -= OnTimeline;
        }
        _wired.Clear();
        if (_manager is null) return;
        foreach (var s in _manager.GetSessions())
        {
            s.MediaPropertiesChanged += OnProperties;
            s.PlaybackInfoChanged += OnPlayback;
            s.TimelinePropertiesChanged += OnTimeline;
            _wired.Add(s);
        }
    }

    private void OnProperties(Session s, MediaPropertiesChangedEventArgs e) => Post(() => Schedule(true));
    private void OnPlayback(Session s, PlaybackInfoChangedEventArgs e) => Post(() => Schedule(false));
    private void OnTimeline(Session s, TimelinePropertiesChangedEventArgs e) => Post(() => Schedule(false));

    /// The one Windows calls current, unless it's stopped and another is playing.
    private Session? Pick()
    {
        if (_manager is null) return null;
        var current = _manager.GetCurrentSession();
        if (IsPlaying(current)) return current;
        return _manager.GetSessions().FirstOrDefault(IsPlaying) ?? current ?? _manager.GetSessions().FirstOrDefault();
    }

    private static bool IsPlaying(Session? s)
    {
        if (s is null) return false;
        try
        {
            return s.GetPlaybackInfo()?.PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing;
        }
        catch (COMException)
        {
            return false;
        }
    }

    private async Task RefreshAsync()
    {
        // One at a time: an older answer arriving late must not win.
        if (_refreshing) { _refreshAgain = true; return; }
        _refreshing = true;
        try
        {
            do
            {
                _refreshAgain = false;
                await ReadAsync();
            } while (_refreshAgain);
        }
        catch (Exception e) when (e is COMException or InvalidOperationException or ObjectDisposedException)
        {
            // The player went away mid-read; the next event sorts it out.
            Log.Write($"media read failed: {e.Message}");
        }
        finally
        {
            _refreshing = false;
        }
    }

    private async Task ReadAsync()
    {
        var session = Pick();
        if (!ReferenceEquals(session, _current)) { _current = session; _propertiesDirty = true; }
        if (session is null) { Clear(); return; }

        var refreshProperties = _propertiesDirty;
        _propertiesDirty = false;
        var props = await session.TryGetMediaPropertiesAsync();
        if (props is null || string.IsNullOrWhiteSpace(props.Title)) { Clear(); return; }

        var playback = session.GetPlaybackInfo();
        var timeline = session.GetTimelineProperties();
        var playing = playback.PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing;
        var now = DateTime.Now;

        var duration = Math.Max(0, (timeline.EndTime - timeline.StartTime).TotalSeconds);
        var position = timeline.Position.TotalSeconds;
        // Timelines arrive stamped with when the player wrote them, which can
        // be a while ago. Never trust a nonsense stamp from a player that has
        // no timeline at all.
        var age = (DateTimeOffset.Now - timeline.LastUpdatedTime).TotalSeconds;
        if (playing && age is > 0 and < 24 * 3600) position += age;
        if (duration > 0) position = Math.Clamp(position, 0, duration);

        var track = new Track
        {
            Title = props.Title,
            Artist = string.IsNullOrEmpty(props.Artist) ? props.AlbumArtist ?? "" : props.Artist,
            Album = props.AlbumTitle ?? "",
            Duration = duration,
            SampledPosition = position,
            SampledAt = now,
            IsPlaying = playing,
            Source = session.SourceAppUserModelId ?? "",
        };

        // Same song, same state, and where we predicted: keep the old anchor,
        // so the bar doesn't twitch on every small correction.
        if (_model.Track is { } old && old.IsSameTrack(track) && old.IsPlaying == track.IsPlaying
            && Math.Abs(old.Position(now) - position) < DriftTolerance
            && Math.Abs(old.Duration - duration) < 0.5)
        {
            track = old;
        }

        if (track != _model.Track) _model.Track = track;
        if (refreshProperties) await ReadArtworkAsync(props);
    }

    private void Clear()
    {
        if (_model.Track is not null) _model.Track = null;
        _artworkHash = null;
        _model.Artwork = null;
        _model.Accent = null;
    }

    private async Task ReadArtworkAsync(GlobalSystemMediaTransportControlsSessionMediaProperties props)
    {
        if (props.Thumbnail is null)
        {
            _artworkHash = null;
            _model.Artwork = null;
            _model.Accent = null;
            return;
        }
        using var stream = await props.Thumbnail.OpenReadAsync();
        using var read = stream.AsStreamForRead();
        using var memory = new MemoryStream();
        await read.CopyToAsync(memory);
        var bytes = memory.ToArray();
        var hash = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes));
        // Players often re-announce the same cover; the colour need not be redone.
        if (hash == _artworkHash) return;
        _artworkHash = hash;
        var (image, accent) = await Task.Run(() => Artwork.Decode(bytes));
        _model.Artwork = image;
        _model.Accent = accent;
    }

    public void Send(TransportCommand command)
    {
        if (_current is not { } session) return;
        _ = RunCommandAsync(command switch
        {
            TransportCommand.Next => session.TrySkipNextAsync().AsTask(),
            TransportCommand.Previous => session.TrySkipPreviousAsync().AsTask(),
            _ => session.TryTogglePlayPauseAsync().AsTask(),
        });
    }

    public void Seek(double seconds)
    {
        if (_current is not { } session) return;
        _ = RunCommandAsync(session.TryChangePlaybackPositionAsync((long)(seconds * TimeSpan.TicksPerSecond)).AsTask());
    }

    private async Task RunCommandAsync(Task<bool> command)
    {
        try
        {
            var accepted = await command;
            if (!accepted) Log.Write("the player refused a command");
        }
        catch (COMException e)
        {
            Log.Write($"command failed: {e.Message}");
        }
        // Nothing else tells us the playhead just jumped.
        await Task.Delay(400);
        Schedule(false);
    }
}

public static class Artwork
{
    public static (BitmapSource? Image, Color? Accent) Decode(byte[] bytes)
    {
        try
        {
            using var stream = new MemoryStream(bytes);
            var image = new BitmapImage();
            image.BeginInit();
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.StreamSource = stream;
            image.EndInit();
            image.Freeze();
            return (image, AccentOf(image));
        }
        catch (Exception e) when (e is NotSupportedException or FileFormatException or InvalidOperationException)
        {
            Log.Write($"unreadable artwork: {e.Message}");
            return (null, null);
        }
    }

    public static Color? AccentOf(BitmapSource image)
    {
        var scaled = new TransformedBitmap(image, new ScaleTransform(
            (double)AccentPicker.Grid / image.PixelWidth, (double)AccentPicker.Grid / image.PixelHeight));
        var bgra = new FormatConvertedBitmap(scaled, PixelFormats.Bgra32, null, 0);
        var stride = bgra.PixelWidth * 4;
        var pixels = new byte[stride * bgra.PixelHeight];
        bgra.CopyPixels(pixels, stride, 0);
        for (var i = 0; i + 3 < pixels.Length; i += 4) (pixels[i], pixels[i + 2]) = (pixels[i + 2], pixels[i]);
        return AccentPicker.Pick(pixels) is { } c
            ? Color.FromRgb((byte)(c.R * 255), (byte)(c.G * 255), (byte)(c.B * 255))
            : null;
    }
}
