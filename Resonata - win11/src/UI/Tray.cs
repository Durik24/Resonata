using System.Windows;
using System.Windows.Threading;
using Forms = System.Windows.Forms;

namespace Resonata;

/// The icon by the clock. With the tab switched off or hidden, it's how you
/// find Resonata at all, and the one way to quit it.
public sealed class Tray : IDisposable
{
    private readonly PanelModel _m;
    private readonly NotchWindow _window;
    private readonly Forms.NotifyIcon _icon;
    private readonly Forms.ContextMenuStrip _menu = new();
    private readonly DispatcherTimer _tooltip = new() { Interval = TimeSpan.FromSeconds(1) };

    public Tray(PanelModel model, NotchWindow window)
    {
        _m = model;
        _window = window;
        var stream = Application.GetResourceStream(new Uri("pack://application:,,,/Assets/Resonata.ico"))!.Stream;
        using var icon = new System.Drawing.Icon(stream, Forms.SystemInformation.SmallIconSize);
        _icon = new Forms.NotifyIcon { Icon = (System.Drawing.Icon)icon.Clone(), Text = "Resonata", Visible = true, ContextMenuStrip = _menu };
        _icon.MouseClick += (_, e) => { if (e.Button == Forms.MouseButtons.Left) _m.Toggle?.Invoke(); };
        _menu.Opening += (_, _) => Rebuild();
        _tooltip.Tick += (_, _) => UpdateTooltip();
        _tooltip.Start();
        UpdateTooltip();
    }

    public void ShowMenu()
    {
        Rebuild();
        _menu.Show(Forms.Cursor.Position);
    }

    private void Rebuild()
    {
        _menu.Items.Clear();
        if (Screens.HasSeveral) Item(L.T("Move to the next display", "Přepnout na další displej"), () => _m.SwitchScreen?.Invoke());
        if (Updater.Shared.State is UpdateState.Available a)
        {
            Item(L.T($"Install Resonata {a.Version}", $"Nainstalovat Resonata {a.Version}"), () => _ = Updater.Shared.InstallAsync());
            _menu.Items.Add(new Forms.ToolStripSeparator());
        }
        Item(L.T("Settings…", "Nastavení…"), () => SettingsWindow.ShowShared(_window));
        var login = Item(L.T("Open at login", "Spouštět po přihlášení"), () => LoginItem.Set(!LoginItem.IsEnabled));
        login.Checked = LoginItem.IsEnabled;
        _menu.Items.Add(new Forms.ToolStripSeparator());
        Item(L.T("Quit Resonata", "Ukončit Resonata"), () => ((App)Application.Current).Quit());
    }

    private Forms.ToolStripMenuItem Item(string title, Action action)
    {
        var item = new Forms.ToolStripMenuItem(title);
        item.Click += (_, _) => action();
        _menu.Items.Add(item);
        return item;
    }

    private void UpdateTooltip()
    {
        var timer = CountdownTimer.Shared;
        var text = timer.IsActive
            ? L.T($"Timer: {TimeText.Countdown(timer.Remaining(DateTime.Now))}", $"Časovač: {TimeText.Countdown(timer.Remaining(DateTime.Now))}")
            : _m.Track is { } t ? $"{t.Title} – {t.Artist}" : "Resonata";
        // NotifyIcon throws past 127 characters.
        _icon.Text = text.Length > 120 ? text[..120] + "…" : text;
    }

    public void Dispose()
    {
        _tooltip.Stop();
        _icon.Visible = false;
        _icon.Dispose();
        _menu.Dispose();
    }
}
