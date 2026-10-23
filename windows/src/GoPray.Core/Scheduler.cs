// Scheduler.cs — one timer + system events → the gate (§C.4). Port of Core/Scheduler.swift.
// One timer, armed for the next Athan or the next local midnight, whichever is first. While paused
// it arms no Athan: only the pause end (or midnight, if that is sooner). Re-armed after it fires
// and on wake, clock, time zone and settings changes. No polling. Talks to the gate only through
// AthanFired(prayer, at) and Reevaluate(reason).
//
// Core has no Windows UI types, so the app supplies two things:
//   - an ITimerFactory (the app's posts back to the UI thread);
//   - the system events: the app wires SystemEvents.PowerModeChanged(Resume) / SessionSwitch(Unlock)
//     → Handle(Wake), SystemEvents.TimeChanged → TimeZoneInfo.ClearCachedData() + Handle(ClockChanged)
//     (PLAN.md §3 row 6). Windows fires one event for clock and zone changes.

using System;
using System.Threading;

namespace GoPray.Core;

public interface ITimerFactory
{
    /// <summary>Calls <paramref name="fire"/> once after <paramref name="delay"/>. Dispose cancels it.</summary>
    IDisposable Arm(TimeSpan delay, Action fire);
}

/// <summary>A System.Threading.Timer that runs the callback on the SynchronizationContext it was armed
/// on (the UI thread in the app). Timers do not run during sleep; the wake rule catches up.</summary>
public sealed class ThreadingTimerFactory : ITimerFactory
{
    public IDisposable Arm(TimeSpan delay, Action fire)
    {
        var ctx = SynchronizationContext.Current;
        var due = delay < TimeSpan.Zero ? TimeSpan.Zero : delay;
        if (due.TotalMilliseconds > 0xFFFFFFFE) due = TimeSpan.FromMilliseconds(0xFFFFFFFE);   // Timer's max; re-armed at midnight anyway
        return new Timer(_ => { if (ctx != null) ctx.Post(_ => fire(), null); else fire(); }, null, due, Timeout.InfiniteTimeSpan);
    }
}

public sealed class Scheduler
{
    public enum ArmedKind { Athan, Midnight, PauseEnds }

    public readonly record struct Armed(ArmedKind Kind, DateTime At, Prayer? Prayer = null)
    {
        public static Armed ForAthan(Prayer p, DateTime at) => new(ArmedKind.Athan, at, p);
        public static Armed ForMidnight(DateTime at) => new(ArmedKind.Midnight, at);
        public static Armed ForPauseEnd(DateTime at) => new(ArmedKind.PauseEnds, at);
    }

    readonly IClock _clock;
    readonly IPrayerScheduleProviding _schedule;
    readonly BlockGate _gate;
    readonly Func<Settings> _settings;
    readonly Func<TimeZoneInfo> _zone;
    readonly ITimerFactory _timers;
    IDisposable? _timer;
    bool _started;

    /// <summary>What the one timer is armed for; null = not armed (setup incomplete, or stopped).</summary>
    public Armed? Current { get; private set; }

    public Scheduler(IClock clock, IPrayerScheduleProviding schedule, BlockGate gate, Func<Settings> settings,
                     Func<TimeZoneInfo>? zone = null, ITimerFactory? timers = null)
    {
        _clock = clock;
        _schedule = schedule;
        _gate = gate;
        _settings = settings;
        _zone = zone ?? (() => TimeZoneInfo.Local);
        _timers = timers ?? new ThreadingTimerFactory();
    }

    /// <summary>Arm. Call once after gate.Reevaluate(Launch); the app wires system events to Handle.</summary>
    public void Start()
    {
        if (_started) return;
        _started = true;
        Rearm();
    }

    public void Stop()
    {
        _started = false;
        CancelTimer();
    }

    /// <summary>The single entry for system and settings events: let the gate apply its rules, then
    /// re-arm. SettingsStore's change hook calls this with SettingsChanged.</summary>
    public void Handle(ReevalReason reason)
    {
        _gate.Reevaluate(reason);
        Rearm();
    }

    /// <summary>Re-arm for the next Athan (or midnight) strictly after <paramref name="after"/> (default: now).</summary>
    public void Rearm(DateTime? after = null)
    {
        CancelTimer();
        var s = _settings();
        if (!s.SetupComplete) return;                      // setup incomplete → never armed
        var now = _clock.Now;
        var from = after is { } a && a > now ? a : now;
        var tomorrow = ZoneCalendar.StartOfNextDay(from, _zone());
        var target = Armed.ForMidnight(tomorrow);
        if (s.IsPaused(from) && s.PausedUntil is { } until)
        {
            // Paused: no Athan is armed. Wake at the pause end to re-arm.
            if (until <= tomorrow) target = Armed.ForPauseEnd(until);
        }
        else if (_schedule.NextAthan(from) is { } next && next.At > from && next.At <= tomorrow
                 && (next.At - from).TotalSeconds <= 2 * 86_400)
        {
            // A schedule answer outside (from, 2 days] is treated as no schedule.
            target = Armed.ForAthan(next.Prayer, next.At);
        }
        Current = target;
        var delay = target.At - now;
        if (delay < TimeSpan.Zero) delay = TimeSpan.Zero;
        _timer = _timers.Arm(delay, Fire);
        CoreLog.Notice($"armed {target.Kind} {target.Prayer} in {(int)delay.TotalSeconds} s");
    }

    /// <summary>The timer fired. Public so tests can fire it without waiting.</summary>
    public void Fire()
    {
        if (Current is not { } a) return;
        Current = null;
        switch (a.Kind)
        {
            case ArmedKind.Athan:
                _gate.AthanFired(a.Prayer!.Value, a.At);
                break;
            case ArmedKind.Midnight:
                _gate.Reevaluate(ReevalReason.Midnight);
                break;
            case ArmedKind.PauseEnds:
                _gate.Reevaluate(ReevalReason.PauseEnded);
                break;
        }
        Rearm(a.At);
    }

    void CancelTimer()
    {
        _timer?.Dispose();
        _timer = null;
        Current = null;
    }
}
