// ForegroundWatch.cs — tells the shield when something else took the foreground.
// EVENT_SYSTEM_FOREGROUND out of context (no DLL injection) PLUS a 250 ms GetForegroundWindow poll:
// spike Q6 showed the event arrives ~3 s late for console and Windows Terminal windows.

using System;
using System.Windows.Threading;
using GoPray.App.Native;

namespace GoPray.App.Shield;

internal sealed class ForegroundWatch : IDisposable
{
    readonly Func<IntPtr, bool> _isOurs;
    readonly Action _lost;
    readonly Win32.WinEventProc _proc;
    readonly DispatcherTimer _poll;
    IntPtr _hook;

    /// <param name="isOurs">true for any of our windows (the foreground's root owner is passed).</param>
    /// <param name="lost">called on the UI thread whenever a foreign window is in front.</param>
    public ForegroundWatch(Func<IntPtr, bool> isOurs, Action lost, TimeSpan? pollEvery = null)
    {
        _isOurs = isOurs;
        _lost = lost;
        _proc = (_, _, hwnd, _, _, _, _) => Check(hwnd);
        _hook = Win32.SetWinEventHook(Win32.EVENT_SYSTEM_FOREGROUND, Win32.EVENT_SYSTEM_FOREGROUND, IntPtr.Zero, _proc, 0, 0, Win32.WINEVENT_OUTOFCONTEXT);
        _poll = new DispatcherTimer(DispatcherPriority.Normal) { Interval = pollEvery ?? TimeSpan.FromMilliseconds(250) };
        _poll.Tick += (_, _) => Check(Win32.GetForegroundWindow());
        _poll.Start();
    }

    void Check(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return;
        var root = Win32.GetAncestor(hwnd, 3 /* GA_ROOTOWNER */);
        if (!_isOurs(root == IntPtr.Zero ? hwnd : root)) _lost();
    }

    public void Dispose()
    {
        _poll.Stop();
        if (_hook != IntPtr.Zero) { Win32.UnhookWinEvent(_hook); _hook = IntPtr.Zero; }
    }
}
