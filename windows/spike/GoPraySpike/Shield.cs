using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using WinForms = System.Windows.Forms;

namespace GoPraySpike;

// Q1: one topmost borderless window per monitor + foreground re-assert + optional WH_KEYBOARD_LL.
// SAFETY: closes itself after --seconds (max 15) by a DispatcherTimer; a background watchdog thread
// calls Environment.Exit 2 s later even if the UI thread is stuck; Ctrl+Alt+Shift+F12 exits at once
// (through the hook, or RegisterHotKey-free: the hook sees it first). The hook dies with the process.
static class ShieldMode
{
    static IntPtr _kbHook, _fgHook;
    static N.LowLevelProc? _kbProc;
    static N.WinEventProc? _fgProc;
    static bool _win, _ctrl, _shift;
    static readonly HashSet<IntPtr> Ours = new();
    static IntPtr _main;
    static bool _allowClose, _reassert, _strong;
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    static double _lostAt = -1;
    static int _sfwCalls, _sfwRefused, _fgLost;
    static readonly Dictionary<string, int> Swallowed = new();
    static readonly List<double> Latencies = new();

    public static void Run(string[] a)
    {
        int secs = Math.Clamp(Program.IntArg(a, "--seconds", 15), 1, 15);
        bool hook = !a.Contains("--nohook");
        _reassert = !a.Contains("--noreassert");
        _strong = a.Contains("--strong");
        Log.Open(Program.StrArg(a, "--log", "q1-shield"));
        Log.W($"seconds={secs} hook={hook} reassert={_reassert} strong={_strong}");
        new Thread(() => { Thread.Sleep((secs + 2) * 1000); Log.W("WATCHDOG exit"); Environment.Exit(0); }) { IsBackground = true }.Start();

        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        var screens = WinForms.Screen.AllScreens;
        Log.W($"monitors={screens.Length}");
        var windows = new List<Window>();
        foreach (var s in screens)
        {
            var b = s.Bounds;
            var w = new Window
            {
                WindowStyle = WindowStyle.None, ResizeMode = ResizeMode.NoResize, Topmost = true,
                ShowInTaskbar = false, Background = new SolidColorBrush(Color.FromRgb(0x2E, 0x4A, 0x3F)),
                Left = b.X, Top = b.Y, Width = 400, Height = 300, Title = "GOPRAY-SPIKE-SHIELD",
                Content = new System.Windows.Controls.TextBlock
                {
                    Text = $"GO PRAY SPIKE SHIELD\ncloses by itself in {secs} s\nCtrl+Alt+Shift+F12 = exit now",
                    Foreground = Brushes.White, FontSize = 32, TextAlignment = TextAlignment.Center,
                    HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
                },
            };
            w.SourceInitialized += (_, _) =>
            {
                var h = new WindowInteropHelper(w).Handle;
                Ours.Add(h);
                if (s.Primary) _main = h;
                bool ok = N.SetWindowPos(h, N.HWND_TOPMOST, b.X, b.Y, b.Width, b.Height, N.SWP_SHOWWINDOW);
                N.GetWindowRect(h, out var r);
                Log.W($"shield {s.DeviceName} want={b} setpos={ok} got=({r.L},{r.T},{r.R},{r.B}) primary={s.Primary}");
            };
            w.Closing += (_, e) => { if (!_allowClose) { e.Cancel = true; Log.W("Closing CANCELLED (Alt+F4/WM_CLOSE)"); } };
            windows.Add(w);
            w.Show();
        }
        windows[0].Activate();
        Log.W($"after show fg={N.Describe(N.GetForegroundWindow())} ours={Ours.Contains(N.GetForegroundWindow())}");

        if (hook)
        {
            _kbProc = KbProc;
            _kbHook = N.SetWindowsHookEx(N.WH_KEYBOARD_LL, _kbProc, N.GetModuleHandle(null), 0);
            Log.W($"LL hook installed={_kbHook != IntPtr.Zero} err={Marshal.GetLastWin32Error()}");
        }
        _fgProc = FgProc;
        _fgHook = N.SetWinEventHook(N.EVENT_SYSTEM_FOREGROUND, N.EVENT_SYSTEM_FOREGROUND, IntPtr.Zero, _fgProc, 0, 0, N.WINEVENT_OUTOFCONTEXT);
        Log.W($"winevent hook installed={_fgHook != IntPtr.Zero}");

        // Taskbar probe: what is the top window at the taskbar's centre? (ours = covered)
        var tray = N.FindWindow("Shell_TrayWnd", null);
        N.GetWindowRect(tray, out var tr);
        var probe = new N.POINT { X = (tr.L + tr.R) / 2, Y = (tr.T + tr.B) / 2 };
        Log.W($"taskbar rect=({tr.L},{tr.T},{tr.R},{tr.B}) probe=({probe.X},{probe.Y}) trayVisible={N.IsWindowVisible(tray)}");
        double peekStart = -1; string lastFg = "";
        double totalPeek = 0; int peeks = 0;
        var poll = new DispatcherTimer(DispatcherPriority.Send) { Interval = TimeSpan.FromMilliseconds(20) };
        poll.Tick += (_, _) =>
        {
            var root = N.GetAncestor(N.WindowFromPoint(probe), 2);
            bool covered = Ours.Contains(root);
            if (!covered && peekStart < 0) { peekStart = Log.T; Log.W($"TASKBAR POINT UNCOVERED by {N.Describe(root)}"); }
            if (covered && peekStart >= 0) { var d = Log.T - peekStart; totalPeek += d; peeks++; Log.W($"taskbar point covered again after {d:0} ms"); peekStart = -1; }
            var fg = N.GetForegroundWindow();
            var desc = Ours.Contains(fg) ? "OURS" : N.Describe(fg);
            if (desc != lastFg) { Log.W($"poll fg -> {desc}"); lastFg = desc; }
        };
        poll.Start();

        var end = new DispatcherTimer { Interval = TimeSpan.FromSeconds(secs) };
        end.Tick += (_, _) =>
        {
            end.Stop(); poll.Stop();
            if (_kbHook != IntPtr.Zero) Log.W($"unhook kb={N.UnhookWindowsHookEx(_kbHook)}");
            N.UnhookWinEvent(_fgHook);
            Log.W($"SUMMARY fgLost={_fgLost} sfwCalls={_sfwCalls} sfwRefused={_sfwRefused} " +
                  $"reassertLatencyMs=[{string.Join(",", Latencies.Select(x => x.ToString("0")))}] " +
                  $"taskbarPeeks={peeks} taskbarPeekTotalMs={totalPeek:0} stillUncovered={(peekStart >= 0)} " +
                  $"swallowed={{{string.Join(", ", Swallowed.Select(kv => kv.Key + ":" + kv.Value))}}}");
            _allowClose = true;
            foreach (var w in windows) w.Close();
            app.Shutdown();
        };
        end.Start();
        app.Run();
    }

    static IntPtr KbProc(int n, IntPtr wp, IntPtr lp)
    {
        if (n >= 0)
        {
            var k = Marshal.PtrToStructure<N.KBDLLHOOKSTRUCT>(lp);
            bool up = (k.flags & N.LLKHF_UP) != 0, alt = (k.flags & N.LLKHF_ALTDOWN) != 0;
            uint vk = k.vkCode;
            if (vk is 0xA2 or 0xA3 or 0x11) _ctrl = !up;
            if (vk is 0xA0 or 0xA1 or 0x10) _shift = !up;
            if (vk == 0x7B && _ctrl && _shift && alt && !up) { Environment.Exit(3); }   // hard debug exit
            string? why = null;
            if (vk is 0x5B or 0x5C) { _win = !up; why = "win"; }
            else if (_win && vk != 0x4C) why = "win+combo";
            else if (vk == 0x09 && alt) why = "alt+tab";
            else if (vk == 0x1B && alt) why = "alt+esc";
            else if (vk == 0x1B && _ctrl) why = _shift ? "ctrl+shift+esc" : "ctrl+esc";
            else if (vk == 0x73 && alt) why = null;   // Alt+F4 passes: the window's Closing cancels it
            if (why != null)
            {
                lock (Swallowed) Swallowed[why] = Swallowed.GetValueOrDefault(why) + 1;
                bool inj = (k.flags & N.LLKHF_INJECTED) != 0;
                ThreadPool.QueueUserWorkItem(_ => Log.W($"hook SWALLOW {why} {(up ? "up" : "down")} injected={inj}"));
                return (IntPtr)1;
            }
        }
        return N.CallNextHookEx(_kbHook, n, wp, lp);
    }

    static void FgProc(IntPtr hook, uint ev, IntPtr hwnd, int o, int c, uint t, uint time)
    {
        if (Ours.Contains(hwnd))
        {
            if (_lostAt >= 0 && Ours.Contains(N.GetForegroundWindow())) { var d = Log.T - _lostAt; Latencies.Add(d); Log.W($"fg back to OURS after {d:0} ms"); _lostAt = -1; }
            return;
        }
        _fgLost++;
        Log.W($"fg event -> {N.Describe(hwnd)} '{(N.ProcName(N.Pid(hwnd)).StartsWith("GoPraySpike") ? N.Title(hwnd) : "")}'");
        if (_lostAt < 0) _lostAt = Log.T;
        if (!_reassert) return;
        _ = Reassert();
    }

    static async Task Reassert()
    {
        // Debounce lightly (the Mac ping-ponged without it), then retry every 100 ms until we hold foreground.
        await Task.Delay(50);
        for (int i = 0; i < 30 && !Ours.Contains(N.GetForegroundWindow()) && !_allowClose; i++)
        {
            N.SetWindowPos(_main, N.HWND_TOPMOST, 0, 0, 0, 0, N.SWP_NOMOVE | N.SWP_NOSIZE | N.SWP_SHOWWINDOW);
            bool ok = N.SetForegroundWindow(_main);
            if (!ok && _strong)
            {
                // AttachThreadInput trick: share input state with the foreground thread, then ask again.
                uint fgThread = N.GetWindowThreadProcessId(N.GetForegroundWindow(), out _), me = GetCurrentThreadId();
                bool att = AttachThreadInput(me, fgThread, true);
                BringWindowToTop(_main);
                ok = N.SetForegroundWindow(_main);
                AttachThreadInput(me, fgThread, false);
                Log.W($"   strong: attach={att} SetForegroundWindow={ok}");
            }
            _sfwCalls++;
            if (!ok) _sfwRefused++;
            Log.W($"reassert try {i} SetForegroundWindow={ok} fgNow={(Ours.Contains(N.GetForegroundWindow()) ? "OURS" : N.Describe(N.GetForegroundWindow()))}");
            await Task.Delay(100);
        }
    }
}

// A test window for the Phase 4 hider check: shows, then at --restore-at restores and activates itself (like a
// person clicking it in the taskbar) and logs whether it ends up minimised again. Exits at --seconds (max 15).
static class TestWindowMode
{
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int c);
    public static void Run(string[] a)
    {
        Log.Open("p4-test-window");
        int secs = Math.Clamp(Program.IntArg(a, "--seconds", 12), 2, 15);
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        var w = new Window { Title = "GOPRAY-SPIKE-TESTWINDOW", Width = 360, Height = 200, Left = 120, Top = 120 };
        w.Show();
        var h = new WindowInteropHelper(w).Handle;
        var poll = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(100) };
        bool last = false;
        poll.Tick += (_, _) => { bool i = IsIconic(h); if (i != last) { Log.W($"iconic -> {i}"); last = i; } };
        poll.Start();
        var restore = new DispatcherTimer { Interval = TimeSpan.FromSeconds(Program.IntArg(a, "--restore-at", 6)) };
        restore.Tick += (_, _) => { restore.Stop(); ShowWindow(h, 9); w.Activate(); N.SetForegroundWindow(h); Log.W("restored and activated myself (a person clicking me)"); };
        restore.Start();
        var end = new DispatcherTimer { Interval = TimeSpan.FromSeconds(secs) };
        end.Tick += (_, _) => { Log.W($"end iconic={IsIconic(h)}"); app.Shutdown(); };
        end.Start();
        app.Run();
    }
}

// A foreground thief: a normal window that activates itself (launched by the key tester).
static class StealMode
{
    public static void Run(string[] a)
    {
        Log.Open("q1-steal");
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        var w = new Window { Title = "GOPRAY-SPIKE-STEAL", Width = 300, Height = 200, Left = 100, Top = 100, Topmost = false };
        w.Show(); w.Activate();
        var h = new WindowInteropHelper(w).Handle;
        Log.W($"steal SetForegroundWindow={N.SetForegroundWindow(h)} fg={N.Describe(N.GetForegroundWindow())} mine={N.GetForegroundWindow() == h}");
        var t = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        t.Tick += (_, _) => { Log.W($"steal end fg={N.Describe(N.GetForegroundWindow())} mine={N.GetForegroundWindow() == h}"); app.Shutdown(); };
        t.Start();
        app.Run();
    }
}

