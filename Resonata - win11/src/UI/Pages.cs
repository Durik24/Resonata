using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;

namespace Resonata;

/// A free-form note on the left, a to-do list on the right. Saved as you type.
public sealed class NotesPage : Grid
{
    private readonly NotesStore _store = NotesStore.Shared;
    private readonly StackPanel _list = new();
    private readonly TextBox _new;

    public NotesPage()
    {
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(200) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(12) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var note = new TextBox
        {
            Style = (Style)Application.Current.Resources["PlainText"],
            Text = _store.Note,
            AcceptsReturn = true,
            AcceptsTab = false,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(9, 6, 9, 6),
        };
        note.TextChanged += (_, _) => _store.Note = note.Text;
        var placeholder = Ui.Label(L.T("Note…", "Poznámka…"), 12, FontWeights.Normal, Ui.White(0.3));
        placeholder.IsHitTestVisible = false;
        placeholder.Margin = new Thickness(11, 6, 0, 0);
        placeholder.Visibility = note.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        note.TextChanged += (_, _) => placeholder.Visibility = note.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        var noteBox = new Grid();
        noteBox.Children.Add(new Border { CornerRadius = new CornerRadius(10), Background = Ui.White(0.06) });
        noteBox.Children.Add(note);
        noteBox.Children.Add(placeholder);
        Children.Add(noteBox);

        var right = new Grid();
        right.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        right.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        _new = new TextBox { Style = (Style)Application.Current.Resources["PlainText"], VerticalAlignment = VerticalAlignment.Center };
        _new.KeyDown += (_, e) =>
        {
            if (e.Key != Key.Enter) return;
            _store.Add(_new.Text);
            _new.Clear();
            e.Handled = true;
        };
        var hint = Ui.Label(L.T("New to-do", "Nový úkol"), 12, FontWeights.Normal, Ui.White(0.3));
        hint.IsHitTestVisible = false;
        hint.VerticalAlignment = VerticalAlignment.Center;
        hint.Margin = new Thickness(2, 0, 0, 0);
        _new.TextChanged += (_, _) => hint.Visibility = _new.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        var entry = new Grid { Margin = new Thickness(8, 5, 8, 5) };
        entry.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(16) });
        entry.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        entry.Children.Add(Ui.Icon(Glyph.Add, 10, Ui.White(0.5)));
        var field = new Grid { Margin = new Thickness(4, 0, 0, 0) };
        field.Children.Add(_new);
        field.Children.Add(hint);
        SetColumn(field, 1);
        entry.Children.Add(field);
        right.Children.Add(new Border { CornerRadius = new CornerRadius(8), Background = Ui.White(0.06), Child = entry });

        var scroller = new ScrollViewer
        {
            Content = _list,
            VerticalScrollBarVisibility = ScrollBarVisibility.Hidden,
            Margin = new Thickness(0, 6, 0, 0),
            Focusable = false,
        };
        SetRow(scroller, 1);
        right.Children.Add(scroller);

        SetColumn(right, 2);
        Children.Add(right);

        _store.Changed += Rebuild;
        Rebuild();
    }

    private void Rebuild()
    {
        _list.Children.Clear();
        if (_store.Todos.Count == 0)
        {
            var empty = Ui.Label(L.T("No to-dos", "Žádné úkoly"), 11, FontWeights.Normal, Ui.White(0.3));
            empty.Margin = new Thickness(2, 4, 0, 0);
            _list.Children.Add(empty);
            return;
        }
        foreach (var todo in _store.Todos) _list.Children.Add(Row(todo));
    }

    private Grid Row(TodoItem todo)
    {
        var row = new Grid { Margin = new Thickness(0, 0, 0, 5) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(20) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(16) });

        row.Children.Add(Ui.Button(Ui.Icon(todo.Done ? Glyph.CircleCheck : Glyph.Circle, 13, Ui.White(todo.Done ? 0.45 : 0.8)),
            () => _store.Toggle(todo), null, 18, 18));

        var text = Ui.Label(todo.Text, 12, FontWeights.Normal, Ui.White(todo.Done ? 0.4 : 0.9));
        text.VerticalAlignment = VerticalAlignment.Center;
        if (todo.Done) text.TextDecorations = TextDecorations.Strikethrough;
        SetColumn(text, 1);
        row.Children.Add(text);

        var delete = Ui.Button(Ui.Icon(Glyph.Close, 8, Ui.White(0.3)), () => _store.Remove(todo), L.T("Delete", "Smazat"), 16, 16);
        SetColumn(delete, 2);
        row.Children.Add(delete);
        return row;
    }
}

/// A grid of app shortcuts; the last tile adds another.
public sealed class AppsPage : WrapPanel
{
    private readonly Action _onLaunch;

    public AppsPage(Action onLaunch)
    {
        _onLaunch = onLaunch;
        Orientation = Orientation.Horizontal;
        HorizontalAlignment = HorizontalAlignment.Center;
        VerticalAlignment = VerticalAlignment.Top;
        MaxWidth = 6 * 68;
        QuickApps.Changed += Rebuild;
        Rebuild();
    }

    private void Rebuild()
    {
        Children.Clear();
        foreach (var app in QuickApps.Current)
        {
            var captured = app;
            var icon = new Image { Width = 40, Height = 40, Source = ShellIcons.Get(app) };
            RenderOptions.SetBitmapScalingMode(icon, BitmapScalingMode.HighQuality);
            var name = QuickApps.Name(app);
            Children.Add(Tile(icon, name, () => { QuickApps.Launch(captured); _onLaunch(); }, name));
        }
        if (QuickApps.Current.Count < QuickApps.Limit)
        {
            var add = new Grid { Width = 40, Height = 40 };
            add.Children.Add(new Rectangle
            {
                RadiusX = 10, RadiusY = 10, Stroke = Ui.White(0.25), StrokeThickness = 1, StrokeDashArray = [3, 3],
            });
            add.Children.Add(Ui.Icon(Glyph.Add, 15, Ui.White(0.6)));
            Children.Add(Tile(add, L.T("Add", "Přidat"), QuickApps.ChooseAndAdd, L.T("Add an app", "Přidat aplikaci")));
        }
    }

    private static Button Tile(UIElement icon, string title, Action click, string tip)
    {
        var stack = new StackPanel();
        if (icon is FrameworkElement element) element.HorizontalAlignment = HorizontalAlignment.Center;
        stack.Children.Add(icon);
        var label = Ui.Label(title, 10, FontWeights.Normal, Ui.White(0.75));
        label.TextAlignment = TextAlignment.Center;
        label.Margin = new Thickness(0, 4, 0, 0);
        stack.Children.Add(label);
        var button = Ui.Button(stack, click, tip, 62);
        button.Margin = new Thickness(3, 0, 3, 8);
        return button;
    }
}

/// The time left in a ring on the left, the lengths to start on the right.
public sealed class TimerPage : StackPanel, IPage
{
    private readonly CountdownTimer _timer = CountdownTimer.Shared;
    private readonly Ring _ring = new();
    private readonly StackPanel _running = new() { VerticalAlignment = VerticalAlignment.Center };
    private readonly StackPanel _dial = new() { VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _time = Ui.Label("", 24, FontWeights.SemiBold, Brushes.White);
    private readonly TextBlock _caption = Ui.Label("", 10, FontWeights.Medium, Ui.White(0.45));
    private readonly TextBox _typed;
    private readonly List<(int Minutes, Border Pill)> _presets = [];
    private readonly StackPanel _controls = new() { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 12, 0, 0) };
    private bool _writing;
    private bool _open;
    /// What the buttons under the ring were last built for — see `Refresh`.
    private string? _controlsFor;

    public TimerPage()
    {
        Orientation = Orientation.Horizontal;
        HorizontalAlignment = HorizontalAlignment.Center;
        VerticalAlignment = VerticalAlignment.Center;

        _time.HorizontalAlignment = HorizontalAlignment.Center;
        _caption.HorizontalAlignment = HorizontalAlignment.Center;
        _running.Children.Add(_time);
        _running.Children.Add(_caption);

        // Text read as it's typed, not a number field that only takes the
        // value on Enter: typing 37 and clicking start must start 37.
        _typed = new TextBox
        {
            Style = (Style)Application.Current.Resources["PlainText"],
            FontSize = 26, FontWeight = FontWeights.SemiBold, TextAlignment = TextAlignment.Center,
            Width = 70, MaxLength = 3, HorizontalAlignment = HorizontalAlignment.Center,
            ToolTip = L.T("Click and type the minutes", "Klikni a napiš počet minut"),
        };
        _typed.TextChanged += OnTyped;
        _typed.KeyDown += (_, e) => { if (e.Key == Key.Enter) { WriteChosen(); e.Handled = true; } };
        _typed.LostKeyboardFocus += (_, _) => WriteChosen();
        var steps = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 4, 0, 0) };
        steps.Children.Add(Step(Glyph.Minus, -1, L.T("A minute less", "O minutu míň")));
        var unit = Ui.Label("min", 10, FontWeights.Medium, Ui.White(0.45));
        unit.VerticalAlignment = VerticalAlignment.Center;
        unit.Margin = new Thickness(10, 0, 10, 0);
        steps.Children.Add(unit);
        steps.Children.Add(Step(Glyph.Add, 1, L.T("A minute more", "O minutu víc")));
        _dial.Children.Add(_typed);
        _dial.Children.Add(steps);

        var ringHost = new Grid { Width = 112, Height = 112, Margin = new Thickness(0, 0, 28, 0) };
        ringHost.Children.Add(_ring);
        ringHost.Children.Add(_running);
        ringHost.Children.Add(_dial);
        Children.Add(ringHost);

        var right = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        var grid = new UniformGrid { Columns = 3, Rows = 2 };
        foreach (var minutes in CountdownTimer.Presets)
        {
            var captured = minutes;
            var label = Ui.Label($"{minutes} min", 12, FontWeights.SemiBold, Ui.White(0.9));
            label.HorizontalAlignment = HorizontalAlignment.Center;
            label.VerticalAlignment = VerticalAlignment.Center;
            var pill = Ui.Capsule(label, 0.08, 26);
            pill.Width = 58;
            var button = Ui.Button(pill, () => _timer.Start(captured));
            button.Margin = new Thickness(0, 0, 8, 8);
            grid.Children.Add(button);
            _presets.Add((minutes, pill));
        }
        right.Children.Add(grid);
        right.Children.Add(_controls);
        Children.Add(right);

        // The second's tick only matters while the page can be seen.
        _timer.Ticked += () => { if (_open) Refresh(); };
        Settings.Current.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(Settings.PomodoroWork) or nameof(Settings.PomodoroRest)) Refresh();
        };
        WriteChosen();
        Refresh();
    }

    public void PanelVisibilityChanged(bool panelOpen)
    {
        _open = panelOpen;
        if (panelOpen) Refresh();
    }

    private RepeatButton Step(string glyph, int delta, string tip)
    {
        var button = new RepeatButton
        {
            Style = (Style)Application.Current.Resources["Plain"],
            Width = 22, Height = 22, ToolTip = tip, Delay = 350, Interval = 80,
            Content = new Border
            {
                Width = 22, Height = 22, CornerRadius = new CornerRadius(11), Background = Ui.White(0.12),
                Child = Ui.Icon(glyph, 9, Ui.White(0.85)),
            },
        };
        button.Click += (_, _) => _timer.Choose(_timer.ChosenMinutes + delta);
        return button;
    }

    private void OnTyped(object sender, TextChangedEventArgs e)
    {
        if (_writing) return;
        var digits = new string(_typed.Text.Where(char.IsAsciiDigit).Take(3).ToArray());
        if (digits != _typed.Text) { _writing = true; _typed.Text = digits; _typed.CaretIndex = digits.Length; _writing = false; }
        if (int.TryParse(digits, out var value) && value > 0) _timer.Choose(value);
    }

    /// Left empty or at 0, it goes back to the length that counts.
    private void WriteChosen()
    {
        _writing = true;
        _typed.Text = _timer.ChosenMinutes.ToString();
        _writing = false;
    }

    private void Refresh()
    {
        var now = DateTime.Now;
        var active = _timer.IsActive;
        _running.Visibility = active ? Visibility.Visible : Visibility.Collapsed;
        _dial.Visibility = active ? Visibility.Collapsed : Visibility.Visible;
        _ring.Remaining = active ? 1 - _timer.Progress(now) : 0;
        _ring.Tint = Ui.Solid(_timer.Phase == PomodoroPhase.Rest ? ActivityLook.Green : ActivityLook.Orange);
        _time.Text = TimeText.Countdown(_timer.Remaining(now));
        _time.Foreground = Ui.White(_timer.IsPaused ? 0.5 : 1);
        _caption.Text = Caption;
        if (!_typed.IsKeyboardFocused && _typed.Text != _timer.ChosenMinutes.ToString()) WriteChosen();

        foreach (var (minutes, pill) in _presets)
        {
            var current = active && _timer.Phase is null && (int)Math.Round(_timer.Total / 60) == minutes;
            pill.Background = Ui.White(current ? 0.2 : 0.08);
        }

        // Built again only when they'd come out different. They used to be
        // thrown away and rebuilt every second while a timer ran, and a click
        // that was down when the second ticked — on Pause, on Cancel — landed
        // on a button that was no longer there and did nothing.
        var plan = Settings.Current.PomodoroPlan;
        var controlsFor = active
            ? $"running|{_timer.IsPaused}"
            : $"stopped|{_timer.ChosenMinutes}|{plan.Work}|{plan.Rest}|{plan.LongRest}|{plan.Rounds}";
        if (controlsFor == _controlsFor) return;
        _controlsFor = controlsFor;

        _controls.Children.Clear();
        if (active)
        {
            _controls.Children.Add(Control(_timer.IsPaused ? Glyph.Play : Glyph.Pause, _timer.IsPaused ? L.T("Resume", "Pokračovat") : L.T("Pause", "Pozastavit"),
                () => { if (_timer.IsPaused) _timer.Resume(); else _timer.Pause(); }));
            _controls.Children.Add(Control(Glyph.Close, L.T("Cancel", "Zrušit"), _timer.Cancel));
        }
        else
        {
            _controls.Children.Add(Control(Glyph.Play, L.T($"Start {_timer.ChosenMinutes} min", $"Spustit {_timer.ChosenMinutes} min"), () => _timer.Start(_timer.ChosenMinutes)));
            var pomodoro = Control(Glyph.Repeat, $"Pomodoro {plan.Work} + {plan.Rest}", _timer.StartPomodoro);
            pomodoro.ToolTip = L.T($"{plan.Work} min of work and {plan.Rest} min of break, over and over; every {plan.Rounds}th break is {plan.LongRest} min. Set the lengths in Settings → Pomodoro.", $"{plan.Work} min práce a {plan.Rest} min pauza pořád dokola, každá {plan.Rounds}. pauza {plan.LongRest} min. Délky nastavíš v Nastavení → Pomodoro.");
            _controls.Children.Add(pomodoro);
        }
    }

    private string Caption
    {
        get
        {
            if (_timer.IsPaused) return L.T("paused", "pozastaveno");
            return _timer.Phase switch
            {
                PomodoroPhase.Work => L.T($"work · round {_timer.Round}", $"práce · {_timer.Round}. kolo"),
                PomodoroPhase.Rest => L.T("break", "pauza"),
                _ => _timer.IsActive ? L.T("left", "zbývá") : L.T("timer", "časovač"),
            };
        }
    }

    private static Button Control(string glyph, string title, Action click)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(12, 0, 12, 0), VerticalAlignment = VerticalAlignment.Center };
        row.Children.Add(Ui.Icon(glyph, 10, Brushes.White));
        var label = Ui.Label(title, 11, FontWeights.SemiBold, Brushes.White);
        label.Margin = new Thickness(6, 0, 0, 0);
        row.Children.Add(label);
        var button = Ui.Button(Ui.Capsule(row, 0.14, 26), click);
        button.Margin = new Thickness(0, 0, 8, 0);
        return button;
    }
}

/// Files parked on the panel: drop them on it, drag them off later.
public sealed class ShelfPage : Grid, IPage
{
    public const string OwnDragFormat = "Resonata.ShelfDrag";

    private readonly ShelfStore _shelf = ShelfStore.Shared;
    private readonly WrapPanel _tiles = new();
    private readonly Grid _filled = new();
    private readonly Grid _empty = new();
    private Point? _pressAt;
    private string? _pressed;

    public ShelfPage()
    {
        _filled.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _filled.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _filled.Children.Add(new ScrollViewer { Content = _tiles, VerticalScrollBarVisibility = ScrollBarVisibility.Hidden, Focusable = false });
        var footer = new Grid { Margin = new Thickness(0, 6, 0, 0) };
        footer.Children.Add(Ui.Label(L.T("Drag a file anywhere to copy it. Click to open it.", "Přetáhni soubor kamkoli — zkopíruje se. Klik ho otevře."), 10, FontWeights.Normal, Ui.White(0.4)));
        var clear = Ui.Button(Ui.Label(L.T("Clear", "Vyčistit"), 11, FontWeights.SemiBold, Ui.White(0.6)), _shelf.Clear);
        clear.HorizontalAlignment = HorizontalAlignment.Right;
        footer.Children.Add(clear);
        SetRow(footer, 1);
        _filled.Children.Add(footer);
        Children.Add(_filled);

        _empty.Children.Add(new Rectangle
        {
            RadiusX = 14, RadiusY = 14, Stroke = Ui.White(0.2), StrokeThickness = 1.5, StrokeDashArray = [5, 4],
        });
        var message = new StackPanel { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
        message.Children.Add(Ui.Icon(Glyph.Shelf, 24, Ui.White(0.75)));
        var line1 = Ui.Label(L.T("Drop files here", "Přetáhni sem soubory"), 13, FontWeights.SemiBold, Ui.White(0.75));
        line1.HorizontalAlignment = HorizontalAlignment.Center;
        line1.Margin = new Thickness(0, 6, 0, 2);
        message.Children.Add(line1);
        var line2 = Ui.Label(L.T("Park them here, then drag them wherever you need.", "Odložíš si je tu a pak je odtáhneš, kam potřebuješ."), 11, FontWeights.Normal, Ui.White(0.45));
        line2.HorizontalAlignment = HorizontalAlignment.Center;
        message.Children.Add(line2);
        _empty.Children.Add(message);
        Children.Add(_empty);

        _shelf.Changed += Rebuild;
        Rebuild();
    }

    public void PanelVisibilityChanged(bool panelOpen) { if (panelOpen) _shelf.Prune(); }

    private void Rebuild()
    {
        var any = _shelf.Items.Count > 0;
        _filled.Visibility = any ? Visibility.Visible : Visibility.Collapsed;
        _empty.Visibility = any ? Visibility.Collapsed : Visibility.Visible;
        _tiles.Children.Clear();
        foreach (var item in _shelf.Items) _tiles.Children.Add(Tile(item));
    }

    private Grid Tile(string path)
    {
        var tile = new Grid { Width = 72, Margin = new Thickness(0, 0, 8, 10), Background = Brushes.Transparent, ToolTip = path };
        var stack = new StackPanel { Margin = new Thickness(0, 4, 0, 4) };
        var icon = new Image { Width = 40, Height = 40, Source = ShellIcons.Get(path), HorizontalAlignment = HorizontalAlignment.Center };
        RenderOptions.SetBitmapScalingMode(icon, BitmapScalingMode.HighQuality);
        stack.Children.Add(icon);
        var name = Ui.Label(System.IO.Path.GetFileName(path), 10, FontWeights.Normal, Ui.White(0.8));
        name.TextAlignment = TextAlignment.Center;
        name.Margin = new Thickness(0, 4, 0, 0);
        stack.Children.Add(name);
        tile.Children.Add(stack);

        var remove = Ui.Button(Ui.Icon("", 11, Ui.White(0.55)), () => _shelf.Remove(path), L.T("Remove from the shelf", "Odebrat z police"), 16, 16);
        remove.HorizontalAlignment = HorizontalAlignment.Right;
        remove.VerticalAlignment = VerticalAlignment.Top;
        tile.Children.Add(remove);

        tile.MouseLeftButtonDown += (_, e) => { _pressAt = e.GetPosition(this); _pressed = path; };
        tile.MouseMove += (_, e) => MaybeDrag(tile, e);
        tile.MouseLeftButtonUp += (_, _) =>
        {
            if (_pressed == path) Shell.Open(path);
            _pressed = null;
        };
        return tile;
    }

    /// Dragging out hands over the file itself: the place it's dropped decides.
    private void MaybeDrag(Grid tile, MouseEventArgs e)
    {
        if (_pressed is not { } path || _pressAt is not { } start || e.LeftButton != MouseButtonState.Pressed) return;
        var move = e.GetPosition(this) - start;
        if (Math.Abs(move.X) < SystemParameters.MinimumHorizontalDragDistance
            && Math.Abs(move.Y) < SystemParameters.MinimumVerticalDragDistance) return;
        _pressed = null;
        var data = new DataObject();
        data.SetFileDropList([path]);
        data.SetData(OwnDragFormat, true);
        DragDrop.DoDragDrop(tile, data, DragDropEffects.Copy);
    }
}
