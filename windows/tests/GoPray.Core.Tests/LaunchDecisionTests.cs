// LaunchDecisionTests.cs — the tick + single-instance decision (PM ruling 2026-10-23) and the
// userQuit flag. Windows-only suite: the Mac's SingleInstanceTests cover flock/launchd instead.

using System;
using System.IO;
using System.Threading;
using GoPray.Core;
using Xunit;

namespace GoPray.Core.Tests;

public class LaunchDecisionTests
{
    const string Me = "0:0x1a2b3c";
    const string Earlier = "0:0x99";

    static LaunchFacts F(LaunchKind kind, bool? mutex = true, bool block = false, string? quit = null, string? cur = Me) =>
        new(kind, mutex, block, quit, cur);

    // MARK: the decision table

    [Theory]
    //          kind              mutex  block  quit     → plan
    [InlineData(LaunchKind.ByHand, true, false, null, LaunchPlan.Wire)]
    [InlineData(LaunchKind.ByHand, true, false, Me, LaunchPlan.Wire)]                       // a hand launch always runs
    [InlineData(LaunchKind.ByHand, false, false, null, LaunchPlan.AskHolderToShowAndExit)]
    [InlineData(LaunchKind.ByHand, false, true, null, LaunchPlan.AskHolderToShowAndExit)]
    [InlineData(LaunchKind.Tick, true, false, null, LaunchPlan.Wire)]                       // (b) not quit: come back
    [InlineData(LaunchKind.Tick, true, false, Me, LaunchPlan.ExitQuietly)]                  // quit on purpose this session
    [InlineData(LaunchKind.Tick, true, false, Earlier, LaunchPlan.Wire)]                    // a new logon clears it
    [InlineData(LaunchKind.Tick, true, true, Me, LaunchPlan.Wire)]                          // (a) an open block always resumes
    [InlineData(LaunchKind.Tick, false, true, null, LaunchPlan.ExitQuietly)]                // already running
    [InlineData(LaunchKind.Tick, false, false, Me, LaunchPlan.ExitQuietly)]
    public void decisionTable(LaunchKind kind, bool mutex, bool block, string? quit, LaunchPlan expected) =>
        Assert.Equal(expected, LaunchDecision.Decide(F(kind, mutex, block, quit)));

    [Fact]
    public void aBrokenMutexNeverStopsTheApp()
    {
        Assert.Equal(LaunchPlan.Wire, LaunchDecision.Decide(F(LaunchKind.ByHand, mutex: null)));
        Assert.Equal(LaunchPlan.Wire, LaunchDecision.Decide(F(LaunchKind.Tick, mutex: null)));
        Assert.Equal(LaunchPlan.ExitQuietly, LaunchDecision.Decide(F(LaunchKind.Tick, mutex: null, quit: Me)));
    }

    [Fact]
    public void anUnknownLogonIdRuns()
    {
        Assert.Equal(LaunchPlan.Wire, LaunchDecision.Decide(F(LaunchKind.Tick, quit: Me, cur: null)));
        Assert.Equal(LaunchPlan.Wire, LaunchDecision.Decide(F(LaunchKind.Tick, quit: "", cur: "")));
    }

    [Fact]
    public void clearingTheFlag()
    {
        Assert.True(LaunchDecision.ShouldClearUserQuit(F(LaunchKind.ByHand, quit: Me)));
        Assert.True(LaunchDecision.ShouldClearUserQuit(F(LaunchKind.Tick, quit: Earlier)));
        Assert.False(LaunchDecision.ShouldClearUserQuit(F(LaunchKind.Tick, quit: Me)));
        Assert.False(LaunchDecision.ShouldClearUserQuit(F(LaunchKind.ByHand, quit: null)));
    }

    [Theory]
    [InlineData(new string[0], LaunchKind.ByHand)]
    [InlineData(new[] { "--tick" }, LaunchKind.Tick)]
    [InlineData(new[] { "--debug-seed", "toronto", "--tick" }, LaunchKind.Tick)]
    public void argumentsMapToTheKind(string[] args, LaunchKind kind) => Assert.Equal(kind, LaunchDecision.KindOf(args));

    // MARK: launch.json + the gate's quit rule

    [Fact]
    public void quitIsRecordedOnlyWhenIdleAndReadBack()
    {
        var asr = FakeSchedule.At(Prayer.Asr);
        using var h = new Harness(asr);
        var launch = new LaunchStateStore(h.Dir);
        Assert.Null(launch.ReadUserQuitLogonId());
        launch.RecordUserQuit(Me, h.Gate);
        Assert.Equal(Me, launch.ReadUserQuitLogonId());
        launch.ClearUserQuit();
        Assert.Null(launch.ReadUserQuitLogonId());

        h.Gate.AthanFired(Prayer.Asr, asr);
        Assert.Throws<InvalidOperationException>(() => launch.RecordUserQuit(Me, h.Gate));
        Assert.Null(launch.ReadUserQuitLogonId());
    }

    [Fact]
    public void aTickDuringABlockResumesEvenAfterAQuitFlag()
    {
        // End task mid-block: the flag may be from an earlier idle Quit; the open block wins.
        var asr = FakeSchedule.At(Prayer.Asr);
        using var h = new Harness(asr);
        var launch = new LaunchStateStore(h.Dir);
        launch.RecordUserQuit(Me, h.Gate);
        h.Gate.AthanFired(Prayer.Asr, asr);
        var facts = new LaunchFacts(LaunchKind.Tick, true, new StateStore(h.Dir).PeekHasOpenBlock(), launch.ReadUserQuitLogonId(), Me);
        Assert.Equal(LaunchPlan.Wire, LaunchDecision.Decide(facts));
    }

    [Fact]
    public void aCorruptLaunchFileReadsAsNotQuit()
    {
        var dir = Path.Combine(Path.GetTempPath(), "gopray-launch-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(dir);
            File.WriteAllText(Path.Combine(dir, "launch.json"), "{oops");
            Assert.Null(new LaunchStateStore(dir).ReadUserQuitLogonId());
        }
        finally { Directory.Delete(dir, true); }
    }

    // MARK: the real mutex

    [Fact]
    public void secondCopyDoesNotGetTheMutex()
    {
        var name = @"Local\GoPray.Test." + Guid.NewGuid().ToString("N");
        using var first = new InstanceMutex(name);
        Assert.True(first.Owned);
        bool? second = null;
        var t = new Thread(() => { using var m = new InstanceMutex(name); second = m.Owned; });   // another thread = another owner
        t.Start(); t.Join();
        Assert.False(second);
    }

    [Fact]
    public void theMutexIsFreeAgainAfterTheHolderGoes()
    {
        var name = @"Local\GoPray.Test." + Guid.NewGuid().ToString("N");
        new InstanceMutex(name).Dispose();
        using var again = new InstanceMutex(name);
        Assert.True(again.Owned);
    }

    [Fact]
    public void anAbandonedMutexIsTakenOver()
    {
        // A holder that dies without releasing (End task) leaves the mutex abandoned: the next copy owns it.
        var name = @"Local\GoPray.Test." + Guid.NewGuid().ToString("N");
        var t = new Thread(() => { _ = new Mutex(true, name); });   // thread exits still owning it
        t.Start(); t.Join();
        using var next = new InstanceMutex(name);
        Assert.True(next.Owned);
    }
}
