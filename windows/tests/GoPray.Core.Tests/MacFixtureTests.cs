// MacFixtureTests.cs — state.json and settings.json move between the Mac and Windows apps unchanged
// in meaning (PLAN.md §2 "State / settings", PM Phase 1 brief). Windows-only suite (no Swift twin).

using System;
using System.IO;
using System.Text;
using System.Text.Json;
using GoPray.Core;
using Xunit;

namespace GoPray.Core.Tests;

public class MacFixtureTests
{
    static string Fixture(string name) => Path.Combine(AppContext.BaseDirectory, "fixtures", name);

    static void AssertSameJson(byte[] mac, byte[] ours)
    {
        using var a = JsonDocument.Parse(mac);
        using var b = JsonDocument.Parse(ours);
        Assert.True(JsonElement.DeepEquals(a.RootElement, b.RootElement),
            $"re-encoded JSON differs\nMac:\n{Encoding.UTF8.GetString(mac)}\nWindows:\n{Encoding.UTF8.GetString(ours)}");
    }

    [Fact]
    public void macIdleStateLoadsAndRoundTrips()
    {
        var mac = File.ReadAllBytes(Fixture("mac-state-idle.json"));
        var s = BlockStateFile.Decode(mac);
        Assert.Null(s.CurrentBlock);
        Assert.Equal(new BlockStateFile.Done(Prayer.Isha, new DateTime(2026, 10, 22, 23, 41, 0, DateTimeKind.Utc)), s.LastConfirmed);
        Assert.Empty(s.Launches);
        AssertSameJson(mac, s.Encode());
        Assert.Contains("\"block\": null", Encoding.UTF8.GetString(s.Encode()));   // explicit null, as Swift writes it
    }

    [Fact]
    public void macMidBlockStateLoadsAndResumesWithTheSameStart()
    {
        var mac = File.ReadAllBytes(Fixture("mac-state-block.json"));
        var s = BlockStateFile.Decode(mac);
        var started = new DateTime(2026, 10, 22, 19, 56, 0, DateTimeKind.Utc).AddMilliseconds(512);
        Assert.Equal(started, s.CurrentBlock?.BlockStartedAt);   // milliseconds survive
        Assert.Equal(1200, s.CurrentBlock?.LockSeconds);
        Assert.Equal(Prayer.Fajr, s.LastDropped?.Prayer);
        Assert.Single(s.Launches);
        AssertSameJson(mac, s.Encode());
        Assert.Contains("\"blockStartedAt\": \"2026-10-22T19:56:00.512Z\"", Encoding.UTF8.GetString(s.Encode()));

        // A gate over that file resumes the block with the Mac's start and its captured 20-min lock.
        var dir = Path.Combine(Path.GetTempPath(), "gopray-fixture-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        File.Copy(Fixture("mac-state-block.json"), Path.Combine(dir, "state.json"));
        var asr = new DateTime(2026, 10, 22, 19, 56, 0, DateTimeKind.Utc);
        var schedule = new OneWindowSchedule(new PrayerWindow(Prayer.Asr, asr, asr.AddHours(3)));
        using var h = new Harness(started.AddMinutes(5), dir: dir);
        var gate = new BlockGate(h.Clock, new StateStore(dir), schedule, h.Shield, h.Audio, h.Hider, () => h.Settings);
        gate.Reevaluate(ReevalReason.Launch);
        Assert.Equal(Phase.Locked(started.AddSeconds(1200)), gate.Phase);
        Assert.Equal(started, gate.CurrentBlock?.BlockStartedAt);
        Assert.Empty(h.Audio.Plays);                              // athanPlayed: no replay
    }

    [Fact]
    public void macSettingsLoadValidateAndRoundTrip()
    {
        var mac = File.ReadAllBytes(Fixture("mac-settings.json"));
        var s = SettingsRules.DecodeSettings(mac);
        s.Validate();
        Assert.Equal("Montréal, Québec", s.City);
        Assert.Equal(Voice.Shia("Salimi"), s.Voice);
        Assert.Equal(BlockMode.CodingApps, s.Mode);
        Assert.Equal(DateTimes.DistantFuture, s.PausedUntil);   // "until I resume"
        Assert.Null(s.ReduceMotion);
        Assert.Null(s.HighLatitudeRule);
        Assert.Equal(0.15f, s.AthanVolume);
        AssertSameJson(mac, s.Encode());
        var text = Encoding.UTF8.GetString(s.Encode());
        Assert.Contains("\"pausedUntil\": \"4001-01-01T00:00:00Z\"", text);   // whole seconds, like Swift .iso8601
        Assert.Contains("Montréal", text);                                    // raw UTF-8, not é
        Assert.DoesNotContain("reduceMotion", text);                          // nil omitted
    }

    [Fact]
    public void macSettingsFileIsAcceptedByTheStore()
    {
        var dir = Path.Combine(Path.GetTempPath(), "gopray-fixture-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(dir);
            File.Copy(Fixture("mac-settings.json"), Path.Combine(dir, "settings.json"));
            var store = new SettingsStore(dir);
            Assert.False(store.LoadedFromCorruptFile);
            Assert.True(store.Settings.SetupComplete);
            Assert.Equal(20, store.Settings.LockMinutes);
        }
        finally { Directory.Delete(dir, true); }
    }

    // Real files from Ahmed's Mac (PM, 2026-10-23; city/coords replaced).

    [Fact]
    public void realMacSettingsLoadAndRoundTrip()
    {
        var mac = File.ReadAllBytes(Fixture("mac-real-settings.json"));
        var s = SettingsRules.DecodeSettings(mac);
        s.Validate();
        Assert.Equal(0.6663495f, s.AthanVolume);                  // a Swift Float, written with 7 digits
        Assert.Equal(Voice.Sunni("Abdul-Basit"), s.Voice);
        Assert.Null(s.PausedUntil);
        AssertSameJson(mac, s.Encode());
        Assert.Contains("\"athanVolume\": 0.6663495", Encoding.UTF8.GetString(s.Encode()));
        var dir = Path.Combine(Path.GetTempPath(), "gopray-fixture-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(dir);
            File.Copy(Fixture("mac-real-settings.json"), Path.Combine(dir, "settings.json"));
            var store = new SettingsStore(dir);
            Assert.False(store.LoadedFromCorruptFile);
            Assert.Equal(s, store.Settings);
        }
        finally { Directory.Delete(dir, true); }
    }

    [Fact]
    public void realMacIdleStateLoadsAndRoundTrips()
    {
        var mac = File.ReadAllBytes(Fixture("mac-real-state-idle.json"));
        var s = BlockStateFile.Decode(mac);
        Assert.Null(s.CurrentBlock);
        Assert.Equal(Prayer.Asr, s.LastConfirmed?.Prayer);
        Assert.Equal(Prayer.Dhuhr, s.LastDropped?.Prayer);
        AssertSameJson(mac, s.Encode());
    }

    [Fact]
    public void everyDefaultIsWrittenTheMacWay()
    {
        var text = Encoding.UTF8.GetString(SettingsRules.Defaults.Encode());
        Assert.Contains("\"voice\": {\n    \"sunni\": {\n      \"_0\": \"Adhan-Makkah\"", text.Replace("\r\n", "\n"));
        Assert.Contains("\"method\": \"muslimWorldLeague\"", text);
        Assert.DoesNotContain("pausedUntil", text);
        var idle = Encoding.UTF8.GetString(new BlockStateFile().Encode());
        Assert.Contains("\"schemaVersion\": 1", idle);
        Assert.DoesNotContain("lastConfirmed", idle);
    }

    sealed class OneWindowSchedule(PrayerWindow w) : IPrayerScheduleProviding
    {
        public DayTimes? Times(DateTime day) => null;
        public PrayerWindow? Window(DateTime t) => t >= w.Athan && t < w.End ? w : null;
        public (Prayer Prayer, DateTime At)? NextAthan(DateTime t) => null;
    }
}
