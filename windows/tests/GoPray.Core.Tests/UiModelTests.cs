// UiModelTests.cs — the logic behind the popover, Setup and Settings (ports of the Mac's MenuViewModel,
// SetupViewModel, SettingsViewModel and CitySearchModel rules, plus the copy tables).

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using GoPray.Core;
using Xunit;

namespace GoPray.Core.Tests;

sealed class FakeGeocoder : ICityGeocoding
{
    public List<string> Queries { get; } = [];
    public Func<string, IReadOnlyList<CityMatch>> Answer { get; set; } = _ => [];
    public bool Offline { get; set; }
    public async Task<IReadOnlyList<CityMatch>> SearchAsync(string text, CancellationToken cancel)
    {
        Queries.Add(text);
        await Task.Yield();
        if (Offline) throw new GeocodeOfflineException("down");
        return Answer(text);
    }
}

sealed class FakeLogon : ILogonTask
{
    public bool IsRegistered { get; private set; }
    public bool Fail { get; set; }
    public int Registers, Unregisters;
    public void Register() { if (Fail) throw new InvalidOperationException("no"); Registers++; IsRegistered = true; }
    public void Unregister() { if (Fail) throw new InvalidOperationException("no"); Unregisters++; IsRegistered = false; }
}

public class UiModelTests
{
    readonly DateTime asr = FakeSchedule.At(Prayer.Asr);
    static readonly CityMatch Toronto = new("Toronto", "Ontario", "Canada", "CA", 43.6532, -79.3832);
    static readonly CityMatch Cairo = new("Cairo", "Cairo Governorate", "Egypt", "EG", 30.0444, 31.2357);

    static string TempDir() => Path.Combine(Path.GetTempPath(), "gopray-ui-" + Guid.NewGuid().ToString("N"));

    (SettingsStore, Harness) StoreAndGate(DateTime at, Settings? s = null)
    {
        var h = new Harness(at, s ?? SettingsRules.Defaults);   // like the app: the gate starts from what the store holds
        var store = new SettingsStore(TempDir());
        store.Attach(h.Gate);
        if (s != null) store.Mutate(_ => s);
        h.Settings = store.Settings;
        return (store, h);
    }

    // MARK: TimeText

    [Theory]
    [InlineData(0, "less than a minute")]
    [InlineData(59.2, "1 min")]
    [InlineData(61, "2 min")]
    [InlineData(49 * 60, "49 min")]
    [InlineData(3600, "1 h")]
    [InlineData(6540, "1 h 49 min")]
    public void durationRoundsUpAndNeverSaysZero(double s, string want) => Assert.Equal(want, TimeText.Duration(s));

    [Fact]
    public void countdownAndClock()
    {
        Assert.Equal("6:12", TimeText.Countdown(371.2));
        Assert.Equal("0:00", TimeText.Countdown(-5));
        Assert.Equal("3:30 PM", TimeText.Clock(asr, TimeZoneInfo.Utc, CultureInfo.GetCultureInfo("en-US")));
        Assert.Equal("Thu Oct 22", TimeText.Day(asr, TimeZoneInfo.Utc, CultureInfo.GetCultureInfo("en-US")));
    }

    // MARK: popover snapshot (MenuViewModel)

    MenuSnapshot Snap(SettingsStore store, Harness h, DateTime now) =>
        new MenuModel(store, h.Gate, h.Schedule, h.Clock, () => TimeZoneInfo.Utc).Snapshot(now);

    [Fact]
    public void beforeSetupThePopoverAsksForACity()
    {
        var (store, h) = StoreAndGate(asr);
        using var _ = h;
        Assert.Equal(MenuStatus.NeedsSetup, Snap(store, h, asr).Status);
    }

    [Fact]
    public void fiveRowsNextDotCountdownAndFooter()
    {
        var (store, h) = StoreAndGate(asr.AddSeconds(-3600), TestSettings.Test() with { City = "Toronto, Ontario", Method = "northAmerica" });
        using var _ = h;
        var s = Snap(store, h, asr.AddSeconds(-3600));
        Assert.Equal(MenuStatus.Ready, s.Status);
        Assert.Equal(5, s.Rows.Count);
        Assert.Equal(Prayer.Asr, s.NextPrayer);
        Assert.Single(s.Rows, r => r.IsNext);
        Assert.True(s.Rows.Single(r => r.Prayer == Prayer.Dhuhr).IsPast);
        Assert.Equal("in 1 h", s.Subtitle);
        Assert.Equal("Toronto · ISNA · Standard", s.Footer);
        Assert.Equal(Prayer.Asr, s.HeaderPrayer);
    }

    [Fact]
    public void afterIshaTheListIsTomorrowsHeadedByFajr()
    {
        var after = FakeSchedule.At(Prayer.Isha).AddSeconds(600);
        var (store, h) = StoreAndGate(after, TestSettings.Test());
        using var _ = h;
        var s = Snap(store, h, after);
        Assert.Equal(FakeSchedule.At(Prayer.Fajr, day: 1), s.Rows[0].Time);
        Assert.True(s.Rows[0].IsNext);
        Assert.DoesNotContain(s.Rows, r => r.IsPast);
    }

    [Fact]
    public void duringABlockTheHeaderCountsDown()
    {
        var (store, h) = StoreAndGate(asr, TestSettings.Test());
        using var _ = h;
        h.Gate.AthanFired(Prayer.Asr, asr);
        var s = Snap(store, h, asr.AddSeconds(228));
        Assert.True(s.IsBlocked);
        Assert.Equal(Prayer.Asr, s.HeaderPrayer);
        Assert.Equal("6:12 left", s.Subtitle);
        h.Clock.Now = asr.AddSeconds(600);
        Assert.Equal("Ready when you are", Snap(store, h, asr.AddSeconds(600)).Subtitle);
    }

    [Fact]
    public void pausedShowsTheLineAndResumeEndsIt()
    {
        var (store, h) = StoreAndGate(asr.AddSeconds(-3600), TestSettings.Test());
        using var _ = h;
        store.Pause(PauseOption.UntilResumed, h.Clock.Now);
        var m = new MenuModel(store, h.Gate, h.Schedule, h.Clock, () => TimeZoneInfo.Utc);
        Assert.Equal("Paused until you resume", m.Snapshot(h.Clock.Now).Subtitle);
        m.Resume();
        Assert.Null(m.Snapshot(h.Clock.Now.AddSeconds(1)).PausedLine);
    }

    [Fact]
    public void noScheduleSaysSo()
    {
        var (store, h) = StoreAndGate(asr, TestSettings.Test());
        using var _ = h;
        h.Schedule.Valid = false;
        Assert.Equal(MenuStatus.NoSchedule, Snap(store, h, asr).Status);
    }

    // MARK: city search

    [Fact]
    public void creatingTheSearchNeverQueriesAndShortTextStaysIdle()
    {
        var geo = new FakeGeocoder();
        var m = new CitySearchModel(geo, TimeSpan.FromMilliseconds(10));
        m.QueryChanged("T");
        Assert.Equal(SearchState.Idle, m.State);
        Assert.Empty(geo.Queries);
    }

    [Fact]
    public async Task resultsNoMatchAndOffline()
    {
        var geo = new FakeGeocoder { Answer = q => q.StartsWith("Tor") ? [Toronto] : [] };
        var m = new CitySearchModel(geo, TimeSpan.FromMilliseconds(10));
        m.QueryChanged("Toronto");
        Assert.Equal(SearchState.Searching, m.State);           // skeleton rows
        await m.Settle();
        Assert.Equal(SearchState.Results, m.State);
        Assert.Equal("Toronto, Ontario", m.Results[0].Label);
        m.QueryChanged("Zzzz");
        await m.Settle();
        Assert.Equal(SearchState.NoMatch, m.State);
        geo.Offline = true;
        m.QueryChanged("Cairo");
        await m.Settle();
        Assert.Equal(SearchState.Offline, m.State);
    }

    [Fact]
    public async Task aNewKeystrokeCancelsTheOldSearch()
    {
        var geo = new FakeGeocoder { Answer = _ => [Toronto] };
        var m = new CitySearchModel(geo, TimeSpan.FromMilliseconds(80));
        m.QueryChanged("To");
        m.QueryChanged("Tor");
        m.QueryChanged("Toro");
        await m.Settle();
        Assert.Equal(["Toro"], geo.Queries);                    // debounced: only the last text goes out
    }

    [Theory]
    [InlineData("43.65, -79.38", 43.65, -79.38)]
    [InlineData("43.65 -79.38", 43.65, -79.38)]
    [InlineData("-33.9;18.4", -33.9, 18.4)]
    public void coordinateInputParses(string text, double lat, double lon)
    {
        var c = CoordinateInput.Parse(text)!;
        Assert.Equal((lat, lon), (c.Latitude, c.Longitude));
    }

    [Theory]
    [InlineData("91, 0")]
    [InlineData("hello")]
    [InlineData("1,2,3")]
    [InlineData("0, 181")]
    public void badCoordinatesAreRejected(string text) => Assert.Null(CoordinateInput.Parse(text));

    // MARK: Setup

    SetupModel Setup(SettingsStore store, Harness h, ILogonTask logon) =>
        new(store, h.Schedule, h.Clock, h.Audio, logon, new FakeGeocoder(), h.Gate, () => TimeZoneInfo.Utc);

    [Fact]
    public void setupWritesEverythingAtOnceAndNeverBlocksTheOpenPrayer()
    {
        var (store, h) = StoreAndGate(asr.AddSeconds(120));
        using var _ = h;
        var logon = new FakeLogon();
        var m = Setup(store, h, logon);
        Assert.Equal("Where do you pray?", m.Title);
        Assert.False(m.CanGoNext);
        m.PickedCity = Toronto;
        Assert.Equal("northAmerica", m.Method);                 // suggested from the country
        m.Next();
        Assert.Equal(SetupStep.Method, m.Step);
        Assert.False(store.Settings.SetupComplete);             // nothing saved yet
        m.Madhab = 2;
        m.Next();
        m.Mode = BlockMode.CodingApps;
        m.Volume = 0.3;
        m.Next();                                               // Finish
        Assert.Equal(SetupStep.Done, m.Step);
        var s = store.Settings;
        Assert.True(s.SetupComplete);
        Assert.Equal(("Toronto, Ontario", 2, BlockMode.CodingApps, "northAmerica"), (s.City, s.Madhab, s.Mode, s.Method));
        Assert.Equal(0.3f, s.AthanVolume, 3);
        Assert.True(s.LaunchAtLogin);
        Assert.Equal(1, logon.Registers);
        Assert.Equal("Next: Maghrib at 6:00 PM.", m.NextLine!.Replace(' ', ' '));
        // the Asr window that was open when setup finished is not blocked (CONTRACT-NOTES #28)
        h.Settings = store.Settings;
        h.Gate.Reevaluate(ReevalReason.SettingsChanged);
        h.Gate.Reevaluate(ReevalReason.Wake);
        Assert.Equal(Phase.Idle, h.Gate.Phase);
    }

    [Fact]
    public void aMethodPickedByHandIsNotOverwrittenByTheCountry()
    {
        var (store, h) = StoreAndGate(asr);
        using var _ = h;
        var m = Setup(store, h, new FakeLogon());
        m.PickedCity = Toronto;
        m.Method = "karachi";
        m.PickedCity = Cairo;
        Assert.Equal("karachi", m.Method);
    }

    [Fact]
    public void aFailedLogonTaskNeverBlocksSetup()
    {
        var (store, h) = StoreAndGate(asr);
        using var _ = h;
        var m = Setup(store, h, new FakeLogon { Fail = true });
        m.PickedCity = Toronto;
        m.Next(); m.Next(); m.Next();
        Assert.Equal(SetupStep.Done, m.Step);
        Assert.False(store.Settings.LaunchAtLogin);
        Assert.NotNull(m.LoginNote);
    }

    [Fact]
    public void setupIsRefusedDuringABlock()
    {
        var (store, h) = StoreAndGate(asr, TestSettings.Test());
        using var _ = h;
        h.Gate.AthanFired(Prayer.Asr, asr);
        var m = Setup(store, h, new FakeLogon());
        m.PickedCity = Toronto;
        m.Next(); m.Next(); m.Next();
        Assert.Equal(SetupStep.Mode, m.Step);
        Assert.Equal(Copy.BlockedLine, m.Notice);
    }

    // MARK: Settings

    [Fact]
    public void everySettingsChangeIsRefusedDuringABlockWithOneLine()
    {
        var (store, h) = StoreAndGate(asr, TestSettings.Test());
        using var _ = h;
        var logon = new FakeLogon();
        var m = new SettingsModel(store, h.Gate, h.Clock, h.Audio, logon, new FakeGeocoder(), () => TimeZoneInfo.Utc);
        h.Gate.AthanFired(Prayer.Asr, asr);
        Assert.True(m.IsBlocked);
        Assert.False(m.Apply(s => s with { LockMinutes = 30 }));
        Assert.Equal(Copy.BlockedLine, m.Notice);
        m.Pause(PauseOption.OneDay);
        Assert.Null(store.Settings.PausedUntil);
        m.SetLaunchAtLogin(true);
        Assert.Equal(0, logon.Registers);                      // the side effect never runs
        m.SetCity(Cairo);
        Assert.Equal("Testville", store.Settings.City);
    }

    [Fact]
    public void launchAtLoginOnRegistersFirstOffSavesFirst()
    {
        var (store, h) = StoreAndGate(asr.AddSeconds(-3600), TestSettings.Test());
        using var _ = h;
        var logon = new FakeLogon();
        var m = new SettingsModel(store, h.Gate, h.Clock, h.Audio, logon, new FakeGeocoder());
        m.SetLaunchAtLogin(true);
        Assert.True(store.Settings.LaunchAtLogin && logon.IsRegistered);
        m.SetLaunchAtLogin(false);
        Assert.False(store.Settings.LaunchAtLogin || logon.IsRegistered);
        logon.Fail = true;
        m.SetLaunchAtLogin(true);
        Assert.False(store.Settings.LaunchAtLogin);
        Assert.NotNull(m.Notice);
    }

    [Fact]
    public void pauseAndResumeBetweenPrayers()
    {
        var (store, h) = StoreAndGate(asr.AddSeconds(-3600), TestSettings.Test());
        using var _ = h;
        var m = new SettingsModel(store, h.Gate, h.Clock, h.Audio, new FakeLogon(), new FakeGeocoder(), () => TimeZoneInfo.Utc);
        Assert.Equal(PauseKind.Active, m.PauseState);
        m.Pause(PauseOption.UntilResumed);
        Assert.Equal(PauseKind.UntilResumed, m.PauseState);
        Assert.Equal("Paused until you resume", m.PauseSummary);
        m.Resume();
        h.Clock.Advance(1);
        Assert.Equal(PauseKind.Active, m.PauseState);
        m.Pause(PauseOption.ThreeDays);
        Assert.Equal("Paused until Sun Oct 25", m.PauseSummary);
    }

    [Fact]
    public void automaticHighLatitudeLabelFollowsTheCity()
    {
        var (store, h) = StoreAndGate(asr, TestSettings.Test() with { Latitude = 59.9 });
        using var _ = h;
        var m = new SettingsModel(store, h.Gate, h.Clock, h.Audio, new FakeLogon(), new FakeGeocoder());
        Assert.Equal("Automatic (Seventh of the night)", m.AutomaticRuleLabel);
    }

    [Fact]
    public void previewNeverStopsABlocksAthan()
    {
        var (store, h) = StoreAndGate(asr.AddSeconds(-60), TestSettings.Test());
        using var _ = h;
        var p = new AthanPreview(h.Audio, () => h.Gate.IsBlocked);
        p.Toggle(Voice.Sunni("Saber"), 0.5f);
        Assert.True(p.IsPlaying);
        Assert.Equal(Prayer.Dhuhr, h.Audio.Plays.Single().Prayer);   // Dhuhr: Fajr would ignore the voice
        h.Clock.Now = asr;
        h.Gate.AthanFired(Prayer.Asr, asr);                          // a block takes the audio over
        int stops = h.Audio.StopCount;
        p.Stop();
        Assert.Equal(stops, h.Audio.StopCount);
        Assert.False(p.IsPlaying);
    }

    // MARK: copy tables

    [Fact]
    public void theVoicePickerHasThe28Voices()
    {
        Assert.Equal(16, VoiceChoices.Sunni.Count);
        Assert.Equal(12, VoiceChoices.Shia.Count);
        Assert.Equal(28, VoiceChoices.All.Select(v => v.Voice).Distinct().Count());
        Assert.Contains(VoiceChoices.All, v => v.Voice == VoiceChoices.DefaultVoice);
        Assert.Contains("Sheikh Hamed", VoiceChoices.FajrNote);
    }

    [Fact]
    public void suggestedMethodsFollowTheCountry()
    {
        Assert.Equal("northAmerica", Labels.SuggestedMethod("CA"));
        Assert.Equal("ummAlQura", Labels.SuggestedMethod("sa"));
        Assert.Equal("egyptian", Labels.SuggestedMethod("EG"));
        Assert.Equal("muslimWorldLeague", Labels.SuggestedMethod(null));
        Assert.Equal(12, Labels.Methods.Count);
        Assert.Equal(SettingsRules.Methods, Labels.Methods.Select(m => m.Raw).ToArray());
        Assert.All(Labels.Methods, m => Assert.True(m.DisplayName.Length > 0 && m.Detail.Length > 0));
    }

    [Fact]
    public void copyKeepsTheDoNotList()
    {
        var all = string.Join(" ", new[]
        {
            Copy.BlockedLine, Copy.InvalidLine, Copy.LaunchAtLoginNote, CitySearchModel.NoMatchLine, CitySearchModel.OfflineLine,
            Credits.TakedownText, Credits.FajrNote, Labels.ModeHelp(BlockMode.WholeScreen), Labels.ModeHelp(BlockMode.CodingApps),
        });
        Assert.DoesNotContain("!", all);                                    // no exclamation marks
        foreach (var w in new[] { "missed", "streak", "Don't break" }) Assert.DoesNotContain(w, all, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("hello@simkinselgazar.com", Credits.TakedownText);
    }
}
