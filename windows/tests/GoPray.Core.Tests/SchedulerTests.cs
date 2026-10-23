// SchedulerTests.cs — §E PM test 6 + scheduler arming rules. Port of GoPrayTests/Core/SchedulerTests.swift.
// Fire() is called directly; no test waits for a real timer.

using System;
using System.Collections.Generic;
using GoPray.Core;
using Xunit;

namespace GoPray.Core.Tests;

/// <summary>Records arm/cancel; never fires by itself.</summary>
public sealed class ManualTimers : ITimerFactory
{
    public List<TimeSpan> Armed { get; } = [];
    public int Live { get; private set; }

    public IDisposable Arm(TimeSpan delay, Action fire)
    {
        Armed.Add(delay);
        Live++;
        return new Handle(this);
    }

    sealed class Handle(ManualTimers owner) : IDisposable
    {
        bool _done;
        public void Dispose() { if (!_done) { _done = true; owner.Live--; } }
    }
}

public class SchedulerTests
{
    sealed class TZ { public TimeZoneInfo Zone = TimeZoneInfo.Utc; }

    static Scheduler Make(Harness h, TZ? tz = null, ManualTimers? timers = null)
    {
        tz ??= new TZ();
        return new Scheduler(h.Clock, h.Schedule, h.Gate, () => h.Settings, () => tz.Zone, timers ?? new ManualTimers());
    }

    [Fact]
    public void armsTheNextAthanAndFiresIntoTheGate()
    {
        var asr = FakeSchedule.At(Prayer.Asr);
        using var h = new Harness(asr.AddSeconds(-3600));
        var s = Make(h);
        s.Rearm();
        Assert.Equal(Scheduler.Armed.ForAthan(Prayer.Asr, asr), s.Current);

        h.Clock.Now = asr;
        s.Fire();
        Assert.Equal(Prayer.Asr, h.Gate.CurrentBlock?.Prayer);
        Assert.Equal(Scheduler.Armed.ForAthan(Prayer.Maghrib, FakeSchedule.At(Prayer.Maghrib)), s.Current);
        s.Stop();
    }

    [Fact]
    public void timeZoneChangeKeepsTheSameInstant()
    {
        var asr = FakeSchedule.At(Prayer.Asr);
        using var h = new Harness(asr.AddSeconds(-5400));
        var tz = new TZ();
        var s = Make(h, tz);
        s.Rearm();
        var before = s.Current;
        Assert.Equal(Scheduler.Armed.ForAthan(Prayer.Asr, asr), before);
        tz.Zone = TimeZoneInfo.FindSystemTimeZoneById("America/Los_Angeles");
        s.Handle(ReevalReason.TimeZoneChanged);
        Assert.Equal(before, s.Current);
        Assert.Equal(asr, h.Schedule.Times(asr)?.Asr);   // absolute instants, unchanged
        s.Stop();
    }

    [Fact]
    public void armsMidnightWhenTheNextAthanIsTomorrow()
    {
        var isha = FakeSchedule.At(Prayer.Isha);
        using var h = new Harness(isha.AddSeconds(60));
        var s = Make(h);
        s.Rearm();
        Assert.Equal(Scheduler.Armed.ForMidnight(FakeSchedule.Day0.AddSeconds(86_400)), s.Current);
        h.Clock.Now = FakeSchedule.Day0.AddSeconds(86_400);
        s.Fire();
        Assert.Equal(Scheduler.Armed.ForAthan(Prayer.Fajr, FakeSchedule.At(Prayer.Fajr, day: 1)), s.Current);
        s.Stop();
    }

    [Fact]
    public void notArmedWhenSetupIncomplete()
    {
        using var h = new Harness(FakeSchedule.At(Prayer.Dhuhr), TestSettings.Test(setupComplete: false));
        var s = Make(h);
        s.Rearm();
        Assert.Null(s.Current);
        s.Fire();                                   // nothing armed: no-op
        Assert.Equal(Phase.Idle, h.Gate.Phase);
    }

    [Fact]
    public void noScheduleArmsOnlyMidnight()
    {
        using var h = new Harness(FakeSchedule.At(Prayer.Dhuhr));
        h.Schedule.Valid = false;
        var s = Make(h);
        s.Rearm();
        Assert.Equal(Scheduler.ArmedKind.Midnight, s.Current?.Kind);
        h.Clock.Now = s.Current!.Value.At;
        s.Fire();
        Assert.Equal(Phase.Idle, h.Gate.Phase);
        s.Stop();
    }

    [Fact]
    public void settingsChangeReevaluatesAndRearms()
    {
        var asr = FakeSchedule.At(Prayer.Asr);
        using var h = new Harness(asr.AddSeconds(120), TestSettings.Test(setupComplete: false));
        var s = Make(h);
        s.Rearm();
        Assert.Null(s.Current);
        h.Settings = TestSettings.Test(setupComplete: true);
        s.Handle(ReevalReason.SettingsChanged);
        Assert.Equal(Scheduler.Armed.ForAthan(Prayer.Maghrib, FakeSchedule.At(Prayer.Maghrib)), s.Current);
        Assert.Equal(Phase.Idle, h.Gate.Phase);     // first setup never blocks the open window (PM ruling a)
        s.Stop();
    }

    [Fact]
    public void stopCancelsTheTimer()
    {
        using var h = new Harness(FakeSchedule.At(Prayer.Dhuhr));
        var timers = new ManualTimers();
        var s = Make(h, timers: timers);
        s.Start();
        Assert.NotNull(s.Current);
        Assert.Equal(1, timers.Live);
        s.Stop();
        Assert.Null(s.Current);
        Assert.Equal(0, timers.Live);
    }

    // Windows addition: one timer only, ever (re-arming disposes the old one).
    [Fact]
    public void rearmKeepsExactlyOneTimer()
    {
        using var h = new Harness(FakeSchedule.At(Prayer.Dhuhr));
        var timers = new ManualTimers();
        var s = Make(h, timers: timers);
        for (int i = 0; i < 5; i++) s.Rearm();
        s.Handle(ReevalReason.Wake);
        Assert.Equal(1, timers.Live);
        s.Stop();
    }
}
