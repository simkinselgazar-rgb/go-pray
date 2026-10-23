// Win32.cs — the window-management calls the shield needs. Deliberately absent (guard.ps1):
// SetWindowsHookEx (only Shield/KeyboardGuard.cs), ShowWindow (only Blocker/AppHider.cs), and every
// call that kills, closes, hides or injects input.

using System;
using System.Runtime.InteropServices;

namespace GoPray.App.Native;

internal static partial class Win32
{
    public static readonly IntPtr HWND_TOPMOST = new(-1);
    public const uint SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2, SWP_NOACTIVATE = 0x10, SWP_SHOWWINDOW = 0x40;
    public const int GWL_EXSTYLE = -20;
    public const long WS_EX_TOOLWINDOW = 0x80, WS_EX_NOACTIVATE = 0x08000000, WS_EX_APPWINDOW = 0x40000;
    public const uint EVENT_SYSTEM_FOREGROUND = 3, WINEVENT_OUTOFCONTEXT = 0;
    public const int DWMWA_WINDOW_CORNER_PREFERENCE = 33, DWMWCP_ROUND = 2;
    public const int MDT_EFFECTIVE_DPI = 0;

    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

    public delegate void WinEventProc(IntPtr hook, uint ev, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);

    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool SetForegroundWindow(IntPtr hwnd);
    [LibraryImport("user32.dll")] public static partial IntPtr GetForegroundWindow();
    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool IsWindow(IntPtr hwnd);
    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GetWindowRect(IntPtr hwnd, out RECT r);
    [LibraryImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] public static partial IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
    [LibraryImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] public static partial IntPtr SetWindowLongPtr(IntPtr hwnd, int index, IntPtr value);
    [DllImport("user32.dll")] public static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr mod, WinEventProc proc, uint pid, uint tid, uint flags);
    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool UnhookWinEvent(IntPtr hook);
    [LibraryImport("user32.dll")] public static partial IntPtr GetAncestor(IntPtr hwnd, uint flags);
    [LibraryImport("dwmapi.dll")] public static partial int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    [LibraryImport("shcore.dll")] public static partial int GetDpiForMonitor(IntPtr monitor, int type, out uint dpiX, out uint dpiY);
    [LibraryImport("user32.dll")] public static partial IntPtr MonitorFromPoint(POINT pt, uint flags);
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }

    public static void AddExStyle(IntPtr hwnd, long bits) =>
        SetWindowLongPtr(hwnd, GWL_EXSTYLE, new IntPtr(GetWindowLongPtr(hwnd, GWL_EXSTYLE).ToInt64() | bits));
    public static void RemoveExStyle(IntPtr hwnd, long bits) =>
        SetWindowLongPtr(hwnd, GWL_EXSTYLE, new IntPtr(GetWindowLongPtr(hwnd, GWL_EXSTYLE).ToInt64() & ~bits));

    /// <summary>Effective DPI scale (1.0 = 96 dpi) of the monitor containing a point (device pixels).</summary>
    public static double ScaleAt(int x, int y)
    {
        var mon = MonitorFromPoint(new POINT { X = x, Y = y }, 2 /* MONITOR_DEFAULTTONEAREST */);
        return GetDpiForMonitor(mon, MDT_EFFECTIVE_DPI, out var dx, out _) == 0 && dx > 0 ? dx / 96.0 : 1.0;
    }
}
