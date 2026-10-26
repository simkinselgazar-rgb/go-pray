// BlockGate.cs — THE choke point (§C.3). Line-for-line port of Core/BlockGate.swift.
//
// Only this type starts a block, ends a block, or says whether "I prayed" is allowed.
// Two rules, in this order (§A):
//   1. Never trap him. Every failure fails OPEN.
//   2. No escape by reflex. Only RequestConfirm() after the lock ends a block.
//
// Two private exits, both in this file:
//   EndBlock(kind) — the end of a block by request. Exactly two callers: RequestConfirm() ("I prayed" after
//                    the lock → LastConfirmed) and RequestEmergencyExit() (v2, PLAN-v2 §2 + §9: 5 a year, the
//                    captured switch on → LastDropped, a plain fade). Nothing else may end a block.
//   FailOpen(reason) — a §G fail-open rule (window closed, next Athan, crash loop, no schedule).
//                      Never reachable from the shield, the menu or a page message.
// windows/scripts/guard.ps1 checks both (rules 1 and 2) and that only RequestEmergencyExit records a use (rule 14).
//
// v2 captures (PLAN-v2 §1.1 rule 3, §9.2): the blocked-apps list and "Allow emergency exits" are copied into
// state.json at block start, like the lock length; the running block reads only those copies.
//
// TVs (0.3.0): at block start, right after the Athan starts, the gate hands the enabled TVs to ITvLaunching once
// (fire and forget). Only a fresh start within 3 min of the prayer's real Athan calls them; a relaunch mid-block,
// Silence and a late wake never do. Nothing the TVs do can reach the block.
//
// Threading: like the Mac's @MainActor, the gate is used from one thread (the app's UI thread).
// The only async path is the leaving timeout, which posts back to the SynchronizationContext that
// ended the block.

using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace GoPray.Core;

public enum PhaseKind { Idle, Locked, CanConfirm, Leaving }

public readonly record struct Phase(PhaseKind Kind, DateTime? Until = null)
{
    public static readonly Phase Idle = new(PhaseKind.Idle);
    public static readonly Phase CanConfirm = new(PhaseKind.CanConfirm);
    public static readonly Phase Leaving = new(PhaseKind.Leaving);
    public static Phase Locked(DateTime until) => new(PhaseKind.Locked, until);
}

public enum FailOpenReason
{
    /// <summary>Block outlived its prayer window: missed.</summary>
    WindowClosed,
    /// <summary>Overlap: the new prayer replaces the old.</summary>
    ReplacedByNextAthan,
    /// <summary>3 launches in 120 s while blocked.</summary>
    CrashLoop,
    /// <summary>The block's window cannot be found.</summary>
    NoSchedule,
}

/// <summary>What the settings store needs from the gate.</summary>
public interface ISettingsChangeAuthorizing
{
    void AuthorizeSettingsChange();
}

public sealed class BlockGate : IShieldDelegate, ISettingsChangeAuthorizing
{
    // MARK: Dependencies

    readonly IClock _clock;
    readonly StateStore _store;
    readonly IPrayerScheduleProviding _schedule;
    readonly IShieldPresenting _shield;
    readonly IAthanPlaying _audio;
    readonly IAppHiding _hider;
    readonly Func<Settings> _settings;
    readonly Func<bool> _systemReduceMotion;
    /// <summary>null = no exits on this gate (0 left): tests that predate v2, and a wiring slip fails closed.</summary>
    readonly EmergencyLedger? _ledger;
    /// <summary>The compiled-in default app ids (App: CodingApps.Names.Keys).</summary>
    readonly IReadOnlyList<string> _defaultApps;
    /// <summary>null = no TV support on this gate (tests that predate 0.3.0).</summary>
    readonly ITvLaunching? _tvs;
    /// <summary>A dismiss that never calls back is torn down after this (fail open).</summary>
    public TimeSpan LeavingTimeout { get; }

    public const int CrashLoopLaunches = 3;
    public const double CrashLoopWindow = 120;

    // MARK: State

    public BlockStateFile State { get; private set; }
    public string? HiddenAppName { get; private set; }
    int? _leavingToken;
    int _tokenCounter;
    bool _presented;
    bool _loadedCorrupt;
    /// <summary>Settings as last seen by Reevaluate, to catch "setup just finished" and "pause just
    /// ended" (neither may block the window that is already open).</summary>
    (bool SetupComplete, bool Paused) _lastSeen;

    public BlockGate(IClock clock, StateStore store, IPrayerScheduleProviding schedule, IShieldPresenting shield,
                     IAthanPlaying audio, IAppHiding hider, Func<Settings> settings,
                     TimeSpan? leavingTimeout = null, Func<bool>? systemReduceMotion = null,
                     EmergencyLedger? ledger = null, IEnumerable<string>? defaultApps = null, ITvLaunching? tvs = null)
    {
        _tvs = tvs;
        _ledger = ledger;
        _defaultApps = (defaultApps ?? []).ToList();
        _clock = clock;
        _store = store;
        _schedule = schedule;
        _shield = shield;
        _audio = audio;
        _hider = hider;
        _settings = settings;
        LeavingTimeout = leavingTimeout ?? TimeSpan.FromSeconds(4);
        _systemReduceMotion = systemReduceMotion ?? (() => false);
        switch (store.Load())
        {
            case StateStore.LoadResult.Loaded l: State = l.State; break;
            case StateStore.LoadResult.Corrupt: State = new BlockStateFile(); _loadedCorrupt = true; break;
            default: State = new BlockStateFile(); break;
        }
        var s0 = settings();
        _lastSeen = (s0.SetupComplete, s0.IsPaused(clock.Now));
        shield.Delegate = this;
        audio.OnFinished = AthanFinished;
        hider.OnReHide = AppReHidden;
    }

    // MARK: Read-only views

    public Phase Phase
    {
        get
        {
            if (State.CurrentBlock is not { } b) return _leavingToken != null ? Phase.Leaving : Phase.Idle;
            double elapsed = (_clock.Now - b.BlockStartedAt).TotalSeconds;
            double lockSecs = Lock(b);
            // Clamp: a clock behind blockStartedAt opens the button. A lock is never longer than
            // the block's captured lock (≤ 30 min) from any moment.
            if (elapsed >= 0 && elapsed < lockSecs) return Phase.Locked(b.BlockStartedAt.AddSeconds(lockSecs));
            return Phase.CanConfirm;
        }
    }

    public bool IsBlocked => Phase != Phase.Idle;
    public BlockStateFile.Block? CurrentBlock => State.CurrentBlock;

    public bool ShouldAllowQuit() => !IsBlocked;
    public bool AllowsSettingsChange() => !IsBlocked;

    /// <summary>SettingsStore.Mutate calls this first. Covers every setting, including mode,
    /// LockMinutes and pause/resume: none may change during a block.</summary>
    public void AuthorizeSettingsChange()
    {
        if (!AllowsSettingsChange()) throw new SettingsBlockedException();
    }

    /// <summary>What the shield should show right now; null when no block is active.</summary>
    public ShieldContext? ShieldContext()
    {
        if (State.CurrentBlock is not { } b) return null;
        var s = _settings();
        int remaining = 0;
        if (Phase is { Kind: PhaseKind.Locked, Until: { } until })
        {
            remaining = (int)Math.Ceiling((until - _clock.Now).TotalSeconds * 1000);
            remaining = Math.Min(Math.Max(remaining, 0), (int)(Lock(b) * 1000));
        }
        return new ShieldContext
        {
            Prayer = b.Prayer, Mode = s.Mode, RemainingMs = remaining,
            AthanRemainingMs = _audio.IsPlaying ? Math.Max(0, _audio.RemainingMs()) : 0,
            ReduceMotion = s.ReduceMotion ?? _systemReduceMotion(),
            HiddenAppName = HiddenAppName,
            BlockStartedAt = b.BlockStartedAt, LockSeconds = (int)Lock(b),
            EmergencyExitsLeft = ExitsLeft(b),
        };
    }

    /// <summary>Exits left for this block: 0 when its captured switch is off (the page draws no button).</summary>
    int ExitsLeft(BlockStateFile.Block b) => b.EmergencyExitsEnabled ? EmergencyExitsRemaining : 0;

    /// <summary>Exits left this year, whatever the switch says (the menu and Settings show it). Read from disk every time.</summary>
    public int EmergencyExitsRemaining => _ledger?.Remaining(_clock.Now) ?? 0;

    // MARK: Inputs

    /// <summary>Scheduler only. Starts a block if the schedule agrees this Athan is now.</summary>
    public void AthanFired(Prayer prayer, DateTime at)
    {
        var now = _clock.Now;
        var s = _settings();
        if (!s.SetupComplete) return;
        if (_schedule.Window(Max(now, at)) is not { } w || w.Prayer != prayer
            || Math.Abs((w.Athan - at).TotalSeconds) >= 60 || !(w.End > now))
        {
            CoreLog.Notice($"athanFired({SwiftJson.Name(prayer)}) ignored: schedule disagrees");
            return;
        }
        if (State.CurrentBlock is { } b && Math.Abs((b.AthanAt - w.Athan).TotalSeconds) < 1) return;   // already blocking it
        if (IsDone(w)) return;
        if (CoveredByPause(w, s))
        {
            CoreLog.Notice($"athanFired({SwiftJson.Name(prayer)}) skipped: paused");
            return;
        }
        if (State.CurrentBlock != null) FailOpen(FailOpenReason.ReplacedByNextAthan);
        StartBlock(w.Prayer, w.Athan, now, LockPolicy.SecondsForMinutes(s.LockMinutes), s);
    }

    /// <summary>Launch, wake, clock, time zone, settings, midnight. Applies the wake rule and every
    /// fail-open rule. Never stacks two blocks.</summary>
    public void Reevaluate(ReevalReason reason)
    {
        var now = _clock.Now;
        if (reason == ReevalReason.Launch && !LaunchChecks(now)) return;

        var s = _settings();
        bool paused = s.IsPaused(now);
        bool setupJustFinished = !_lastSeen.SetupComplete && s.SetupComplete;
        bool pauseJustEnded = _lastSeen.Paused && !paused;
        _lastSeen = (s.SetupComplete, paused);

        if (State.CurrentBlock is { } b)
        {
            if (WindowOf(b) is { } bw)
            {
                if (bw.Prayer == b.Prayer && Math.Abs((bw.Athan - b.AthanAt).TotalSeconds) < 1 && bw.End > now)
                {
                    if (_presented) _shield.Update(ShieldContext()!); else Present(freshAthan: false);
                    return;
                }
                FailOpen(FailOpenReason.WindowClosed);
            }
            else
            {
                FailOpen(FailOpenReason.NoSchedule);
            }
        }

        // First setup and resume never block the window already open (PM ruling 2026-10-22).
        if (setupJustFinished || pauseJustEnded)
        {
            DropOpenWindow(now, setupJustFinished ? "setup just finished" : "pause just ended");
            return;
        }

        // Wake rule (§3): the open window's prayer, if not done and not paused, blocks now.
        if (!s.SetupComplete || _schedule.Window(now) is not { } w || !(w.Athan <= now) || !(now < w.End)
            || IsDone(w) || CoveredByPause(w, s)) return;
        StartBlock(w.Prayer, w.Athan, now, LockPolicy.SecondsForMinutes(s.LockMinutes), s);
    }

    /// <summary>"I prayed": ends the block only after the lock. False while locked (or idle).</summary>
    public bool RequestConfirm()
    {
        if (Phase != Phase.CanConfirm) return false;
        EndBlock(EndKind.Confirmed);
        return true;
    }

    /// <summary>The second and last way a request ends a block (PLAN-v2 §2.2, §9). Allowed while locked or at
    /// canConfirm, only if the block's captured switch is on and an exit is left this year. The use is recorded
    /// FIRST; if it cannot be written the exit is refused (the normal path is untouched: no trap, no free exit).
    /// The prayer is recorded as dropped, never confirmed.</summary>
    public bool RequestEmergencyExit()
    {
        if (State.CurrentBlock is not { } b) { CoreLog.Notice("emergency exit refused: idle"); return false; }
        if (Phase.Kind is not (PhaseKind.Locked or PhaseKind.CanConfirm)) { CoreLog.Notice("emergency exit refused: leaving"); return false; }
        if (!b.EmergencyExitsEnabled) { CoreLog.Notice("emergency exit refused: exits off"); return false; }
        if (_ledger == null || _ledger.Remaining(_clock.Now) <= 0) { CoreLog.Notice("emergency exit refused: none left"); return false; }
        try { _ledger.RecordUse(new EmergencyLedger.Use(b.Prayer, b.AthanAt, _clock.Now)); }
        catch (Exception e)
        {
            CoreLog.Error($"emergency exit refused: the use could not be recorded ({e.Message})");
            return false;
        }
        EndBlock(EndKind.Emergency);
        return true;
    }

    /// <summary>Stops the sound. The block is untouched.</summary>
    public void RequestSilence()
    {
        if (State.CurrentBlock is not { } b) return;
        _audio.Stop();
        if (!b.Silenced)
        {
            State = State with { CurrentBlock = b with { Silenced = true } };
            Persist();
        }
        _shield.Update(ShieldContext()!);
    }

    // MARK: Private

    /// <summary>The lock a block honours: its captured length, never above the 30-min maximum (a
    /// tampered file cannot trap), never negative.</summary>
    internal static double Lock(BlockStateFile.Block b) => Math.Min(Math.Max(b.LockSeconds, 0), LockPolicy.MaxSeconds);

    /// <summary>A window whose Athan came before PausedUntil was skipped by the pause. Stateless, so it
    /// also holds after a relaunch or a pause that ran out while asleep.</summary>
    internal static bool CoveredByPause(PrayerWindow w, Settings s) => s.PausedUntil is { } until && w.Athan < until;

    static DateTime Max(DateTime a, DateTime b) => a > b ? a : b;

    /// <summary>The window a running block belongs to. Real blocks: the schedule's. DEBUG builds also
    /// accept a "Trigger Athan now" block's synthetic window (at most 1 h long).</summary>
    PrayerWindow? WindowOf(BlockStateFile.Block b)
    {
#if DEBUG
        if (b.DebugWindowEnd is { } end)
        {
            var cap = b.AthanAt.AddSeconds(3600);
            return new PrayerWindow(b.Prayer, b.AthanAt, end < cap ? end : cap);
        }
#endif
        return _schedule.Window(b.AthanAt);
    }

    bool IsDone(PrayerWindow w) => State.LatestDoneAthan is { } done && (w.Athan - done).TotalSeconds < 1;

    /// <summary>Launch-only fail-open checks. Returns false when it already settled the state.</summary>
    bool LaunchChecks(DateTime now)
    {
        if (_loadedCorrupt)
        {
            _loadedCorrupt = false;
            DropOpenWindow(now, "corrupt state.json");
            return false;
        }

        // A far-future "done" date would make every later prayer look finished: quarantine it.
        if (State.LatestDoneAthan is { } done && done > now.AddSeconds(86_400))
        {
            _store.Quarantine("future done date");
            State = new BlockStateFile();
            DropOpenWindow(now, "future done date in state.json");
            return false;
        }
        if (State.CurrentBlock is not { } b) return true;

        // A block cannot start before its Athan or in the future.
        if (b.BlockStartedAt < b.AthanAt.AddSeconds(-60) || b.BlockStartedAt > now.AddSeconds(60))
        {
            _store.Quarantine("impossible dates");
            State = new BlockStateFile();
            DropOpenWindow(now, "impossible dates in state.json");
            return false;
        }

        // Crash loop: 3 launches in 120 s while blocked → give this prayer up.
        var launches = State.Launches.Where(l => (now - l).TotalSeconds >= 0 && (now - l).TotalSeconds <= CrashLoopWindow).ToList();
        launches.Add(now);
        State = State with { Launches = launches.Skip(Math.Max(0, launches.Count - 5)).ToList() };
        if (State.Launches.Count >= CrashLoopLaunches)
        {
            FailOpen(FailOpenReason.CrashLoop);
            return false;
        }
        Persist();
        return true;
    }

    /// <summary>No block in memory: mark the open window as done so the wake rule does not block it,
    /// write a clean file. Used by fail-open (corrupt file) and by "setup just finished" / "pause just ended".</summary>
    void DropOpenWindow(DateTime now, string reason)
    {
        CoreLog.Notice($"open window dropped: {reason}");
        if (_schedule.Window(now) is { } w && w.Athan <= now && now < w.End)
            State = State with { LastDropped = new BlockStateFile.Done(w.Prayer, w.Athan) };
        Persist();
    }

    /// <summary>The blocked-apps list for a block starting with these settings, sorted so the file is stable.</summary>
    List<string> Capture(Settings s) => BlockedApps.Effective(s, _defaultApps).OrderBy(x => x, StringComparer.Ordinal).ToList();

    void StartBlock(Prayer prayer, DateTime athanAt, DateTime now, double lockSeconds, Settings s)
    {
        if (_leavingToken != null)        // a dismiss is still fading: cut it
        {
            _leavingToken = null;
            _shield.TearDown();
        }
        State = State with
        {
            CurrentBlock = new BlockStateFile.Block
            {
                Prayer = prayer, AthanAt = athanAt, BlockStartedAt = now, Silenced = false, AthanPlayed = true,
                LockSeconds = lockSeconds,   // captured: later settings changes cannot touch it
                HiddenApps = Capture(s),     // captured too (v2)
                EmergencyExitsEnabled = s.EmergencyExitsEnabled,
            },
            Launches = [],
        };
        Persist();                        // on disk BEFORE the shield goes up
        CoreLog.Notice($"block start {SwiftJson.Name(prayer)}");
        Present(freshAthan: true);
    }

    void Present(bool freshAthan)
    {
        var s = _settings();
        _presented = true;
        // A 0.1.x block resumed after the upgrade has no captured list: compute it once and write it back.
        if (State.CurrentBlock is { HiddenApps: null } old)
        {
            State = State with { CurrentBlock = old with { HiddenApps = Capture(s) } };
            Persist();
        }
        if (s.Mode == BlockMode.CodingApps && State.CurrentBlock is { } cb)
            _hider.Start(BlockedApps.CleanCaptured(cb.HiddenApps ?? []).ToHashSet(StringComparer.Ordinal));
        if (freshAthan && State.CurrentBlock is { Silenced: false } b)
        {
            try { _audio.Play(b.Prayer, s.Voice, s.AthanVolume); }
            catch (Exception e) { CoreLog.Error($"athan play failed: {e.Message}"); }
        }
        if (freshAthan && State.CurrentBlock is { } started) CallTvs(started, s);    // also when the PC's audio failed
        _shield.Show(ShieldContext()!);
    }

    /// <summary>Block start only. The TVs are extra: a refusal or a failure is one log line and changes nothing.</summary>
    void CallTvs(BlockStateFile.Block b, Settings s)
    {
        if (_tvs == null || !s.Tvs.Any(t => t.Enabled)) return;
        if (!TvRules.InLaunchWindow(b.AthanAt, _clock.Now)) { CoreLog.Notice("tv: skipped, late wake"); return; }
        try { _tvs.AthanStarted(s.Tvs, b.Prayer, s.Voice); }
        catch (Exception e) { CoreLog.Error($"tv: {e.Message}"); }
    }

    private void EndBlock(EndKind kind)
    {
        if (State.CurrentBlock is not { } b) return;
        // Both mark the prayer done for the wake rule. Honest record: an emergency exit is dropped, never confirmed.
        var done = new BlockStateFile.Done(b.Prayer, b.AthanAt);
        State = kind == EndKind.Confirmed
            ? State with { LastConfirmed = done, CurrentBlock = null, Launches = [] }
            : State with { LastDropped = done, CurrentBlock = null, Launches = [] };
        Persist();
        CoreLog.Notice($"block {kind.ToString().ToLowerInvariant()} {SwiftJson.Name(b.Prayer)}");
        _audio.Stop();
        _hider.Stop();
        _presented = false;
        HiddenAppName = null;
        int token = ++_tokenCounter;
        _leavingToken = token;
        _shield.Dismiss(() => FinishLeaving(token), kind);
        // Fail open: a dismiss that never calls back cannot keep us "blocked".
        var ctx = SynchronizationContext.Current;
        _ = Task.Delay(LeavingTimeout).ContinueWith(_ =>
        {
            void Fire()
            {
                if (_leavingToken != token) return;
                _shield.TearDown();
                FinishLeaving(token);
            }
            if (ctx != null) ctx.Post(_ => Fire(), null); else Fire();
        }, TaskScheduler.Default);
    }

    void FinishLeaving(int token)
    {
        if (_leavingToken != token) return;
        _leavingToken = null;
    }

    private void FailOpen(FailOpenReason reason)
    {
        if (State.CurrentBlock is not { } b) return;
        CoreLog.Error($"{reason}: {SwiftJson.Name(b.Prayer)} block dropped");
        // Record the prayer as done so the wake rule does not block it again.
        if (reason == FailOpenReason.CrashLoop) State = State with { LastDropped = new BlockStateFile.Done(b.Prayer, b.AthanAt) };
        State = State with { CurrentBlock = null, Launches = [] };
        Persist();
        _audio.Stop();
        _hider.Stop();
        _shield.TearDown();
        _presented = false;
        HiddenAppName = null;
        _leavingToken = null;
    }

    void Persist()
    {
        try { _store.Save(State); }
        catch (Exception e) { CoreLog.Error($"state.json write failed: {e.Message}"); }
    }

    void AthanFinished()
    {
        if (ShieldContext() is { } ctx) _shield.Update(ctx);
    }

    void AppReHidden(string name)
    {
        if (State.CurrentBlock == null) return;
        HiddenAppName = name;
        _shield.Update(ShieldContext()!);
    }

    // MARK: Debug

#if DEBUG
    /// <summary>Debug menu only. Starts a block now with a short lock. It can start a block, never end one.</summary>
    public void DebugTriggerAthan(Prayer prayer, double lockSeconds)
    {
        var now = _clock.Now;
        if (State.CurrentBlock != null) FailOpen(FailOpenReason.ReplacedByNextAthan);
        StartBlock(prayer, now, now, lockSeconds, _settings());
        // A synthetic window (athan = now, end = now + 1 h) through the same state.json, so a
        // relaunch mid-block resumes it like a real block.
        State = State with { CurrentBlock = State.CurrentBlock! with { DebugWindowEnd = now.AddSeconds(3600) } };
        Persist();
    }

    /// <summary>Debug menu only, idle only.</summary>
    public void DebugWipeState()
    {
        if (IsBlocked) return;
        _store.Wipe();
        State = new BlockStateFile();
    }

    /// <summary>Debug menu only, idle only: this year's emergency exits used = <paramref name="used"/> (0…5).</summary>
    public void DebugSetEmergencyExitsUsed(int used)
    {
        if (IsBlocked || _ledger == null) return;
        _ledger.DebugSetUsed(used, _clock.Now);
    }
#endif

    // MARK: IShieldDelegate

    public void ShieldDidRequestConfirm()
    {
        // Refused → re-sync the page with the gate's own remaining time.
        if (!RequestConfirm() && ShieldContext() is { } ctx) _shield.Update(ctx);
    }

    public void ShieldDidRequestSilence() => RequestSilence();

    public void ShieldDidRequestEmergencyExit()
    {
        // Refused → re-sync the page with the true count (0 hides the button).
        if (!RequestEmergencyExit() && ShieldContext() is { } ctx) _shield.Update(ctx);
    }
}
