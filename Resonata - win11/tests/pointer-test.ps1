# Drives a running Resonata with the real pointer and the real wheel, the way
# a hand on a touchpad does, and reads back from its log what it did:
#   the pointer resting on the right edge brings the pill out, and staying
#   there opens the panel (the Hover setting, the default);
#   a sideways two-finger swipe on the panel turns the page, and back;
#   leaving the panel closes it;
#   a swipe on the pill skips the song and keeps the panel from opening.
#
# A touchpad's swipe arrives as a run of small sideways wheel steps, and a
# Mac streaming Windows (Parsec, Moonlight, Remote Desktop) sends its
# trackpad the same way, as injected input: exactly what this sends.
#
# Moves the real pointer, so it's for a machine nobody is using: CI's.
#   pwsh tests\pointer-test.ps1 -Exe <Resonata.exe> [-CloseCovering]
# -CloseCovering ends whatever covers the whole screen first (not the
# desktop): on CI's ARM64 machine, Windows' first-run screen, which takes the
# wheel from anything under it.
param([Parameter(Mandatory)][string]$Exe, [switch]$CloseCovering)

$ErrorActionPreference = 'Stop'
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Hand
{
    [StructLayout(LayoutKind.Sequential)]
    struct MOUSEINPUT { public int dx, dy, mouseData; public uint dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    struct INPUT { public uint type; public MOUSEINPUT mi; }
    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    const uint WHEEL = 0x0800, HWHEEL = 0x01000;

    static void Wheel(uint flags, int delta)
    {
        var input = new INPUT { type = 0, mi = new MOUSEINPUT { mouseData = delta, dwFlags = flags } };
        if (SendInput(1, new[] { input }, Marshal.SizeOf<INPUT>()) != 1) throw new Exception("SendInput: " + Marshal.GetLastWin32Error());
    }
    public static void Sideways(int delta) { Wheel(HWHEEL, delta); }
    public static void Vertical(int delta) { Wheel(WHEEL, delta); }

    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out RECT r);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
    delegate bool EnumProc(IntPtr hwnd, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc, IntPtr l);

    /// The process whose window the wheel goes to at this point.
    public static uint Under(int x, int y)
    {
        uint pid;
        GetWindowThreadProcessId(GetAncestor(WindowFromPoint(new POINT { X = x, Y = y }), 2), out pid);
        return pid;
    }

    /// The processes of visible windows that cover the whole primary screen.
    public static System.Collections.Generic.List<uint> Covering()
    {
        var found = new System.Collections.Generic.List<uint>();
        int w = GetSystemMetrics(0), h = GetSystemMetrics(1);
        EnumWindows((hwnd, l) =>
        {
            RECT r;
            if (IsWindowVisible(hwnd) && GetWindowRect(hwnd, out r) && r.Left <= 0 && r.Top <= 0 && r.Right >= w && r.Bottom >= h)
            {
                uint pid;
                GetWindowThreadProcessId(hwnd, out pid);
                if (!found.Contains(pid)) found.Add(pid);
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
'@
function Named($id) { (Get-Process -Id $id -ErrorAction SilentlyContinue).ProcessName }

if ($CloseCovering) {
  foreach ($id in [Hand]::Covering()) {
    $name = Named $id
    if ($name -in 'explorer', 'Resonata', $null) { continue }
    "closing what covers the screen: $name ($id)"
    Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
  }
  Start-Sleep 2
}

$log = "$env:APPDATA\Resonata\resonata.log"
$from = if (Test-Path $log) { (Get-Content $log).Count } else { 0 }
function Lines { if (Test-Path $log) { @(Get-Content $log | Select-Object -Skip $from) } else { @() } }
function Expect($pattern, $what, $seconds = 4) {
  $deadline = (Get-Date).AddSeconds($seconds)
  while ((Get-Date) -lt $deadline) {
    if (Lines | Select-String -SimpleMatch $pattern) { "ok: $what"; return }
    Start-Sleep -Milliseconds 50
  }
  Lines | Select-Object -Last 30 | Write-Host
  throw "not seen in $seconds s: $what ($pattern)"
}
function Mark { $script:from = $from + @(Lines).Count }
# A swipe as a touchpad sends it: small steps, close together.
function Swipe([int]$sign) { for ($i = 0; $i -lt 12; $i++) { [Hand]::Sideways($sign * 18); Start-Sleep -Milliseconds 12 } }

"scroll inactive windows under the pointer: $((Get-ItemProperty 'HKCU:\Control Panel\Desktop' -ErrorAction SilentlyContinue).MouseWheelRouting)"
$env:RESONATA_DEMO = '1'
$env:RESONATA_TRACE = '1'
$app = Start-Process $Exe -PassThru
Remove-Item Env:RESONATA_DEMO, Env:RESONATA_TRACE
$null = $app.Handle
try {
  Expect 'trace: placed:' 'placed on the screen' 20
  $placed = (Lines | Select-String 'edge at x (\d+), line at y (\d+), scale ([\d.,]+)' | Select-Object -Last 1).Matches[0].Groups
  $edge = [int]$placed[1].Value; $line = [int]$placed[2].Value; $scale = [double]($placed[3].Value -replace ',', '.')
  "edge x $edge, line y $line, scale $scale"
  Start-Sleep 2

  # Hover: the pill, then the panel.
  Mark
  [Hand]::SetCursorPos($edge - [int](900 * $scale), $line) | Out-Null
  Start-Sleep -Milliseconds 400
  [Hand]::SetCursorPos($edge, $line) | Out-Null
  Expect 'trace: EdgeHeld True' 'resting on the edge brings the pill out'
  Expect 'trace: IsExpanded True' 'staying on the pill opens the panel'
  Start-Sleep 1

  # Swipes on the open panel.
  Mark
  [Hand]::SetCursorPos($edge - [int](200 * $scale), $line) | Out-Null
  Start-Sleep -Milliseconds 300
  $under = Named ([Hand]::Under($edge - [int](200 * $scale), $line))
  if ($under -ne 'Resonata') { throw "the wheel would go to $under, which is in front of the panel" }
  Swipe -1
  Expect 'trace: Tab Notes' 'a swipe turns to the next page'
  Start-Sleep -Milliseconds 600
  Swipe 1
  Expect 'trace: Tab Music' 'a swipe back turns back'

  # Off the panel: it closes.
  Mark
  [Hand]::SetCursorPos($edge - [int](1000 * $scale), $line + [int](300 * $scale)) | Out-Null
  Expect 'trace: IsExpanded False' 'leaving the panel closes it'
  Start-Sleep 2

  # A swipe on the pill: the next song, and the panel waits.
  Mark
  [Hand]::SetCursorPos($edge, $line) | Out-Null
  Expect 'trace: EdgeHeld True' 'the pill comes out again'
  Start-Sleep -Milliseconds 300
  Swipe -1
  Expect 'trace: pill swipe Next' 'a swipe on the pill skips the song'
  Start-Sleep -Milliseconds 300
  if (Lines | Select-String -SimpleMatch 'trace: IsExpanded True') { throw 'the panel opened in the middle of swiping songs' }
  'ok: the panel waited while songs were swiped'
  # The wheel turned down on the pill opens the panel, at once: before
  # staying on the pill would have. The pointer hasn't moved since the pill
  # came out under it, which is when the wheel used to get lost.
  Mark
  for ($i = 0; $i -lt 3; $i++) { [Hand]::Vertical(-120); Start-Sleep -Milliseconds 20 }
  Expect 'on the pill' 'the wheel reaches the pill under a pointer standing still' 0.25
  Expect 'trace: IsExpanded True' 'the wheel down on the pill opens the panel' 0.25
}
finally {
  [Hand]::SetCursorPos(10, 10) | Out-Null
  Start-Process $Exe -ArgumentList '--quit' -Wait
  if (-not $app.WaitForExit(15000)) { $app.Kill() }
}
