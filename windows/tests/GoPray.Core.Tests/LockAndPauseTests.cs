// LockAndPauseTests.cs — lockMinutes (10–30, captured at block start) and pause (1 day / 3 days /
// 1 week / until resumed), plus "first setup and resume never block the open window".
// Port of GoPrayTests/Core/LockAndPauseTests.swift.

using System;
using System.IO;
using GoPray.Core;
using Xunit;

namespace GoPray.Core.Tests;

public class LockAndPauseTests
{
    readonly DateTime asr = FakeSchedule.At(Prayer.Asr);
    readonly DateTime maghrib = FakeSchedule.At(Prayer.Maghrib);

    static Scheduler MakeScheduler(Harness h) =>
        new(h.Clock, h.Schedule, h.Gate, () => h.Settings, () => TimeZoneInfo.Utc, new ManualTimers());

    // MARK: lockMinutes

    [Fact]
    public void lockPolicyClamps()
    {
        Assert.Equal(10, LockPolicy.MinMinutes);
        Assert.Equal(30, LockPolicy.MaxMinutes);
        Assert.Equal(10, LockPolicy.DefaultMinutes);
        Assert.Equal(10, LockPolicy.Clamp(0));
        Assert.Equal(10, LockPolicy.Clamp(5));
        Assert.Equal(15, LockPolicy.Clamp(15));
        Assert.Equal(30, LockPolicy.Clamp(45));
        Assert.Equal(1800, LockPolicy.SecondsForMinutes(99));
    }

    [Fact]
    public void blockUsesSettingsLockLength()
    {
        using var h = new Harness(asr, TestSettings.Test(lockMinutes: 20));
        h.Gate.AthanFired(Prayer.Asr, asr);
        Assert.Equal(Phase.Locked(asr.AddSeconds(1200)), h.Gate.Phase);
        Assert.Equal(1_200_000, h.Shield.Shows[0].RemainingMs);
        Assert.Equal(1200, h.DiskState().CurrentBlock?.LockSeconds);
    }

    [Theory]
    [InlineData(3, 600.0)]
    [InlineData(99, 1800.0)]
    public void outOfRangeLockMinutesAreClamped(int minutes, double expected)
    {
        using var h = new Harness(asr, TestSettings.Test(lockMinutes: minutes));
        h.Gate.AthanFired(Prayer.Asr, asr);
        Assert.Equal(Phase.Locked(asr.AddSeconds(expected)), h.Gate.Phase);
    }

    [Fact]
    public void capturedLockSurvivesRelaunchWithDifferentSettings()
    {
        using var h = new Harness(asr, TestSettings.Test(lockMinutes: 20));
        h.Gate.AthanFired(Prayer.Asr, asr);
        h.Settings = TestSettings.Test(lockMinutes: 10);    // changed behind the store's back
        h.Clock.Now = asr.AddSeconds(700);
        h.Relaunch();
        Assert.Equal(Phase.Locked(asr.AddSeconds(1200)), h.Gate.Phase);
        Assert.False(h.Gate.RequestConfirm());
        h.Clock.Now = asr.AddSeconds(1200);
        Assert.True(h.Gate.RequestConfirm());
    }

    [Fact]
    public void lockMinutesChangeMidBlockIsRefusedAndNeverMovesTheLock()
    {
        using var h = new Harness(asr, TestSettings.Test(lockMinutes: 30));
        h.Gate.AthanFired(Prayer.Asr, asr);
        Assert.Throws<SettingsBlockedException>(() => h.Gate.AuthorizeSettingsChange());
        // Even if a change slips past the store, the running block keeps its own lock.
        h.Settings = TestSettings.Test(lockMinutes: 10);
        h.Clock.Now = asr.AddSeconds(601);
        h.Gate.Reevaluate(ReevalReason.SettingsChanged);
        Assert.Equal(Phase.Locked(asr.AddSeconds(1800)), h.Gate.Phase);   // not shortened
        Assert.False(h.Gate.RequestConfirm());
    }

    [Fact]
    public void raisingLockMidBlockDoesNotExtendIt()
    {
        using var h = new Harness(asr, TestSettings.Test(lockMinutes: 10));
        h.Gate.AthanFired(Prayer.Asr, asr);
        h.Settings = TestSettings.Test(lockMinutes: 30);
        h.Clock.Now = asr.AddSeconds(600);
        h.Gate.Reevaluate(ReevalReason.SettingsChanged);
        Assert.Equal(Phase.CanConfirm, h.Gate.Phase);
        Assert.True(h.Gate.RequestConfirm());
    }

    [Fact]
    public void tamperedHugeLockIsCappedAtThirtyMinutes()
    {
        using var h = new Harness(asr.AddSeconds(1800));
        var tampered = new BlockStateFile
        {
            CurrentBlock = new BlockStateFile.Block
            {
                Prayer = Prayer.Asr, AthanAt = asr, BlockStartedAt = asr, Silenced = false, AthanPlayed = true, LockSeconds = 1_000_000,
            },
        };
        new StateStore(h.Dir).Save(tampered);
        h.Relaunch();
        Assert.Equal(Phase.CanConfirm, h.Gate.Phase);
        Assert.True(h.Gate.RequestConfirm());
    }

    [Fact]
    public void fileWithoutLockSecondsUsesTheDefault()
    {
        using var h = new Harness(asr.AddSeconds(60));
        Directory.CreateDirectory(h.Dir);
        const string json = """
        {"schemaVersion": 1, "block": {"prayer": "asr", "athanAt": "2026-10-22T15:30:00Z",
         "blockStartedAt": "2026-10-22T15:30:00Z", "silenced": false, "athanPlayed": true}, "launches": []}
        """;
        File.WriteAllText(h.StateFile, json);
        h.Relaunch();
        Assert.Equal(Phase.Locked(asr.AddSeconds(600)), h.Gate.Phase);
    }

    // MARK: pause

    [Fact]
    public void pauseOptions()
    {
        var now = asr;
        var utc = TimeZoneInfo.Utc;
        Assert.Equal(now.AddSeconds(86_400), PauseOption.OneDay.Until(now, utc));
        Assert.Equal(now.AddSeconds(3 * 86_400), PauseOption.ThreeDays.Until(now, utc));
        Assert.Equal(now.AddSeconds(7 * 86_400), PauseOption.OneWeek.Until(now, utc));
        Assert.Equal(DateTimes.DistantFuture, PauseOption.UntilResumed.Until(now, utc));
        Assert.Equal(4, PauseOptions.All.Length);
    }

    [Fact]
    public void pauseSkipsAthansAndTheWakeRule()
    {
        using var h = new Harness(asr.AddSeconds(-60), TestSettings.Test(pausedUntil: DateTimes.DistantFuture));
        h.Clock.Now = asr;
        h.Gate.AthanFired(Prayer.Asr, asr);
        Assert.Equal(Phase.Idle, h.Gate.Phase);
        h.Clock.Now = asr.AddSeconds(600);
        h.Gate.Reevaluate(ReevalReason.Wake);
        h.Gate.Reevaluate(ReevalReason.Launch);
        Assert.Equal(Phase.Idle, h.Gate.Phase);
        Assert.Empty(h.Shield.Shows);
        Assert.Empty(h.Audio.Plays);
    }

    [Fact]
    public void pausedSchedulerArmsNoAthan()
    {
        using var h = new Harness(asr.AddSeconds(-3600), TestSettings.Test(pausedUntil: DateTimes.DistantFuture));
        var s = MakeScheduler(h);
        s.Rearm();
        Assert.Equal(Scheduler.ArmedKind.Midnight, s.Current?.Kind);
        s.Stop();
    }

    [Fact]
    public void pauseExpiresThenNextAthanBlocksButNotTheOpenWindow()
    {
        // Pause ends at Asr + 30 min, inside Asr's window.
        var until = asr.AddSeconds(1800);
        using var h = new Harness(asr.AddSeconds(-3600), TestSettings.Test(pausedUntil: until));
        var s = MakeScheduler(h);
        s.Rearm();
        Assert.Equal(Scheduler.Armed.ForPauseEnd(until), s.Current);   // Asr is not armed
        h.Clock.Now = until;
        s.Fire();                                                    // → Reevaluate(PauseEnded)
        Assert.Equal(Phase.Idle, h.Gate.Phase);                      // open Asr window is not blocked
        Assert.Equal(Scheduler.Armed.ForAthan(Prayer.Maghrib, maghrib), s.Current);
        h.Clock.Now = maghrib;
        s.Fire();
        Assert.Equal(Prayer.Maghrib, h.Gate.CurrentBlock?.Prayer);
        s.Stop();
    }

    [Fact]
    public void pauseThatRanOutWhileAppWasDownDoesNotBlockTheOpenWindow()
    {
        var until = asr.AddSeconds(1800);
        using var h = new Harness(asr.AddSeconds(2400), TestSettings.Test(pausedUntil: until));
        h.Relaunch();                                                // relaunch after expiry, Asr still open
        Assert.Equal(Phase.Idle, h.Gate.Phase);
        h.Clock.Now = maghrib;
        h.Gate.AthanFired(Prayer.Maghrib, maghrib);
        Assert.Equal(Prayer.Maghrib, h.Gate.CurrentBlock?.Prayer);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void resumeNeverBlocksTheOpenWindow(bool resumeWithNil)
    {
        using var h = new Harness(asr.AddSeconds(-3600), TestSettings.Test(pausedUntil: DateTimes.DistantFuture));
        h.Clock.Now = asr.AddSeconds(120);
        h.Gate.Reevaluate(ReevalReason.Wake);
        Assert.Equal(Phase.Idle, h.Gate.Phase);
        // Resume: PausedUntil = now (preferred) or null.
        h.Settings = TestSettings.Test(pausedUntil: resumeWithNil ? null : h.Clock.Now);
        h.Gate.Reevaluate(ReevalReason.SettingsChanged);
        Assert.Equal(Phase.Idle, h.Gate.Phase);
        h.Gate.Reevaluate(ReevalReason.Wake);
        Assert.Equal(Phase.Idle, h.Gate.Phase);
        h.Clock.Now = maghrib;
        h.Gate.AthanFired(Prayer.Maghrib, maghrib);
        Assert.Equal(Prayer.Maghrib, h.Gate.CurrentBlock?.Prayer);
    }

    [Fact]
    public void pauseRefusedMidBlockAndCannotEndIt()
    {
        using var h = new Harness(asr);
        h.Gate.AthanFired(Prayer.Asr, asr);
        Assert.Throws<SettingsBlockedException>(() => h.Gate.AuthorizeSettingsChange());
        // A pause that slips past the store neither ends nor shortens the block.
        h.Settings = TestSettings.Test(pausedUntil: DateTimes.DistantFuture);
        h.Clock.Now = asr.AddSeconds(60);
        h.Gate.Reevaluate(ReevalReason.SettingsChanged);
        Assert.Equal(Phase.Locked(asr.AddSeconds(600)), h.Gate.Phase);
        Assert.False(h.Gate.RequestConfirm());
        Assert.Equal(0, h.Shield.TearDownCount);
    }

    [Fact]
    public void settingsChangesAllowedBetweenPrayers()
    {
        using var h = new Harness(asr);
        h.Gate.AuthorizeSettingsChange();
        h.Gate.AthanFired(Prayer.Asr, asr);
        h.Clock.Now = asr.AddSeconds(600);
        Assert.True(h.Gate.RequestConfirm());
        h.Gate.AuthorizeSettingsChange();
    }

    // MARK: first setup (PM ruling a)

    [Fact]
    public void finishingSetupInsideAnOpenWindowDoesNotBlockIt()
    {
        using var h = new Harness(asr.AddSeconds(-3600), TestSettings.Test(setupComplete: false));
        h.Clock.Now = asr.AddSeconds(120);
        h.Settings = TestSettings.Test(setupComplete: true);
        h.Gate.Reevaluate(ReevalReason.SettingsChanged);
        Assert.Equal(Phase.Idle, h.Gate.Phase);
        Assert.Equal(new BlockStateFile.Done(Prayer.Asr, asr), h.DiskState().LastDropped);
        h.Gate.Reevaluate(ReevalReason.Wake);
        Assert.Equal(Phase.Idle, h.Gate.Phase);
        h.Clock.Now = maghrib;
        h.Gate.AthanFired(Prayer.Maghrib, maghrib);
        Assert.Equal(Prayer.Maghrib, h.Gate.CurrentBlock?.Prayer);
    }
}
