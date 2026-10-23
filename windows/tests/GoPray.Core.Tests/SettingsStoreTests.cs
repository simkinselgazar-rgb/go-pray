// SettingsStoreTests.cs — the store asks the gate first ("mutate throws when the gate is blocked and
// the file is unchanged"), clamps, rejects invalid values, saves atomically, and knows the pause
// options. Port of GoPrayTests/Prayer/SettingsStoreTests.swift. Not ported here (they need the
// prayer library or are UI copy, Phase 3): theVoicePickerHasThe28Voices, suggestedMethodsFollowTheCountry,
// coordinateInputParses.

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using GoPray.Core;
using Xunit;

namespace GoPray.Core.Tests;

public class SettingsStoreTests
{
    readonly DateTime asr = FakeSchedule.At(Prayer.Asr);

    static string TempDir() => Path.Combine(Path.GetTempPath(), "gopray-settings-" + Guid.NewGuid().ToString("N"));

    sealed class Ctx : IDisposable
    {
        public required SettingsStore Store;
        public required Harness H;
        public required string Dir;
        public void Dispose() { H.Dispose(); try { Directory.Delete(Dir, true); } catch { } }
    }

    /// <summary>A store over a temp dir, attached to a real gate (with the core fakes).</summary>
    Ctx Make(DateTime? start = null)
    {
        var dir = TempDir();
        var h = new Harness(start ?? asr.AddSeconds(-3600));
        var store = new SettingsStore(dir);
        store.Attach(h.Gate);
        return new Ctx { Store = store, H = h, Dir = dir };
    }

    void StartBlock(Harness h)
    {
        h.Clock.Now = asr;
        h.Gate.AthanFired(Prayer.Asr, asr);
        Assert.True(h.Gate.IsBlocked);
    }

    // MARK: through the gate

    [Fact]
    public void everyChangeIsRefusedDuringABlockAndTheFileIsUnchanged()
    {
        using var c = Make();
        c.Store.Mutate(s => s with { City = "Toronto" });               // saved while idle
        var before = File.ReadAllBytes(c.Store.FilePath);
        var snapshot = c.Store.Settings;
        StartBlock(c.H);

        int ran = 0;
        var changes = new List<(string, Func<Settings, Settings>)>
        {
            ("mode", s => s with { Mode = BlockMode.CodingApps }),
            ("lockMinutes", s => s with { LockMinutes = 30 }),
            ("pause", s => s with { PausedUntil = DateTimes.DistantFuture }),
            ("city", s => s with { City = "Cairo" }),
            ("method", s => s with { Method = "egyptian" }),
            ("madhab", s => s with { Madhab = 2 }),
            ("volume", s => s with { AthanVolume = 0.1f }),
            ("voice", s => s with { Voice = Voice.Shia("Salimi") }),
            ("launchAtLogin", s => s with { LaunchAtLogin = !s.LaunchAtLogin }),
        };
        foreach (var (_, change) in changes)
            Assert.Throws<SettingsBlockedException>(() => c.Store.Mutate(s => { ran++; return change(s); }));
        Assert.Equal(0, ran);                                           // a refused change must not even run
        Assert.Equal(snapshot, c.Store.Settings);
        Assert.Equal(before, File.ReadAllBytes(c.Store.FilePath));
        Assert.Throws<SettingsBlockedException>(() => c.Store.Pause(PauseOption.OneDay, asr));
        Assert.Throws<SettingsBlockedException>(() => c.Store.Authorize());
    }

    [Fact]
    public void resumeIsRefusedDuringABlock()
    {
        using var c = Make();
        c.Store.Pause(PauseOption.UntilResumed, c.H.Clock.Now);
        StartBlock(c.H);
        Assert.Throws<SettingsBlockedException>(() => c.Store.Resume(asr));
        Assert.Equal(DateTimes.DistantFuture, c.Store.Settings.PausedUntil);
    }

    [Fact]
    public void changesWorkAgainAfterThePrayerIsConfirmed()
    {
        using var c = Make();
        StartBlock(c.H);
        c.H.Clock.Now = asr.AddSeconds(600);
        Assert.True(c.H.Gate.RequestConfirm());
        c.H.Shield.PendingDismiss?.Invoke();
        c.Store.Mutate(s => s with { Mode = BlockMode.CodingApps });
        Assert.Equal(BlockMode.CodingApps, c.Store.Settings.Mode);
    }

    [Fact]
    public void aStoreWithNoGateRefusesEverything()
    {
        var dir = TempDir();
        try
        {
            var store = new SettingsStore(dir);
            Assert.Throws<SettingsBlockedException>(() => store.Mutate(s => s with { Mode = BlockMode.CodingApps }));
            Assert.Equal(SettingsRules.Defaults, store.Settings);
            Assert.False(File.Exists(store.FilePath));
        }
        finally { try { Directory.Delete(dir, true); } catch { } }
    }

    // MARK: saving, loading, notifying

    [Fact]
    public void savesAtomicallyAndReloads()
    {
        using var c = Make();
        c.Store.Mutate(s => s with
        {
            City = "Cairo, Egypt", Latitude = 30.03, Longitude = 31.25, Method = "egyptian", Mode = BlockMode.CodingApps,
            SetupComplete = true, Voice = Voice.Shia("Salimi"), LockMinutes = 20,
        });
        var again = new SettingsStore(c.Dir);
        Assert.Equal(c.Store.Settings, again.Settings);
        Assert.Equal(Voice.Shia("Salimi"), again.Settings.Voice);
        Assert.False(again.LoadedFromCorruptFile);
        var leftovers = Directory.GetFiles(c.Dir).Select(f => Path.GetFileName(f)).ToArray();
        Assert.Equal(["settings.json"], leftovers);                     // no temp files left behind
    }

    [Fact]
    public void onChangeFiresOncePerRealChangeAfterTheValueIsLive()
    {
        using var c = Make();
        var seen = new List<Settings>();
        c.Store.OnChange = seen.Add;
        c.Store.Mutate(s => s with { Mode = BlockMode.CodingApps });
        c.Store.Mutate(s => s with { Mode = BlockMode.CodingApps });  // same value: nothing to do
        c.Store.Mutate(s => s);
        Assert.Single(seen);
        Assert.Equal(BlockMode.CodingApps, seen[0].Mode);
        Assert.Equal(BlockMode.CodingApps, c.Store.Settings.Mode);
    }

    [Fact]
    public void aCorruptFileIsSetAsideAndTheAppStartsFresh()
    {
        var dir = TempDir();
        try
        {
            Directory.CreateDirectory(dir);
            File.WriteAllText(Path.Combine(dir, "settings.json"), "{ not json");
            var store = new SettingsStore(dir);
            Assert.Equal(SettingsRules.Defaults, store.Settings);
            Assert.False(store.Settings.SetupComplete);                 // nothing blocks until setup is redone
            Assert.True(store.LoadedFromCorruptFile);
            var names = Directory.GetFiles(dir).Select(f => Path.GetFileName(f)).ToList();
            Assert.Contains(names, n => n.StartsWith("settings.corrupt-"));
            Assert.DoesNotContain("settings.json", names);
        }
        finally { try { Directory.Delete(dir, true); } catch { } }
    }

    [Fact]
    public void aFileWithAnImpossiblePlaceIsTreatedAsCorrupt()
    {
        var dir = TempDir();
        try
        {
            var bad = TestSettings.Test() with { Latitude = 999 };
            Directory.CreateDirectory(dir);
            File.WriteAllBytes(Path.Combine(dir, "settings.json"), bad.Encode());
            Assert.Equal(SettingsRules.Defaults, new SettingsStore(dir).Settings);
        }
        finally { try { Directory.Delete(dir, true); } catch { } }
    }

    // MARK: clamping and validation

    [Theory]
    [InlineData(0, 10)]
    [InlineData(5, 10)]
    [InlineData(10, 10)]
    [InlineData(17, 17)]
    [InlineData(30, 30)]
    [InlineData(45, 30)]
    [InlineData(-3, 10)]
    public void lockMinutesAreClamped(int given, int stored)
    {
        using var c = Make();
        c.Store.Mutate(s => s with { LockMinutes = given });
        Assert.Equal(stored, c.Store.Settings.LockMinutes);
    }

    [Fact]
    public void volumeIsClampedAndNaNFallsBack()
    {
        using var c = Make();
        c.Store.Mutate(s => s with { AthanVolume = 3 });
        Assert.Equal(1f, c.Store.Settings.AthanVolume);
        c.Store.Mutate(s => s with { AthanVolume = -1 });
        Assert.Equal(0f, c.Store.Settings.AthanVolume);
        c.Store.Mutate(s => s with { AthanVolume = float.NaN });
        Assert.Equal(SettingsRules.Defaults.AthanVolume, c.Store.Settings.AthanVolume);
    }

    [Fact]
    public void invalidValuesAreRejectedAndNothingChanges()
    {
        using var c = Make();
        var before = c.Store.Settings;
        void Expect(SettingsValidationError e, Func<Settings, Settings> change) =>
            Assert.Equal(e, Assert.Throws<SettingsValidationException>(() => c.Store.Mutate(change)).Error);
        Expect(SettingsValidationError.InvalidCoordinates, s => s with { Latitude = 91 });
        Expect(SettingsValidationError.InvalidCoordinates, s => s with { Longitude = double.NaN });
        Expect(SettingsValidationError.UnknownMethod, s => s with { Method = "bogus" });
        Expect(SettingsValidationError.UnknownMethod, s => s with { Method = "other" });
        Expect(SettingsValidationError.UnknownMadhab, s => s with { Madhab = 7 });
        Expect(SettingsValidationError.UnknownHighLatitudeRule, s => s with { HighLatitudeRule = "x" });
        Assert.Equal(before, c.Store.Settings);
    }

    [Fact]
    public void defaultsAreValidAndBlockNothing()
    {
        SettingsRules.Defaults.Validate();
        Assert.False(SettingsRules.Defaults.SetupComplete);
        Assert.Equal(LockPolicy.DefaultMinutes, SettingsRules.Defaults.LockMinutes);
        Assert.Equal(BlockMode.WholeScreen, SettingsRules.Defaults.Mode);
        Assert.Null(SettingsRules.Defaults.PausedUntil);
    }

    // MARK: pause

    [Fact]
    public void pauseOptionsMakeTheRightDates()
    {
        using var c = Make();
        var now = FakeSchedule.Day0.AddSeconds(9 * 3600);
        var expected = new (PauseOption, DateTime)[]
        {
            (PauseOption.OneDay, now.AddSeconds(86_400)), (PauseOption.ThreeDays, now.AddSeconds(3 * 86_400)),
            (PauseOption.OneWeek, now.AddSeconds(7 * 86_400)), (PauseOption.UntilResumed, DateTimes.DistantFuture),
        };
        Assert.Equal(4, PauseOptions.All.Length);
        foreach (var (option, until) in expected)
        {
            c.Store.Pause(option, now, TimeZoneInfo.Utc);
            Assert.Equal(until, c.Store.Settings.PausedUntil);
            Assert.True(c.Store.Settings.IsPaused(now));
        }
    }

    [Fact]
    public void pauseSurvivesARestartAndResumeEndsIt()
    {
        using var c = Make();
        var now = c.H.Clock.Now;
        c.Store.Pause(PauseOption.UntilResumed, now);
        Assert.Equal(DateTimes.DistantFuture, new SettingsStore(c.Dir).Settings.PausedUntil);
        c.Store.Resume(now.AddSeconds(60));
        Assert.Equal(now.AddSeconds(60), c.Store.Settings.PausedUntil);
        Assert.False(c.Store.Settings.IsPaused(now.AddSeconds(61)));
    }

    [Fact]
    public void pauseCallsTheSchedulerHook()
    {
        using var c = Make();
        int calls = 0;
        c.Store.OnChange = _ => calls++;
        c.Store.Pause(PauseOption.OneDay, c.H.Clock.Now);
        c.Store.Resume(c.H.Clock.Now);
        c.Store.Resume(c.H.Clock.Now);                                 // already resumed: no-op
        Assert.Equal(2, calls);
    }

    // Windows addition: a pause across a DST change keeps the wall-clock time (Swift Calendar semantics).
    [Fact]
    public void oneWeekPauseAcrossDstKeepsTheWallClockTime()
    {
        var ny = TimeZoneInfo.FindSystemTimeZoneById("America/New_York");
        var now = new DateTime(2026, 10, 30, 13, 0, 0, DateTimeKind.Utc);   // 09:00 EDT, DST ends 2026-11-01
        var until = PauseOption.OneWeek.Until(now, ny);
        Assert.Equal(new DateTime(2026, 11, 6, 14, 0, 0, DateTimeKind.Utc), until);   // 09:00 EST
    }
}
