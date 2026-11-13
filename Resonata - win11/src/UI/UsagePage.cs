using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace Resonata;

/// Claude Code's and Vibe's limits, written out: the session's five hours
/// and the week, Vibe's month, and what each running session is doing. A
/// page of its own in the open panel, and what the music page shows in the
/// song's place while nothing plays.
public sealed class UsagePage : StackPanel, IPage
{
    private static readonly Brush Quiet = Ui.White(0.62);

    private readonly PanelModel _m;
    private readonly DispatcherTimer _clock = new() { Interval = TimeSpan.FromSeconds(30) };

    /// Without the list of sessions: under it there is something else.
    public bool Compact { get; set; }

    /// How many sessions the list has room for.
    public int MaxSessions { get; set; } = 6;

    public UsagePage(PanelModel model)
    {
        _m = model;
        // The countdown is against the clock, so it stays right between
        // readings; twice a minute is as often as its minutes change.
        _clock.Tick += (_, _) => Rebuild();
        _m.PropertyChanged += OnModelChanged;
        Rebuild();
    }

    private void OnModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(PanelModel.Claude) or nameof(PanelModel.Vibe)) Rebuild();
    }

    public void PanelVisibilityChanged(bool panelOpen)
    {
        if (panelOpen) { Rebuild(); _clock.Start(); } else _clock.Stop();
    }

    public void Rebuild()
    {
        Children.Clear();
        var now = DateTime.Now;
        if (_m.Claude is null && _m.Vibe is null)
        {
            var none = Ui.Label(Settings.Current.ShowClaude || Settings.Current.ShowVibe
                ? L.T("Neither Claude Code nor Mistral Vibe was found on this PC", "Claude Code ani Mistral Vibe na tomhle PC nejsou")
                : L.T("Switch on Claude Code or Mistral Vibe in Settings", "Zapni Claude Code nebo Mistral Vibe v Nastavení"), 11, FontWeights.Normal, Quiet);
            none.TextWrapping = TextWrapping.Wrap;
            none.TextAlignment = TextAlignment.Center;
            none.Margin = new Thickness(8, 60, 8, 0);
            Children.Add(none);
            return;
        }
        if (_m.Claude is { } claude) Children.Add(ClaudeCard(claude, now));
        if (_m.Vibe is { } vibe) Children.Add(VibeCard(vibe));
        if (!Compact && MaxSessions > 0) Children.Add(SessionsCard(AiSummary.Rows(_m.Claude, _m.Vibe)));
    }

    /// The five-hour window, the ring the tab shows, with the week under it.
    private Border ClaudeCard(ClaudeStatus status, DateTime now)
    {
        var usage = status.Usage;
        var card = new StackPanel();
        card.Children.Add(Header("C", ActivityLook.Claude, "Claude Code", status.State));
        card.Children.Add(Reading(status.Fraction, status.State, ActivityLook.Claude, L.T("Session · 5 h", "Relace · 5 h"),
            usage?.SessionPercent, usage?.SessionResets is { } resets ? AiText.Countdown(resets, now) : null));
        if (usage is null)
        {
            card.Children.Add(Note(ClaudeMonitor.LocateCli() is null
                ? L.T("The limits are read with the claude command, which isn't installed here. The sessions' states work without it.",
                      "Limity se čtou příkazem claude, který tu není nainstalovaný. Stavy relací fungují i bez něj.")
                : L.T("The limits haven't been read: the claude command has to be signed in.",
                      "Limity se nenačetly: příkaz claude musí být přihlášený.")));
        }
        if (usage?.WeekPercent is { } week)
            card.Children.Add(Foot(L.T("Week", "Týden") + (usage.WeekResets is { } w ? " · " + AiText.Day(w) : ""), week, ActivityLook.Week));
        foreach (var model in usage?.Models ?? [])
            card.Children.Add(Foot(model.Name + (model.Resets is { } r ? " · " + AiText.Day(r) : ""), model.Percent, ActivityLook.Violet));
        return Card(card);
    }

    /// Vibe's: the month's allowance, and the plan it comes with.
    private Border VibeCard(VibeStatus status)
    {
        var usage = status.Usage;
        var card = new StackPanel();
        card.Children.Add(Header("M", ActivityLook.Vibe, "Mistral Vibe", status.State));
        card.Children.Add(Reading(status.Fraction, status.State, ActivityLook.Vibe, L.T("Month", "Měsíc"),
            usage?.Percent, usage?.Resets is { } resets ? AiText.Date(resets) : null));
        if (usage is null)
            card.Children.Add(Note(L.T("The allowance hasn't been read: Vibe has to be signed in.", "Limit se nenačetl: Vibe musí být přihlášený.")));
        if (usage?.Plan is { } plan)
            card.Children.Add(Line(L.T("Plan", "Tarif"), plan + (usage.PayAsYouGo ? L.T(" · billed past 100 %", " · nad 100 % se platí") : "")));
        return Card(card);
    }

    /// Every running session and what it is doing; a click goes to its app.
    private Border SessionsCard(IReadOnlyList<(AiSession Session, bool IsVibe)> rows)
    {
        var both = _m.Claude is not null && _m.Vibe is not null;
        var card = new StackPanel();
        card.Children.Add(Header(rows.Count.ToString(), ActivityLook.Violet, L.T("Sessions", "Relace"), null));
        if (rows.Count == 0) card.Children.Add(Note(L.T("None running", "Žádná neběží")));
        foreach (var (session, isVibe) in rows.Take(MaxSessions))
        {
            var dot = new System.Windows.Shapes.Ellipse
            {
                Width = 6, Height = 6, Margin = new Thickness(1, 0, 7, 0), VerticalAlignment = VerticalAlignment.Center,
                Fill = session.State switch
                {
                    AiState.Working => Ui.Solid(isVibe ? ActivityLook.Vibe : ActivityLook.Claude),
                    AiState.Waiting => Ui.Solid(ActivityLook.Amber),
                    _ => Ui.White(0.3),
                },
            };
            var text = new StackPanel();
            text.Children.Add(Ui.Label(session.Name, 10.5, FontWeights.SemiBold, Brushes.White));
            // "working · Terminal", or "Vibe · working · Terminal" where the tool has to be said.
            text.Children.Add(Ui.Label((both ? (isVibe ? "Vibe · " : "Claude · ") : "") + AiText.State(session.State)
                + (session.App is { } app ? " · " + app : ""), 9, FontWeights.Normal, Quiet));
            var row = new DockPanel { Margin = new Thickness(0, 6, 0, 0), Background = Brushes.Transparent, Cursor = Cursors.Hand };
            DockPanel.SetDock(dot, Dock.Left);
            row.Children.Add(dot);
            row.Children.Add(text);
            var pid = session.Pid;
            row.ToolTip = L.T("Go to its app", "Přejít do její aplikace");
            row.MouseLeftButtonUp += (_, e) => { HostApp.BringForward(pid); _m.Close?.Invoke(); e.Handled = true; };
            card.Children.Add(row);
        }
        return Card(card);
    }

    // MARK: The pieces of a card

    private static Border Card(UIElement content) => new()
    {
        Child = content, Padding = new Thickness(10, 9, 10, 10), Margin = new Thickness(0, 0, 0, 8),
        CornerRadius = new CornerRadius(10), Background = Ui.White(0.06),
    };

    private static UIElement Header(string mark, Color tint, string title, AiState? state)
    {
        var row = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
        var letter = Ui.Label(mark, 9, FontWeights.Heavy, Ui.Solid(Color.FromArgb(217, 0, 0, 0)));
        letter.HorizontalAlignment = HorizontalAlignment.Center;
        letter.VerticalAlignment = VerticalAlignment.Center;
        var badge = new Border { Width = 16, Height = 16, CornerRadius = new CornerRadius(8), Background = Ui.Solid(tint), Child = letter, Margin = new Thickness(0, 0, 6, 0) };
        DockPanel.SetDock(badge, Dock.Left);
        row.Children.Add(badge);
        if (state is { } s)
        {
            var chip = Ui.Capsule(new TextBlock
            {
                Text = s switch { AiState.Working => L.T("Working", "Pracuje"), AiState.Waiting => L.T("Waiting", "Čeká"), _ => L.T("Idle", "Volno") },
                FontFamily = Ui.TextFont, FontSize = 9, FontWeight = FontWeights.SemiBold, Margin = new Thickness(7, 0, 7, 1), VerticalAlignment = VerticalAlignment.Center,
                Foreground = s switch { AiState.Working => Brushes.White, AiState.Waiting => Ui.Solid(ActivityLook.Amber), _ => Quiet },
            }, 0.12, 16);
            DockPanel.SetDock(chip, Dock.Right);
            row.Children.Add(chip);
        }
        var name = Ui.Label(title, 11.5, FontWeights.Bold, Brushes.White);
        name.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(name);
        return row;
    }

    /// The ring with its figures beside it.
    private static UIElement Reading(double? fraction, AiState state, Color tint, string label, int? percent, string? detail)
    {
        var ring = new AiRing(46, 4.5) { Margin = new Thickness(0, 0, 10, 0) };
        ring.Show(fraction, state, tint);
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(Ui.Label(label, 9, FontWeights.Normal, Quiet));
        text.Children.Add(Ui.Label(percent is { } p ? $"{p} %" : "–", 18, FontWeights.Bold, Brushes.White));
        text.Children.Add(Ui.Label(detail ?? " ", 9, FontWeights.Normal, Quiet));
        var row = new DockPanel();
        DockPanel.SetDock(ring, Dock.Left);
        row.Children.Add(ring);
        row.Children.Add(text);
        return row;
    }

    /// A line and a thin bar under it.
    private static UIElement Foot(string label, int percent, Color tint)
    {
        var foot = new StackPanel { Margin = new Thickness(0, 8, 0, 0) };
        foot.Children.Add(Line(label, $"{percent} %", 0));
        var share = Math.Clamp(percent / 100.0, 0, 1);
        var bar = new Grid { Height = 4, Margin = new Thickness(0, 4, 0, 0) };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(share, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1 - share, GridUnitType.Star) });
        var back = new Border { CornerRadius = new CornerRadius(2), Background = Ui.White(0.14) };
        Grid.SetColumnSpan(back, 2);
        bar.Children.Add(back);
        bar.Children.Add(new Border { CornerRadius = new CornerRadius(2), Background = Ui.Solid(tint), MinWidth = 4 });
        foot.Children.Add(bar);
        return foot;
    }

    private static UIElement Line(string label, string value, double top = 8)
    {
        var line = new DockPanel { Margin = new Thickness(0, top, 0, 0) };
        var right = Ui.Label(value, 9, FontWeights.SemiBold, Ui.White(0.85));
        DockPanel.SetDock(right, Dock.Right);
        line.Children.Add(right);
        line.Children.Add(Ui.Label(label, 9, FontWeights.Normal, Quiet));
        return line;
    }

    private static TextBlock Note(string text)
    {
        var note = Ui.Label(text, 9.5, FontWeights.Normal, Quiet);
        note.TextWrapping = TextWrapping.Wrap;
        note.TextTrimming = TextTrimming.None;
        note.Margin = new Thickness(0, 6, 0, 0);
        return note;
    }
}

/// The limits' page in the panel: scrolled by the wheel, with no bar drawn.
public sealed class UsageScroll : ScrollViewer, IPage
{
    private readonly UsagePage _page;

    public UsageScroll(UsagePage page)
    {
        _page = page;
        Content = page;
        VerticalScrollBarVisibility = ScrollBarVisibility.Hidden;
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;
        Focusable = false;
    }

    public void PanelVisibilityChanged(bool panelOpen) => _page.PanelVisibilityChanged(panelOpen);
}
