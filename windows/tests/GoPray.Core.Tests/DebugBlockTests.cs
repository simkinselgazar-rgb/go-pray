// DebugBlockTests.cs — DEBUG "Trigger Athan now" blocks resume after a relaunch.
// Port of GoPrayTests/Core/DebugBlockTests.swift. They carry a synthetic window (athan = trigger
// time, end = +1 h) in state.json, so the gate's normal resume rule matches them.

#if DEBUG
using System;
using System.IO;
using GoPray.Core;
using Xunit;

namespace GoPray.Core.Tests;

public class DebugBlockTests
{
    /// <summary>09:00 in FakeSchedule: after sunrise, before Dhuhr. No real window is open.</summary>
    readonly DateTime nine = FakeSchedule.Day0.AddSeconds(9 * 3600);

    [Fact]
    public void aDebugBlockSurvivesARelaunchWithItsOriginalStart()
    {
        using var h = new Harness(nine);
        h.Gate.DebugTriggerAthan(Prayer.Dhuhr, lockSeconds: 20);
        Assert.Equal(nine.AddSeconds(3600), h.DiskState().CurrentBlock?.DebugWindowEnd);

        h.Clock.Now = nine.AddSeconds(5);
        h.Relaunch();
        Assert.Equal(Phase.Locked(nine.AddSeconds(20)), h.Gate.Phase);
        Assert.Equal(nine, h.Gate.CurrentBlock?.BlockStartedAt);
        Assert.Single(h.Shield.Shows);
        Assert.Equal(15_000, h.Shield.Shows[0].RemainingMs);
        Assert.Empty(h.Audio.Plays);                // no replay
        Assert.False(h.Gate.RequestConfirm());
        h.Clock.Now = nine.AddSeconds(20);
        Assert.True(h.Gate.RequestConfirm());
    }

    [Fact]
    public void withoutTheSyntheticWindowItFailsOpenAsBefore()
    {
        using var h = new Harness(nine);
        h.Gate.DebugTriggerAthan(Prayer.Dhuhr, lockSeconds: 20);
        var s = h.DiskState();
        s = s with { CurrentBlock = s.CurrentBlock! with { DebugWindowEnd = null } };   // negative control: the old file shape
        File.WriteAllBytes(h.StateFile, s.Encode());
        h.Clock.Now = nine.AddSeconds(5);
        h.Relaunch();
        Assert.Equal(Phase.Idle, h.Gate.Phase);
    }

    [Fact]
    public void theSyntheticWindowEndsAfterAnHour()
    {
        using var h = new Harness(nine);
        h.Gate.DebugTriggerAthan(Prayer.Dhuhr, lockSeconds: 20);
        h.Clock.Now = nine.AddSeconds(3601);
        h.Relaunch();
        Assert.Equal(Phase.Idle, h.Gate.Phase);
    }
}
#endif
