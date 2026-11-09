using System.Media;
using System.Windows.Threading;

namespace Resonata;

/// Counts down, shows the time left and chimes at the end. Kept in the
/// settings, so a running timer survives Resonata restarting.
public sealed class CountdownTimer : Observable
{
    public static CountdownTimer Shared { get; } = new();

    public static readonly int[] Presets = [5, 10, 15, 25, 45, 60];

    /// A second's tick rather than one timer for the end: it fires on time
    /// after the PC wakes, and the ring needs the tick anyway.
    private readonly DispatcherTimer _tick = new() { Interval = TimeSpan.FromSeconds(1) };
    private static Settings S => Settings.Current;

    public event Action<int>? Finished;
    public event Action<PomodoroPhase, int>? PhaseStarted;
    public event Action? Ticked;

    private CountdownTimer()
    {
        _tick.Tick += (_, _) => OnTick();
        // One that ran out while Resonata wasn't running is simply over.
        if (S.TimerEnd is { } end && end <= DateTime.Now) S.TimerEnd = null;
        if (S.TimerEnd is not null) _tick.Start();
    }

    public DateTime? End => S.TimerEnd;
    public double? PausedRemaining => S.TimerPausedRemaining;
    public double Total => S.TimerTotal;
    public int ChosenMinutes => S.TimerChosen;
    public PomodoroPhase? Phase => S.TimerPhase;
    public int Round => S.TimerRound;
    public bool IsActive => End is not null || PausedRemaining is not null;
    public bool IsPaused => PausedRemaining is not null;

    public double Remaining(DateTime now)
    {
        if (End is { } end) return Math.Max(0, (end - now).TotalSeconds);
        return PausedRemaining ?? ChosenMinutes * 60;
    }

    /// 0 at the start, 1 at the end.
    public double Progress(DateTime now) =>
        !IsActive || Total <= 0 ? 0 : Math.Clamp(1 - Remaining(now) / Total, 0, 1);

    private void Notify()
    {
        Raise(nameof(IsActive));
        Ticked?.Invoke();
    }

    public void Choose(int minutes)
    {
        S.TimerChosen = TimeText.ClampMinutes(minutes);
        Notify();
    }

    public void Start(int minutes)
    {
        S.TimerPhase = null;
        S.TimerChosen = minutes;
        Run(minutes);
    }

    public void StartPomodoro()
    {
        S.TimerPhase = PomodoroPhase.Work;
        S.TimerRound = 1;
        Run(S.PomodoroPlan.Work);
    }

    private void Run(int minutes)
    {
        S.TimerTotal = minutes * 60;
        S.TimerPausedRemaining = null;
        S.TimerEnd = DateTime.Now.AddMinutes(minutes);
        _tick.Start();
        Notify();
    }

    public void Pause()
    {
        if (End is not { } end) return;
        S.TimerPausedRemaining = Math.Max(0, (end - DateTime.Now).TotalSeconds);
        S.TimerEnd = null;
        _tick.Stop();
        Notify();
    }

    public void Resume()
    {
        if (PausedRemaining is not { } left) return;
        S.TimerPausedRemaining = null;
        S.TimerEnd = DateTime.Now.AddSeconds(left);
        _tick.Start();
        Notify();
    }

    public void Cancel()
    {
        S.TimerEnd = null;
        S.TimerPausedRemaining = null;
        S.TimerPhase = null;
        S.TimerRound = 1;
        _tick.Stop();
        Notify();
    }

    private void OnTick()
    {
        if (End is { } end && end <= DateTime.Now) Done();
        else Ticked?.Invoke();
    }

    private void Done()
    {
        Chime();
        if (Phase is { } phase)
        {
            var next = S.PomodoroPlan.Next(phase, Round);
            S.TimerPhase = next.Phase;
            S.TimerRound = next.Round;
            Run(next.Minutes);
            PhaseStarted?.Invoke(next.Phase, next.Minutes);
            return;
        }
        var minutes = (int)Math.Round(Total / 60);
        Cancel();
        Finished?.Invoke(minutes);
    }

    private static void Chime()
    {
        var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),
            "Media", "Windows Notify Calendar.wav");
        try
        {
            if (File.Exists(path)) { new SoundPlayer(path).Play(); return; }
        }
        catch (Exception e) when (e is InvalidOperationException or TimeoutException)
        {
            Log.Write($"chime failed: {e.Message}");
        }
        SystemSounds.Asterisk.Play();
    }
}
