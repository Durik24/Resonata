using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Threading;

namespace Resonata;

/// The open panel's clipboard page: a card for each thing copied, newest
/// first; a click copies it again.
public sealed class ClipboardPage : Grid, IPage
{
    private readonly ClipboardStore _store = ClipboardStore.Shared;
    private readonly UniformGrid _cards = new() { Columns = 2, VerticalAlignment = VerticalAlignment.Top };
    private readonly Grid _filled = new();
    private readonly StackPanel _empty = new() { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
    /// The ages are against the clock: twice a minute is as often as their minutes change.
    private readonly DispatcherTimer _clock = new() { Interval = TimeSpan.FromSeconds(30) };
    private bool _open;

    public ClipboardPage()
    {
        _filled.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _filled.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _filled.Children.Add(new ScrollViewer { Content = _cards, VerticalScrollBarVisibility = ScrollBarVisibility.Hidden, Focusable = false });
        var footer = new Grid { Margin = new Thickness(0, 6, 0, 0) };
        var hint = Ui.Label(L.T("Click to copy again. Passwords from password managers are not kept.",
            "Klik zkopíruje znovu. Hesla ze správců hesel se neukládají."), 10, FontWeights.Normal, Ui.White(0.4));
        hint.TextWrapping = TextWrapping.Wrap;
        hint.TextTrimming = TextTrimming.None;
        hint.Margin = new Thickness(0, 0, 60, 0);
        footer.Children.Add(hint);
        var clear = Ui.Button(Ui.Label(L.T("Clear", "Vyčistit"), 11, FontWeights.SemiBold, Ui.White(0.6)), _store.Clear);
        clear.HorizontalAlignment = HorizontalAlignment.Right;
        clear.VerticalAlignment = VerticalAlignment.Bottom;
        footer.Children.Add(clear);
        SetRow(footer, 1);
        _filled.Children.Add(footer);
        Children.Add(_filled);

        _empty.Children.Add(Ui.Icon(Glyph.Clipboard, 24, Ui.White(0.75)));
        var line1 = Ui.Label(L.T("Nothing copied yet", "Zatím nic zkopírovaného"), 13, FontWeights.SemiBold, Ui.White(0.75));
        line1.HorizontalAlignment = HorizontalAlignment.Center;
        line1.Margin = new Thickness(0, 6, 0, 2);
        _empty.Children.Add(line1);
        var line2 = Ui.Label(L.T("What you copy from now on shows up here.", "Co odteď zkopíruješ, najdeš tady."), 11, FontWeights.Normal, Ui.White(0.45));
        line2.HorizontalAlignment = HorizontalAlignment.Center;
        line2.TextWrapping = TextWrapping.Wrap;
        line2.TextTrimming = TextTrimming.None;
        line2.TextAlignment = TextAlignment.Center;
        line2.Margin = new Thickness(16, 0, 16, 0);
        _empty.Children.Add(line2);
        Children.Add(_empty);

        _store.Changed += () => { if (_open) Rebuild(); };
        _clock.Tick += (_, _) => Rebuild();
        // The cards are as wide as half the page, whatever that is.
        SizeChanged += (_, e) => { if (_open && e.WidthChanged) Rebuild(); };
        Rebuild();
    }

    public void PanelVisibilityChanged(bool panelOpen)
    {
        _open = panelOpen;
        if (panelOpen)
        {
            Rebuild();
            _clock.Start();
        }
        else _clock.Stop();
    }

    private void Rebuild()
    {
        var any = _store.Clips.Count > 0;
        _filled.Visibility = any ? Visibility.Visible : Visibility.Collapsed;
        _empty.Visibility = any ? Visibility.Collapsed : Visibility.Visible;
        _cards.Children.Clear();
        var now = DateTime.Now;
        foreach (var clip in _store.Clips) _cards.Children.Add(Card(clip, _store.Current == clip.Id, now));
    }

    /// One card: what was copied, and from where and when under it.
    private Button Card(Clip clip, bool current, DateTime now)
    {
        var czech = Settings.Current.Language == AppLanguage.Czech;
        var rows = new Grid { Margin = new Thickness(8, 6, 8, 6) };
        rows.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        rows.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        rows.Children.Add(What(clip));

        // "Chrome · 4 min ago", or just the age when the app isn't known.
        var meta = new DockPanel { Margin = new Thickness(0, 3, 0, 0) };
        if (current)
        {
            var mark = Ui.Label(L.T("on clipboard", "ve schránce"), 8.5, FontWeights.Bold, Brushes.White);
            DockPanel.SetDock(mark, Dock.Right);
            mark.Margin = new Thickness(4, 0, 0, 0);
            meta.Children.Add(mark);
        }
        var age = ClipRules.Age(clip.Date, now, czech);
        meta.Children.Add(Ui.Label(clip.App is { } app ? $"{app} · {age}" : age, 8.5, FontWeights.Normal, Ui.White(current ? 0.78 : 0.6)));
        SetRow(meta, 1);
        rows.Children.Add(meta);

        var card = new Border
        {
            Height = 58, Width = Math.Max(80, (ActualWidth > 0 ? ActualWidth : 250) / 2 - 6), CornerRadius = new CornerRadius(9), Child = rows,
            Background = Ui.White(current ? 0.12 : 0.06),
            BorderBrush = current ? Ui.White(0.4) : Brushes.Transparent, BorderThickness = new Thickness(1),
        };
        var button = Ui.Button(card, () => _store.Copy(clip), L.T("Copy again", "Zkopírovat znovu"));
        button.Margin = new Thickness(0, 0, 6, 6);
        button.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        System.Windows.Automation.AutomationProperties.SetName(button, Spoken(clip));
        return button;
    }

    private static TextBlock Words(string text, Brush brush, FontWeight? weight = null)
    {
        var label = Ui.Label(text, 10, weight ?? FontWeights.Normal, brush);
        label.TextWrapping = TextWrapping.Wrap;
        label.TextTrimming = TextTrimming.CharacterEllipsis;
        label.MaxHeight = 28;
        label.VerticalAlignment = VerticalAlignment.Top;
        return label;
    }

    private static UIElement Beside(UIElement picture, TextBlock words)
    {
        var row = new DockPanel { VerticalAlignment = VerticalAlignment.Top };
        DockPanel.SetDock(picture, Dock.Left);
        row.Children.Add(picture);
        words.Margin = new Thickness(6, 0, 0, 0);
        words.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(words);
        return row;
    }

    private static UIElement What(Clip clip)
    {
        switch (clip.Kind)
        {
            case ClipKind.Link:
                var link = Ui.Icon(Glyph.Link, 10, Ui.Solid(ActivityLook.Sky));
                link.VerticalAlignment = VerticalAlignment.Top;
                link.Margin = new Thickness(0, 2, 0, 0);
                var address = Words(ClipRules.Shortened(clip.Text), Ui.Solid(ActivityLook.Sky));
                address.VerticalAlignment = VerticalAlignment.Top;
                var row = new DockPanel();
                DockPanel.SetDock(link, Dock.Left);
                row.Children.Add(link);
                address.Margin = new Thickness(4, 0, 0, 0);
                row.Children.Add(address);
                return row;
            case ClipKind.Colour:
                var swatch = new Border
                {
                    Width = 20, Height = 20, CornerRadius = new CornerRadius(5), VerticalAlignment = VerticalAlignment.Center,
                    Background = Ui.Solid(Ui.ParseHex(clip.Text) ?? Colors.White), BorderBrush = Ui.White(0.25), BorderThickness = new Thickness(0.5),
                };
                var hex = Words(clip.Text, Ui.White(0.92));
                hex.FontFamily = new FontFamily("Consolas");
                return Beside(swatch, hex);
            case ClipKind.Image when clip.Thumbnail is { } thumbnail:
                var (width, height) = ClipRules.Fitted(thumbnail.PixelWidth, thumbnail.PixelHeight, 44, 26);
                var image = new Image { Source = thumbnail, Width = width, Height = height, VerticalAlignment = VerticalAlignment.Center };
                RenderOptions.SetBitmapScalingMode(image, BitmapScalingMode.HighQuality);
                return Beside(image, Words(L.T("Picture", "Obrázek"), Ui.White(0.92), FontWeights.SemiBold));
            case ClipKind.Files when clip.Files.Count > 0:
                var icon = new Image { Width = 22, Height = 22, Source = ShellIcons.Get(clip.Files[0]), VerticalAlignment = VerticalAlignment.Center };
                RenderOptions.SetBitmapScalingMode(icon, BitmapScalingMode.HighQuality);
                var count = clip.Files.Count;
                return Beside(icon, Words(count == 1 ? System.IO.Path.GetFileName(clip.Files[0])
                    : L.T($"{count} files", count <= 4 ? $"{count} soubory" : $"{count} souborů"), Ui.White(0.92)));
            default:
                return Words(ClipRules.Shown(clip.Text), Ui.White(0.92));
        }
    }

    private static string Spoken(Clip clip) => clip.Kind switch
    {
        ClipKind.Colour => L.T($"Colour {clip.Text}", $"Barva {clip.Text}"),
        ClipKind.Image => L.T("Picture", "Obrázek"),
        ClipKind.Files => string.Join(", ", clip.Files.Select(System.IO.Path.GetFileName)),
        _ => clip.Text.Length > 120 ? clip.Text[..120] : clip.Text,
    };
}
