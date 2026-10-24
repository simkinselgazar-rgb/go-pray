// AppHost.cs — entry and wiring. Port of GoPrayApp.swift (AppEnvironment + AppDelegate) and App/Windows.swift.
// Order (CONTRACT-NOTES #5, #14): settings store → gate reads the store → store.Attach(gate) (the store refuses
// everything until then) → store changes go to scheduler.Handle(SettingsChanged).
//
// Launch: LaunchDecision.Decide is the one place that decides (PM ruling 2026-10-23). A copy opened by hand
// while another runs broadcasts "GoPray.Show" (the holder opens Setup or Settings, never during a block) and
// exits 0. A `--tick` from the Task Scheduler task exits at once unless a block is open or the person did not
// quit on purpose in this logon session.

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;
using GoPray.App.Audio;
using GoPray.App.Blocker;
using GoPray.App.Launch;
using GoPray.App.Places;
using GoPray.App.Shield;
using GoPray.App.Tray;
using GoPray.App.UI;
using GoPray.App.Update;
using GoPray.Core;
using Microsoft.Win32;

namespace GoPray.App;

internal sealed class AppHost
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint RegisterWindowMessage(string name);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr w, IntPtr l);
    static readonly IntPtr HWND_BROADCAST = new(0xffff);
    static readonly uint ShowMessage = RegisterWindowMessage(LaunchDecision.ShowMessageName);
    static readonly uint QuitMessage = RegisterWindowMessage(LaunchDecision.QuitMessageName);

    // MARK: entry

    public static int Run(string[] args)
    {
        var dir = StateStore.DefaultDirectory();
        StartLog(dir);
        if (args.Contains("--uninstall-task"))
        {
            // The uninstaller: remove the task, ask a running copy to quit (it does only between prayers), and wait up
            // to 10 s for it to go so its files can be removed.
            try { new LogonTask().Unregister(); } catch (Exception e) { CoreLog.Error("uninstall-task: " + e.Message); }
            PostMessage(HWND_BROADCAST, QuitMessage, IntPtr.Zero, IntPtr.Zero);
            for (int i = 0; i < 40; i++)
            {
                using (var probe = new InstanceMutex()) { if (probe.Owned != false) break; }
                System.Threading.Thread.Sleep(250);
            }
            return 0;
        }
        using var mutex = new InstanceMutex();
        var launch = new LaunchStateStore(dir);
        var facts = new LaunchFacts(LaunchDecision.KindOf(args), mutex.Owned, new StateStore(dir).PeekHasOpenBlock(),
                                    launch.ReadUserQuitLogonId(), LogonSession.CurrentId());
        var plan = LaunchDecision.Decide(facts);
        if (plan != LaunchPlan.ExitQuietly || facts.Kind == LaunchKind.ByHand)
            CoreLog.Notice($"launch {facts.Kind} mutex={facts.GotMutex} openBlock={facts.OpenBlockInState} → {plan}");
        switch (plan)
        {
            case LaunchPlan.ExitQuietly: return 0;
            case LaunchPlan.AskHolderToShowAndExit: PostMessage(HWND_BROADCAST, ShowMessage, IntPtr.Zero, IntPtr.Zero); return 0;
        }
        if (LaunchDecision.ShouldClearUserQuit(facts)) launch.ClearUserQuit();
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        AppHost? host = null;
        app.Startup += (_, _) => { host = new AppHost(app, dir, launch, facts.CurrentLogonId, args); host.Start(); };
        return app.Run();
    }

    static void StartLog(string dir)
    {
        var path = Path.Combine(dir, "log.txt");
        CoreLog.Sink = m =>
        {
            try
            {
                Directory.CreateDirectory(dir);
                if (File.Exists(path) && new FileInfo(path).Length > 1_000_000) File.Move(path, path + ".1", overwrite: true);
                File.AppendAllText(path, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {m}{Environment.NewLine}");
            }
            catch (IOException) { /* logging never stops the app */ }
        };
    }

    // MARK: the environment

    readonly Application _app;
    readonly LaunchStateStore _launch;
    readonly string? _logonId;
    readonly string[] _args;
    readonly Dispatcher _ui = Dispatcher.CurrentDispatcher;
    public IClock Clock { get; } = new SystemClock();
    public SettingsStore SettingsStore { get; }
    public IPrayerScheduleProviding Schedule { get; }
    public ShieldController Shield { get; }
    public AthanPlayer Audio { get; }
    public AppHider Hider { get; }
    public LogonTask Logon { get; } = new();
    public ICityGeocoding Geocoder { get; } = new Geocoder();
    public BlockGate Gate { get; }
    public Scheduler Scheduler { get; }
    public EmergencyLedger Ledger { get; }
    public UpdateChecker Updates { get; }
    DispatcherTimer? _updateTimer;
    TrayIcon? _tray;
    PopoverWindow? _popover;
    SetupWindow? _setup;
    SettingsWindow? _settings;
    CreditsWindow? _credits;
    HwndSource? _messages;

    AppHost(Application app, string dir, LaunchStateStore launch, string? logonId, string[] args)
    {
        _app = app; _launch = launch; _logonId = logonId; _args = args;
        SettingsStore = new SettingsStore(dir);
        var store = SettingsStore;
        Schedule = new PrayerSchedule(() => store.Settings);
        Shield = new ShieldController { Log = CoreLog.Notice };
        Audio = new AthanPlayer();
        Hider = new AppHider(displayName: p => NameOf(store.Settings, p));
        Ledger = new EmergencyLedger(dir);
        Gate = new BlockGate(Clock, new StateStore(dir), Schedule, Shield, Audio, Hider, () => store.Settings,
                             ledger: Ledger, defaultApps: DefaultApps());
        store.Attach(Gate);                                  // fail closed until this line
        var scheduler = Scheduler = new Scheduler(Clock, Schedule, Gate, () => store.Settings);
        store.OnChange = _ => scheduler.Handle(ReevalReason.SettingsChanged);
        var gate = Gate;
        Updates = new UpdateChecker(typeof(AppHost).Assembly.GetName().Version ?? new Version(0, 0, 0), dir,
                                    () => gate.IsBlocked, () => store.Settings.CheckForUpdates, Clock, RunInstallerAndQuit);
    }

    /// <summary>The compiled-in defaults the gate turns into the captured list (v2: minus the ones turned off, plus custom).</summary>
    static IEnumerable<string> DefaultApps()
    {
#if DEBUG
        // DEBUG only: a test run can minimise only an app it started itself (the Mac's GoPrayDebugHideOnly).
        var only = Environment.GetEnvironmentVariable("GOPRAY_DEBUG_HIDE_ONLY");
        if (!string.IsNullOrWhiteSpace(only))
        {
            var set = only.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            CoreLog.Notice("DEBUG hide list override: " + string.Join(",", set));
            return set;
        }
#endif
        return CodingApps.Names.Keys;
    }

    /// <summary>The notice's app name: the person's own label for a custom app, else the defaults table.</summary>
    static string NameOf(Settings s, string process)
    {
        var n = BlockedApps.Normalize(process);
        return s.CustomApps.FirstOrDefault(c => c.Platform == BlockedApps.Current && c.Id == n)?.Name ?? CodingApps.DisplayName(process);
    }

    /// <summary>A verified installer: run it and quit, only between prayers (the checker never gets here during a block).</summary>
    void RunInstallerAndQuit(string setup)
    {
        if (!Gate.ShouldAllowQuit()) return;
        try { UpdateChecker.RunInstaller(setup); }
        catch (Exception e) { CoreLog.Error("installer did not start: " + e.Message); return; }
        CoreLog.Notice("quit: running the update installer");
        Shutdown();
    }

    void StartUpdateChecks()
    {
        Updates.ClearDownloads();
        // 30 s after launch, then hourly ticks; the checker itself only goes out when the last check is 24 h old.
        _updateTimer = new DispatcherTimer { Interval = UpdateChecker.FirstDelay };
        _updateTimer.Tick += async (_, _) => { _updateTimer.Interval = TimeSpan.FromHours(1); await Updates.AutomaticCheck(); };
        _updateTimer.Start();
    }

    void Start()
    {
        Gate.Reevaluate(ReevalReason.Launch);                // resume / wake rule / fail-open checks
        Scheduler.Start();
        SystemEvents.PowerModeChanged += (_, e) =>
        {
            if (e.Mode != PowerModes.Resume) return;
            _ui.BeginInvoke(() => { Scheduler.Handle(ReevalReason.Wake); _ = Updates.AutomaticCheck(); });
        };
        SystemEvents.SessionSwitch += (_, e) => { if (e.Reason == SessionSwitchReason.SessionUnlock) _ui.BeginInvoke(() => Scheduler.Handle(ReevalReason.Wake)); };
        SystemEvents.TimeChanged += (_, _) => _ui.BeginInvoke(() => { TimeZoneInfo.ClearCachedData(); Scheduler.Handle(ReevalReason.ClockChanged); });

        var model = new MenuModel(SettingsStore, Gate, Schedule, Clock);
        _popover = new PopoverWindow(model, ShowSettings, ShowSetup, Quit, Updates);
#if DEBUG
        if (Debug.DebugScreens.Wants(_args)) { Debug.DebugScreens.Run(this, _args, () => _app.Shutdown(0)); return; }
        _popover.DebugPanel = Debug.DebugMenu.Build(this);
        Debug.DebugMenu.SeedIfAsked(this, _args);
#endif
        _tray = new TrayIcon(() => _popover.ShowNearTray(), ShowSettings, ShowCredits, Quit, () => Gate.IsBlocked,
                             () => { _ = Updates.CheckNow(); _popover.ShowNearTray(); });
        ListenForShow();
        StartUpdateChecks();
        RepairLogonTask();
        if (!SettingsStore.Settings.SetupComplete) ShowSetup();
    }

    /// <summary>After a move or a manual delete the task can be gone; put it back if the person chose it (only after setup).</summary>
    void RepairLogonTask()
    {
        var s = SettingsStore.Settings;
        if (!s.SetupComplete || !s.LaunchAtLogin) return;
        try { if (!Logon.IsRegistered) { Logon.Register(); CoreLog.Notice("logon task re-registered at launch"); } }
        catch (Exception e) { CoreLog.Error("logon task repair failed: " + e.Message); }
    }

    void ListenForShow()
    {
        // A hidden top-level window: HWND_BROADCAST reaches top-level windows only (not message-only ones).
        _messages = new HwndSource(new HwndSourceParameters("GoPray.Messages") { WindowStyle = 0, Width = 0, Height = 0 });
        _messages.AddHook((IntPtr h, int msg, IntPtr w, IntPtr l, ref bool handled) =>
        {
            if ((uint)msg == ShowMessage) { ShowRequested(); handled = true; }
            else if ((uint)msg == QuitMessage)
            {
                handled = true;
                if (Gate.ShouldAllowQuit()) { CoreLog.Notice("quit: asked by the uninstaller"); Shutdown(); }
                else CoreLog.Notice("uninstaller asked to quit during a block: staying until the block ends");
            }
            return IntPtr.Zero;
        });
    }

    /// <summary>Someone opened Go Pray by hand while this copy runs. Never during a block: a window would take
    /// focus under the shield.</summary>
    void ShowRequested()
    {
        if (Gate.IsBlocked) return;
        if (SettingsStore.Settings.SetupComplete) ShowSettings(); else ShowSetup();
    }

    // MARK: windows (one of each, reused)

    void ShowSetup()
    {
        if (Gate.IsBlocked) return;
        if (_setup == null || !_setup.IsLoaded)
        {
            var m = new SetupModel(SettingsStore, Schedule, Clock, Audio, Logon, Geocoder, Gate);
            _setup = new SetupWindow(m);
            _setup.Closed += (_, _) => _setup = null;
        }
        Present(_setup);
    }

    void ShowSettings()
    {
        if (!SettingsStore.Settings.SetupComplete) { ShowSetup(); return; }
        if (_settings == null)
        {
            _settings = new SettingsWindow(new SettingsModel(SettingsStore, Gate, Clock, Audio, Logon, Geocoder, defaultApps: CodingApps.Defaults), ShowCredits);
            _settings.Closing += (_, e) => { e.Cancel = true; _settings.Hide(); };    // reused, never destroyed
        }
        Present(_settings);
    }

    void ShowCredits()
    {
        if (_credits == null || !_credits.IsLoaded) { _credits = new CreditsWindow(); _credits.Closed += (_, _) => _credits = null; }
        Present(_credits);
    }

    /// <summary>DEBUG screenshot runs only: windows open far off-screen and never take focus.</summary>
    internal bool OffScreen { get; set; }

    void Present(Window w)
    {
        if (OffScreen) { w.WindowStartupLocation = WindowStartupLocation.Manual; w.Left = -32000; w.Top = -32000; w.ShowActivated = false; w.Show(); return; }
        w.Show();
        if (w.WindowState == WindowState.Minimized) w.WindowState = WindowState.Normal;
        w.Activate();
    }

    void Quit()
    {
        if (!Gate.ShouldAllowQuit()) return;                 // the gate refuses it during a block
        try { if (_logonId != null) _launch.RecordUserQuit(_logonId, Gate); }
        catch (Exception e) { CoreLog.Error("quit flag not written: " + e.Message); }
        CoreLog.Notice("quit by the person");
        Shutdown();
    }

    void Shutdown()
    {
        _updateTimer?.Stop();
        Scheduler.Stop();
        Audio.Stop();
        _tray?.Dispose();
        _messages?.Dispose();
        KeyboardGuard.Uninstall();
        _app.Shutdown(0);
    }

    internal void ShowSetupForDebug() => ShowSetup();
    internal void ShowSettingsForDebug() => ShowSettings();
    internal void ShowCreditsForDebug() => ShowCredits();
    internal PopoverWindow? Popover => _popover;
    internal SetupWindow? Setup => _setup;
    internal SettingsWindow? SettingsView => _settings;
    internal CreditsWindow? CreditsView => _credits;
}
