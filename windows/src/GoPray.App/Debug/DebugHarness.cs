// DebugHarness.cs — DEBUG builds only (whole file). The live Phase 2 checks on a real screen:
// a real BlockGate + StateStore (temp folder) + the real ShieldController, started with the gate's
// DebugTriggerAthan, then scripted: an early "I prayed" (must be refused), an optional renderer crash
// (fallback must appear), "I prayed" after the lock (must end the block and remove the keyboard hook).
//
// SAFETY on Ahmed's PC: --cap (max 15 s) tears the shield down and exits, a watchdog thread exits the
// process 3 s later regardless, and the hook dies with the process. guard.ps1 keeps all of this out of
// Release (rule 10 + the -Release binary scan).
//
//   GoPray.exe --debug-shield [--prayer dhuhr] [--mode wholeScreen|codingApps] [--lock 8] [--cap 15]
//              [--click-early-at 3] [--crash-at 4] [--click-at 10] [--log <file>]

#if DEBUG
using System;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows;
using System.Windows.Threading;
using GoPray.App.Shield;
using GoPray.Core;

namespace GoPray.App.Debug;

internal static class DebugHarness
{
    public static bool Wants(string[] a) => Array.IndexOf(a, "--debug-shield") >= 0;

    static string Fg()
    {
        var h = Native.Win32.GetForegroundWindow();
        GetWindowThreadProcessId(h, out uint pid);
        try { return System.Diagnostics.Process.GetProcessById((int)pid).ProcessName + (pid == Environment.ProcessId ? " (us)" : ""); } catch (ArgumentException) { return "?"; }
    }
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string? title);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern IntPtr WindowFromPoint(Native.Win32.POINT p);

    /// <summary>Who owns the top-level window at a screen point: "GoPray (us)" when the shield covers it.</summary>
    static string Top(int x, int y)
    {
        var h = Native.Win32.GetAncestor(WindowFromPoint(new Native.Win32.POINT { X = x, Y = y }), 2);
        GetWindowThreadProcessId(h, out uint pid);
        try { return System.Diagnostics.Process.GetProcessById((int)pid).ProcessName + (pid == Environment.ProcessId ? " (us)" : ""); } catch (ArgumentException) { return "?"; }
    }

    static string Arg(string[] a, string k, string d) { int i = Array.IndexOf(a, k); return i >= 0 && i + 1 < a.Length ? a[i + 1] : d; }
    static double Num(string[] a, string k, double d) => double.TryParse(Arg(a, k, ""), NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : d;

    sealed class NoSchedule : IPrayerScheduleProviding
    {
        public DayTimes? Times(DateTime day) => null;
        public PrayerWindow? Window(DateTime t) => null;
        public (Prayer Prayer, DateTime At)? NextAthan(DateTime t) => null;
    }
    sealed class NoAudio : IAthanPlaying
    {
        public bool IsPlaying => false;
        public Action? OnFinished { get; set; }
        public void Play(Prayer prayer, Voice voice, float volume) { }
        public void Stop() { }
        public int RemainingMs() => 0;
    }
    sealed class NoHider : IAppHiding
    {
        public Action<string>? OnReHide { get; set; }
        public void Start() { }
        public void Stop() { }
    }

    public static int Run(string[] a)
    {
        double cap = Math.Clamp(Num(a, "--cap", 15), 1, 15);
        double lockS = Math.Clamp(Num(a, "--lock", 8), 1, 600);
        var prayer = Enum.TryParse<Prayer>(Arg(a, "--prayer", "dhuhr"), true, out var p) ? p : Prayer.Dhuhr;
        var mode = Arg(a, "--mode", "wholeScreen").Equals("codingApps", StringComparison.OrdinalIgnoreCase) ? BlockMode.CodingApps : BlockMode.WholeScreen;
        var logPath = Arg(a, "--log", Path.Combine(Path.GetTempPath(), "gopray-debug-shield.log"));
        var sw = System.Diagnostics.Stopwatch.StartNew();
        void Log(string m) { var line = $"[{sw.Elapsed.TotalSeconds,7:0.000}] {m}"; try { File.AppendAllText(logPath, line + Environment.NewLine); } catch (IOException) { } }

        new Thread(() => { Thread.Sleep(TimeSpan.FromSeconds(cap + 3)); Log("WATCHDOG exit"); Environment.Exit(4); }) { IsBackground = true }.Start();

        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        var stateDir = Path.Combine(Path.GetTempPath(), "gopray-debug-state-" + Guid.NewGuid().ToString("N"));
        float volume = (float)Math.Clamp(Num(a, "--volume", 0.05), 0, 0.2);          // safety: quiet
        var settings = SettingsRules.Defaults with { Mode = mode, SetupComplete = true, ReduceMotion = false, AthanVolume = volume };
        // Its own WebView2 profile in temp: a harness run never writes to %LOCALAPPDATA%\GoPray.
        var shield = new ShieldController(new ShieldOptions { Web = new SceneWebView.Options { UserDataFolder = Path.Combine(Path.GetTempPath(), "gopray-debug-webview2") } }) { Log = m => Log("shield: " + m) };
        IAthanPlaying audio = Array.IndexOf(a, "--real-audio") >= 0 ? new Audio.AthanPlayer() : new NoAudio();
        var hideOnly = Arg(a, "--hide-only", "");
        IAppHiding hider = hideOnly.Length > 0
            ? new Blocker.AppHider(isListed: p => hideOnly.Split(",").Any(x => string.Equals(x, p, StringComparison.OrdinalIgnoreCase)))
            : new NoHider();
        var gate = new BlockGate(new SystemClock(), new StateStore(stateDir), new NoSchedule(), shield, audio, hider, () => settings);
        hider.OnReHide += n => Log($"hider: re-minimised {n}");
        CoreLog.Sink = m => Log("core: " + m);
        Log($"start prayer={prayer} mode={mode} lock={lockS}s cap={cap}s monitors={Displays.Live().Count} hookBefore={KeyboardGuard.IsInstalled}");

        void At(double s, Action act)
        {
            if (s <= 0) return;
            var t = new DispatcherTimer { Interval = TimeSpan.FromSeconds(s) };
            t.Tick += (_, _) => { t.Stop(); act(); };
            t.Start();
        }
        async void Click(string label)
        {
            var main = shield.Slots.FirstOrDefault(x => x.IsMain);
            if (main?.Web is { } web)
            {
                var r = await web.Js("(function(){var b=document.querySelector('.prayed'); if(!b) return 'no button'; b.disabled=false; b.click(); return 'clicked';})()");
                Log($"{label}: page click {r}");
            }
            else if (main?.Fallback is { } fb) { fb.OnPrayed(); Log($"{label}: fallback click"); }
            else Log($"{label}: nothing to click");
        }

        app.Startup += (_, _) =>
        {
            gate.DebugTriggerAthan(prayer, lockS);
            Log($"triggered: phase={gate.Phase.Kind} slots={shield.Slots.Count} layouts={string.Join(",", shield.Slots.Select(x => x.Layout))} hook={KeyboardGuard.IsInstalled}");
            var poll = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(100) };
            string last = "";
            poll.Tick += (_, _) =>
            {
                var s = $"phase={gate.Phase.Kind} presenting={shield.IsPresenting} ready={string.Join(",", shield.Slots.Select(x => x.Ready))} fallback={string.Join(",", shield.Slots.Select(x => x.Fallback != null))} hook={KeyboardGuard.IsInstalled} reasserts={shield.Reasserts}/{shield.ReassertsRefused}";
                if (s != last) { Log(s); last = s; }
                if (gate.Phase == Phase.Idle && !shield.IsPresenting)
                {
                    poll.Stop();
                    Log($"IDLE: block ended; hook={KeyboardGuard.IsInstalled} keyEventsSeen={KeyboardGuard.EventsSeen} lastConfirmed={gate.State.LastConfirmed?.Prayer}");
                    double linger = Math.Clamp(Num(a, "--linger", 0.5), 0.1, 5);
                    At(linger, () => { Log($"exit 0 after linger {linger}s; hook={KeyboardGuard.IsInstalled} keyEventsSeen={KeyboardGuard.EventsSeen} (unchanged = no hook after the block)"); app.Shutdown(0); });
                }
            };
            poll.Start();
            At(1.0, () => Log($"foreground after 1 s: {Fg()}"));
            At(2.0, () =>
            {
                // Multi-monitor check: each window against its monitor, and what is on top at each monitor's centre
                // and at every taskbar (primary Shell_TrayWnd + Shell_SecondaryTrayWnd on the others).
                foreach (var s in shield.Slots)
                {
                    Native.Win32.GetWindowRect(s.Window.Handle, out var r);
                    var d = s.Display;
                    Log($"slot {s.Layout} monitor={d.Id} want=({d.X},{d.Y},{d.Width}x{d.Height}) got=({r.Left},{r.Top},{r.Right - r.Left}x{r.Bottom - r.Top}) exact={(r.Left == d.X && r.Top == d.Y && r.Right - r.Left == d.Width && r.Bottom - r.Top == d.Height)} ready={s.Ready}");
                    Log($"   top window at centre of {d.Id}: {Top(d.X + d.Width / 2, d.Y + d.Height / 2)}");
                }
                foreach (var cls in new[] { "Shell_TrayWnd", "Shell_SecondaryTrayWnd" })
                {
                    IntPtr bar = IntPtr.Zero;
                    while ((bar = FindWindowEx(IntPtr.Zero, bar, cls, null)) != IntPtr.Zero)
                    {
                        Native.Win32.GetWindowRect(bar, out var b);
                        Log($"   taskbar {cls} at ({b.Left},{b.Top},{b.Right - b.Left}x{b.Bottom - b.Top}): top window there = {Top((b.Left + b.Right) / 2, (b.Top + b.Bottom) / 2)}");
                    }
                }
            });
            At(Num(a, "--click-early-at", 0), () => Click("early"));
            double crash = Num(a, "--crash-at", 0);
            if (crash > 0) At(crash, async () =>
            {
                var main = shield.Slots.FirstOrDefault(x => x.IsMain);
                Log("crash: renderer (CDP Page.crash)");
                var t0 = sw.Elapsed;
                if (main?.Web is { } web) await web.DebugCrashRenderer();
                var w = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(20) };
                w.Tick += (_, _) => { if (main?.Fallback != null) { w.Stop(); Log($"FALLBACK shown {(sw.Elapsed - t0).TotalMilliseconds:0} ms after the crash; reasons={string.Join(";", shield.FallbackReasons)} fallbackTime={main.FallbackView?.TimeText}"); } };
                w.Start();
            });
            At(Num(a, "--silence-at", 0), () => { gate.RequestSilence(); Log($"silence: audio playing={audio.IsPlaying} phase={gate.Phase.Kind} (the block goes on)"); });
            At(1.5, () => Log($"audio after 1.5 s: playing={audio.IsPlaying} remainingMs={audio.RemainingMs()}" + (audio is Audio.AthanPlayer ap ? $" position={ap.Position:0.00}s" : "")));
            At(Num(a, "--click-at", 0), () => Click("after lock"));
            At(cap, () =>
            {
                if (shield.IsPresenting) { Log("CAP reached: debug safety tear-down"); shield.TearDown(); }
                Log($"exit at cap; hook={KeyboardGuard.IsInstalled}");
                app.Shutdown(3);
            });
        };
        int code = app.Run();
        KeyboardGuard.Uninstall();
        try { Directory.Delete(stateDir, true); } catch (IOException) { }
        return code;
    }
}
#endif
