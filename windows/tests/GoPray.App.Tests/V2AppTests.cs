// V2AppTests.cs — v2 App parts: the update checker with a fake transport and verifier (PLAN-v2 §8.5), and the
// emergency exit on the native fallback (hold, card, one request) and through the shield controller (§5 lane F).

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using GoPray.App.Shield;
using GoPray.App.Update;
using GoPray.Core;
using Xunit;

namespace GoPray.App.Tests;

sealed class FakeTransport : IUpdateTransport
{
    public string Releases = "[]";
    public List<Uri> Gets = [], Downloads = [];
    public Task<string> GetText(Uri url, CancellationToken c) { Gets.Add(url); return Task.FromResult(Releases); }
    public Task Download(Uri url, string path, long max, CancellationToken c)
    {
        Downloads.Add(url);
        File.WriteAllText(path, url.AbsoluteUri.EndsWith(".sha256") ? new string('a', 64) + "  GoPray-Setup.exe" : "setup bytes");
        return Task.CompletedTask;
    }
}

sealed class FakeVerifier(bool ok) : IUpdateVerifier
{
    public int Calls;
    public string? Expected;
    public bool Verify(string file, string sha) { Calls++; Expected = sha; return ok; }
}

sealed class TestClock(DateTime now) : IClock { public DateTime Now { get; set; } = now; }

public class V2AppTests : IDisposable
{
    readonly string _dir = Path.Combine(Path.GetTempPath(), "gopray-update-" + Guid.NewGuid().ToString("N"));
    public void Dispose() { try { Directory.Delete(_dir, true); } catch { } }

    const string Dl = "https://github.com/simkinselgazar-rgb/go-pray/releases/download/";

    static string Release(string tag, bool draft = false, bool pre = false, string? setupUrl = null, long size = 65_000_000)
    {
        var v = tag.StartsWith("win-v") ? tag[5..] : tag.TrimStart('v');
        var name = $"GoPray-Setup-{v}.exe";
        return $$"""
        { "tag_name": "{{tag}}", "draft": {{(draft ? "true" : "false")}}, "prerelease": {{(pre ? "true" : "false")}},
          "assets": [ { "name": "{{name}}", "size": {{size}}, "browser_download_url": "{{setupUrl ?? Dl + tag + "/" + name}}" },
                      { "name": "{{name}}.sha256", "size": 90, "browser_download_url": "{{Dl + tag + "/" + name}}.sha256" },
                      { "name": "GoPray-{{v}}.dmg", "size": 9, "browser_download_url": "{{Dl + tag}}/GoPray-{{v}}.dmg" } ] }
        """;
    }

    static readonly string ReleasesJson = "[" + string.Join(",", Release("v0.1.1"), Release("v0.2.0"), Release("win-v0.1.0"), Release("win-v0.2.0"),
                                                       Release("win-v0.3.0", draft: true), Release("win-v0.3.0-beta", pre: true)) + "]";

    UpdateChecker Checker(FakeTransport t, IUpdateVerifier v, Func<bool>? blocked = null, Func<bool>? auto = null, Version? current = null, TestClock? clock = null, List<string>? runs = null) =>
        new(current ?? new Version(0, 1, 0), _dir, blocked ?? (() => false), auto ?? (() => true), clock ?? new TestClock(new DateTime(2026, 10, 24, 12, 0, 0, DateTimeKind.Utc)),
            s => runs?.Add(s), t, v);

    [Fact]
    public void picksTheHighestWindowsReleaseSkippingDraftsPrereleasesAndMacTags()
    {
        var r = UpdateChecker.Pick(ReleasesJson, new Version(0, 1, 0))!;
        Assert.Equal("win-v0.2.0", r.Tag);
        Assert.Equal(new Version(0, 2, 0), r.Version);
        Assert.Equal(Dl + "win-v0.2.0/GoPray-Setup-0.2.0.exe", r.Setup.AbsoluteUri);
        Assert.Null(UpdateChecker.Pick(ReleasesJson, new Version(0, 2, 0)));                     // equal → up to date
        Assert.Null(UpdateChecker.Pick(ReleasesJson, new Version(0, 3, 0)));                     // lower → nothing
        Assert.Null(UpdateChecker.ParseTag("win-v0.3.0-beta"));
        Assert.Null(UpdateChecker.ParseTag("v0.2.0"));
    }

    [Fact]
    public void anAssetOffOurPathOrTooBigIsRejected()
    {
        Assert.Null(UpdateChecker.Pick("[" + Release("win-v0.2.0", setupUrl: "https://evil.example/GoPray-Setup-0.2.0.exe") + "]", new Version(0, 1, 0)));
        Assert.Null(UpdateChecker.Pick("[" + Release("win-v0.2.0", setupUrl: "https://github.com/someone/go-pray/releases/download/win-v0.2.0/GoPray-Setup-0.2.0.exe") + "]", new Version(0, 1, 0)));
        Assert.Null(UpdateChecker.Pick("[" + Release("win-v0.2.0", size: UpdateChecker.MaxBytes + 1) + "]", new Version(0, 1, 0)));
    }

    [Fact]
    public async Task blockedMeansNoNetworkAtAllEvenForCheckNow()
    {
        var t = new FakeTransport { Releases = ReleasesJson };
        var u = Checker(t, new FakeVerifier(true), blocked: () => true);
        await u.AutomaticCheck();
        await u.CheckNow();
        Assert.Empty(t.Gets);
        Assert.Equal(0, u.Requests);
    }

    [Fact]
    public async Task switchedOffStopsAutomaticChecksButCheckNowWorks()
    {
        var t = new FakeTransport { Releases = ReleasesJson };
        var u = Checker(t, new FakeVerifier(true), auto: () => false);
        await u.AutomaticCheck();
        Assert.Empty(t.Gets);
        await u.CheckNow();
        Assert.Single(t.Gets);
        Assert.Equal(UpdateStatus.Available, u.Status);
        Assert.StartsWith("https://api.github.com/repos/simkinselgazar-rgb/go-pray/releases", t.Gets[0].AbsoluteUri);
    }

    [Fact]
    public async Task automaticChecksAreDailyAndACorruptMemoryChecksOnce()
    {
        var clock = new TestClock(new DateTime(2026, 10, 24, 12, 0, 0, DateTimeKind.Utc));
        var t = new FakeTransport { Releases = "[]" };
        var u = Checker(t, new FakeVerifier(true), clock: clock);
        Directory.CreateDirectory(_dir);
        File.WriteAllText(u.MemoryFile, "{ broken");
        await u.AutomaticCheck();
        Assert.Single(t.Gets);                                    // corrupt = never checked
        Assert.Equal(UpdateStatus.UpToDate, u.Status);
        clock.Now = clock.Now.AddHours(23);
        await u.AutomaticCheck();
        Assert.Single(t.Gets);                                    // 23 h: no call
        clock.Now = clock.Now.AddHours(2);
        await u.AutomaticCheck();
        Assert.Equal(2, t.Gets.Count);                            // 25 h: call
    }

    [Fact]
    public async Task aDownloadThatFailsVerificationIsDeletedAndNeverRun()
    {
        var t = new FakeTransport { Releases = ReleasesJson };
        var runs = new List<string>();
        var v = new FakeVerifier(false);
        var u = Checker(t, v, runs: runs);
        await u.CheckNow();
        await u.DownloadAndOpen();
        Assert.Equal(1, v.Calls);
        Assert.Equal(new string('a', 64), v.Expected);           // the hash from the .sha256 asset
        Assert.Empty(runs);
        Assert.Equal(UpdateStatus.Failed, u.Status);
        Assert.Equal("Couldn't verify the download. Get it from GitHub.", u.Message);
        Assert.Empty(Directory.GetFiles(u.UpdatesDir));
    }

    [Fact]
    public async Task aVerifiedDownloadRunsTheInstallerOnceOutsideABlock()
    {
        var t = new FakeTransport { Releases = ReleasesJson };
        var runs = new List<string>();
        bool blocked = false;
        var u = Checker(t, new FakeVerifier(true), blocked: () => blocked, runs: runs);
        await u.CheckNow();
        blocked = true;
        await u.DownloadAndOpen();                                // a block started: nothing downloads
        Assert.Empty(t.Downloads);
        blocked = false;
        await u.DownloadAndOpen();
        Assert.Single(runs);
        Assert.EndsWith(Path.Combine("updates", "GoPray-Setup-0.2.0.exe"), runs[0]);
        Assert.Equal([Dl + "win-v0.2.0/GoPray-Setup-0.2.0.exe.sha256", Dl + "win-v0.2.0/GoPray-Setup-0.2.0.exe"], t.Downloads.Select(x => x.AbsoluteUri));
        u.ClearDownloads();
        Assert.False(Directory.Exists(u.UpdatesDir));
    }

    [Fact]
    public void theRealVerifierRejectsAnUnsignedFileAndAWrongHash()
    {
        Directory.CreateDirectory(_dir);
        var f = Path.Combine(_dir, "x.exe");
        File.WriteAllText(f, "not signed");
        var sha = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(f)));
        var v = new UpdateChecker.SignatureVerifier();
        Assert.False(v.Verify(f, new string('0', 64)));           // wrong hash
        Assert.False(v.Verify(f, sha));                           // right hash, no Authenticode signature
    }

    [Fact]
    public void theVersionLineComesFromTheBuildNotFromText()
    {
        Assert.Equal("0.2.0", UI.AppVersion.Clean("0.2.0+6dc13d1d9620cea87f5629cbd5a10014b8aeef25"));
        Assert.Equal("0.0.0", UI.AppVersion.Clean(null));
        Assert.Equal("Go Pray 0.3.0", UI.AppVersion.Line);                     // <Version> in GoPray.App.csproj
        Assert.Equal(new Version(0, 3, 0, 0), typeof(UpdateChecker).Assembly.GetName().Version);   // what the checker compares
    }

    [Fact]
    public void onlyCanonicalTagsAreOffered()
    {
        Assert.Null(UpdateChecker.ParseTag("win-v01.2.0"));
        Assert.Null(UpdateChecker.ParseTag("win-v0.2.00"));
        Assert.Equal(new Version(0, 2, 0), UpdateChecker.ParseTag("win-v0.2.0"));
        var json = "[" + Release("win-v01.2.0").Replace("GoPray-Setup-01.2.0", "GoPray-Setup-1.2.0") + "]";
        Assert.Null(UpdateChecker.Pick(json, new Version(0, 1, 0)));
    }

    [Theory]
    [InlineData("tag", "win-v0.3.0")]                                                        // tag and version disagree
    [InlineData("tag", "win-v00.2.0")]                                                       // non-canonical tag
    [InlineData("assetURL", "https://evil.example/GoPray-Setup-0.2.0.exe")]                  // another host
    [InlineData("assetURL", "https://github.com/someone/go-pray/releases/download/win-v0.2.0/GoPray-Setup-0.2.0.exe")]   // another repo
    [InlineData("size", "0")]                                                                // empty
    [InlineData("version", "0.1.0")]                                                         // not newer
    public async Task aTamperedStoredOfferIsRefused(string key, string value)
    {
        var t = new FakeTransport { Releases = ReleasesJson };
        var runs = new List<string>();
        var u = Checker(t, new FakeVerifier(true), runs: runs);
        await u.CheckNow();
        Assert.NotNull(u.StoredOffer());                                       // the honest offer is accepted
        var doc = System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(u.MemoryFile))!;
        doc["latest"]![key] = key == "size" ? System.Text.Json.Nodes.JsonValue.Create(long.Parse(value)) : System.Text.Json.Nodes.JsonValue.Create(value);
        if (key == "version") doc["latest"]!["tag"] = "win-v" + value;
        File.WriteAllText(u.MemoryFile, doc.ToJsonString());
        Assert.Null(u.StoredOffer());
        await u.DownloadAndOpen();
        Assert.Empty(t.Downloads);
        Assert.Empty(runs);
    }

    /// <summary>Live check against a real signed installer, when one is named (local only: CI has none).
    /// GOPRAY_TEST_SIGNED_SETUP=<path to GoPray-Setup.exe> GOPRAY_TEST_SIGNED_SHA=<its sha256></summary>
    [Fact]
    public void theRealVerifierAcceptsTheShippedSignedInstallerWhenGiven()
    {
        var path = Environment.GetEnvironmentVariable("GOPRAY_TEST_SIGNED_SETUP");
        var sha = Environment.GetEnvironmentVariable("GOPRAY_TEST_SIGNED_SHA");
        if (string.IsNullOrEmpty(path) || string.IsNullOrEmpty(sha) || !File.Exists(path)) return;
        Assert.True(new UpdateChecker.SignatureVerifier().Verify(path, sha));
        Assert.False(new UpdateChecker.SignatureVerifier().Verify(path, new string('0', 64)));
    }

    // MARK: emergency exit on the native fallback

    static ShieldContext Ctx(int exits, int remainingMs = 300_000) => new() { Prayer = Prayer.Asr, RemainingMs = remainingMs, EmergencyExitsLeft = exits, LockSeconds = 600 };

    [Fact]
    public void fallbackFooterIsAbsentAtZeroAndShowsTheCount() => Ui.Run(async () =>
    {
        var m = new FallbackModel(Ctx(0));
        var v = new NativeFallbackShield(m);
        Assert.False(v.ExitVisible);
        m.Apply(Ctx(3));
        Assert.True(v.ExitVisible);
        Assert.Equal("Emergency exit · 3 of 5 left this year", v.ExitText);
        await Task.CompletedTask;
    });

    [Fact]
    public void fallbackHoldReleasedEarlySendsNothingAndAFullHoldOpensTheCard() => Ui.Run(async () =>
    {
        int asked = 0;
        var m = new FallbackModel(Ctx(3)) { OnEmergency = () => asked++ };
        var v = new NativeFallbackShield(m) { HoldFor = TimeSpan.FromMilliseconds(400) };
        v.BeginHold();
        Assert.Equal("Keep holding…", v.ExitText);
        await Task.Delay(200);
        v.CancelHold();                                           // released at half time
        await Task.Delay(400);
        Assert.False(v.CardOpen);
        Assert.Equal(0, asked);
        v.BeginHold();
        Assert.True(await Ui.Until(2, () => v.CardOpen));
        Assert.Equal("This ends the block now. Asr will count as missed, not prayed. You'll have 2 of 5 left this year.", v.CardBody);
        v.PressNotNow();
        Assert.False(v.CardOpen);
        Assert.Equal(0, asked);                                   // "Not now" sends nothing
        v.BeginHold();
        Assert.True(await Ui.Until(2, () => v.CardOpen));
        v.PressUseIt();
        Assert.Equal(1, asked);                                   // exactly one request
        Assert.False(v.CardOpen);
    });

    [Fact]
    public void controllerRoutesTheFallbacksRequestAndClosesWithoutTheAcceptLine() => Ui.Run(async () =>
    {
        var spy = new SpyDelegate();
        var c = Fixture.Controller(scenesRoot: Fixture.Scratch([]));    // no page → native fallback at once
        c.Delegate = spy;
        try
        {
            c.Show(Ctx(4));
            var slot = c.Slots[0];
            Assert.True(await Ui.Until(3, () => slot.Fallback != null));
            Assert.True(slot.FallbackView!.ExitVisible);
            slot.Fallback!.OnEmergency();
            Assert.Equal(1, spy.Emergencies);
            int idle = 0;
            var sw = System.Diagnostics.Stopwatch.StartNew();
            c.Dismiss(() => idle++, EndKind.Emergency);
            Assert.True(slot.Fallback.Leaving);
            Assert.False(slot.Fallback.Accepting);                // no "May Allah accept it."
            Assert.True(await Ui.Until(3, () => idle == 1));
            Assert.True(sw.ElapsedMilliseconds < Ui.Upper(2000));
            Assert.False(c.IsPresenting);
        }
        finally { c.TearDown(); }
    });

    [Fact]
    public void aRefusedFallbackRequestShowsTheNote() => Ui.Run(async () =>
    {
        var m = new FallbackModel(Ctx(1));
        var v = new NativeFallbackShield(m);
        m.RequestEmergency();
        m.Apply(Ctx(0));                                          // the gate said no (e.g. the write failed) and re-synced
        Assert.True(v.ShowingExitNote);
        Assert.Equal("Couldn't use the exit. Try again in a moment.", v.ExitText);
        await Task.CompletedTask;
    });

    /// <summary>The Mac lane's bridge.js on the real page: the footer, the 3 s hold, the card, one `emergency`,
    /// the refusal note, and the plain fade with no accept line.</summary>
    [Fact]
    public void thePagesHoldCardAndPlainFadeWorkEndToEnd() => Ui.Run(async () =>
    {
        var spy = new SpyDelegate();
        var c = Fixture.Controller();
        c.Delegate = spy;
        try
        {
            c.Show(Ctx(3));
            var web = c.Slots[0].Web!;
            Assert.True(await Ui.Until(4, () => c.Slots[0].Ready));
            Assert.True(await Ui.UntilAsync(2, () => Fixture.BlockBuilt(web)));
            Assert.True(await Ui.UntilAsync(2, async () => await Fixture.Text(web, "document.querySelector('.exit-label')?.textContent ?? ''") == "Emergency exit · 3 of 5 left this year"));
            await web.Js("document.querySelector('.exit-btn').dispatchEvent(new PointerEvent('pointerdown', { button: 0, bubbles: true }))");
            await Task.Delay(1000);
            await web.Js("document.querySelector('.exit-btn').dispatchEvent(new PointerEvent('pointerup', { button: 0, bubbles: true }))");   // released early
            await Task.Delay(2500);
            Assert.Equal("none", await Fixture.Text(web, "document.querySelector('.exit-card') ? 'card' : 'none'"));
            await web.Js("document.querySelector('.exit-btn').dispatchEvent(new PointerEvent('pointerdown', { button: 0, bubbles: true }))");
            Assert.True(await Ui.UntilAsync(5, async () => await Fixture.Text(web, "document.querySelector('.exit-card') ? 'card' : 'none'") == "card"));
            Assert.Equal(0, spy.Emergencies);
            await web.Js("document.querySelector('.exit-yes').click()");
            Assert.True(await Ui.Until(2, () => spy.Emergencies == 1));
            c.Update(Ctx(3, 290_000));                            // the gate refused: re-sync
            Assert.True(await Ui.UntilAsync(2, async () => (await Fixture.Text(web, "document.querySelector('.exit-note')?.textContent ?? ''")).StartsWith("Couldn't use the exit")));
            int idle = 0;
            c.Dismiss(() => idle++, EndKind.Emergency);
            await Task.Delay(300);
            Assert.Equal("false", await Fixture.Text(web, "String(!!document.querySelector('.accept.is-on'))"));   // no "May Allah accept it."
            Assert.True(await Ui.Until(3, () => idle == 1));      // `gone` after the plain fade
        }
        finally { c.TearDown(); }
    });

    [Fact]
    public void thePagesEmergencyMessageReachesTheDelegateOnlyFromTheMainSlot() => Ui.Run(async () =>
    {
        var spy = new SpyDelegate();
        var c = Fixture.Controller([Fixture.D("1", 0, 1920, 1080), Fixture.D("2", 1920, 1920, 1080)]);
        c.Delegate = spy;
        try
        {
            c.Show(Ctx(2));
            Assert.True(await Ui.Until(8, () => c.Slots.All(s => s.Ready)));
            await c.Slots[1].Web!.Js("window.chrome.webview.postMessage({type:'emergency'})");    // art slot: ignored
            await Task.Delay(300);
            Assert.Equal(0, spy.Emergencies);
            await c.Slots[0].Web!.Js("window.chrome.webview.postMessage({type:'emergency'})");
            Assert.True(await Ui.Until(2, () => spy.Emergencies == 1));
        }
        finally { c.TearDown(); }
    });
}
