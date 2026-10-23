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
        var settings = SettingsRules.Defaults with { Mode = mode, SetupComplete = true, ReduceMotion = false };
        var shield = new ShieldController { Log = m => Log("shield: " + m) };
        var gate = new BlockGate(new SystemClock(), new StateStore(stateDir), new NoSchedule(), shield, new NoAudio(), new NoHider(), () => settings);
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
