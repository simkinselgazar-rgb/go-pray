using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Windows;
using System.Windows.Threading;

namespace GoPraySpike;

// Q6: minimise listed coding apps by exe name, re-minimise when one comes forward.
// SAFETY: only windows whose TITLE contains the marker the orchestrator gave its own test windows are
// ever minimised. Every other window is only listed by exe name (never titles) and left alone.
static class HiderMode
{
    static readonly string[] Coding = { "claude", "Code", "Cursor", "Windsurf", "zed", "WindowsTerminal", "OpenConsole", "conhost",
        "powershell", "pwsh", "cmd", "wezterm-gui", "alacritty", "Warp", "ChatGPT", "chrome", "msedge", "firefox", "brave", "Arc", "Codex" };
    static string _marker = "";
    static HashSet<uint> _pids = new();
    static bool Mine(IntPtr h) => N.Title(h).Contains(_marker) || _pids.Contains(N.Pid(h));
    static readonly Dictionary<IntPtr, double> Pending = new();

    static bool Listed(string proc) => Coding.Any(c => string.Equals(c, proc, StringComparison.OrdinalIgnoreCase));

    static List<IntPtr> TopLevel()
    {
        var l = new List<IntPtr>();
        N.EnumWindows((h, _) => { if (N.IsWindowVisible(h) && N.GetWindow(h, 4) == IntPtr.Zero) l.Add(h); return true; }, IntPtr.Zero);
        return l;
    }

    public static void Run(string[] a)
    {
        Log.Open("q6-hider");
        _marker = Program.StrArg(a, "--marker", "GOPRAY-SPIKE-HIDE");
        int secs = Program.IntArg(a, "--seconds", 25);
        new Thread(() => { Thread.Sleep((secs + 3) * 1000); Environment.Exit(0); }) { IsBackground = true }.Start();

        var all = TopLevel();
        var names = all.Select(h => N.ProcName(N.Pid(h))).GroupBy(x => x).Select(g => $"{g.Key}x{g.Count()}{(Listed(g.Key) ? "*" : "")}");
        Log.W("visible top-level windows by exe (* = on the coding list): " + string.Join(", ", names));
        var pids = Program.StrArg(a, "--pids", "").Split(',', StringSplitOptions.RemoveEmptyEntries).Select(uint.Parse).ToHashSet();
        _pids = pids;
        var mine = all.Where(Mine).ToList();
        foreach (var h in mine) Log.W($"test window {N.Describe(h)} pid={N.Pid(h)} title='{(N.Title(h).Contains(_marker) ? N.Title(h) : "(by pid; title not logged)")}' listed={Listed(N.ProcName(N.Pid(h)))}");

        foreach (var h in mine.Where(h => Listed(N.ProcName(N.Pid(h)))))
        {
            bool r = N.ShowWindow(h, N.SW_MINIMIZE);
            Thread.Sleep(300);
            Log.W($"minimise {N.Describe(h)} ShowWindow={r} err={System.Runtime.InteropServices.Marshal.GetLastWin32Error()} iconic={N.IsIconic(h)}");
        }

        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        var myPids = mine.Select(N.Pid).ToHashSet();
        bool usePoll = a.Contains("--poll");
        void Handle(IntPtr hwnd, string via)
        {
            var root = N.GetAncestor(hwnd, 3);   // GA_ROOTOWNER
            if (root == IntPtr.Zero) root = hwnd;
            if (!myPids.Contains(N.Pid(root)) || !Listed(N.ProcName(N.Pid(root)))) return;
            if (N.IsIconic(root)) return;
            var t0 = Pending.TryGetValue(root, out var x) ? x : Log.T;
            bool r = N.ShowWindow(root, N.SW_MINIMIZE);
            Log.W($"[{via}] fg -> listed {N.Describe(root)} (event hwnd {N.Describe(hwnd)} same={hwnd == root}): re-minimise ShowWindow={r} {Log.T - t0:0} ms after restore");
        }
        N.WinEventProc proc = (hook, ev, hwnd, o, c, t, time) =>
        {
            Log.W($"   event fg hwnd={N.Describe(hwnd)} pid={N.Pid(hwnd)} root={N.Describe(N.GetAncestor(hwnd, 3))}");
            Handle(hwnd, "event");
        };
        var fgHook = N.SetWinEventHook(N.EVENT_SYSTEM_FOREGROUND, N.EVENT_SYSTEM_FOREGROUND, IntPtr.Zero, proc, 0, 0, N.WINEVENT_OUTOFCONTEXT);
        if (usePoll)
        {
            var poll = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
            poll.Tick += (_, _) => Handle(N.GetForegroundWindow(), "poll");
            poll.Start();
        }
        // Bring each test window forward, as a user clicking its taskbar button would.
        int i = 0;
        var t = new DispatcherTimer { Interval = TimeSpan.FromSeconds(3) };
        t.Tick += (_, _) =>
        {
            if (i >= mine.Count) { i++; if (i > mine.Count + 1) { t.Stop(); Finish(mine, fgHook, app); } return; }
            var h = mine[i++];
            Pending[h] = Log.T;
            N.ShowWindow(h, N.SW_RESTORE);
            bool f = N.SetForegroundWindow(h);
            Log.W($"restore+foreground {N.Describe(h)} SetForegroundWindow={f}");
            var chk = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(1000) };
            chk.Tick += (_, _) => { chk.Stop(); Log.W($"   1 s later iconic={N.IsIconic(h)} fg={N.Describe(N.GetForegroundWindow())}"); };
            chk.Start();
        };
        t.Start();
        app.Run();
    }

    static void Finish(List<IntPtr> mine, IntPtr hook, Application app)
    {
        N.UnhookWinEvent(hook);
        foreach (var h in mine) Log.W($"final {N.Describe(h)} iconic={N.IsIconic(h)}");
        Log.W("hider done");
        app.Shutdown();
    }
}

