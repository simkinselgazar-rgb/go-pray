// MacFixtureTests.cs — state.json and settings.json move between the Mac and Windows apps unchanged
// in meaning (PLAN.md §2 "State / settings", PM Phase 1 brief). Windows-only suite (no Swift twin).

using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using GoPray.Core;
using Xunit;

namespace GoPray.Core.Tests;

public class MacFixtureTests
{
    static string Fixture(string name) => Path.Combine(AppContext.BaseDirectory, "fixtures", name);

    /// <summary>A 0.1.x Mac file re-encodes with the v2 keys added at their defaults (the Mac's v2 does the same):
    /// those, and only those, are taken out of ours before comparing, and only when the Mac file lacks them.</summary>
    static void AssertSameJson(byte[] mac, byte[] ours)
    {
        var macNode = System.Text.Json.Nodes.JsonNode.Parse(mac)!.AsObject();
        var ourNode = System.Text.Json.Nodes.JsonNode.Parse(ours)!.AsObject();
        static void DropDefaults(System.Text.Json.Nodes.JsonObject m, System.Text.Json.Nodes.JsonObject o, params (string Key, string Default)[] keys)
        {
            foreach (var (k, d) in keys)
                if (!m.ContainsKey(k) && o[k] is { } v && v.ToJsonString() == d) o.Remove(k);
        }
        DropDefaults(macNode, ourNode, ("customApps", "[]"), ("disabledDefaultApps", "[]"), ("emergencyExitsEnabled", "true"), ("checkForUpdates", "true"), ("tvs", "[]"));
        if (macNode["block"] is System.Text.Json.Nodes.JsonObject mb && ourNode["block"] is System.Text.Json.Nodes.JsonObject ob)
            DropDefaults(mb, ob, ("emergencyExitsEnabled", "true"));
        ours = Encoding.UTF8.GetBytes(ourNode.ToJsonString());
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

    // MARK: v2 (PLAN-v2 §4 brief item 5)

    [Fact]
    public void macV2SettingsDecodeAndReencodeTheSameJson()
    {
        var mac = File.ReadAllBytes(Fixture("mac-settings-v2.json"));
        var s = SettingsRules.DecodeSettings(mac);
        Assert.Equal(["com.apple.Safari", "msedge"], s.DisabledDefaultApps);
        Assert.Equal([new CustomApp("com.figma.Desktop", "Figma", AppPlatform.Mac), new CustomApp("figma", "Figma", AppPlatform.Windows)], s.CustomApps);
        Assert.False(s.EmergencyExitsEnabled);
        Assert.False(s.CheckForUpdates);
        Assert.Equal(s, s.Sanitized());                                     // nothing to clean in a Mac v2 file
        AssertSameJson(mac, s.Encode());                                    // 0.3.0 adds only "tvs": []
        Assert.Equal(["figma"], BlockedApps.Effective(s, ["msedge", "Code"]).Where(x => x != "code"));   // msedge off, the Mac app ignored
    }

    [Fact]
    public void macV2BlockStateDecodesAndReencodesTheSameJson()
    {
        var mac = File.ReadAllBytes(Fixture("mac-state-block-v2.json"));
        var s = BlockStateFile.Decode(mac);
        Assert.Equal(["com.anthropic.claudefordesktop", "com.apple.Terminal", "figma"], s.CurrentBlock!.HiddenApps!);
        Assert.True(s.CurrentBlock.EmergencyExitsEnabled);
        using var a = JsonDocument.Parse(mac);
        using var b = JsonDocument.Parse(s.Encode());
        Assert.True(JsonElement.DeepEquals(a.RootElement, b.RootElement), Encoding.UTF8.GetString(s.Encode()));
    }

    [Fact]
    public void macV01MidBlockStateResumesAndWritesHiddenApps()
    {
        var dir = Path.Combine(Path.GetTempPath(), "gopray-fixture-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        File.Copy(Fixture("mac-state-block.json"), Path.Combine(dir, "state.json"));
        var started = new DateTime(2026, 10, 22, 19, 56, 0, DateTimeKind.Utc).AddMilliseconds(512);
        var asr = new DateTime(2026, 10, 22, 19, 56, 0, DateTimeKind.Utc);
        using var h = new Harness(started.AddMinutes(5), TestSettings.Test(BlockMode.CodingApps), dir: dir);
        var gate = new BlockGate(h.Clock, new StateStore(dir), new OneWindowSchedule(new PrayerWindow(Prayer.Asr, asr, asr.AddHours(3))),
                                 h.Shield, h.Audio, h.Hider, () => h.Settings, defaultApps: ["Cursor", "Code"]);
        gate.Reevaluate(ReevalReason.Launch);
        var written = BlockStateFile.Decode(File.ReadAllBytes(Path.Combine(dir, "state.json")));
        Assert.Equal(["code", "cursor"], written.CurrentBlock!.HiddenApps!);
        Assert.True(written.CurrentBlock.EmergencyExitsEnabled);
        Assert.Equal(1200, written.CurrentBlock.LockSeconds);                // the captured lock is untouched
        Assert.Equal(["code", "cursor"], h.Hider.Started.Last().OrderBy(x => x, StringComparer.Ordinal));
    }

    sealed class OneWindowSchedule(PrayerWindow w) : IPrayerScheduleProviding
    {
        public DayTimes? Times(DateTime day) => null;
        public PrayerWindow? Window(DateTime t) => t >= w.Athan && t < w.End ? w : null;
        public (Prayer Prayer, DateTime At)? NextAthan(DateTime t) => null;
    }
}
