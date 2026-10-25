// TvTests.cs — 0.3.0 TV support, Core side (PM brief 2026-10-24 + the two amendments): the host and channel id rules,
// settings.json `tvs`, the gate's one block-start hand-off (and when it must not happen), and the Settings model.
// The network side (the exact URL, the active-app check, the 512 KB cap) is GoPray.App.Tests/TvControllerTests.cs.

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using GoPray.Core;
using Xunit;

namespace GoPray.Core.Tests;

public class TvTests
{
    readonly DateTime asr = FakeSchedule.At(Prayer.Asr);

    static TvDevice Tv(string host = "192.168.1.160", bool enabled = true, string channel = "dev", bool installed = true, string id = "TV-1") =>
        new(id, "Living room", TvKind.Roku, host, channel, enabled, installed);

    static Settings WithTvs(params TvDevice[] tvs) => TestSettings.Test() with { Tvs = tvs };

    static string TempDir() => Path.Combine(Path.GetTempPath(), "gopray-tv-tests-" + Guid.NewGuid().ToString("N"));

    // MARK: rules

    [Theory]
    [InlineData("192.168.1.160")] [InlineData("10.0.0.1")] [InlineData("172.16.0.1")] [InlineData("172.31.255.254")]
    [InlineData("169.254.10.20")] [InlineData("192.168.0.0")]
    public void privateIPv4LiteralsAreAllowed(string host) => Assert.True(TvRules.IsAllowedHost(host));

    [Theory]
    [InlineData("8.8.8.8")] [InlineData("172.32.0.1")] [InlineData("172.15.0.1")] [InlineData("192.169.1.1")] [InlineData("100.69.27.113")]
    [InlineData("127.0.0.1")] [InlineData("0.0.0.0")] [InlineData("255.255.255.255")] [InlineData("239.255.255.250")]
    [InlineData("roku.local")] [InlineData("tv")] [InlineData("example.com")] [InlineData("192.168.1.256")] [InlineData("192.168.01.1")]
    [InlineData(" 192.168.1.5")] [InlineData("192.168.1.5 ")] [InlineData("192.168.1")] [InlineData("192.168.1.5.6")] [InlineData("::1")]
    [InlineData("fe80::1")] [InlineData("192.168.1.5:8060")] [InlineData("")] [InlineData(null)] [InlineData("0x0a.0.0.1")] [InlineData("10.0.0.1/8")]
    public void publicHostsAndHostnamesAreRefused(string? host) => Assert.False(TvRules.IsAllowedHost(host));

    [Theory]
    [InlineData("dev", true)] [InlineData("12345", true)] [InlineData("1234567890", true)] [InlineData("12345678901", false)]
    [InlineData("dev2", false)] [InlineData("DEV", false)] [InlineData("", false)] [InlineData("../launch", false)] [InlineData("12 3", false)]
    [InlineData(null, false)] [InlineData("１２３", false)]
    public void channelIdRule(string? id, bool ok) => Assert.Equal(ok, TvRules.IsValidChannelId(id));

    [Fact]
    public void voiceAndPrayerParams()
    {
        Assert.Equal("sunni.Adhan-Makkah", TvRules.VoiceParam(Voice.Sunni("Adhan-Makkah")));
        Assert.Equal("shia.Aghati", TvRules.VoiceParam(Voice.Shia("Aghati")));
        Assert.Equal(["fajr", "dhuhr", "asr", "maghrib", "isha"], Enum.GetValues<Prayer>().Select(TvRules.PrayerParam));
    }

    // MARK: settings.json

    [Fact]
    public void settingsWithoutTvsDecodeAsEmpty()
    {
        var json = Encoding.UTF8.GetString(TestSettings.Test().Encode());
        var without = json.Replace("\"tvs\" : [],", "").Replace("\"tvs\": [],", "");
        Assert.DoesNotContain("tvs", without);
        Assert.Empty(SettingsRules.DecodeSettings(Encoding.UTF8.GetBytes(without)).Tvs);
    }

    [Fact]
    public void tvsRoundTripInSortedKeyOrder()
    {
        var s = WithTvs(Tv(), Tv("10.0.0.9", enabled: false, channel: "12345", installed: false, id: "TV-2"));
        var bytes = s.Encode();
        var text = Encoding.UTF8.GetString(bytes);
        Assert.True(text.IndexOf("\"setupComplete\"") < text.IndexOf("\"tvs\"") && text.IndexOf("\"tvs\"") < text.IndexOf("\"voice\""));
        var e = text.IndexOf("\"channelId\"");
        Assert.True(e < text.IndexOf("\"enabled\"") && text.IndexOf("\"host\"") < text.IndexOf("\"id\"") && text.IndexOf("\"kind\"") < text.IndexOf("\"name\""));
        Assert.Contains("\"kind\" : \"roku\"", text.Replace("\":", "\" :"));
        Assert.Equal(s, SettingsRules.DecodeSettings(bytes));
    }

    [Fact]
    public void aBadTvEntryIsDroppedAndTheRestKept()
    {
        var json = Encoding.UTF8.GetString(TestSettings.Test().Encode());
        var tvs = """
            "tvs" : [
              {"enabled":true,"host":"192.168.1.160","id":"A","kind":"roku","name":"Good, no installed key","channelId":"dev"},
              {"enabled":true,"host":"8.8.8.8","id":"B","kind":"roku","name":"Public host"},
              {"enabled":true,"host":"roku.local","id":"C","kind":"roku","name":"Hostname"},
              {"enabled":true,"host":"10.0.0.2","id":"D","kind":"lg","name":"Other kind"},
              {"host":"10.0.0.3","id":"E","kind":"roku","name":"No enabled"},
              "not an object",
              {"enabled":"yes","host":"10.0.0.4","id":"F","kind":"roku","name":"Bad bool"},
              {"enabled":false,"host":"10.0.0.5","id":"G","kind":"roku","name":"Junk channel","channelId":"../x","installed":false}
            ],
            """;
        var withTvs = json.Replace("\"voice\"", tvs + "\"voice\"");
        var s = SettingsRules.DecodeSettings(Encoding.UTF8.GetBytes(withTvs));
        Assert.Equal(["A", "E", "G"], s.Tvs.Select(t => t.Id));
        Assert.True(s.Tvs[0].Installed);                                    // missing → true
        Assert.Equal("dev", s.Tvs[0].ChannelId);
        Assert.True(s.Tvs[1].Enabled);                                      // missing → true (only id, host, kind are needed)
        Assert.Equal("dev", s.Tvs[2].ChannelId);                            // a junk id → "dev", the TV kept
        Assert.False(s.Tvs[2].Installed);
        Assert.Equal(40.7, s.Latitude);                                     // the rest of the settings untouched
    }

    [Fact]
    public void tvsThatIsNotAnArrayReadsAsEmpty()
    {
        var json = Encoding.UTF8.GetString(TestSettings.Test().Encode()).Replace("\"voice\"", "\"tvs\" : {\"x\":1},\n\"voice\"");
        Assert.Empty(SettingsRules.DecodeSettings(Encoding.UTF8.GetBytes(json)).Tvs);
    }

    [Fact]
    public void savingDropsAPublicHost()
    {
        var s = WithTvs(Tv(), Tv("8.8.8.8", id: "TV-2"), Tv("192.168.1.160", id: "TV-3"), Tv("roku.local", id: "TV-4")).Sanitized();
        Assert.Equal(["TV-1"], s.Tvs.Select(t => t.Id));                    // public host, hostname and duplicate host gone
    }

    [Fact]
    public void savingCleansLikeTheMac()
    {
        var many = Enumerable.Range(1, 12).Select(i => Tv($"10.0.0.{i}", id: $"T{i}")).ToArray();
        Assert.Equal(TvRules.MaxTvs, WithTvs(many).Sanitized().Tvs.Count);
        var t = WithTvs(new TvDevice("X", "  ", TvKind.Roku, " 10.0.0.1 ", "junk")).Sanitized().Tvs.Single();
        Assert.Equal(("Roku TV", "10.0.0.1", "dev"), (t.Name, t.Host, t.ChannelId));
    }

    // MARK: the gate's hand-off

    [Fact]
    public void liveAthanCallsTheTvsOnceWithThePrayerAndVoice()
    {
        using var h = new Harness(asr, WithTvs(Tv()));
        h.Gate.AthanFired(Prayer.Asr, asr);
        var call = Assert.Single(h.Tvs.Calls);
        Assert.Equal(Prayer.Asr, call.Prayer);
        Assert.Equal(Voice.Sunni("test-voice"), call.Voice);
        Assert.Single(call.Tvs);
        Assert.Single(h.Shield.Shows);
        h.Gate.Reevaluate(ReevalReason.Wake);                               // re-sync, not a new start
        h.Gate.RequestSilence();
        Assert.Single(h.Tvs.Calls);
    }

    [Fact]
    public void fajrStillSendsTheChosenVoice()
    {
        var fajr = FakeSchedule.At(Prayer.Fajr);
        using var h = new Harness(fajr, WithTvs(Tv()) with { Voice = Voice.Shia("Aghati") });
        h.Gate.AthanFired(Prayer.Fajr, fajr);
        Assert.Equal((Prayer.Fajr, Voice.Shia("Aghati")), (h.Tvs.Calls[0].Prayer, h.Tvs.Calls[0].Voice));
    }

    [Fact]
    public void wakeTwoMinutesAfterTheAthanCalls()
    {
        using var h = new Harness(asr.AddMinutes(2), WithTvs(Tv()));
        h.Gate.Reevaluate(ReevalReason.Wake);
        Assert.NotNull(h.Gate.CurrentBlock);
        Assert.Single(h.Tvs.Calls);
    }

    [Fact]
    public void wakeTenMinutesAfterTheAthanBlocksButCallsNoTv()
    {
        var log = new List<string>();
        using var h = new Harness(asr.AddMinutes(10), WithTvs(Tv()));
        lock (typeof(CoreLog))
        {
            var old = CoreLog.Sink;
            CoreLog.Sink = m => { lock (log) log.Add(m); };
            try { h.Gate.Reevaluate(ReevalReason.Wake); } finally { CoreLog.Sink = old; }
        }
        Assert.NotNull(h.Gate.CurrentBlock);                                // the PC block as usual
        Assert.Single(h.Shield.Shows);
        Assert.Empty(h.Tvs.Calls);
        Assert.Contains(log, l => l.EndsWith("tv: skipped, late wake"));
    }

    [Fact]
    public void exactlyThreeMinutesStillCallsJustAfterDoesNot()
    {
        using (var h = new Harness(asr.AddMinutes(3), WithTvs(Tv()))) { h.Gate.Reevaluate(ReevalReason.Wake); Assert.Single(h.Tvs.Calls); }
        using (var h = new Harness(asr.AddMinutes(3).AddSeconds(1), WithTvs(Tv()))) { h.Gate.Reevaluate(ReevalReason.Wake); Assert.Empty(h.Tvs.Calls); }
    }

    [Fact]
    public void relaunchMidBlockNeverCallsAgain()
    {
        using var h = new Harness(asr, WithTvs(Tv()));
        h.Gate.AthanFired(Prayer.Asr, asr);
        h.Clock.Now = asr.AddSeconds(40);
        h.Relaunch();
        Assert.NotNull(h.Gate.CurrentBlock);
        Assert.Single(h.Shield.Shows);                                      // the new process shows the block…
        Assert.Single(h.Tvs.Calls);                                         // …and the TVs were called only at the start
    }

    [Fact]
    public void pausedNoBlockNoCall()
    {
        using var h = new Harness(asr, WithTvs(Tv()) with { PausedUntil = asr.AddDays(1) });
        h.Gate.AthanFired(Prayer.Asr, asr);
        Assert.Null(h.Gate.CurrentBlock);
        Assert.Empty(h.Tvs.Calls);
    }

    [Fact]
    public void stillCallsWhenThePcAudioFails()
    {
        using var h = new Harness(asr, WithTvs(Tv()));
        h.Audio.ThrowOnPlay = true;
        h.Gate.AthanFired(Prayer.Asr, asr);
        Assert.Single(h.Tvs.Calls);
        Assert.Single(h.Shield.Shows);
    }

    [Fact]
    public void onlyDisabledTvsNoCall()
    {
        using var h = new Harness(asr, WithTvs(Tv(enabled: false)));
        h.Gate.AthanFired(Prayer.Asr, asr);
        Assert.Empty(h.Tvs.Calls);
        Assert.Single(h.Shield.Shows);
    }

    [Fact]
    public void aThrowingControllerNeverChangesTheBlock()
    {
        using var h = new Harness(asr, WithTvs(Tv()));
        h.Tvs.Throw = true;
        h.Gate.AthanFired(Prayer.Asr, asr);
        Assert.Single(h.Tvs.Calls);
        Assert.NotNull(h.Gate.CurrentBlock);
        Assert.Single(h.Shield.Shows);
        Assert.Equal(PhaseKind.Locked, h.Gate.Phase.Kind);
    }

    // MARK: Settings model

    sealed class FakeControl : ITvControlling
    {
        public TvProbe Answer { get; set; } = new(true, "58\" Hisense Roku TV", "dev");
        public bool LaunchOk { get; set; } = true;
        public List<string> Probes { get; } = [];
        public List<(string Host, string Channel, Prayer Prayer, Voice Voice)> Tests { get; } = [];
        public TvDiscovery Found { get; set; } = new([], false);
        public void AthanStarted(IReadOnlyList<TvDevice> tvs, Prayer prayer, Voice voice) { }
        public Task<TvDiscovery> Discover(CancellationToken cancel) => Task.FromResult(Found);
        public Task<TvProbe> Probe(string host, CancellationToken cancel) { Probes.Add(host); return Task.FromResult(Answer); }
        public Task<bool> TestLaunch(string host, string channelId, Prayer prayer, Voice voice, CancellationToken cancel)
        {
            Tests.Add((host, channelId, prayer, voice));
            return Task.FromResult(LaunchOk);
        }
    }

    (SettingsStore, Harness, SettingsModel, FakeControl) Model(DateTime at)
    {
        var h = new Harness(at, SettingsRules.Defaults);
        var store = new SettingsStore(TempDir());
        store.Attach(h.Gate);
        store.Mutate(_ => TestSettings.Test());
        h.Settings = store.Settings;
        store.OnChange = s => h.Settings = s;
        var tv = new FakeControl();
        var m = new SettingsModel(store, h.Gate, h.Clock, h.Audio, new FakeLogon(), new FakeGeocoder(), () => TimeZoneInfo.Utc,
                                  tvs: tv, schedule: h.Schedule);
        return (store, h, m, tv);
    }

    [Fact]
    public async Task addByAddressStoresTheTvWithItsNameAndChannel()
    {
        var (store, h, m, tv) = Model(asr.AddHours(1));
        using var _ = h;
        Assert.True(await m.AddTv(" 192.168.1.160 "));
        var t = Assert.Single(store.Settings.Tvs);
        Assert.Equal(("192.168.1.160", "58\" Hisense Roku TV", "dev", true, true), (t.Host, t.Name, t.ChannelId, t.Enabled, t.Installed));
        Assert.Null(m.TvNotice);
        Assert.False(await m.AddTv("192.168.1.160"));
        Assert.Equal(Copy.TvAlreadyListed, m.TvNotice);
        Assert.Single(tv.Probes);
    }

    [Theory]
    [InlineData("8.8.8.8")] [InlineData("roku.local")] [InlineData("http://192.168.1.160:8060/")]
    public async Task addRefusesAPublicHostOrNameWithoutTouchingTheNetwork(string host)
    {
        var (store, h, m, tv) = Model(asr.AddHours(1));
        using var _ = h;
        Assert.False(await m.AddTv(host));
        Assert.Equal(Copy.TvHostRefused, m.TvNotice);
        Assert.Empty(tv.Probes);
        Assert.Empty(store.Settings.Tvs);
    }

    [Fact]
    public async Task anUnreachableTvIsKeptWithTheDefaults()
    {
        var (store, h, m, tv) = Model(asr.AddHours(1));
        using var _ = h;
        tv.Answer = new TvProbe(false, null, null);
        Assert.True(await m.AddTv("10.0.0.30", "Kitchen"));
        var t = Assert.Single(store.Settings.Tvs);
        Assert.Equal(("Kitchen", "dev", true), (t.Name, t.ChannelId, t.Installed));
        Assert.Equal(Copy.TvUnreachable, m.TvNotice);
    }

    [Fact]
    public async Task aTvWithoutGoPraySaysSo()
    {
        var (store, h, m, tv) = Model(asr.AddHours(1));
        using var _ = h;
        tv.Answer = new TvProbe(true, "Bedroom", null);
        Assert.True(await m.AddTv("10.0.0.20"));
        Assert.False(store.Settings.Tvs[0].Installed);
        Assert.Equal(Copy.TvNotInstalled, m.TvNotice);
        Assert.False(m.TvRows[0].Installed);
    }

    [Fact]
    public async Task testLooksTheChannelUpAgainStoresItAndLaunchesTheNextPrayer()
    {
        var (store, h, m, tv) = Model(asr.AddHours(1));                     // next: Maghrib
        using var _ = h;
        await m.AddTv("192.168.1.160");
        tv.Answer = new TvProbe(true, "x", "12345");                         // the published channel is now installed
        Assert.True(await m.TestTv(store.Settings.Tvs[0].Id));
        Assert.Equal("12345", store.Settings.Tvs[0].ChannelId);
        Assert.Equal(("192.168.1.160", "12345", Prayer.Maghrib, Voice.Sunni("test-voice")), tv.Tests.Single());
        Assert.Equal(Copy.TvTestSent, m.TvNotice);
        Assert.Equal(2, tv.Probes.Count);

        tv.Answer = new TvProbe(true, "x", null);                            // removed from the TV
        Assert.False(await m.TestTv(store.Settings.Tvs[0].Id));
        Assert.False(store.Settings.Tvs[0].Installed);
        Assert.Equal("12345", store.Settings.Tvs[0].ChannelId);              // kept, like the Mac
        Assert.Equal("58\" Hisense Roku TV", store.Settings.Tvs[0].Name);  // a Test never renames
        Assert.Equal(Copy.TvNotInstalled, m.TvNotice);
        Assert.Single(tv.Tests);
    }

    [Fact]
    public async Task tvsAreReadOnlyDuringABlock()
    {
        var (store, h, m, tv) = Model(asr);
        using var _ = h;
        await m.AddTv("192.168.1.160");
        h.Clock.Now = asr.AddHours(1).AddMinutes(30);                       // Maghrib
        h.Gate.AthanFired(Prayer.Maghrib, FakeSchedule.At(Prayer.Maghrib));
        Assert.True(m.IsBlocked);
        var id = store.Settings.Tvs[0].Id;
        Assert.False(await m.AddTv("192.168.1.161"));
        Assert.False(await m.TestTv(id));
        Assert.Empty(await m.FindTvs());
        m.SetTvEnabled(id, false);
        m.RemoveTv(id);
        Assert.Equal(Copy.BlockedLine, m.Notice);
        Assert.True(store.Settings.Tvs.Single().Enabled);
        Assert.Single(tv.Probes);                                           // only the add before the block
        Assert.Empty(tv.Tests);
    }

    [Fact]
    public async Task findListsOnlyNewTvsAndExplainsAFirewall()
    {
        var (store, h, m, tv) = Model(asr.AddHours(1));
        using var _ = h;
        await m.AddTv("192.168.1.160");
        tv.Found = new([new("192.168.1.160", "Known"), new("192.168.1.161", "New"), new("8.8.8.8", "Public")], false);
        Assert.Equal(["192.168.1.161"], (await m.FindTvs()).Select(f => f.Host));
        tv.Found = new([new("192.168.1.160", "Known")], false);
        Assert.Empty(await m.FindTvs());
        Assert.Equal(Copy.TvAllListed, m.TvNotice);
        tv.Found = new([], false);
        await m.FindTvs();
        Assert.Equal(Copy.TvNoneFound, m.TvNotice);
        tv.Found = new([], true);
        await m.FindTvs();
        Assert.Equal(Copy.TvFirewall, m.TvNotice);
    }

    [Fact]
    public async Task removeAndToggle()
    {
        var (store, h, m, tv) = Model(asr.AddHours(1));
        using var _ = h;
        await m.AddTv("192.168.1.160");
        var id = store.Settings.Tvs[0].Id;
        m.SetTvEnabled(id, false);
        Assert.False(store.Settings.Tvs[0].Enabled);
        m.RemoveTv(id);
        Assert.Empty(store.Settings.Tvs);
    }
}
