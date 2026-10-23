// ShieldController.cs — IShieldPresenting: one window per monitor, the web page, the native fallback,
// "May Allah accept it.", the foreground re-assert and the keyboard guard. Port of Shield/ShieldController.swift.
//
// The shield never ends a block. `prayed` from the page only becomes Delegate.ShieldDidRequestConfirm();
// the gate decides and answers with Show/Update/Dismiss. Rule 1 (never trap): every failure of the web
// side swaps in the native fallback with the same gate and the same remaining time. TearDown() works
// from any state and always removes the keyboard hook.
//
// Windows differences from the Mac (PLAN.md §3 row 1, spike Q1):
// - No window level above the shell: topmost windows + a foreground re-assert (event + 250 ms poll,
//   debounced 50 ms, retried every 100 ms) + the low-level keyboard hook while a whole-screen block is up.
// - Coding-apps mode: one 420 x 520 notice on the primary monitor that never takes focus, no hook,
//   no re-assert (the person keeps working in every other app).

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Windows;
using System.Windows.Threading;
using GoPray.App.Native;
using GoPray.Core;
using Microsoft.Win32;

namespace GoPray.App.Shield;

internal sealed record ShieldOptions
{
    /// <summary>false (tests): windows far off-screen, never topmost or activated, no re-assert, no hook.</summary>
    public bool OnScreen { get; init; } = true;
    public bool InstallKeyboardGuard { get; init; } = true;
    /// <summary>Primary first.</summary>
    public Func<IReadOnlyList<Display>> Displays { get; init; } = Shield.Displays.Live;
    public string ScenesRoot { get; init; } = SceneWebView.BundledScenesRoot;
    public SceneWebView.Options Web { get; init; } = new();
    public TimeSpan ReadyTimeout { get; init; } = TimeSpan.FromSeconds(4);
    /// <summary>If the page never says `gone`, finish anyway (the gate gives up at 4 s).</summary>
    public TimeSpan GoneTimeout { get; init; } = TimeSpan.FromSeconds(2.5);
    public TimeSpan FallbackAcceptHold { get; init; } = TimeSpan.FromSeconds(1);
    public TimeSpan ReassertDebounce { get; init; } = TimeSpan.FromMilliseconds(50);
}

internal sealed class ShieldController : IShieldPresenting
{
    internal sealed class Slot(Display display, ShieldLayout layout, ShieldWindow window)
    {
        public Display Display { get; } = display;
        public ShieldLayout Layout { get; } = layout;
        public ShieldWindow Window { get; } = window;
        public SceneWebView? Web { get; set; }
        public FallbackModel? Fallback { get; set; }
        public NativeFallbackShield? FallbackView { get; set; }
        public bool Ready { get; set; }
        public DispatcherTimer? ReadyTimer { get; set; }
        public long ShownAtMs { get; set; }
        public int ShownRemainingMs { get; set; }
        public string? ShownApp { get; set; }
        public bool AthanActive { get; set; }
        public bool NeedsReshow { get; set; }
        public bool IsMain => Layout != ShieldLayout.Art;
        public bool FellBack => Web == null;
    }

    public IShieldDelegate? Delegate { get; set; }
    public ShieldOptions Options { get; }
    public List<Slot> Slots { get; private set; } = [];
    public bool IsPresenting { get; private set; }
    public bool IsDismissing { get; private set; }
    /// <summary>Why web slots fell back (tests and logs).</summary>
    public List<string> FallbackReasons { get; } = [];
    public int Reasserts { get; private set; }
    public int ReassertsRefused { get; private set; }
    public Action<string> Log { get; set; } = _ => { };

    readonly Stopwatch _clock = Stopwatch.StartNew();
    readonly Dispatcher _ui = Dispatcher.CurrentDispatcher;
    ShieldContext? _ctx;
    long _ctxAtMs;
    int _epoch;
    Action? _dismissCompletion;
    DispatcherTimer? _dismissTimer, _rebuildTimer;
    ForegroundWatch? _watch;
    bool _reassertPending;
    bool _engagedDisplays;
    /// <summary>The window that was in front before a whole-screen shield took the foreground; it gets it back.</summary>
    IntPtr _restoreTo;

    public ShieldController(ShieldOptions? options = null) => Options = options ?? new ShieldOptions();

    long Now => _clock.ElapsedMilliseconds;

    // MARK: IShieldPresenting

    public void Show(ShieldContext ctx)
    {
        if (IsPresenting)
        {
            if (_ctx?.Prayer == ctx.Prayer && !IsDismissing) { Update(ctx); return; }
            TearDown();   // a different prayer replaces the old one; nothing stacks
        }
        IsPresenting = true;
        _ctx = ctx;
        _ctxAtMs = Now;
        if (_restoreTo == IntPtr.Zero && Options.OnScreen && ctx.Mode == BlockMode.WholeScreen) _restoreTo = Win32.GetForegroundWindow();
        Build();
        Engage();
    }

    public void Update(ShieldContext ctx)
    {
        if (!IsPresenting || IsDismissing) return;
        bool hiddenChanged = _ctx?.HiddenAppName != ctx.HiddenAppName;
        _ctx = ctx;
        _ctxAtMs = Now;
        foreach (var slot in Slots)
        {
            if (slot.Fallback is { } model) { model.Apply(ctx); continue; }
            if (!slot.Ready || slot.Web == null || slot.Layout == ShieldLayout.Art) continue;
            long elapsed = Now - slot.ShownAtMs;
            long pageThinks = slot.ShownRemainingMs - elapsed;
            if (slot.NeedsReshow || Math.Abs(pageThinks - ctx.RemainingMs) > 1500 || (hiddenChanged && slot.ShownApp != ctx.HiddenAppName))
            {
                SendShow(slot);
                if (slot.Layout == ShieldLayout.Notice && hiddenChanged) slot.Window.RaiseToTop();
            }
            else if (slot.AthanActive && ctx.AthanRemainingMs == 0)
            {
                slot.AthanActive = false;
                slot.Web.AthanStopped();
            }
        }
    }

    public void Dismiss(Action thenIdle)
    {
        if (!IsPresenting) { thenIdle(); return; }
        if (IsDismissing) { _dismissCompletion = thenIdle; return; }
        IsDismissing = true;
        _dismissCompletion = thenIdle;
        StopProtecting();    // the block is over: give the keyboard and the foreground back now
        foreach (var slot in Slots)
        {
            if (slot.FellBack) { if (slot.IsMain && slot.Fallback != null) slot.Fallback.Accepting = true; }
            else slot.Web?.DismissPage();
        }
        ArmDismissTimer();
    }

    public void TearDown()
    {
        _dismissTimer?.Stop(); _rebuildTimer?.Stop();
        _dismissTimer = null; _rebuildTimer = null;
        _dismissCompletion = null;
        IsDismissing = false;
        IsPresenting = false;
        _epoch++;
        CloseAll();
        Disengage();
        _ctx = null;
        // Live run B: after the shield closed nothing had the focus. Hand it back to what had it before
        // (we are still the foreground process, so Windows allows it). A window that is gone is ignored.
        var back = _restoreTo;
        _restoreTo = IntPtr.Zero;
        if (back != IntPtr.Zero && Win32.IsWindow(back)) Win32.SetForegroundWindow(back);
    }

    // MARK: Building

    static System.Windows.Media.Color Ground(ShieldContext ctx) => ShieldPalette.Of(ctx.Prayer).Ground;

    /// <summary>The context with the time that has passed since it arrived taken off (rebuilds, fallbacks).</summary>
    ShieldContext? Adjusted()
    {
        if (_ctx is not { } c) return null;
        int ms = (int)(Now - _ctxAtMs);
        return c with { RemainingMs = Math.Max(0, c.RemainingMs - ms), AthanRemainingMs = Math.Max(0, c.AthanRemainingMs - ms) };
    }

    void Build()
    {
        if (_ctx is not { } ctx) return;
        var displays = Options.Displays();
        var ground = Ground(ctx);
        var made = new List<Slot>();
        if (ctx.Mode == BlockMode.CodingApps)
        {
            if (displays.Count > 0)
            {
                var p = displays[0];
                double scale = Options.OnScreen ? Win32.ScaleAt(p.X + p.Width / 2, p.Y + p.Height / 2) : 1.0;
                var frame = Shield.Displays.NoticeFrame(p, scale);
                made.Add(new Slot(p, ShieldLayout.Notice, new ShieldWindow(frame, ground, activates: false, Options.OnScreen, notice: true)));
            }
        }
        else
        {
            for (int i = 0; i < displays.Count; i++)
                made.Add(new Slot(displays[i], i == 0 ? ShieldLayout.Full : ShieldLayout.Art,
                                  new ShieldWindow(displays[i], ground, activates: i == 0, Options.OnScreen, notice: false)));
        }
        Slots = made;
        foreach (var slot in Slots) AttachWeb(slot);
    }

    void AttachWeb(Slot slot)
    {
        if (_ctx is not { } ctx) return;
        var web = new SceneWebView(Options.ScenesRoot, Ground(ctx), Options.Web);
        web.OnMessage = msg => _ui.BeginInvoke(() => Handle(msg, slot));
        web.OnFailure = why => _ui.BeginInvoke(() => FallBack(slot, why));
        slot.Web = web;
        slot.Window.Content = web.View;
        web.Load();
        int myEpoch = _epoch;
        slot.ReadyTimer = After(Options.ReadyTimeout, () =>
        {
            if (_epoch == myEpoch && !slot.Ready && !slot.FellBack) FallBack(slot, "ready timeout");
        });
    }

    void SendShow(Slot slot)
    {
        if (Adjusted() is not { } c || slot.Web is not { } web) return;
        var payload = BridgePayload.From(c, slot.Layout, reduceMotionOverride: slot.Layout == ShieldLayout.Full ? null : true);
        slot.ShownAtMs = Now;
        slot.ShownRemainingMs = c.RemainingMs;
        slot.ShownApp = c.HiddenAppName;
        slot.AthanActive = c.AthanRemainingMs > 0;
        slot.NeedsReshow = false;
        web.Show(payload);
    }

    // MARK: Messages from the page

    void Handle(BridgeMessage msg, Slot slot)
    {
        if (!Slots.Contains(slot)) return;          // a message from a torn-down page
        switch (msg)
        {
            case BridgeMessage.Ready:
                slot.Ready = true;
                slot.ReadyTimer?.Stop();
                SendShow(slot);
                break;
            case BridgeMessage.Prayed:
                if (!slot.IsMain || !IsPresenting || IsDismissing) return;
                // The page may be ahead of the gate. If the gate refuses it calls Update, and this flag makes
                // that update rebuild the page with the true remaining time.
                slot.NeedsReshow = true;
                Delegate?.ShieldDidRequestConfirm();
                break;
            case BridgeMessage.Silence:
                if (!slot.IsMain || !IsPresenting || IsDismissing) return;
                Delegate?.ShieldDidRequestSilence();
                break;
            case BridgeMessage.Gone:
                if (IsDismissing && slot.IsMain) FinishDismiss();
                break;
        }
    }

    // MARK: Fallback (rule 1: never trap)

    internal void FallBack(Slot slot, string reason)
    {
        if (!IsPresenting || slot.Web == null || !Slots.Contains(slot)) return;
        Log($"web shield failed ({reason}); native fallback");
        FallbackReasons.Add(reason);
        slot.ReadyTimer?.Stop();
        slot.Web.ShutDown();
        slot.Web = null;
        if (Adjusted() is not { } c) return;
        if (slot.IsMain)
        {
            var model = new FallbackModel(c)
            {
                OnPrayed = () => { if (IsPresenting && !IsDismissing) Delegate?.ShieldDidRequestConfirm(); },
                OnSilence = () => { if (IsPresenting && !IsDismissing) Delegate?.ShieldDidRequestSilence(); },
            };
            slot.Fallback = model;
            slot.FallbackView = new NativeFallbackShield(model);
            slot.Window.Content = slot.FallbackView;
            if (IsDismissing) { model.Accepting = true; ArmDismissTimer(); }
        }
        else
        {
            slot.Window.Content = null;     // the ground colour of the window stays
        }
    }

    // MARK: Dismiss

    void ArmDismissTimer()
    {
        _dismissTimer?.Stop();
        bool mainFell = Slots.Any(s => s.IsMain && s.FellBack);
        int myEpoch = _epoch;
        _dismissTimer = After(mainFell ? Options.FallbackAcceptHold : Options.GoneTimeout, () => { if (_epoch == myEpoch) FinishDismiss(); });
    }

    void FinishDismiss()
    {
        if (!IsDismissing || _dismissCompletion is not { } done) return;
        _dismissCompletion = null;
        TearDown();
        done();
    }

    void CloseAll()
    {
        if (_engagedDisplays) { SystemEvents.DisplaySettingsChanged -= OnDisplaySettingsChanged; _engagedDisplays = false; }
        foreach (var slot in Slots)
        {
            slot.ReadyTimer?.Stop();
            slot.Web?.ShutDown();
            slot.Window.Content = null;
            slot.Window.CloseForReal();
        }
        Slots = [];
    }

    // MARK: Showing, foreground, keyboard, displays

    void Engage()
    {
        foreach (var s in Slots) s.Window.Show();
        bool wholeScreen = _ctx?.Mode == BlockMode.WholeScreen;
        if (Options.OnScreen)
        {
            if (wholeScreen)
            {
                ActivateMain();
                _watch ??= new ForegroundWatch(IsOurWindow, OnForegroundLost);
                if (Options.InstallKeyboardGuard) Log($"keyboard guard installed={KeyboardGuard.Install()}");
            }
            else
            {
                foreach (var s in Slots) s.Window.RaiseToTop();
            }
        }
        SystemEvents.DisplaySettingsChanged += OnDisplaySettingsChanged;
        _engagedDisplays = true;
    }

    /// <summary>The block's protections: re-assert and the keyboard hook. Off at dismiss and tear-down.</summary>
    void StopProtecting()
    {
        _watch?.Dispose();
        _watch = null;
        if (KeyboardGuard.IsInstalled) { KeyboardGuard.Uninstall(); Log("keyboard guard removed"); }
    }

    void Disengage() => StopProtecting();

    bool IsOurWindow(IntPtr hwnd) => Slots.Any(s => s.Window.Handle == hwnd);

    void ActivateMain()
    {
        var main = Slots.FirstOrDefault(s => s.IsMain)?.Window;
        if (main == null) return;
        foreach (var s in Slots) s.Window.RaiseToTop();
        main.Activate();
        if (main.Handle != IntPtr.Zero) Win32.SetForegroundWindow(main.Handle);
    }

    /// <summary>Spike Q1: debounce lightly, then retry every 100 ms until we hold the foreground again.</summary>
    void OnForegroundLost()
    {
        if (!IsPresenting || IsDismissing || _ctx?.Mode != BlockMode.WholeScreen || !Options.OnScreen || _reassertPending) return;
        _reassertPending = true;
        int myEpoch = _epoch;
        int tries = 0;
        DispatcherTimer? t = null;
        t = After(Options.ReassertDebounce, Retry);
        void Retry()
        {
            if (_epoch != myEpoch || !IsPresenting || IsDismissing) { _reassertPending = false; return; }
            var main = Slots.FirstOrDefault(s => s.IsMain)?.Window;
            if (main == null || IsOurWindow(Win32.GetForegroundWindow())) { _reassertPending = false; return; }
            foreach (var s in Slots) s.Window.RaiseToTop();
            bool ok = main.Handle != IntPtr.Zero && Win32.SetForegroundWindow(main.Handle);
            Reasserts++;
            if (!ok) ReassertsRefused++;
            if (++tries >= 30) { _reassertPending = false; Log("re-assert gave up after 30 tries"); return; }
            t = After(TimeSpan.FromMilliseconds(100), Retry);
        }
    }

    void OnDisplaySettingsChanged(object? sender, EventArgs e) => _ui.BeginInvoke(DisplaysChanged);

    /// <summary>Windows are rebuilt from the current monitors; one that cannot be made is just missing (the
    /// main window and the gate still hold the block).</summary>
    internal void DisplaysChanged()
    {
        if (!IsPresenting || IsDismissing) return;
        _rebuildTimer?.Stop();
        int myEpoch = _epoch;
        _rebuildTimer = After(TimeSpan.FromMilliseconds(300), () =>
        {
            if (_epoch != myEpoch || !IsPresenting || IsDismissing) return;
            var now = Options.Displays();
            bool same = now.SequenceEqual(Slots.Select(s => s.Display)) || (_ctx?.Mode == BlockMode.CodingApps && now.FirstOrDefault() == Slots.FirstOrDefault()?.Display);
            if (same || Adjusted() is not { } c) return;
            Log("displays changed: rebuilding the shield");
            CloseAll();
            _ctx = c;
            _ctxAtMs = Now;
            Build();
            Engage();
        });
    }

    DispatcherTimer After(TimeSpan delay, Action action)
    {
        var t = new DispatcherTimer(DispatcherPriority.Normal, _ui) { Interval = delay < TimeSpan.Zero ? TimeSpan.Zero : delay };
        t.Tick += (_, _) => { t.Stop(); action(); };
        t.Start();
        return t;
    }
}
