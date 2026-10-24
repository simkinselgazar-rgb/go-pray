// V2Tests.cs — Go Pray v2 Core: the emergency exit (PLAN-v2 §5 gate + ledger tests 1–11, §9.5 year rule and
// switch), the captured blocked-apps list (§5 lane E Core parts) and the v2 JSON keys (Mac CONTRACT-NOTES #49–#55).
// Same names as the Mac tests where the case is the same. FakeClock + temp dirs; the ledger uses UTC as "local".

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using GoPray.Core;
using Xunit;

namespace GoPray.Core.Tests;

public class V2Tests
{
    readonly DateTime asr = FakeSchedule.At(Prayer.Asr);

    static void SeedUses(string path, params DateTime[] at)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllBytes(path, EmergencyLedger.Encode(at.Select(a => new EmergencyLedger.Use(Prayer.Dhuhr, a.AddMinutes(-5), a))));
    }

    static List<EmergencyLedger.Use> Uses(string path) => EmergencyLedger.Decode(File.ReadAllBytes(path));

    // MARK: §5 gate + ledger

    [Fact]
    public void emergencyExitMidLockEndsTheBlockAsDroppedAndCountsOne()
    {
        using var h = new Harness(asr);
        h.Gate.AthanFired(Prayer.Asr, asr);
        h.Clock.Now = asr.AddSeconds(30);
        Assert.Equal(5, h.Gate.ShieldContext()!.EmergencyExitsLeft);

        Assert.True(h.Gate.RequestEmergencyExit());
        var s = h.DiskState();
        Assert.Null(s.CurrentBlock);
        Assert.Equal(new BlockStateFile.Done(Prayer.Asr, asr), s.LastDropped);
        Assert.Null(s.LastConfirmed);                                   // honest record: never "prayed"
        Assert.Equal(4, h.Ledger.Remaining(h.Clock.Now));
        Assert.Single(Uses(h.Ledger.PrimaryPath));
        Assert.Single(Uses(h.Ledger.MirrorPath));
        Assert.Equal(new EmergencyLedger.Use(Prayer.Asr, asr, asr.AddSeconds(30)), Uses(h.Ledger.PrimaryPath)[0]);
        Assert.Equal([EndKind.Emergency], h.Shield.DismissKinds);
        Assert.Equal(1, h.Audio.StopCount);
        Assert.Equal(1, h.Hider.StopCount);
        Assert.False(h.Gate.RequestEmergencyExit());                    // one per block: the block is gone
        Assert.Single(Uses(h.Ledger.PrimaryPath));
    }

    [Fact]
    public void emergencyExitAllowedAtCanConfirmRefusedIdleAndLeaving()
    {
        using var h = new Harness(asr);
        Assert.False(h.Gate.RequestEmergencyExit());                    // idle
        h.Shield.AutoCompleteDismiss = false;
        h.Gate.AthanFired(Prayer.Asr, asr);
        h.Clock.Now = asr.AddSeconds(601);
        Assert.Equal(Phase.CanConfirm, h.Gate.Phase);
        Assert.True(h.Gate.RequestEmergencyExit());
        Assert.Equal(Phase.Leaving, h.Gate.Phase);
        Assert.False(h.Gate.RequestEmergencyExit());                    // leaving
        Assert.Equal(4, h.Ledger.Remaining(h.Clock.Now));
    }

    [Fact]
    public void noExitsLeftRefusesAndResyncsTheShieldWithZero()
    {
        using var h = new Harness(asr);
        SeedUses(h.Ledger.PrimaryPath, Enumerable.Range(0, 5).Select(i => asr.AddHours(-1 - i)).ToArray());
        h.Gate.AthanFired(Prayer.Asr, asr);
        Assert.Equal(0, h.Shield.Shows[0].EmergencyExitsLeft);
        h.Gate.ShieldDidRequestEmergencyExit();
        Assert.NotNull(h.DiskState().CurrentBlock);
        Assert.Equal(0, h.Shield.Updates.Last().EmergencyExitsLeft);
        Assert.Equal(5, Uses(h.Ledger.PrimaryPath).Count);
    }

    [Fact]
    public void aLedgerThatCannotBeWrittenRefusesTheExitAndLeavesTheBlock()
    {
        using var h = new Harness(asr);
        h.Gate.AthanFired(Prayer.Asr, asr);
        Directory.CreateDirectory(h.Ledger.PrimaryPath);                 // a folder where the file must go: the write fails
        Assert.False(h.Gate.RequestEmergencyExit());
        Assert.NotNull(h.DiskState().CurrentBlock);
        Assert.Equal(Phase.Locked(asr.AddSeconds(600)), h.Gate.Phase);
        Assert.False(File.Exists(h.Ledger.MirrorPath));
    }

    [Fact]
    public void relaunchMidBlockKeepsTheSameCount()
    {
        using var h = new Harness(asr);
        SeedUses(h.Ledger.PrimaryPath, asr.AddDays(-2));
        h.Gate.AthanFired(Prayer.Asr, asr);
        h.Clock.Now = asr.AddSeconds(10);
        h.Relaunch();
        Assert.Equal(4, h.Gate.ShieldContext()!.EmergencyExitsLeft);
        Assert.Equal(4, h.Shield.Shows.Last().EmergencyExitsLeft);
    }

    [Fact]
    public void eitherStoreAloneStillCountsAndBadFilesFailSafe()
    {
        var dir = Path.Combine(Path.GetTempPath(), "gopray-ledger-" + Guid.NewGuid().ToString("N"));
        try
        {
            var now = asr;
            var l = new EmergencyLedger(dir, Path.Combine(dir, "m"), TimeZoneInfo.Utc);
            Assert.Equal(5, l.Remaining(now));                                         // both missing
            SeedUses(l.MirrorPath, now.AddDays(-1), now.AddDays(-2), now.AddDays(-3));
            Assert.Equal(2, l.Remaining(now));                                         // file missing, mirror 3
            File.Delete(l.MirrorPath);
            SeedUses(l.PrimaryPath, now.AddDays(-1), now.AddDays(-2), now.AddDays(-3));
            Assert.Equal(2, l.Remaining(now));                                         // mirror missing, file 3
            File.WriteAllText(l.PrimaryPath, "{ not json");
            Assert.Equal(0, l.Remaining(now));                                         // corrupt → 0
            File.WriteAllText(l.PrimaryPath, "{\"schemaVersion\":2,\"used\":[]}");
            Assert.Equal(0, l.Remaining(now));                                         // wrong version → 0
            SeedUses(l.PrimaryPath, Enumerable.Range(0, 9).Select(i => now.AddDays(-i - 1)).ToArray());
            Assert.Equal(0, l.Remaining(now));                                         // 9 this year → 0
            SeedUses(l.PrimaryPath, new DateTime(2099, 1, 1, 0, 0, 0, DateTimeKind.Utc));
            Assert.Equal(4, l.Remaining(now));                                         // a future use still counts (§9.1)
            SeedUses(l.PrimaryPath, Enumerable.Range(0, 1001).Select(i => now.AddYears(-3).AddHours(-i)).ToArray());
            Assert.Equal(0, l.Remaining(now));                                         // >1000 uses (all old) → 0
        }
        finally { try { Directory.Delete(dir, true); } catch { } }
    }

    [Fact]
    public void deletingStateJsonDoesNotRefillExits()
    {
        using var h = new Harness(asr);
        h.Gate.AthanFired(Prayer.Asr, asr);
        Assert.True(h.Gate.RequestEmergencyExit());
        File.Delete(h.StateFile);
        h.Relaunch();
        Assert.Equal(4, h.Gate.EmergencyExitsRemaining);
    }

    [Fact]
    public void editingOneStoreToEmptyChangesNothing()
    {
        using var h = new Harness(asr);
        h.Gate.AthanFired(Prayer.Asr, asr);
        Assert.True(h.Gate.RequestEmergencyExit());
        File.WriteAllBytes(h.Ledger.PrimaryPath, EmergencyLedger.Encode([]));
        Assert.Equal(4, h.Gate.EmergencyExitsRemaining);                              // the mirror still says 1
        File.Delete(h.Ledger.MirrorPath);
        Assert.Equal(5, h.Gate.EmergencyExitsRemaining);                              // both found and changed: accepted (§2.4)
    }

    [Fact]
    public void afterAnEmergencyExitTheWakeRuleDoesNotReblockThatPrayer()
    {
        using var h = new Harness(asr);
        h.Gate.AthanFired(Prayer.Asr, asr);
        Assert.True(h.Gate.RequestEmergencyExit());
        h.Clock.Now = asr.AddMinutes(30);
        h.Gate.Reevaluate(ReevalReason.Wake);
        Assert.Equal(Phase.Idle, h.Gate.Phase);
        var maghrib = FakeSchedule.At(Prayer.Maghrib);
        h.Clock.Now = maghrib;
        h.Gate.AthanFired(Prayer.Maghrib, maghrib);
        Assert.Equal(Prayer.Maghrib, h.Gate.CurrentBlock?.Prayer);                   // the next Athan blocks normally
    }

    [Fact]
    public void confirmedStillSetsLastConfirmedAndNeverLastDropped()
    {
        using var h = new Harness(asr);
        h.Gate.AthanFired(Prayer.Asr, asr);
        h.Clock.Now = asr.AddSeconds(600);
        Assert.True(h.Gate.RequestConfirm());
        var s = h.DiskState();
        Assert.Equal(new BlockStateFile.Done(Prayer.Asr, asr), s.LastConfirmed);
        Assert.Null(s.LastDropped);
        Assert.Equal([EndKind.Confirmed], h.Shield.DismissKinds);
        Assert.Equal(5, h.Gate.EmergencyExitsRemaining);
    }

    [Fact]
    public void aGateWithNoLedgerHasNoExits()
    {
        using var h = new Harness(asr);
        var gate = new BlockGate(h.Clock, new StateStore(h.Dir), h.Schedule, new FakeShield(), new FakeAudio(), new FakeHider(), () => h.Settings);
        gate.AthanFired(Prayer.Asr, asr);
        Assert.Equal(0, gate.ShieldContext()!.EmergencyExitsLeft);
        Assert.False(gate.RequestEmergencyExit());
        Assert.NotNull(gate.CurrentBlock);
    }

#if DEBUG
    [Fact]
    public void debugSetEmergencyExitsUsedSetsThisYearOnly()
    {
        using var h = new Harness(asr);
        SeedUses(h.Ledger.PrimaryPath, asr.AddYears(-1));
        h.Gate.DebugSetEmergencyExitsUsed(5);
        Assert.Equal(0, h.Gate.EmergencyExitsRemaining);
        Assert.Contains(Uses(h.Ledger.PrimaryPath), u => u.At.Year == asr.Year - 1);  // history kept
        h.Gate.DebugSetEmergencyExitsUsed(2);
        Assert.Equal(3, h.Gate.EmergencyExitsRemaining);
    }
#endif

    // MARK: §9.5 year rule

    [Fact]
    public void yearRuleCountsOnlyThisLocalYearPlusFutureUses()
    {
        var dir = Path.Combine(Path.GetTempPath(), "gopray-ledger-" + Guid.NewGuid().ToString("N"));
        try
        {
            var now = new DateTime(2026, 10, 24, 12, 0, 0, DateTimeKind.Utc);
            var l = new EmergencyLedger(dir, Path.Combine(dir, "m"), TimeZoneInfo.Utc);
            SeedUses(l.PrimaryPath, Enumerable.Range(0, 5).Select(i => new DateTime(2025, 3, 1 + i, 0, 0, 0, DateTimeKind.Utc)).ToArray());
            Assert.Equal(5, l.Remaining(now));                                         // 5 last year → 5 left
            SeedUses(l.PrimaryPath, now.AddDays(-1), now.AddDays(-2), now.AddDays(-3));
            Assert.Equal(2, l.Remaining(now));                                         // 3 this year → 2
            SeedUses(l.PrimaryPath, now.AddDays(-1), now.AddDays(-2), now.AddDays(1), now.AddDays(1).AddHours(1));
            Assert.Equal(1, l.Remaining(now));                                         // 2 + 2 dated tomorrow → 1
            SeedUses(l.PrimaryPath, Enumerable.Range(0, 6).Select(i => now.AddDays(-i - 1)).ToArray());
            Assert.Equal(0, l.Remaining(now));                                         // 6 → 0
        }
        finally { try { Directory.Delete(dir, true); } catch { } }
    }

    [Fact]
    public void yearBoundaryIsLocalMidnightOnFirstJanuary()
    {
        var dir = Path.Combine(Path.GetTempPath(), "gopray-ledger-" + Guid.NewGuid().ToString("N"));
        try
        {
            var toronto = TimeZoneInfo.CreateCustomTimeZone("Test-5", TimeSpan.FromHours(-5), "Test-5", "Test-5");
            var l = new EmergencyLedger(dir, Path.Combine(dir, "m"), toronto);
            // 23:59:59 local on 31 Dec 2026 = 04:59:59Z on 1 Jan 2027: it counts for 2026.
            SeedUses(l.PrimaryPath, new DateTime(2027, 1, 1, 4, 59, 59, DateTimeKind.Utc));
            Assert.Equal(4, l.Remaining(new DateTime(2027, 1, 1, 4, 59, 59, 500, DateTimeKind.Utc)));   // still 2026 locally
            Assert.Equal(5, l.Remaining(new DateTime(2027, 1, 1, 5, 0, 0, DateTimeKind.Utc)));          // 00:00:00 local 1 Jan: new year
            SeedUses(l.PrimaryPath, new DateTime(2027, 1, 1, 5, 0, 0, DateTimeKind.Utc));               // 00:00:00 local counts for 2027
            Assert.Equal(4, l.Remaining(new DateTime(2027, 1, 1, 6, 0, 0, DateTimeKind.Utc)));
        }
        finally { try { Directory.Delete(dir, true); } catch { } }
    }

    [Fact]
    public void theLargerCountWinsNotTheSum()
    {
        var dir = Path.Combine(Path.GetTempPath(), "gopray-ledger-" + Guid.NewGuid().ToString("N"));
        try
        {
            var now = asr;
            var l = new EmergencyLedger(dir, Path.Combine(dir, "m"), TimeZoneInfo.Utc);
            SeedUses(l.PrimaryPath, now.AddDays(-1), now.AddDays(-2), now.AddDays(-3));
            SeedUses(l.MirrorPath, now.AddDays(-4), now.AddDays(-5), now.AddDays(-6));
            Assert.Equal(2, l.Remaining(now));                                         // 3 and 3 → 3, not 6
            SeedUses(l.PrimaryPath, now.AddDays(-1), now.AddDays(-2));
            SeedUses(l.MirrorPath, now.AddDays(-1), now.AddDays(-2), now.AddDays(-3), now.AddDays(-4));
            Assert.Equal(1, l.Remaining(now));                                         // file 2, mirror 4 → 1
            l.RecordUse(new EmergencyLedger.Use(Prayer.Isha, now, now));
            Assert.Equal(5, Uses(l.PrimaryPath).Count);                               // both get the union
            Assert.Equal(Uses(l.PrimaryPath), Uses(l.MirrorPath));
            Assert.Equal(0, l.Remaining(now));
        }
        finally { try { Directory.Delete(dir, true); } catch { } }
    }

    // MARK: §9.5 switch

    [Fact]
    public void switchOffAtBlockStartMeansNoButtonAndNoExit()
    {
        using var h = new Harness(asr, TestSettings.Test() with { EmergencyExitsEnabled = false });
        h.Gate.AthanFired(Prayer.Asr, asr);
        Assert.Equal(0, h.Gate.ShieldContext()!.EmergencyExitsLeft);
        Assert.False(h.Gate.RequestEmergencyExit());
        Assert.False(File.Exists(h.Ledger.PrimaryPath));
        Assert.False(h.DiskState().CurrentBlock!.EmergencyExitsEnabled);
        Assert.Equal(5, h.Gate.EmergencyExitsRemaining);                               // the count is untouched
    }

    [Fact]
    public void mutatingTheSwitchDuringABlockThrowsAndTheFileIsUnchanged()
    {
        using var h = new Harness(asr);
        var store = new SettingsStore(h.Dir);
        store.Attach(h.Gate);
        store.Mutate(_ => TestSettings.Test());
        h.Settings = store.Settings;
        var before = File.ReadAllBytes(store.FilePath);
        h.Gate.AthanFired(Prayer.Asr, asr);
        Assert.Throws<SettingsBlockedException>(() => store.Mutate(s => s with { EmergencyExitsEnabled = false }));
        Assert.Throws<SettingsBlockedException>(() => store.Mutate(s => s with { CustomApps = [new CustomApp("notepad", "Notepad", AppPlatform.Windows)] }));
        Assert.Equal(before, File.ReadAllBytes(store.FilePath));
    }

    [Fact]
    public void aSwappedSettingsClosureCannotChangeTheCapturedSwitchOrList()
    {
        using var h = new Harness(asr, TestSettings.Test(BlockMode.CodingApps));
        h.Gate.AthanFired(Prayer.Asr, asr);
        var first = h.Hider.Started.Single();
        Assert.Equal(BlockedApps.Effective(TestSettings.Test(), Harness.Defaults).OrderBy(x => x), first.OrderBy(x => x));
        // A bypassed store: the closure now says "no exits, and a different list".
        h.Settings = h.Settings with { EmergencyExitsEnabled = false, DisabledDefaultApps = ["code", "cursor", "chrome", "windowsterminal"] };
        h.Gate.Reevaluate(ReevalReason.SettingsChanged);
        Assert.Equal(5, h.Gate.ShieldContext()!.EmergencyExitsLeft);
        Assert.Single(h.Hider.Started);                                               // not restarted with the new list
        h.Clock.Now = asr.AddSeconds(5);
        h.Relaunch();                                                                  // resumes with the FILE's list
        Assert.Equal(first.OrderBy(x => x), h.Hider.Started.Single().OrderBy(x => x));
        Assert.True(h.Gate.RequestEmergencyExit());                                    // the captured switch rules
    }

    // MARK: captured list (§5 test 9–10, lane E)

    [Fact]
    public void blockStartCapturesTheEffectiveList()
    {
        var s = TestSettings.Test(BlockMode.CodingApps) with
        {
            DisabledDefaultApps = ["chrome", "com.apple.Safari"],
            CustomApps = [new CustomApp("notepad", "Notepad", AppPlatform.Windows), new CustomApp("com.figma.Desktop", "Figma", AppPlatform.Mac)],
        };
        using var h = new Harness(asr, s);
        h.Gate.AthanFired(Prayer.Asr, asr);
        string[] want = ["code", "cursor", "notepad", "windowsterminal"];
        Assert.Equal(want, h.DiskState().CurrentBlock!.HiddenApps);
        Assert.Equal(want, h.Hider.Started.Single().OrderBy(x => x, StringComparer.Ordinal));
    }

    [Fact]
    public void aTamperedHiddenAppsListIsCleanedOnRead()
    {
        using var h = new Harness(asr, TestSettings.Test(BlockMode.CodingApps));
        h.Gate.AthanFired(Prayer.Asr, asr);
        var json = JsonNodeEdit(File.ReadAllText(h.StateFile), apps: new[] { "explorer", "Taskmgr.exe", "GoPray" }.Concat(Enumerable.Range(0, 500).Select(i => "app" + i)));
        File.WriteAllText(h.StateFile, json);
        h.Clock.Now = asr.AddSeconds(5);
        h.Relaunch();
        var got = h.Hider.Started.Single();
        Assert.DoesNotContain("explorer", got);
        Assert.DoesNotContain("taskmgr", got);
        Assert.DoesNotContain("gopray", got);
        Assert.Equal(200, got.Count);
    }

    [Fact]
    public void aV01StateFileMidBlockResumesAndWritesHiddenApps()
    {
        using var h = new Harness(asr, TestSettings.Test(BlockMode.CodingApps));
        h.Gate.AthanFired(Prayer.Asr, asr);
        var doc = System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(h.StateFile))!;
        doc["block"]!.AsObject().Remove("hiddenApps");
        doc["block"]!.AsObject().Remove("emergencyExitsEnabled");
        File.WriteAllText(h.StateFile, doc.ToJsonString());
        h.Clock.Now = asr.AddSeconds(5);
        h.Relaunch();
        var b = h.DiskState().CurrentBlock!;
        Assert.Equal(new[] { "code", "cursor", "chrome", "windowsterminal" }.OrderBy(x => x, StringComparer.Ordinal), b.HiddenApps!);
        Assert.True(b.EmergencyExitsEnabled);                                            // absent → true
        Assert.Equal(b.HiddenApps!.OrderBy(x => x), h.Hider.Started.Single().OrderBy(x => x));
    }

    static string JsonNodeEdit(string state, IEnumerable<string> apps)
    {
        var doc = System.Text.Json.Nodes.JsonNode.Parse(state)!;
        var arr = new System.Text.Json.Nodes.JsonArray();
        foreach (var a in apps) arr.Add(a);
        doc["block"]!["hiddenApps"] = arr;
        return doc.ToJsonString();
    }

    // MARK: lane E — settings rules

    [Fact]
    public void v01SettingsDecodeWithTheNewFieldsDefaulted()
    {
        var json = Encoding.UTF8.GetBytes("{\"athanVolume\":0.5,\"city\":\"X\",\"latitude\":1,\"launchAtLogin\":true,\"lockMinutes\":10,\"longitude\":2,\"madhab\":1,\"method\":\"egyptian\",\"mode\":\"codingApps\",\"setupComplete\":true,\"voice\":{\"sunni\":{\"_0\":\"Adhan-Makkah\"}}}");
        var s = SettingsRules.DecodeSettings(json);
        Assert.Empty(s.DisabledDefaultApps);
        Assert.Empty(s.CustomApps);
        Assert.True(s.EmergencyExitsEnabled);
        Assert.True(s.CheckForUpdates);
    }

    [Fact]
    public void effectiveListRules()
    {
        string[] defaults = ["Code", "msedge", "Cursor"];
        var s = TestSettings.Test() with
        {
            DisabledDefaultApps = ["MSEDGE.exe", "com.apple.Safari"],
            CustomApps = [new CustomApp("figma", "Figma", AppPlatform.Windows), new CustomApp("com.figma.Desktop", "Figma", AppPlatform.Mac), new CustomApp("explorer", "Explorer", AppPlatform.Windows)],
        };
        var e = BlockedApps.Effective(s, defaults);
        Assert.Equal(["code", "cursor", "figma"], e.OrderBy(x => x, StringComparer.Ordinal));
    }

    [Fact]
    public void sanitizedDropsNeverBlockDedupesCapsAndTrims()
    {
        var s = TestSettings.Test() with
        {
            DisabledDefaultApps = new[] { " chrome ", "chrome", "explorer", "com.apple.finder", "", new string('x', 201) }
                .Concat(Enumerable.Range(0, 300).Select(i => "d" + i)).ToList(),
            CustomApps = new[]
            {
                new CustomApp("Figma.EXE", "  " + new string('F', 80) + "  ", AppPlatform.Windows),
                new CustomApp("figma", "dup", AppPlatform.Windows),
                new CustomApp("Taskmgr", "Task Manager", AppPlatform.Windows),
                new CustomApp("com.apple.finder", "Finder", AppPlatform.Mac),
                new CustomApp("com.figma.Desktop", "Figma", AppPlatform.Mac),
            }.Concat(Enumerable.Range(0, 80).Select(i => new CustomApp("c" + i, "C" + i, AppPlatform.Windows))).ToList(),
        };
        var t = s.Sanitized();
        Assert.Equal(200, t.DisabledDefaultApps.Count);
        Assert.Equal("chrome", t.DisabledDefaultApps[0]);
        Assert.DoesNotContain("explorer", t.DisabledDefaultApps);
        Assert.DoesNotContain("com.apple.finder", t.DisabledDefaultApps);
        Assert.Equal(50, t.CustomApps.Count);
        Assert.Equal(new CustomApp("figma", new string('F', 60), AppPlatform.Windows), t.CustomApps[0]);
        Assert.Equal(new CustomApp("com.figma.Desktop", "Figma", AppPlatform.Mac), t.CustomApps[1]);   // the Mac's app survives, untouched
        Assert.DoesNotContain(t.CustomApps, c => c.Id is "taskmgr" or "com.apple.finder");
    }

    [Fact]
    public void aCustomWindowsAppRoundTripsAndAMacOneIsKeptButNotApplied()
    {
        var dir = Path.Combine(Path.GetTempPath(), "gopray-settings-" + Guid.NewGuid().ToString("N"));
        try
        {
            using var h = new Harness(asr);
            var store = new SettingsStore(dir);
            store.Attach(h.Gate);
            store.Mutate(_ => TestSettings.Test() with { CustomApps = [new CustomApp("com.figma.Desktop", "Figma", AppPlatform.Mac), new CustomApp("figma", "Figma", AppPlatform.Windows)] });
            var bytes = File.ReadAllBytes(store.FilePath);
            var again = new SettingsStore(dir).Settings;
            Assert.Equal(store.Settings, again);
            Assert.Equal(bytes, again.Encode());
            Assert.Equal(["figma"], BlockedApps.Effective(again, []));
        }
        finally { try { Directory.Delete(dir, true); } catch { } }
    }

    [Fact]
    public void settingsEqualityComparesTheListsByValue()
    {
        var a = TestSettings.Test() with { DisabledDefaultApps = ["chrome"], CustomApps = [new CustomApp("figma", "Figma", AppPlatform.Windows)] };
        var b = TestSettings.Test() with { DisabledDefaultApps = new List<string> { "chrome" }, CustomApps = new List<CustomApp> { new("figma", "Figma", AppPlatform.Windows) } };
        Assert.Equal(a, b);
        Assert.NotEqual(a, b with { DisabledDefaultApps = [] });
        Assert.NotEqual(a, b with { EmergencyExitsEnabled = false });
    }

    [Fact]
    public void settingsModelAddRefusesWindowsPartsAndDuplicatesAndReEnablesADefault()
    {
        using var h = new Harness(asr);
        var store = new SettingsStore(h.Dir);
        store.Attach(h.Gate);
        store.Mutate(_ => TestSettings.Test() with { DisabledDefaultApps = ["cursor"] });
        var m = new SettingsModel(store, h.Gate, h.Clock, h.Audio, new NoLogon(), new NoGeocoder(), defaultApps: [("code", "Visual Studio Code"), ("cursor", "Cursor")]);
        Assert.False(m.AddApp("explorer.exe", "Windows Explorer"));
        Assert.Equal(Copy.CantRestThat, m.Notice);
        Assert.False(m.AddApp("Code", null));
        Assert.Equal(Copy.AlreadyListed, m.Notice);
        Assert.True(m.AddApp("CURSOR", null));                                          // a default that was off: back on
        Assert.Empty(store.Settings.DisabledDefaultApps);
        Assert.True(m.AddApp("Figma.exe", "Figma"));
        Assert.Equal([new CustomApp("figma", "Figma", AppPlatform.Windows)], store.Settings.CustomApps);
        m.SetDefaultApp("code", false);
        Assert.Equal(["code"], store.Settings.DisabledDefaultApps);
        Assert.False(m.AppRows.Single(r => r.Id == "code").On);
        m.RemoveApp("figma");
        Assert.Empty(store.Settings.CustomApps);
        m.SetEmergencyExitsEnabled(false);
        Assert.Equal("Emergency exits: off", m.EmergencyLine);
        m.SetCheckForUpdates(false);
        Assert.False(store.Settings.CheckForUpdates);
    }

    sealed class NoLogon : ILogonTask { public bool IsRegistered => false; public void Register() { } public void Unregister() { } }
    sealed class NoGeocoder : ICityGeocoding
    {
        public System.Threading.Tasks.Task<IReadOnlyList<CityMatch>> SearchAsync(string text, System.Threading.CancellationToken c) =>
            System.Threading.Tasks.Task.FromResult<IReadOnlyList<CityMatch>>([]);
    }

    // MARK: copy (§9.3)

    [Fact]
    public void emergencyCopyLines()
    {
        Assert.Equal("Emergency exits: 3 of 5 left this year", Copy.EmergencyLine(true, 3));
        Assert.Equal("Emergency exits: none left until 1 January", Copy.EmergencyLine(true, 0));
        Assert.Equal("Emergency exits: off", Copy.EmergencyLine(false, 3));
        Assert.Equal("Emergency exit · 3 of 5 left this year", Copy.EmergencyButton(3));
        Assert.Equal("This ends the block now. Asr will count as missed, not prayed. You'll have 2 of 5 left this year.", Copy.EmergencyCardBody(Prayer.Asr, 3));
        Assert.Equal("This ends the block now. Isha will count as missed, not prayed. This is your last one this year.", Copy.EmergencyCardBody(Prayer.Isha, 1));
    }

    [Fact]
    public void menuShowsTheExitLine()
    {
        using var h = new Harness(asr.AddHours(-2));
        var store = new SettingsStore(h.Dir);
        store.Attach(h.Gate);
        store.Mutate(_ => TestSettings.Test());
        var snap = new MenuModel(store, h.Gate, h.Schedule, h.Clock, () => TimeZoneInfo.Utc).Snapshot(h.Clock.Now);
        Assert.Equal("Emergency exits: 5 of 5 left this year", snap.EmergencyLine);
    }

    // MARK: bridge (§5 lane F, Core parts)

    [Fact]
    public void bridgeAcceptsEmergencyOnlyAsTheOneKey()
    {
        Assert.Equal(BridgeMessage.Emergency, BridgeMessages.Parse("{\"type\":\"emergency\"}"));
        Assert.Null(BridgeMessages.Parse("{\"type\":\"emergency\",\"x\":1}"));
        Assert.Null(BridgeMessages.Parse("{\"type\":\"Emergency\"}"));
    }

    [Fact]
    public void payloadCarriesTheClampedExitCount()
    {
        var ctx = new ShieldContext { Prayer = Prayer.Asr, EmergencyExitsLeft = 9 };
        Assert.Equal(5, BridgePayload.From(ctx, ShieldLayout.Full).EmergencyExitsLeft);
        Assert.Equal(0, BridgePayload.From(ctx with { EmergencyExitsLeft = -3 }, ShieldLayout.Full).EmergencyExitsLeft);
        Assert.Contains("\"emergencyExitsLeft\":3", BridgePayload.From(ctx with { EmergencyExitsLeft = 3 }, ShieldLayout.Full).ShowScript());
    }

    // MARK: JSON contract (Mac CONTRACT-NOTES #49–#55)

    [Fact]
    public void emergencyJsonHasTheMacShape()
    {
        var bytes = EmergencyLedger.Encode([new EmergencyLedger.Use(Prayer.Asr, new DateTime(2026, 10, 24, 20, 5, 0, DateTimeKind.Utc), new DateTime(2026, 10, 24, 20, 8, 41, 512, DateTimeKind.Utc))]);
        using var doc = JsonDocument.Parse(bytes);
        using var want = JsonDocument.Parse("{ \"schemaVersion\": 1, \"used\": [ { \"prayer\": \"asr\", \"athanAt\": \"2026-10-24T20:05:00.000Z\", \"at\": \"2026-10-24T20:08:41.512Z\" } ] }");
        Assert.True(JsonElement.DeepEquals(want.RootElement, doc.RootElement), Encoding.UTF8.GetString(bytes));
        Assert.StartsWith("{\n  \"schemaVersion\"", Encoding.UTF8.GetString(bytes).Replace("\r\n", "\n"));   // sorted keys
    }

    [Fact]
    public void settingsKeysAreSortedWithTheV2KeysInPlace()
    {
        var text = Encoding.UTF8.GetString(TestSettings.Test().Encode());
        var keys = JsonDocument.Parse(text).RootElement.EnumerateObject().Select(p => p.Name).ToList();
        Assert.Equal(keys.OrderBy(k => k, StringComparer.Ordinal), keys);
        foreach (var k in new[] { "emergencyExitsEnabled", "checkForUpdates", "customApps", "disabledDefaultApps" }) Assert.Contains(k, keys);
    }

    [Fact]
    public void blockKeysAreSortedWithTheV2KeysInPlace()
    {
        using var h = new Harness(asr, TestSettings.Test(BlockMode.CodingApps));
        h.Gate.AthanFired(Prayer.Asr, asr);
        using var doc = JsonDocument.Parse(File.ReadAllBytes(h.StateFile));
        var keys = doc.RootElement.GetProperty("block").EnumerateObject().Select(p => p.Name).ToList();
        Assert.Equal(keys.OrderBy(k => k, StringComparer.Ordinal), keys);
        Assert.Contains("emergencyExitsEnabled", keys);
        Assert.Contains("hiddenApps", keys);
    }
}
