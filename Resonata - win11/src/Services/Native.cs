using System.Runtime.InteropServices;
using System.Text;

namespace Resonata;

internal static partial class Native
{
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct CURSORINFO { public int cbSize, flags; public IntPtr hCursor; public POINT ptScreenPos; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MSLLHOOKSTRUCT { public POINT pt; public uint mouseData, flags, time; public IntPtr dwExtraInfo; }

    public delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);

    public const int GWL_EXSTYLE = -20;
    public const long WS_EX_NOACTIVATE = 0x08000000, WS_EX_TOOLWINDOW = 0x00000080, WS_EX_TOPMOST = 0x00000008;
    public const uint SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2, SWP_NOACTIVATE = 0x10, SWP_NOZORDER = 0x4;
    public static readonly IntPtr HWND_TOPMOST = new(-1);
    public const int WH_MOUSE_LL = 14;
    public const int WM_LBUTTONDOWN = 0x201, WM_LBUTTONUP = 0x202, WM_RBUTTONDOWN = 0x204, WM_MBUTTONDOWN = 0x207;
    public const int WM_HOTKEY = 0x312, WM_MOUSEHWHEEL = 0x20E;
    public const int VK_LBUTTON = 1, VK_RBUTTON = 2, VK_MBUTTON = 4;

    public const ushort ImageFileMachineArm64 = 0xAA64;

    [LibraryImport("kernel32.dll")] public static partial IntPtr GetCurrentProcess();

    /// The machine Windows itself runs on, whatever the calling process is.
    [LibraryImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool IsWow64Process2(IntPtr process, out ushort processMachine, out ushort nativeMachine);

    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GetCursorPos(out POINT point);

    [LibraryImport("user32.dll")] public static partial short GetAsyncKeyState(int key);

    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GetCursorInfo(ref CURSORINFO info);

    [LibraryImport("user32.dll", EntryPoint = "LoadCursorW")]
    public static partial IntPtr LoadCursor(IntPtr instance, IntPtr name);

    [LibraryImport("user32.dll")] public static partial IntPtr GetForegroundWindow();

    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool SetForegroundWindow(IntPtr hwnd);

    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GetWindowRect(IntPtr hwnd, out RECT rect);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);

    [LibraryImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    public static partial IntPtr GetWindowLongPtr(IntPtr hwnd, int index);

    [LibraryImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
    public static partial IntPtr SetWindowLongPtr(IntPtr hwnd, int index, IntPtr value);

    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);

    [LibraryImport("user32.dll", EntryPoint = "SetWindowsHookExW")]
    public static partial IntPtr SetWindowsHookEx(int id, HookProc proc, IntPtr module, uint thread);

    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool UnhookWindowsHookEx(IntPtr hook);

    [LibraryImport("user32.dll")]
    public static partial IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern IntPtr WindowFromPoint(POINT point);

    [LibraryImport("user32.dll")]
    public static partial uint GetWindowThreadProcessId(IntPtr hwnd, out uint process);

    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool RegisterHotKey(IntPtr hwnd, int id, uint modifiers, uint key);

    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool UnregisterHotKey(IntPtr hwnd, int id);

    [LibraryImport("kernel32.dll", EntryPoint = "GetModuleHandleW", StringMarshalling = StringMarshalling.Utf16)]
    public static partial IntPtr GetModuleHandle(string? name);

    [LibraryImport("shell32.dll")]
    public static partial int SHQueryUserNotificationState(out int state);

    public static bool IsDown(int key) => (GetAsyncKeyState(key) & 0x8000) != 0;

    public static bool AnyButtonDown => IsDown(VK_LBUTTON) || IsDown(VK_RBUTTON) || IsDown(VK_MBUTTON);

    private static readonly IntPtr[] PlainCursors = new[]
        {
            32512 /* arrow */, 32513 /* ibeam */, 32514 /* wait */, 32515 /* cross */, 32516 /* up */,
            32642, 32643, 32644, 32645, 32646 /* sizes */, 32649 /* hand */, 32650 /* app starting */,
        }
        .Select(id => LoadCursor(IntPtr.Zero, id))
        .ToArray();

    /// A file is probably being dragged. Nothing announces another program's
    /// drag, but during one the cursor is OLE's own copy/move/no-drop shape,
    /// while dragging a window or selecting text keeps a standard one.
    public static bool IsDraggingFile()
    {
        if (!IsDown(VK_LBUTTON)) return false;
        var info = new CURSORINFO { cbSize = Marshal.SizeOf<CURSORINFO>() };
        return GetCursorInfo(ref info) && Array.IndexOf(PlainCursors, info.hCursor) < 0;
    }

    /// Something owns the whole of this screen: a game, a film, F11.
    ///
    /// The exact rect, on purpose: a maximised window hangs 8 px past every
    /// edge, so with an auto-hiding taskbar it covers the screen too, and that
    /// isn't full screen.
    public static bool IsFullScreen(System.Drawing.Rectangle screen, IntPtr ours)
    {
        if (SHQueryUserNotificationState(out var state) == 0 && state is 3 /* D3D */ or 4 /* presentation */)
            return true;
        var foreground = GetForegroundWindow();
        if (foreground == IntPtr.Zero || foreground == ours || !GetWindowRect(foreground, out var r)) return false;
        var name = new StringBuilder(64);
        GetClassName(foreground, name, name.Capacity);
        if (name.ToString() is "Progman" or "WorkerW" or "Shell_TrayWnd") return false;
        return r.Left == screen.Left && r.Top == screen.Top && r.Right == screen.Right && r.Bottom == screen.Bottom;
    }
}
