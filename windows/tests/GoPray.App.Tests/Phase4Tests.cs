// Phase4Tests.cs — hider (fake desktop), coding-apps list, logon-task XML, geocoder parsing, the Athan files and
// player (real NAudio, volume 0), the media-pause order, and the still crop maths. Ports of AppHiderTests,
// AthanPlayerTests and SceneStillTests where the case is the same.

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Threading.Tasks;
using System.Windows;
using System.Xml.Linq;
using GoPray.App.Audio;
using GoPray.App.Blocker;
using GoPray.App.Launch;
using GoPray.App.Places;
using GoPray.App.UI;
using GoPray.Core;
using Xunit;

namespace GoPray.App.Tests;

static class TestEnv
{
    /// <summary>No test touches the real %LOCALAPPDATA%\GoPray (DEBUG override, like the Mac's TestHost folder).</summary>
    [ModuleInitializer]
    internal static void Init() =>
        Environment.SetEnvironmentVariable("GOPRAY_DEBUG_STATE_DIR", Path.Combine(Path.GetTempPath(), "gopray-app-tests-state"));
}

sealed class FakeDesktop : IWindowSystem
{
    public Dictionary<IntPtr, string> Windows = [];
    public HashSet<IntPtr> Minimised = [];
    public HashSet<IntPtr> Refuse = [];
    public Action<IntPtr>? Foreground;
    public int Watching;
    public IEnumerable<(IntPtr, string)> TopLevel() => Windows.Select(kv => (kv.Key, kv.Value)).ToList();
    public string? ProcessOf(IntPtr h) => Windows.TryGetValue(h, out var p) ? p : null;
    public bool IsMinimised(IntPtr h) => Minimised.Contains(h);
    public bool Minimise(IntPtr h) { if (Refuse.Contains(h)) return false; Minimised.Add(h); return true; }
    public IDisposable Watch(Action<IntPtr> f) { Foreground = f; Watching++; return new Off(this); }
    sealed class Off(FakeDesktop d) : IDisposable { public void Dispose() { d.Foreground = null; d.Watching--; } }
}

sealed class SpyPauser : IMediaPausing
{
    public int Calls;
    public void PauseOthers() => Calls++;
}

public class Phase4Tests
{
    // MARK: hider

    static readonly IntPtr Cursor = 1, Term = 2, Notes = 3, Edge = 4;

    static (AppHider, FakeDesktop) Hider()
    {
        var d = new FakeDesktop { Windows = { [Cursor] = "Cursor", [Term] = "WindowsTerminal", [Notes] = "notepad", [Edge] = "MSEDGE" } };
        return (new AppHider(d), d);
    }

    [Fact]
    public void startMinimisesListedAppsOnlyCaseInsensitive()
    {
        var (h, d) = Hider();
        h.Start();
        Assert.Equal(new[] { Cursor, Term, Edge }.OrderBy(x => x), d.Minimised.OrderBy(x => x));
        Assert.DoesNotContain(Notes, d.Minimised);
    }

    [Fact]
    public void aListedAppComingForwardIsMinimisedAgainAndNamed()
    {
        var (h, d) = Hider();
        var names = new List<string>();
        h.OnReHide = names.Add;
        h.Start();
        d.Minimised.Remove(Cursor);                // the person clicks it in the taskbar
        d.Foreground!(Cursor);
        Assert.Contains(Cursor, d.Minimised);
        Assert.Equal(["Cursor"], names);
        d.Foreground!(Notes);                      // not listed: left alone
        Assert.DoesNotContain(Notes, d.Minimised);
        Assert.Single(names);
    }

    [Fact]
    public void stopIgnoresLateEventsAndRestoresNothing()
    {
        var (h, d) = Hider();
        h.Start();
        var watch = d.Foreground!;
        h.Stop();
        Assert.Equal(0, d.Watching);
        d.Minimised.Remove(Cursor);
        watch(Cursor);                             // a late event after the block
        Assert.DoesNotContain(Cursor, d.Minimised);
        Assert.Contains(Term, d.Minimised);        // nothing was restored by us
    }

    [Fact]
    public void startTwiceWatchesOnceAndARefusingWindowIsLeftAlone()
    {
        var (h, d) = Hider();
        d.Refuse.Add(Term);                        // e.g. an elevated terminal (UIPI)
        h.Start(); h.Start();
        Assert.Equal(1, d.Watching);
        Assert.DoesNotContain(Term, d.Minimised);
        Assert.Contains(Cursor, d.Minimised);
    }

    [Fact]
    public void theListHasTheAppsSeenOnThisPcAndNotGoPray()
    {
        foreach (var p in new[] { "cmd", "msedge", "Cursor", "WindowsTerminal", "warp", "WARP", "powershell", "ChatGPT", "Code", "chrome", "firefox" })
            Assert.True(CodingApps.IsListed(p), p);
        foreach (var p in new[] { "GoPray", "msedgewebview2", "explorer", "Spotify", "Teams", "Zoom", "notepad" })
            Assert.False(CodingApps.IsListed(p), p);
        Assert.Equal("Visual Studio Code", CodingApps.DisplayName("code"));
    }

    // MARK: logon task

    [Fact]
    public void logonTaskXmlHasBothTriggersIgnoreNewNoTimeLimitAndTheTick()
    {
        var xml = LogonTask.Xml(@"AzureAD\someone", @"C:\Users\x\AppData\Local\Programs\Go Pray\GoPray.exe", new DateTime(2026, 10, 23, 12, 0, 0));
        var doc = XDocument.Parse(xml);
        XNamespace t = "http://schemas.microsoft.com/windows/2004/02/mit/task";
        Assert.NotNull(doc.Descendants(t + "LogonTrigger").Single());
        Assert.Equal("PT1M", doc.Descendants(t + "TimeTrigger").Single().Descendants(t + "Interval").Single().Value);
        Assert.Equal("IgnoreNew", doc.Descendants(t + "MultipleInstancesPolicy").Single().Value);
        Assert.Equal("PT0S", doc.Descendants(t + "ExecutionTimeLimit").Single().Value);     // the 3-day default would kill the app
        Assert.Equal("LeastPrivilege", doc.Descendants(t + "RunLevel").Single().Value);
        Assert.Equal("InteractiveToken", doc.Descendants(t + "LogonType").Single().Value);
        Assert.Equal("false", doc.Descendants(t + "StopIfGoingOnBatteries").Single().Value);
        Assert.Equal("--tick", doc.Descendants(t + "Arguments").Single().Value);
        Assert.EndsWith("GoPray.exe", doc.Descendants(t + "Command").Single().Value);
        Assert.Empty(doc.Descendants(t + "RestartOnFailure"));                               // spike Q3: it never fires after End task
    }

    [Fact]
    public void logonTaskXmlEscapesNames() =>
        Assert.Contains("Tom &amp; Jerry", LogonTask.Xml("PC\\Tom & Jerry", "C:\\a.exe", DateTime.Now));

    // MARK: geocoder (parsing only; tests never call the network)

    [Fact]
    public void openMeteoResultsBecomeCityMatches()
    {
        const string json = """
        {"results":[
          {"name":"Toronto","latitude":43.70011,"longitude":-79.4163,"country_code":"CA","country":"Canada","admin1":"Ontario"},
          {"name":"Toronto","latitude":43.70011,"longitude":-79.4163,"country_code":"CA","country":"Canada","admin1":"Ontario"},
          {"name":"Toronto","latitude":40.46423,"longitude":-80.60091,"country_code":"US","country":"United States","admin1":"Ohio"},
          {"latitude":1,"longitude":2}
        ],"generationtime_ms":0.5}
        """;
        var r = Geocoder.Parse(json);
        Assert.Equal(2, r.Count);                                    // de-duplicated, nameless dropped
        Assert.Equal("Toronto, Ontario", r[0].Label);
        Assert.Equal("Ontario, Canada", r[0].Subtitle);
        Assert.Equal("CA", r[0].CountryCode);
        Assert.Empty(Geocoder.Parse("""{"generationtime_ms":0.3}"""));   // no "results" = no match
    }

    // MARK: Athan files + player

    static AthanPlayer Player(SpyPauser? p = null) => new(Path.Combine(AppContext.BaseDirectory, "Resources", "athan"), p ?? new SpyPauser());

    [Fact]
    public void every28VoicesAndFajrHasItsFile()
    {
        var player = Player();
        foreach (var v in VoiceChoices.All) Assert.True(File.Exists(player.FileFor(Prayer.Dhuhr, v.Voice)), v.Name);
        Assert.EndsWith(VoiceChoices.FajrStem + ".mp3", player.FileFor(Prayer.Fajr, Voice.Shia("Salimi")));   // Fajr ignores the voice
        Assert.Throws<AthanException>(() => player.FileFor(Prayer.Asr, Voice.Sunni("Yusuf-Islam")));         // never a fallback
    }

    [Fact]
    public void fajrStartsAtNineSecondsAndOtherMediaIsPausedOnce() => Ui.Run(async () =>
    {
        var spy = new SpyPauser();
        var player = Player(spy);
        if (NoSoundDevice) { NoDeviceThrowsAndNeverPauses(player, spy); return; }
        player.Play(Prayer.Fajr, VoiceChoices.DefaultVoice, 0f);   // volume 0: silent
        try
        {
            Assert.InRange(player.Position, 8.95, 9.3);
            Assert.True(player.IsPlaying);
            Assert.InRange(player.RemainingMs(), 1, 195_300 - 9_000);
            Assert.Equal(1, spy.Calls);
            await Task.Delay(300);
            Assert.True(player.Position > 9.0);
        }
        finally { player.Stop(); }
        Assert.False(player.IsPlaying);
        Assert.Equal(0, player.RemainingMs());
    });

    /// <summary>The GitHub runner has no sound card. There the real-playback tests check the no-device path
    /// instead: a clean AthanException (the gate logs it, the block goes on silently) and no media pause.</summary>
    static bool NoSoundDevice => NAudio.Wave.WaveOut.DeviceCount == 0;

    static void NoDeviceThrowsAndNeverPauses(AthanPlayer player, SpyPauser? spy)
    {
        var e = Assert.Throws<AthanException>(() => player.Play(Prayer.Fajr, VoiceChoices.DefaultVoice, 0f));
        Assert.StartsWith("no audio device", e.Message);
        Assert.False(player.IsPlaying);
        Assert.Equal(0, player.RemainingMs());
        if (spy != null) Assert.Equal(0, spy.Calls);
    }

    [Fact]
    public void aMissingFileThrowsAndNeverPauses()
    {
        var spy = new SpyPauser();
        Assert.Throws<AthanException>(() => Player(spy).Play(Prayer.Asr, Voice.Sunni("nope"), 0f));
        Assert.Equal(0, spy.Calls);
    }

    [Fact]
    public void stopNeverCallsOnFinished() => Ui.Run(async () =>
    {
        var player = Player();
        if (NoSoundDevice) { NoDeviceThrowsAndNeverPauses(Player(new SpyPauser()), null); return; }
        int finished = 0;
        player.OnFinished = () => finished++;
        player.Play(Prayer.Dhuhr, Voice.Sunni("Hafiz-Murad"), 0f);
        await Task.Delay(200);
        player.Stop();
        await Task.Delay(300);
        Assert.Equal(0, finished);
    });

    // MARK: still crop maths (SceneStill.swift)

    [Fact]
    public void stillCropKeepsTheSubjectInsideThePage()
    {
        foreach (var p in Enum.GetValues<Prayer>())
        {
            var (page, crop) = SceneStillRenderer.Crop(p, new Size(320, 96));
            Assert.Equal(320, crop.Width);
            Assert.Equal(96, crop.Height);
            Assert.True(crop.X >= 0 && crop.Right <= page.Width + 0.001 && crop.Y >= 0 && crop.Bottom <= page.Height + 0.001, $"{p}: {crop} in {page}");
        }
        var (pg, cr) = SceneStillRenderer.Crop(Prayer.Dhuhr, new Size(320, 96));   // 680 units wide at 320 pt
        Assert.Equal(1600 * 320.0 / 680, pg.Width, 6);
        var (wide, _) = SceneStillRenderer.Crop(Prayer.Dhuhr, new Size(520, 96));   // the Setup band uses 1.35 x the units
        Assert.Equal(1600 * 520.0 / (680 * 1.35), wide.Width, 6);
        _ = cr;
    }

    [Fact]
    public void aStillIsPaintedOffScreenAndCached() => Ui.Run(async () =>
    {
        var dir = Path.Combine(Path.GetTempPath(), "gopray-stills-" + Guid.NewGuid().ToString("N"));
        var r = new SceneStillRenderer(dir);
        var img = await r.Image(Prayer.Isha, new Size(320, 96), 1.25);
        Assert.NotNull(img);
        Assert.Equal(400, img!.PixelWidth);
        Assert.Equal(120, img.PixelHeight);
        var path = r.CachePath(Prayer.Isha, new Size(320, 96), 1.25);
        Assert.True(File.Exists(path));
        var again = await r.Image(Prayer.Isha, new Size(320, 96), 1.25);      // from the cache now
        Assert.NotNull(again);
        Directory.Delete(dir, true);
    }, timeoutSeconds: 90);
}
