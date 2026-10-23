// BlockGateTests.cs — §E PM tests 1–5, 7–9 plus the fail-open rules of §G.
// Port of GoPrayTests/Core/BlockGateTests.swift: same test names, same cases, same expectations.
// All against FakeClock + a temp state directory. Lock = 600 s unless stated.

using System;
using System.IO;
using System.Linq;
using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Threading.Tasks;
using GoPray.Core;
using Xunit;

namespace GoPray.Core.Tests;

public class BlockGateTests
{
    readonly DateTime asr = FakeSchedule.At(Prayer.Asr);
    readonly DateTime maghrib = FakeSchedule.At(Prayer.Maghrib);

    // MARK: E.1 normal flow + the 10-minute lock

    [Fact]
    public void athanLocksForTenMinutesThenConfirmEndsBlock()
    {
        using var h = new Harness(asr);
        h.Gate.AthanFired(Prayer.Asr, asr);

        Assert.Equal(Phase.Locked(asr.AddSeconds(600)), h.Gate.Phase);
        Assert.Single(h.Shield.Shows);
        Assert.Equal(600_000, h.Shield.Shows[0].RemainingMs);
        Assert.Single(h.Audio.Plays);
        Assert.Equal(Prayer.Asr, h.Audio.Plays[0].Prayer);
        var onDisk = h.DiskState();
        Assert.Equal(asr, onDisk.CurrentBlock?.BlockStartedAt);
        Assert.True(onDisk.CurrentBlock?.AthanPlayed);

        h.Clock.Now = asr.AddSeconds(599);
        Assert.False(h.Gate.RequestConfirm());
        Assert.NotNull(h.DiskState().CurrentBlock);

        h.Clock.Now = asr.AddSeconds(600);
        Assert.Equal(Phase.CanConfirm, h.Gate.Phase);
        Assert.True(h.Gate.RequestConfirm());
        var after = h.DiskState();
        Assert.Null(after.CurrentBlock);
        Assert.Equal(new BlockStateFile.Done(Prayer.Asr, asr), after.LastConfirmed);
        Assert.Equal(1, h.Shield.DismissCount);
        Assert.Equal(0, h.Shield.TearDownCount);
        Assert.Equal(Phase.Idle, h.Gate.Phase);
        Assert.Equal(0, h.Hider.StartCount);      // whole-screen mode never hides apps
    }

    [Fact]
    public void leavingPhaseHoldsUntilDismissCompletes()
    {
        using var h = new Harness(asr);
        h.Shield.AutoCompleteDismiss = false;
        h.Gate.AthanFired(Prayer.Asr, asr);
        h.Clock.Now = asr.AddSeconds(600);
        Assert.True(h.Gate.RequestConfirm());
        Assert.Equal(Phase.Leaving, h.Gate.Phase);
        Assert.False(h.Gate.ShouldAllowQuit());
        h.Shield.PendingDismiss?.Invoke();
        Assert.Equal(Phase.Idle, h.Gate.Phase);
        Assert.True(h.Gate.ShouldAllowQuit());
    }

    [Fact]
    public async Task dismissThatNeverCallsBackFailsOpen()
    {
        using var h = new Harness(asr);
        h.Shield.AutoCompleteDismiss = false;
        h.Gate.AthanFired(Prayer.Asr, asr);
        h.Clock.Now = asr.AddSeconds(600);
        Assert.True(h.Gate.RequestConfirm());
        Assert.Equal(Phase.Leaving, h.Gate.Phase);
        await Task.Delay(600);                     // harness leavingTimeout = 200 ms
        Assert.Equal(Phase.Idle, h.Gate.Phase);
        Assert.Equal(1, h.Shield.TearDownCount);
    }

    // MARK: E.2 relaunch mid-block

    [Fact]
    public void relaunchMidBlockResumesOriginalStartWithoutReplay()
    {
        using var h = new Harness(asr);
        h.Gate.AthanFired(Prayer.Asr, asr);
        h.Clock.Now = asr.AddSeconds(300);
        h.Relaunch();

        Assert.Equal(Phase.Locked(asr.AddSeconds(600)), h.Gate.Phase);
        Assert.Equal(asr, h.Gate.CurrentBlock?.BlockStartedAt);
        Assert.Empty(h.Audio.Plays);               // athanPlayed: no replay
        Assert.Single(h.Shield.Shows);
        Assert.Equal(300_000, h.Shield.Shows[0].RemainingMs);
        Assert.False(h.Gate.RequestConfirm());
        h.Clock.Now = asr.AddSeconds(600);
        Assert.True(h.Gate.RequestConfirm());
    }

    [Fact]
    public void relaunchInCodingModeHidesAgain()
    {
        using var h = new Harness(asr, TestSettings.Test(mode: BlockMode.CodingApps));
        h.Gate.AthanFired(Prayer.Asr, asr);
        Assert.Equal(1, h.Hider.StartCount);
        h.Clock.Now = asr.AddSeconds(60);
        h.Relaunch();
        Assert.Equal(1, h.Hider.StartCount);
        Assert.Equal(BlockMode.CodingApps, h.Shield.Shows.FirstOrDefault()?.Mode);
    }

    // MARK: E.3 sleep / wake

    [Fact]
    public void wakeInsideWindowStartsBlockAtWake()
    {
        using var h = new Harness(asr.AddSeconds(-60));
        var wake = asr.AddSeconds(20 * 60);
        h.Clock.Now = wake;                        // asleep through the Athan
        h.Gate.Reevaluate(ReevalReason.Wake);
        Assert.Equal(Prayer.Asr, h.Gate.CurrentBlock?.Prayer);
        Assert.Equal(asr, h.Gate.CurrentBlock?.AthanAt);
        Assert.Equal(wake, h.Gate.CurrentBlock?.BlockStartedAt);
        Assert.Equal(Phase.Locked(wake.AddSeconds(600)), h.Gate.Phase);
        Assert.Single(h.Audio.Plays);
    }

    [Fact]
    public void wakeAfterSunriseMissesFajr()
    {
        var fajr = FakeSchedule.At(Prayer.Fajr);
        using var h = new Harness(fajr.AddSeconds(-3600));
        h.Clock.Now = FakeSchedule.Sunrise().AddSeconds(60);
        h.Gate.Reevaluate(ReevalReason.Wake);
        Assert.Equal(Phase.Idle, h.Gate.Phase);
        Assert.Empty(h.Shield.Shows);
        Assert.Empty(h.Audio.Plays);
    }

    [Fact]
    public void wakeBeforeSunriseBlocksFajr()
    {
        var fajr = FakeSchedule.At(Prayer.Fajr);
        using var h = new Harness(fajr.AddSeconds(-3600));
        h.Clock.Now = FakeSchedule.Sunrise().AddSeconds(-60);
        h.Gate.Reevaluate(ReevalReason.Wake);
        Assert.Equal(Prayer.Fajr, h.Gate.CurrentBlock?.Prayer);
    }

    [Fact]
    public void wakeAfterNextAthanMissesOldPrayerAndBlocksTheCurrentOne()
    {
        var dhuhr = FakeSchedule.At(Prayer.Dhuhr);
        using var h = new Harness(dhuhr);
        h.Gate.AthanFired(Prayer.Dhuhr, dhuhr);
        h.Clock.Now = dhuhr.AddSeconds(600);
        Assert.True(h.Gate.RequestConfirm());
        // Asleep through Asr, wake after Maghrib.
        var wake = maghrib.AddSeconds(5 * 60);
        h.Clock.Now = wake;
        h.Gate.Reevaluate(ReevalReason.Wake);
        Assert.Equal(Prayer.Maghrib, h.Gate.CurrentBlock?.Prayer);   // Asr missed: never blocked
        Assert.Equal(wake, h.Gate.CurrentBlock?.BlockStartedAt);
        Assert.Equal(new BlockStateFile.Done(Prayer.Dhuhr, dhuhr), h.DiskState().LastConfirmed);
    }

    [Fact]
    public void sleepDuringBlockCountsTowardTheLock()
    {
        using var h = new Harness(asr);
        h.Gate.AthanFired(Prayer.Asr, asr);
        h.Clock.Now = asr.AddSeconds(15 * 60);     // lid closed 15 min
        h.Gate.Reevaluate(ReevalReason.Wake);
        Assert.Equal(Phase.CanConfirm, h.Gate.Phase);
        Assert.Equal(asr, h.Gate.CurrentBlock?.BlockStartedAt);
        Assert.Single(h.Shield.Shows);             // same block, re-synced
        Assert.Equal(0, h.Shield.Updates.Last().RemainingMs);
        Assert.True(h.Gate.RequestConfirm());
    }

    [Fact]
    public void wakeAfterBlockWindowClosedDropsItAndBlocksTheNewPrayer()
    {
        using var h = new Harness(asr);
        h.Gate.AthanFired(Prayer.Asr, asr);
        var wake = maghrib.AddSeconds(60);
        h.Clock.Now = wake;
        h.Gate.Reevaluate(ReevalReason.Wake);
        Assert.Equal(1, h.Shield.TearDownCount);
        Assert.Equal(Prayer.Maghrib, h.Gate.CurrentBlock?.Prayer);
        Assert.Equal(wake, h.Gate.CurrentBlock?.BlockStartedAt);
        Assert.Null(h.DiskState().LastConfirmed);
    }

    // MARK: E.4 overlap

    [Fact]
    public void nextAthanDuringBlockReplacesIt()
    {
        using var h = new Harness(asr);
        h.Gate.AthanFired(Prayer.Asr, asr);
        h.Clock.Now = maghrib;
        h.Gate.AthanFired(Prayer.Maghrib, maghrib);
        Assert.Equal(1, h.Shield.TearDownCount);
        Assert.Equal(2, h.Shield.Shows.Count);
        Assert.Equal(Prayer.Maghrib, h.Gate.CurrentBlock?.Prayer);
        Assert.Equal(maghrib, h.Gate.CurrentBlock?.BlockStartedAt);
        Assert.Equal(Phase.Locked(maghrib.AddSeconds(600)), h.Gate.Phase);
        Assert.Equal(Prayer.Maghrib, h.DiskState().CurrentBlock?.Prayer);
    }

    [Fact]
    public void duplicateAthanFireIsIgnored()
    {
        using var h = new Harness(asr);
        h.Gate.AthanFired(Prayer.Asr, asr);
        h.Clock.Now = asr.AddSeconds(5);
        h.Gate.AthanFired(Prayer.Asr, asr);
        Assert.Single(h.Shield.Shows);
        Assert.Equal(0, h.Shield.TearDownCount);
        Assert.Equal(asr, h.Gate.CurrentBlock?.BlockStartedAt);
    }

    // MARK: E.5 clock jumps

    [Fact]
    public void clockForwardMidLockOpensTheButton()
    {
        using var h = new Harness(asr);
        h.Gate.AthanFired(Prayer.Asr, asr);
        h.Clock.Now = asr.AddSeconds(120 + 3600);
        h.Gate.Reevaluate(ReevalReason.ClockChanged);
        Assert.Equal(Phase.CanConfirm, h.Gate.Phase);
        Assert.True(h.Gate.RequestConfirm());
    }

    [Fact]
    public void clockBackMidLockOpensTheButton()
    {
        using var h = new Harness(asr);
        h.Gate.AthanFired(Prayer.Asr, asr);
        h.Clock.Now = asr.AddSeconds(120 - 3600);  // before blockStartedAt
        h.Gate.Reevaluate(ReevalReason.ClockChanged);
        Assert.Equal(Phase.CanConfirm, h.Gate.Phase);   // clamp: never locked for an hour
        Assert.Equal(Prayer.Asr, h.Gate.CurrentBlock?.Prayer);
        Assert.True(h.Gate.RequestConfirm());
    }

    [Fact]
    public void clockBackBeforeConfirmedAthanDoesNotBlockAgain()
    {
        using var h = new Harness(asr);
        h.Gate.AthanFired(Prayer.Asr, asr);
        h.Clock.Now = asr.AddSeconds(600);
        Assert.True(h.Gate.RequestConfirm());
        h.Clock.Now = FakeSchedule.At(Prayer.Dhuhr).AddSeconds(30 * 60);   // back into Dhuhr
        h.Gate.Reevaluate(ReevalReason.ClockChanged);
        Assert.Equal(Phase.Idle, h.Gate.Phase);
        h.Clock.Now = asr;                          // the Athan "fires" again
        h.Gate.AthanFired(Prayer.Asr, asr);
        Assert.Equal(Phase.Idle, h.Gate.Phase);
        Assert.Single(h.Shield.Shows);
    }

    // MARK: E.7 corrupt state.json

    [Theory]
    [InlineData("{\"schemaVersion\": 1, \"block\": {\"prayer\": \"asr\", \"athanAt\": \"2026-10-22T15:3")]   // truncated
    [InlineData("{\"schemaVersion\": 2, \"block\": null, \"launches\": []}")]                                  // wrong version
    [InlineData("{\"schemaVersion\": 1, \"block\": {\"prayer\": \"zuhr\", \"athanAt\": \"2026-10-22T15:30:00Z\", \"blockStartedAt\": \"2026-10-22T15:30:00Z\", \"silenced\": false, \"athanPlayed\": true}}")]
    [InlineData("not json at all")]
    public void corruptFileFailsOpen(string contents)
    {
        using var h = new Harness(asr.AddSeconds(120));
        Directory.CreateDirectory(h.Dir);
        File.WriteAllText(h.StateFile, contents);
        h.Relaunch();
        Assert.Equal(Phase.Idle, h.Gate.Phase);    // even inside an open, unconfirmed window
        Assert.Empty(h.Shield.Shows);
        Assert.Single(h.CorruptFiles());
        var fresh = h.DiskState();                 // a clean file replaced it
        Assert.Null(fresh.CurrentBlock);
        Assert.Equal(Prayer.Asr, fresh.LastDropped?.Prayer);
    }

    [Fact]
    public void blockStartedIn2099FailsOpen()
    {
        using var h = new Harness(asr.AddSeconds(120));
        var future = new DateTime(2099, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        var tampered = new BlockStateFile
        {
            CurrentBlock = new BlockStateFile.Block { Prayer = Prayer.Asr, AthanAt = asr, BlockStartedAt = future, Silenced = false, AthanPlayed = true },
        };
        new StateStore(h.Dir).Save(tampered);
        h.Relaunch();
        Assert.Equal(Phase.Idle, h.Gate.Phase);
        Assert.Empty(h.Shield.Shows);
        Assert.Single(h.CorruptFiles());
        Assert.Null(h.DiskState().CurrentBlock);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void farFutureDoneDateIsQuarantinedAndLaterPrayersStillBlock(bool confirmed)
    {
        using var h = new Harness(asr.AddSeconds(120));
        var future = new DateTime(2099, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        var done = new BlockStateFile.Done(Prayer.Asr, future);
        new StateStore(h.Dir).Save(new BlockStateFile { LastConfirmed = confirmed ? done : null, LastDropped = confirmed ? null : done });
        h.Relaunch();
        Assert.Single(h.CorruptFiles());
        Assert.Equal(Phase.Idle, h.Gate.Phase);    // quarantine fails open on the open window
        h.Clock.Now = maghrib;
        h.Gate.AthanFired(Prayer.Maghrib, maghrib);
        Assert.Equal(Prayer.Maghrib, h.Gate.CurrentBlock?.Prayer);   // and the next prayer is not silently skipped
    }

    [Fact]
    public void missingFileIsAFreshStartAndRunsTheWakeRule()
    {
        // No file = first run. Not corrupt, so nothing is dropped: the open, unconfirmed window
        // blocks (plan §3 wake rule; CONTRACT-NOTES #7).
        var at = asr.AddSeconds(-60);               // inside Dhuhr's window
        using var h = new Harness(at);
        h.Relaunch();
        Assert.Empty(h.CorruptFiles());
        Assert.Equal(Prayer.Dhuhr, h.Gate.CurrentBlock?.Prayer);
        Assert.Equal(at, h.Gate.CurrentBlock?.BlockStartedAt);
    }

    /// <summary>Windows form of the Mac's 0600 check: no temp file left behind, and the file grants
    /// nothing to Everyone / Users / Authenticated Users (it inherits the per-user folder ACL).</summary>
    [Fact]
    public void stateFileIsOwnerOnly()
    {
        using var h = new Harness(asr);
        h.Gate.AthanFired(Prayer.Asr, asr);
        Assert.Empty(Directory.GetFiles(h.Dir, "*.tmp"));
        if (OperatingSystem.IsWindows()) Assert.Equal(0, BroadAllowRules(h.StateFile));
    }

    [SupportedOSPlatform("windows")]
    static int BroadAllowRules(string path)
    {
        var broad = new[] { WellKnownSidType.WorldSid, WellKnownSidType.BuiltinUsersSid, WellKnownSidType.AuthenticatedUserSid }
            .Select(t => new SecurityIdentifier(t, null)).ToHashSet();
        int n = 0;
        foreach (FileSystemAccessRule r in new FileInfo(path).GetAccessControl().GetAccessRules(true, true, typeof(SecurityIdentifier)))
            if (r.AccessControlType == AccessControlType.Allow && broad.Contains((SecurityIdentifier)r.IdentityReference)) n++;
        return n;
    }

    // MARK: E.8 crash loop

    [Fact]
    public void threeLaunchesInTwoMinutesWhileBlockedFailOpen()
    {
        using var h = new Harness(asr);
        h.Gate.AthanFired(Prayer.Asr, asr);
        h.Clock.Now = asr.AddSeconds(10); h.Relaunch();
        Assert.True(h.Gate.IsBlocked);
        h.Clock.Now = asr.AddSeconds(20); h.Relaunch();
        Assert.True(h.Gate.IsBlocked);
        Assert.Equal(2, h.DiskState().Launches.Count);
        h.Clock.Now = asr.AddSeconds(30); h.Relaunch();
        Assert.Equal(Phase.Idle, h.Gate.Phase);
        Assert.Empty(h.Shield.Shows);
        var s = h.DiskState();
        Assert.Null(s.CurrentBlock);
        Assert.Empty(s.Launches);
        Assert.Equal(new BlockStateFile.Done(Prayer.Asr, asr), s.LastDropped);
        // That prayer stays given up; the next one works normally.
        h.Clock.Now = asr.AddSeconds(60); h.Relaunch();
        Assert.Equal(Phase.Idle, h.Gate.Phase);
        h.Clock.Now = maghrib;
        h.Gate.AthanFired(Prayer.Maghrib, maghrib);
        Assert.Equal(Prayer.Maghrib, h.Gate.CurrentBlock?.Prayer);
    }

    [Fact]
    public void launchesSpreadOverMoreThanTwoMinutesKeepTheBlock()
    {
        using var h = new Harness(asr);
        h.Gate.AthanFired(Prayer.Asr, asr);
        foreach (var t in new[] { 10.0, 140, 270 }) { h.Clock.Now = asr.AddSeconds(t); h.Relaunch(); }
        Assert.True(h.Gate.IsBlocked);
        Assert.Equal(asr, h.Gate.CurrentBlock?.BlockStartedAt);
    }

    // MARK: E.9 quit + settings

    [Fact]
    public void quitAndSettingsRefusedWhileBlocked()
    {
        using var h = new Harness(asr);
        Assert.True(h.Gate.ShouldAllowQuit());
        Assert.True(h.Gate.AllowsSettingsChange());
        h.Gate.AthanFired(Prayer.Asr, asr);
        Assert.False(h.Gate.ShouldAllowQuit());
        Assert.False(h.Gate.AllowsSettingsChange());
        h.Clock.Now = asr.AddSeconds(600);
        Assert.False(h.Gate.ShouldAllowQuit());   // canConfirm is still blocked
        Assert.False(h.Gate.AllowsSettingsChange());
        Assert.True(h.Gate.RequestConfirm());
        Assert.True(h.Gate.ShouldAllowQuit());
        Assert.True(h.Gate.AllowsSettingsChange());
    }

    // MARK: prayed refused while locked (bridge `prayed` → ShieldDidRequestConfirm)

    [Fact]
    public void prayedWhileLockedIsRefusedAndResyncs()
    {
        using var h = new Harness(asr);
        h.Gate.AthanFired(Prayer.Asr, asr);
        h.Clock.Now = asr.AddSeconds(100);
        h.Gate.ShieldDidRequestConfirm();
        Assert.True(h.Gate.IsBlocked);
        Assert.NotNull(h.Gate.CurrentBlock);
        Assert.Equal(0, h.Shield.DismissCount);
        Assert.Equal(500_000, h.Shield.Updates.Last().RemainingMs);
        h.Clock.Now = asr.AddSeconds(600);
        h.Gate.ShieldDidRequestConfirm();
        Assert.Equal(1, h.Shield.DismissCount);
    }

    [Fact]
    public void confirmWhenIdleIsRefused()
    {
        using var h = new Harness(asr);
        Assert.False(h.Gate.RequestConfirm());
        Assert.Equal(0, h.Shield.DismissCount);
    }

    // MARK: silence

    [Fact]
    public void silenceStopsSoundOnlyAndSurvivesRelaunch()
    {
        using var h = new Harness(asr);
        h.Gate.AthanFired(Prayer.Asr, asr);
        Assert.True(h.Shield.Shows[0].AthanRemainingMs > 0);
        h.Gate.ShieldDidRequestSilence();
        Assert.False(h.Audio.IsPlaying);
        Assert.True(h.Gate.IsBlocked);
        Assert.Equal(Phase.Locked(asr.AddSeconds(600)), h.Gate.Phase);
        Assert.Equal(0, h.Shield.Updates.Last().AthanRemainingMs);
        Assert.True(h.DiskState().CurrentBlock?.Silenced);
        h.Clock.Now = asr.AddSeconds(30); h.Relaunch();
        Assert.Empty(h.Audio.Plays);
    }

    [Fact]
    public void athanFinishingUpdatesTheShield()
    {
        using var h = new Harness(asr);
        h.Gate.AthanFired(Prayer.Asr, asr);
        h.Audio.Finish();
        Assert.Equal(0, h.Shield.Updates.Last().AthanRemainingMs);
        Assert.True(h.Gate.IsBlocked);
    }

    [Fact]
    public void audioFailureStillBlocks()
    {
        using var h = new Harness(asr);
        h.Audio.ThrowOnPlay = true;
        h.Gate.AthanFired(Prayer.Asr, asr);
        Assert.True(h.Gate.IsBlocked);
        Assert.Single(h.Shield.Shows);
    }

    // MARK: coding-apps mode

    [Fact]
    public void codingModeHidesForTheBlockAndNamesTheApp()
    {
        using var h = new Harness(asr, TestSettings.Test(mode: BlockMode.CodingApps));
        h.Gate.AthanFired(Prayer.Asr, asr);
        Assert.Equal(1, h.Hider.StartCount);
        h.Hider.OnReHide?.Invoke("Cursor");
        Assert.Equal("Cursor", h.Shield.Updates.Last().HiddenAppName);
        h.Clock.Now = asr.AddSeconds(600);
        Assert.True(h.Gate.RequestConfirm());
        Assert.Equal(1, h.Hider.StopCount);
        h.Hider.OnReHide?.Invoke("Cursor");         // late callback after the block: ignored
        Assert.Null(h.Gate.HiddenAppName);
    }

    // MARK: §G: no valid schedule / setup incomplete → never block

    [Fact]
    public void badScheduleNeverBlocks()
    {
        using var h = new Harness(asr);
        h.Schedule.Valid = false;
        h.Gate.AthanFired(Prayer.Asr, asr);
        h.Gate.Reevaluate(ReevalReason.Wake);
        h.Gate.Reevaluate(ReevalReason.Launch);
        Assert.Equal(Phase.Idle, h.Gate.Phase);
        Assert.Empty(h.Shield.Shows);
    }

    [Fact]
    public void scheduleLostMidBlockFailsOpen()
    {
        using var h = new Harness(asr);
        h.Gate.AthanFired(Prayer.Asr, asr);
        h.Schedule.Valid = false;
        h.Gate.Reevaluate(ReevalReason.ClockChanged);
        Assert.Equal(Phase.Idle, h.Gate.Phase);
        Assert.Equal(1, h.Shield.TearDownCount);
    }

    [Fact]
    public void setupIncompleteNeverBlocks()
    {
        using var h = new Harness(asr, TestSettings.Test(setupComplete: false));
        h.Gate.AthanFired(Prayer.Asr, asr);
        h.Gate.Reevaluate(ReevalReason.Wake);
        Assert.Equal(Phase.Idle, h.Gate.Phase);
    }

    [Fact]
    public void athanTheScheduleDoesNotKnowIsIgnored()
    {
        using var h = new Harness(asr.AddSeconds(1800));
        h.Gate.AthanFired(Prayer.Isha, asr.AddSeconds(1800));
        Assert.Equal(Phase.Idle, h.Gate.Phase);
    }
}
