// LateWakeTests.cs — 0.3.5 (Ahmed, 2026-10-27): a block that starts more than TimeSpan.FromMinutes(30) (30 min) after
// its Athan is a late block: the shield shows, but no Athan plays and "I prayed" is open at once. Found on Ahmed's PC:
// a wake at 20:53 played Isha's 19:27 Athan and locked the screen for 10 minutes.

using System;
using GoPray.Core;
using Xunit;

namespace GoPray.Core.Tests;

public class LateWakeTests
{
    static readonly DateTime asr = FakeSchedule.At(Prayer.Asr);
    static readonly DateTime isha = FakeSchedule.At(Prayer.Isha);

    static Scheduler Make(Harness h) =>
        new(h.Clock, h.Schedule, h.Gate, () => h.Settings, () => TimeZoneInfo.Utc, new ManualTimers());

    /// <summary>A late block: up, no sound, "I prayed" open now, written to disk as lock 0 with no Athan.</summary>
    static void AssertLate(Harness h, Prayer prayer, DateTime athan)
    {
        Assert.Equal(prayer, h.Gate.CurrentBlock?.Prayer);
        Assert.Equal(athan, h.Gate.CurrentBlock?.AthanAt);
        Assert.Empty(h.Audio.Plays);
        Assert.Equal(Phase.CanConfirm, h.Gate.Phase);
        Assert.NotEmpty(h.Shield.Shows);
        Assert.Equal(0, h.Shield.Shows[^1].RemainingMs);
        Assert.Equal(0, h.Shield.Shows[^1].LockSeconds);
        var disk = h.DiskState().CurrentBlock!;
        Assert.Equal(0, disk.LockSeconds);
        Assert.False(disk.AthanPlayed);
    }

    static void AssertNormal(Harness h, Prayer prayer, DateTime startedAt)
    {
        Assert.Equal(prayer, h.Gate.CurrentBlock?.Prayer);
        Assert.Single(h.Audio.Plays);
        Assert.Equal(Phase.Locked(startedAt.AddSeconds(600)), h.Gate.Phase);
        Assert.Equal(600_000, h.Shield.Shows[^1].RemainingMs);
        Assert.True(h.DiskState().CurrentBlock!.AthanPlayed);
    }

    [Fact]
    public void unlockFiveMinutesAfterTheAthanPlaysItAndLocks()
    {
        using var h = new Harness(asr.AddSeconds(-3600));
        h.Clock.Now = asr.AddMinutes(5);
        h.Gate.Reevaluate(ReevalReason.Wake);
        AssertNormal(h, Prayer.Asr, asr.AddMinutes(5));
        Assert.False(h.Gate.RequestConfirm());
    }

    [Fact]
    public void unlockThreeHoursAfterIshaBlocksWithNoAthanAndPrayedOpen()
    {
        using var h = new Harness(isha.AddSeconds(-600));
        h.Clock.Now = isha.AddHours(3);
        h.Gate.Reevaluate(ReevalReason.Wake);
        AssertLate(h, Prayer.Isha, isha);
        Assert.True(h.Gate.RequestConfirm());                                       // at once
        Assert.Equal(new BlockStateFile.Done(Prayer.Isha, isha), h.DiskState().LastConfirmed);
    }

    [Fact]
    public void theLimitIsThirtyMinutesExactly()
    {
        Assert.Equal(TimeSpan.FromMinutes(30), BlockGate.LateStartLimit);
        using (var h = new Harness(asr.AddSeconds(-3600)))
        {
            h.Clock.Now = asr.AddMinutes(30);
            h.Gate.Reevaluate(ReevalReason.Wake);
            AssertNormal(h, Prayer.Asr, asr.AddMinutes(30));
        }
        using (var h = new Harness(asr.AddSeconds(-3600)))
        {
            h.Clock.Now = asr.AddMinutes(30).AddSeconds(1);
            h.Gate.Reevaluate(ReevalReason.Wake);
            AssertLate(h, Prayer.Asr, asr);
        }
    }

    [Fact]
    public void sleepAcrossIshaTheStaleTimerAndTheWakeGiveALateBlock()
    {
        using var h = new Harness(isha.AddSeconds(-600));
        var s = Make(h);
        s.Rearm();
        Assert.Equal(Scheduler.Armed.ForAthan(Prayer.Isha, isha), s.Current);
        h.Clock.Now = isha.AddHours(2);                  // the PC slept through it
        s.Fire();                                        // the timer comes in late
        s.Handle(ReevalReason.Wake);                     // and the resume event right after
        AssertLate(h, Prayer.Isha, isha);
        s.Stop();
    }

    [Fact]
    public void aLateTimerAloneGivesALateBlock()
    {
        using var h = new Harness(isha.AddHours(2));
        h.Gate.AthanFired(Prayer.Isha, isha);
        AssertLate(h, Prayer.Isha, isha);
    }

    [Fact]
    public void launchTwoHoursAfterAsrGivesALateBlockAndARelaunchKeepsIt()
    {
        using var h = new Harness(asr.AddHours(2));
        h.Relaunch();
        AssertLate(h, Prayer.Asr, asr);
        h.Clock.Now = asr.AddHours(2).AddMinutes(1);
        h.Relaunch();                                    // same late block: still no Athan, still open
        AssertLate(h, Prayer.Asr, asr);
        Assert.Equal(asr.AddHours(2), h.Gate.CurrentBlock?.BlockStartedAt);
    }

    [Fact]
    public void aNormalBlockRelaunchedAfterTheLimitKeepsItsLock()
    {
        using var h = new Harness(asr.AddSeconds(-3600));
        h.Clock.Now = asr.AddMinutes(25);
        h.Gate.Reevaluate(ReevalReason.Wake);
        AssertNormal(h, Prayer.Asr, asr.AddMinutes(25));
        h.Clock.Now = asr.AddMinutes(31);
        h.Relaunch();
        Assert.Empty(h.Audio.Plays);                                                   // a resume never replays
        Assert.Equal(Phase.Locked(asr.AddMinutes(35)), h.Gate.Phase);                  // no free unlock
        Assert.False(h.Gate.RequestConfirm());
        Assert.Equal(600, h.DiskState().CurrentBlock!.LockSeconds);
    }

    [Fact]
    public void theEmergencyExitStillWorksOnALateBlock()
    {
        using var h = new Harness(isha.AddHours(3));
        h.Gate.Reevaluate(ReevalReason.Wake);
        AssertLate(h, Prayer.Isha, isha);
        Assert.True(h.Gate.RequestEmergencyExit());
        Assert.Equal(new BlockStateFile.Done(Prayer.Isha, isha), h.DiskState().LastDropped);
    }

    [Fact]
    public void afterTheWindowClosesNothingHappens()
    {
        using var h = new Harness(isha.AddSeconds(-600));
        h.Clock.Now = FakeSchedule.At(Prayer.Fajr, day: 1).AddSeconds(-60);         // still Isha's window: late block
        h.Gate.Reevaluate(ReevalReason.Wake);
        AssertLate(h, Prayer.Isha, isha);
        using var h2 = new Harness(isha.AddSeconds(-600));
        h2.Clock.Now = FakeSchedule.Sunrise(day: 1).AddSeconds(60);                  // Fajr's window closed too
        h2.Gate.Reevaluate(ReevalReason.Wake);
        Assert.Equal(Phase.Idle, h2.Gate.Phase);
        Assert.Empty(h2.Audio.Plays);
    }
}
