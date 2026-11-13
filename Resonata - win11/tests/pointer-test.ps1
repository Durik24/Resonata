# Drives a running Resonata with the real pointer and the real wheel, the way
# a hand on a touchpad does, and reads back from its log what it did:
#   the pointer resting on the tab at the right edge opens the panel (the
#   Hover setting, the default);
#   scrolling down and up turns the pages, from where the pointer opened the
#   panel and from on it, swipe after swipe without a pause or a move of the
#   pointer between them; a sideways two-finger swipe turns them too;
#   leaving the panel closes it;
#   a sideways swipe on the tab skips the song and keeps the panel from
#   opening, and the wheel turned down on it opens the panel at once.
#
# A touchpad's swipe arrives as a run of small wheel steps, and a Mac
# streaming Windows (Parsec, Moonlight, Remote Desktop) sends its trackpad
# the same way, as injected input: exactly what this sends.
#
# Moves the real pointer, so it's for a machine nobody is using: CI's.
#   pwsh tests\pointer-test.ps1 -Exe <Resonata.exe> [-CloseCovering]
# -CloseCovering first ends Windows' first-run screen (WWAHost) and the Start
# menu it leaves open, which on CI's ARM64 machine cover everything and take
# the wheel from it.
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
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);

    public static int Size(int index) { return GetSystemMetrics(index); }

    /// The process whose window the wheel goes to at this point.
    public static uint Under(int x, int y)
    {
        uint pid;
        GetWindowThreadProcessId(GetAncestor(WindowFromPoint(new POINT { X = x, Y = y }), 2), out pid);
        return pid;
    }
}
'@
function Named($id) { (Get-Process -Id $id -ErrorAction SilentlyContinue).ProcessName }

if ($CloseCovering) {
  # The first-run screen and the Start menu it leaves open, by name, and
  # nothing else: closing whatever was in front went on to the windows behind
  # them, the runner's own among them. Both are Windows' shell, which starts
  # them again when wanted. Anything else in front of the panel fails the
  # test below, by name.
  $w = [Hand]::Size(0); $h = [Hand]::Size(1)
  foreach ($shell in 'WWAHost', 'StartMenuExperienceHost') {
    "in front where the panel opens: $(Named ([Hand]::Under($w - 200, [int]($h * 0.3))))"
    Get-Process $shell -ErrorAction SilentlyContinue | ForEach-Object {
      "closing $shell ($($_.Id))"
      Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep 2
  }
  "in front where the panel opens: $(Named ([Hand]::Under($w - 200, [int]($h * 0.3))))"
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
# The same up and down: two fingers scrolling. Negative is scrolling down.
function Scroll([int]$sign) { for ($i = 0; $i -lt 12; $i++) { [Hand]::Vertical($sign * 18); Start-Sleep -Milliseconds 12 } }
# What a touchpad goes on sending once the fingers have lifted: the swipe's
# momentum, ever weaker.
function Momentum([int]$sign) { foreach ($step in 16, 13, 10, 8, 6, 5, 4, 3, 2, 2, 1, 1) { [Hand]::Vertical($sign * $step); Start-Sleep -Milliseconds 12 } }

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

  # Hover: resting on the tab opens the panel.
  Mark
  [Hand]::SetCursorPos($edge - [int](900 * $scale), $line) | Out-Null
  Start-Sleep -Milliseconds 400
  [Hand]::SetCursorPos($edge, $line) | Out-Null
  Expect 'trace: EdgeHeld True' 'the tab notices the pointer resting on it'
  Expect 'trace: IsExpanded True' 'staying on the tab opens the panel'
  Start-Sleep 1

  # The wheel right there: the pointer hasn't moved since it opened the
  # panel, and is in the strip between the panel and the edge.
  Mark
  $under = Named ([Hand]::Under($edge, $line))
  if ($under -ne 'Resonata') { throw "beside the open panel the wheel would go to $under" }
  Scroll -1
  Expect 'trace: Tab Notes' 'scrolling down where the pointer opened the panel turns to the next page'
  Start-Sleep -Milliseconds 600

  # And on the panel itself, up and down and sideways.
  Mark
  [Hand]::SetCursorPos($edge - [int](200 * $scale), $line) | Out-Null
  Start-Sleep -Milliseconds 300
  $under = Named ([Hand]::Under($edge - [int](200 * $scale), $line))
  if ($under -ne 'Resonata') { throw "the wheel would go to $under, which is in front of the panel" }
  Scroll 1
  Expect 'trace: Tab Music' 'scrolling up on the panel turns back'
  Start-Sleep -Milliseconds 600

  # Swipe after swipe with no pause, each in the middle of the momentum of
  # the one before, and the pointer never moved: moving it is what stops a
  # touchpad's momentum, and used to be the only way to swipe again.
  Mark
  Scroll -1; Momentum -1; Scroll -1; Momentum -1; Scroll 1; Momentum 1
  Start-Sleep -Milliseconds 500
  $turned = @(Lines | Select-String -SimpleMatch 'trace: Tab ' | ForEach-Object { ($_.Line -split 'trace: Tab ')[1] }) -join ' '
  if ($turned -ne 'Notes Apps Notes') { throw "three swipes straight after one another turned: $turned" }
  'ok: three swipes straight after one another each turn a page, down, down and up'
  Mark
  Scroll 1
  Expect 'trace: Tab Music' 'and a fourth is back on the first page'
  Start-Sleep -Milliseconds 600
  Mark
  Swipe -1
  Expect 'trace: Tab Notes' 'a sideways swipe turns to the next page too'
  Start-Sleep -Milliseconds 600
  Swipe 1
  Expect 'trace: Tab Music' 'and back'

  # Off the panel: it closes.
  Mark
  [Hand]::SetCursorPos($edge - [int](1000 * $scale), $line + [int](300 * $scale)) | Out-Null
  Expect 'trace: IsExpanded False' 'leaving the panel closes it'
  Start-Sleep 2

  # A sideways swipe on the tab: the next song, and the panel waits.
  Mark
  [Hand]::SetCursorPos($edge, $line) | Out-Null
  Expect 'trace: EdgeHeld True' 'the tab notices the pointer again'
  Swipe -1
  Expect 'trace: pill swipe Next' 'a swipe on the tab skips the song'
  Start-Sleep -Milliseconds 150
  if (Lines | Select-String -SimpleMatch 'trace: IsExpanded True') { throw 'the panel opened in the middle of swiping songs' }
  'ok: the panel waited while songs were swiped'
  # The wheel turned down on the tab opens the panel, at once. The pointer
  # has only ever been set down on the tab, which is when a wheel sent
  # through WPF used to get lost.
  Mark
  for ($i = 0; $i -lt 3; $i++) { [Hand]::Vertical(-120); Start-Sleep -Milliseconds 20 }
  Expect 'on the tab' 'the wheel reaches the tab under a pointer standing still' 0.25
  Expect 'trace: IsExpanded True' 'the wheel down on the tab opens the panel' 0.25
  Start-Sleep -Milliseconds 400
  if (Lines | Select-String -SimpleMatch 'trace: Tab ') { throw 'the wheel that opened the panel went on to turn its page' }
  'ok: and leaves it on the page it opened on'
}
finally {
  [Hand]::SetCursorPos(10, 10) | Out-Null
  Start-Process $Exe -ArgumentList '--quit' -Wait
  if (-not $app.WaitForExit(15000)) { $app.Kill() }
}

# Again with nothing playing: the tab slides away altogether once nothing has
# been going on for a while (two seconds here, half a minute as shipped), and
# only the pointer on the very edge of the screen calls it back.
$env:RESONATA_DEMO = '1'; $env:RESONATA_DEMO_IDLE = '1'; $env:RESONATA_TRACE = '1'; $env:RESONATA_SLEEP = '2'
$app = Start-Process $Exe -PassThru
Remove-Item Env:RESONATA_DEMO, Env:RESONATA_DEMO_IDLE, Env:RESONATA_TRACE, Env:RESONATA_SLEEP
$null = $app.Handle
try {
  Mark
  [Hand]::SetCursorPos($edge - [int](900 * $scale), $line) | Out-Null
  Expect 'trace: placed:' 'placed on the screen again' 20
  Expect 'trace: asleep' 'with nothing going on the tab slides away' 8
  Start-Sleep 1

  Mark
  [Hand]::SetCursorPos($edge - [int](8 * $scale) - 4, $line) | Out-Null
  Start-Sleep -Milliseconds 700
  if (Lines | Select-String -SimpleMatch 'trace: awake') { throw 'the hidden tab came out for a pointer that was only near the edge' }
  'ok: near the edge is not enough to call it back'
  [Hand]::SetCursorPos($edge, $line) | Out-Null
  Expect 'trace: awake' 'the pointer on the very edge calls the tab back'
  Expect 'trace: EdgeHeld True' 'which notices the pointer'
  Expect 'trace: IsExpanded True' 'and staying there opens the panel'
  Start-Sleep 1

  Mark
  [Hand]::SetCursorPos($edge - [int](1000 * $scale), $line + [int](300 * $scale)) | Out-Null
  Expect 'trace: IsExpanded False' 'leaving the panel closes it'
  Expect 'trace: asleep' 'and the tab slides away again soon after' 10
}
finally {
  [Hand]::SetCursorPos(10, 10) | Out-Null
  Start-Process $Exe -ArgumentList '--quit' -Wait
  if (-not $app.WaitForExit(15000)) { $app.Kill() }
}
