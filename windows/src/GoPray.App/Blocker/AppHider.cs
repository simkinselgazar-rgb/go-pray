// AppHider.cs — IAppHiding for "Coding apps only" mode. Port of Blocker/AppHider.swift (PLAN.md §3 row 2).
// Rules:
//  - MINIMISE only (SW_MINIMIZE). Never close, kill or hide a window (SW_HIDE would drop its taskbar
//    button: if we crashed it could not be brought back; a minimised window always can). guard rules 3 + 9.
//  - Only top-level visible windows of listed processes, never our own.
//  - Re-minimise when one comes forward: EVENT_SYSTEM_FOREGROUND + a 250 ms poll (spike Q6: the event is
//    ~3 s late for console and Windows Terminal windows).
//  - Stop() does NOT restore anything: windows stay minimised until the person brings them back
//    (restoring on our own would pop windows over the "May Allah accept it." fade).
//  - An elevated window ("Run as administrator") may refuse us (UIPI); that is logged and left alone.
//    We never elevate.
// This is the only file with ShowWindow (guard rule 9).

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using GoPray.App.Shield;
using GoPray.Core;

namespace GoPray.App.Blocker;

/// <summary>What the hider needs from the desktop. The real one is below; tests use a fake.</summary>
internal interface IWindowSystem
{
    /// <summary>Top-level visible windows with their process name.</summary>
    IEnumerable<(IntPtr Hwnd, string Process)> TopLevel();
    string? ProcessOf(IntPtr hwnd);
    bool IsMinimised(IntPtr hwnd);
    bool Minimise(IntPtr hwnd);
    /// <summary>Calls <paramref name="foreground"/> with the foreground window when it changes (event + poll).</summary>
    IDisposable Watch(Action<IntPtr> foreground);
}

internal sealed class AppHider(IWindowSystem? windows = null, Func<string, bool>? isListed = null) : IAppHiding
{
    readonly IWindowSystem _w = windows ?? new DesktopWindows();
    readonly Func<string, bool> _listed = isListed ?? CodingApps.IsListed;
    IDisposable? _watch;

    public Action<string>? OnReHide { get; set; }
    public int Minimised { get; private set; }

    /// <summary>Safe to call more than once (block start, and again on a relaunch that resumes a block).</summary>
    public void Start()
    {
        _watch ??= _w.Watch(OnForeground);
        foreach (var (h, p) in _w.TopLevel())
            if (_listed(p)) Hide(h, p);
    }

    public void Stop()
    {
        _watch?.Dispose();
        _watch = null;
    }

    void OnForeground(IntPtr hwnd)
    {
        if (_watch == null || hwnd == IntPtr.Zero) return;               // after Stop(), late events are ignored
        if (_w.ProcessOf(hwnd) is not { } p || !_listed(p) || _w.IsMinimised(hwnd)) return;
        Hide(hwnd, p);
        OnReHide?.Invoke(CodingApps.DisplayName(p));
    }

    void Hide(IntPtr hwnd, string process)
    {
        if (_w.Minimise(hwnd)) Minimised++;
        else CoreLog.Error($"window refused minimise: {process} (an elevated window is left alone)");
    }

    // MARK: the real desktop

    sealed class DesktopWindows : IWindowSystem
    {
        const int SW_MINIMIZE = 6;
        delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc fn, IntPtr l);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
        [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
        [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint flags);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextLength(IntPtr h);

        static readonly int Self = Environment.ProcessId;

        public IEnumerable<(IntPtr, string)> TopLevel()
        {
            var list = new List<(IntPtr, string)>();
            EnumWindows((h, _) =>
            {
                if (IsWindowVisible(h) && GetWindow(h, 4 /* GW_OWNER */) == IntPtr.Zero && GetWindowTextLength(h) > 0 && ProcessOf(h) is { } p)
                    list.Add((h, p));
                return true;
            }, IntPtr.Zero);
            return list;
        }

        public string? ProcessOf(IntPtr hwnd)
        {
            GetWindowThreadProcessId(hwnd, out uint pid);
            if (pid == 0 || pid == Self) return null;
            try { return Process.GetProcessById((int)pid).ProcessName; } catch (ArgumentException) { return null; }
        }

        public bool IsMinimised(IntPtr hwnd) => IsIconic(hwnd);

        public bool Minimise(IntPtr hwnd)
        {
            ShowWindow(hwnd, SW_MINIMIZE);
            return IsIconic(hwnd);
        }

        public IDisposable Watch(Action<IntPtr> foreground) =>
            new ForegroundWatch(_ => false, () => foreground(GetAncestor(Native.Win32.GetForegroundWindow(), 3)));
    }
}
