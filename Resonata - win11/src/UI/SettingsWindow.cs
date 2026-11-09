using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace Resonata;

public sealed class SettingsWindow : Window
{
    private static SettingsWindow? _shared;

    private readonly StackPanel _root = new() { Margin = new Thickness(20, 12, 20, 20) };
    private readonly StackPanel _updateRow = new() { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
    private readonly StackPanel _appsList = new();
    private readonly NotchWindow? _notch;
    private static Settings S => Settings.Current;

    public static void ShowShared(Window? owner)
    {
        if (_shared is null)
        {
            _shared = new SettingsWindow(owner as NotchWindow);
            _shared.Closed += (_, _) => _shared = null;
        }
        _shared.Show();
        if (_shared.WindowState == WindowState.Minimized) _shared.WindowState = WindowState.Normal;
        _shared.Activate();
    }

    private SettingsWindow(NotchWindow? notch)
    {
        _notch = notch ?? Application.Current.Windows.OfType<NotchWindow>().FirstOrDefault();
        ThemeMode = ThemeMode.System;
        Title = L.T("Resonata – Settings", "Resonata – Nastavení");
        Width = 500;
        Height = 700;
        MinWidth = 420;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Content = new ScrollViewer { Content = _root, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        Build();
        Updater.Shared.PropertyChanged += OnUpdaterChanged;
        Closed += (_, _) => Updater.Shared.PropertyChanged -= OnUpdaterChanged;
        QuickApps.Changed += RebuildApps;
        Closed += (_, _) => QuickApps.Changed -= RebuildApps;
    }

    private void OnUpdaterChanged(object? sender, PropertyChangedEventArgs e) => RebuildUpdate();

    private void Build()
    {
        Section(L.T("General", "Obecné"));
        var login = Toggle(L.T("Open at login", "Spouštět po přihlášení"), LoginItem.IsEnabled, LoginItem.Set);
        Add(login);
        Combo(L.T("Language (after a restart)", "Jazyk (po restartu)"), new[]
        {
            (AppLanguage.English, "English"),
            (AppLanguage.Czech, "Čeština"),
        }, S.Language, v => S.Language = v);
        var taken = new TextBlock { Text = L.T("Another app already uses this shortcut. Pick a different one.", "Tuhle zkratku už používá jiná aplikace. Vyber jinou."), Foreground = Brushes.IndianRed, Visibility = Visibility.Collapsed, Margin = new Thickness(0, 0, 0, 6), TextWrapping = TextWrapping.Wrap };
        Combo(L.T("Keyboard shortcut", "Klávesová zkratka"), Enum.GetValues<HotKeyChoice>().Select(c => (c, HotKey.Title(c))), S.HotKey, value =>
        {
            S.HotKey = value;
            taken.Visibility = _notch?.ApplyHotKey() == false ? Visibility.Visible : Visibility.Collapsed;
        });
        Add(taken);

        Section(L.T("Updates", "Aktualizace"));
        Add(Toggle(L.T("Check for new versions automatically", "Hledat nové verze automaticky"), S.CheckForUpdates, v => S.CheckForUpdates = v));
        var version = new Grid { Margin = new Thickness(0, 4, 0, 8) };
        version.Children.Add(new TextBlock { Text = L.T($"Version {Updater.CurrentVersion}", $"Verze {Updater.CurrentVersion}"), VerticalAlignment = VerticalAlignment.Center });
        version.Children.Add(_updateRow);
        Add(version);
        RebuildUpdate();

        Section(L.T("Sliding out", "Vysouvání"));
        Add(Toggle(L.T("Slide out at the top edge of the screen", "Vysunout najetím k hornímu okraji"), S.EdgeTrigger, v => S.EdgeTrigger = v));
        Combo(L.T("Open the panel", "Otevírat panel"), new[]
        {
            (OpenMode.Hover, L.T("Hover", "Najetím")),
            (OpenMode.Click, L.T("Click", "Kliknutím")),
        }, S.OpenMode, v => S.OpenMode = v);
        Add(Note(L.T(
            "Hover: rest on the pill and the panel opens by itself, and it closes when you move away. Click: the pointer only brings out the pill; a click opens the panel and another click closes it.",
            "Najetím: když zůstaneš na pilulce, panel se otevře sám a po odjetí myší se zavře. Kliknutím: najetí vysune jen pilulku, kliknutí panel otevře a další kliknutí ho zavře.")));
        Combo(L.T("Animation", "Animace"), new[]
        {
            (AnimationSpeed.Fast, L.T("Fast", "Rychlé")),
            (AnimationSpeed.Normal, L.T("Normal", "Normální")),
            (AnimationSpeed.Slow, L.T("Slow", "Pomalé")),
        }, S.AnimationSpeed, v => S.AnimationSpeed = v);

        Section(L.T("Open panel", "Otevřený panel"));
        Combo(L.T("Swipe between pages", "Swipe mezi stránkami"), new[]
        {
            (PageSwipe.WithFingers, L.T("Right = next", "Doprava = další")),
            (PageSwipe.Reversed, L.T("Left = next (like a phone)", "Doleva = další (jako telefon)")),
            (PageSwipe.Off, L.T("Off", "Vypnuto")),
        }, S.PageSwipe, v => S.PageSwipe = v);
        Add(Toggle(L.T("Lyrics", "Texty písní"), S.ShowLyrics, v => S.ShowLyrics = v));
        Add(Toggle(L.T("Calendar beside the player", "Kalendář vedle přehrávače"), S.ShowCalendar, v => S.ShowCalendar = v));
        var custom = new Grid { Margin = new Thickness(0, 0, 0, 8) };
        var customBox = new TextBox { Text = S.CustomWaveColour, Width = 110, HorizontalAlignment = HorizontalAlignment.Right };
        customBox.TextChanged += (_, _) => { if (Ui.ParseHex(customBox.Text) is not null) S.CustomWaveColour = customBox.Text.Trim(); };
        custom.Children.Add(new TextBlock { Text = L.T("Custom colour (#RRGGBB)", "Vlastní barva (#RRGGBB)"), VerticalAlignment = VerticalAlignment.Center });
        custom.Children.Add(customBox);
        custom.Visibility = S.WaveColour == WaveColour.Custom ? Visibility.Visible : Visibility.Collapsed;
        Combo(L.T("Wave colour", "Barva vlny"), new[]
        {
            (WaveColour.Album, L.T("From the album cover", "Podle obalu alba")),
            (WaveColour.White, L.T("White", "Bílá")),
            (WaveColour.Custom, L.T("Custom", "Vlastní")),
        }, S.WaveColour, v =>
        {
            S.WaveColour = v;
            custom.Visibility = v == WaveColour.Custom ? Visibility.Visible : Visibility.Collapsed;
        });
        Add(custom);

        Section(L.T("Calendar", "Kalendář"));
        var urls = new TextBox { Text = S.CalendarUrls, AcceptsReturn = true, TextWrapping = TextWrapping.NoWrap, MinHeight = 70, Margin = new Thickness(0, 4, 0, 4), HorizontalScrollBarVisibility = ScrollBarVisibility.Auto };
        urls.LostKeyboardFocus += (_, _) => S.CalendarUrls = urls.Text;
        Add(Note(L.T("Calendar links in .ics format, one per line. In Google: calendar settings → Secret address in iCal format. In Outlook: Settings → Shared calendars → Publish.", "Odkazy na kalendář ve formátu .ics, každý na vlastní řádek. V Googlu: Nastavení kalendáře → Tajná adresa ve formátu iCal. V Outlooku: Nastavení → Sdílené kalendáře → Publikovat.")));
        Add(urls);

        Section(L.T("Messages", "Zprávy"));
        Add(Toggle(L.T("New song", "Nová skladba"), S.ShowSongPeek, v => S.ShowSongPeek = v));
        Add(Toggle(L.T("Battery — charging and low battery", "Baterie — nabíjení a slabá baterie"), S.ShowChargingPeek, v => S.ShowChargingPeek = v));
        Add(Toggle(L.T("Headphones connected", "Připojená sluchátka"), S.ShowHeadphonesPeek, v => S.ShowHeadphonesPeek = v));
        Add(Toggle(L.T("Calendar event, 5 minutes before", "Událost z kalendáře 5 min předem"), S.MeetingReminder, v => S.MeetingReminder = v));
        Add(Note(L.T("They slide in from the top for a moment. While the panel is open, a reminder, low battery or the end of the timer wait until you close it.", "Na chvíli se vysunou shora. Když je panel zrovna otevřený, připomínka, slabá baterie a konec časovače počkají, až ho zavřeš.")));

        Section("Pomodoro");
        var work = Number(L.T("Work (min)", "Práce (min)"), S.PomodoroWork, 1, 240, v => S.PomodoroWork = v);
        var rest = Number(L.T("Break (min)", "Pauza (min)"), S.PomodoroRest, 1, 240, v => S.PomodoroRest = v);
        var longRest = Number(L.T("Long break (min)", "Dlouhá pauza (min)"), S.PomodoroLongRest, 1, 240, v => S.PomodoroLongRest = v);
        var rounds = Number(L.T("Long break after (rounds)", "Dlouhá pauza po (kolech)"), S.PomodoroRounds, 1, 12, v => S.PomodoroRounds = v);
        var defaults = new Button { Content = L.T("Default (25 + 5)", "Výchozí (25 + 5)"), HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 4, 0, 8) };
        defaults.Click += (_, _) =>
        {
            var plan = PomodoroPlan.Standard;
            work.Text = plan.Work.ToString();
            rest.Text = plan.Rest.ToString();
            longRest.Text = plan.LongRest.ToString();
            rounds.Text = plan.Rounds.ToString();
        };
        Add(defaults);
        Add(Note(L.T("Work and breaks take turns until you cancel the timer. A change counts from the next phase.", "Práce a pauzy se střídají, dokud časovač nezrušíš. Změna platí od další fáze.")));

        Section(L.T("Apps in the panel", "Aplikace v panelu"));
        Add(_appsList);
        RebuildApps();

        if (Updater.Uninstaller is { } uninstaller)
        {
            Section(L.T("Uninstall", "Odinstalace"));
            var remove = new Button { Content = L.T("Uninstall Resonata…", "Odinstalovat Resonatu…"), HorizontalAlignment = HorizontalAlignment.Left };
            remove.Click += (_, _) => Shell.Open(uninstaller);
            Add(remove);
        }
    }

    private void Add(UIElement element) => _root.Children.Add(element);

    private void Section(string title) => Add(new TextBlock
    {
        Text = title,
        FontSize = 15,
        FontWeight = FontWeights.SemiBold,
        Margin = new Thickness(0, 16, 0, 6),
    });

    private static TextBlock Note(string text) => new()
    {
        Text = text,
        Opacity = 0.65,
        FontSize = 12,
        TextWrapping = TextWrapping.Wrap,
        Margin = new Thickness(0, 2, 0, 8),
    };

    private static CheckBox Toggle(string title, bool value, Action<bool> set)
    {
        var box = new CheckBox { Content = title, IsChecked = value, Margin = new Thickness(0, 0, 0, 2) };
        box.Click += (_, _) => set(box.IsChecked == true);
        return box;
    }

    private void Combo<T>(string title, IEnumerable<(T Value, string Name)> items, T current, Action<T> set) where T : struct
    {
        var row = new Grid { Margin = new Thickness(0, 2, 0, 6) };
        row.Children.Add(new TextBlock { Text = title, VerticalAlignment = VerticalAlignment.Center });
        var combo = new ComboBox { Width = 230, HorizontalAlignment = HorizontalAlignment.Right };
        foreach (var (value, name) in items)
        {
            var item = new ComboBoxItem { Content = name, Tag = value };
            combo.Items.Add(item);
            if (EqualityComparer<T>.Default.Equals(value, current)) combo.SelectedItem = item;
        }
        combo.SelectionChanged += (_, _) => { if (combo.SelectedItem is ComboBoxItem { Tag: T value }) set(value); };
        row.Children.Add(combo);
        Add(row);
    }

    private TextBox Number(string title, int value, int min, int max, Action<int> set)
    {
        var row = new Grid { Margin = new Thickness(0, 2, 0, 6) };
        row.Children.Add(new TextBlock { Text = title, VerticalAlignment = VerticalAlignment.Center });
        var box = new TextBox { Text = value.ToString(), Width = 90, HorizontalAlignment = HorizontalAlignment.Right, TextAlignment = TextAlignment.Right };
        box.TextChanged += (_, _) => { if (int.TryParse(box.Text, out var v) && v >= min && v <= max) set(v); };
        box.LostKeyboardFocus += (_, _) =>
        {
            var kept = int.TryParse(box.Text, out var v) ? Math.Clamp(v, min, max) : value;
            box.Text = kept.ToString();
            set(kept);
        };
        row.Children.Add(box);
        Add(row);
        return box;
    }

    private void RebuildUpdate()
    {
        _updateRow.Children.Clear();
        void Text(string text, Brush? colour = null)
        {
            var block = new TextBlock { Text = text, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0), Opacity = 0.7 };
            if (colour is not null) { block.Foreground = colour; block.Opacity = 1; }
            _updateRow.Children.Add(block);
        }
        void Act(string title, Action action)
        {
            var button = new Button { Content = title };
            button.Click += (_, _) => action();
            _updateRow.Children.Add(button);
        }
        var u = Updater.Shared;
        switch (u.State)
        {
            case UpdateState.Checking: Text(L.T("Checking…", "Hledám…")); break;
            case UpdateState.Installing: Text(L.T("Downloading and starting the installer…", "Stahuju a spouštím instalátor…")); break;
            case UpdateState.UpToDate:
                Text(L.T("Up to date", "Nejnovější"));
                Act(L.T("Check now", "Zkontrolovat"), () => _ = u.CheckAsync());
                break;
            case UpdateState.Available a:
                Act(L.T("What's new", "Co je nového"), () => Shell.Open(a.Page));
                var install = new Button { Content = (Updater.IsInstalled ? L.T("Install ", "Nainstalovat ") : L.T("Download ", "Stáhnout ")) + a.Version, Margin = new Thickness(8, 0, 0, 0) };
                install.Click += (_, _) => _ = u.InstallAsync();
                _updateRow.Children.Add(install);
                break;
            case UpdateState.Failed f:
                Text(f.Message, Brushes.IndianRed);
                Act(L.T("Try again", "Zkusit znovu"), () => _ = u.CheckAsync());
                break;
            default:
                Act(L.T("Check now", "Zkontrolovat"), () => _ = u.CheckAsync());
                break;
        }
    }

    private void RebuildApps()
    {
        _appsList.Children.Clear();
        var apps = QuickApps.Current;
        for (var i = 0; i < apps.Count; i++)
        {
            var index = i;
            var app = apps[i];
            var row = new Grid { Margin = new Thickness(0, 0, 0, 4) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(26) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Children.Add(new Image { Width = 18, Height = 18, Source = ShellIcons.Get(app), HorizontalAlignment = HorizontalAlignment.Left });
            var name = new TextBlock { Text = QuickApps.Name(app), VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
            Grid.SetColumn(name, 1);
            row.Children.Add(name);
            var buttons = new StackPanel { Orientation = Orientation.Horizontal };
            buttons.Children.Add(Small("", L.T("Up", "Výš"), index > 0, () => Move(index, -1)));
            buttons.Children.Add(Small("", L.T("Down", "Níž"), index < apps.Count - 1, () => Move(index, 1)));
            buttons.Children.Add(Small(Glyph.Minus, L.T("Remove", "Odebrat"), true, () => QuickApps.Remove(app)));
            Grid.SetColumn(buttons, 2);
            row.Children.Add(buttons);
            _appsList.Children.Add(row);
        }
        var footer = new Grid { Margin = new Thickness(0, 6, 0, 0) };
        var add = new Button { Content = L.T("Add an app…", "Přidat aplikaci…"), IsEnabled = apps.Count < QuickApps.Limit };
        add.HorizontalAlignment = HorizontalAlignment.Left;
        add.Click += (_, _) => QuickApps.ChooseAndAdd();
        var reset = new Button { Content = L.T("Defaults", "Výchozí"), HorizontalAlignment = HorizontalAlignment.Right };
        reset.Click += (_, _) => QuickApps.Save(QuickApps.Defaults());
        footer.Children.Add(add);
        footer.Children.Add(reset);
        _appsList.Children.Add(footer);
    }

    private static Button Small(string glyph, string tip, bool enabled, Action click)
    {
        var button = new Button
        {
            Content = new TextBlock { Text = glyph, FontFamily = Ui.IconFont, FontSize = 11 },
            ToolTip = tip,
            IsEnabled = enabled,
            Margin = new Thickness(4, 0, 0, 0),
            Padding = new Thickness(6, 4, 6, 4),
        };
        button.Click += (_, _) => click();
        return button;
    }

    private static void Move(int index, int offset)
    {
        var apps = QuickApps.Current.ToList();
        var target = index + offset;
        if (target < 0 || target >= apps.Count) return;
        (apps[index], apps[target]) = (apps[target], apps[index]);
        QuickApps.Save(apps);
    }
}
