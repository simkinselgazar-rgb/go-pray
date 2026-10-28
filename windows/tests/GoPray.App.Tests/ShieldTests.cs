// ShieldTests.cs — the shield with the real shield.html in a real WebView2 (off-screen); the gate is a spy.
// Ports of GoPrayTests/Shield/BridgeMessageTests.swift (page parts), ShieldContextTests.swift (ring) and
// WebLockdownTests.swift (lockdown + fallback), same test names where the case is the same.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;
using GoPray.App.Shield;
using GoPray.Core;
using Xunit;
using Xunit.Abstractions;

namespace GoPray.App.Tests;

public class ShieldTests(ITestOutputHelper output)
{
    // MARK: the real page

    [Theory]
    [InlineData(1440, 900)]
    [InlineData(5120, 2880)]
    public void pageSaysReadyWithinTwoSeconds(int w, int h) => Ui.Run(async () =>
    {
        var c = Fixture.Controller([Fixture.D("1", w: w, h: h)]);
        try
        {
            var sw = Stopwatch.StartNew();
            c.Show(Fixture.Ctx());
            bool ok = await Ui.Until(4, () => c.Slots.FirstOrDefault()?.Ready == true);
            output.WriteLine($"READY {w}x{h} in {sw.ElapsedMilliseconds} ms");
            Assert.True(ok);
            Assert.True(sw.ElapsedMilliseconds < Ui.Upper(2000) || w > 1440, $"ready took {sw.ElapsedMilliseconds} ms");
            Assert.Empty(c.FallbackReasons);
            var web = c.Slots[0].Web!;
            Assert.True(await Ui.UntilAsync(2, () => Fixture.BlockBuilt(web)));
            Assert.Equal("Dhuhr", await Fixture.Text(web, "document.querySelector('.name-latin')?.textContent ?? 'none'"));
            Assert.Contains(await Fixture.Text(web, "document.querySelector('.ring-time')?.textContent ?? 'none'"), new[] { "10:00", "9:59", "9:58" });
        }
        finally { c.TearDown(); }
    });

    [Fact]
    public void prayedBeforeUnlockDoesNotEndTheBlockAndTheGateResyncsThePage() => Ui.Run(async () =>
    {
        var spy = new SpyDelegate();
        var c = Fixture.Controller();
        c.Delegate = spy;
        try
        {
            spy.OnConfirm = () => c.Update(Fixture.Ctx(remainingMs: 300_000));   // a gate that refuses, as BlockGate does
            c.Show(Fixture.Ctx(remainingMs: 300_000));
            var slot = c.Slots[0];
            Assert.True(await Ui.Until(4, () => slot.Ready));
            var web = slot.Web!;
            Assert.True(await Ui.UntilAsync(2, () => Fixture.BlockBuilt(web)));
            long shownBefore = slot.ShownAtMs;
            await web.Js("(function(){ const b=document.querySelector('.prayed'); b.disabled=false; b.click(); return 'clicked'; })()");
            Assert.True(await Ui.Until(2, () => spy.Confirms == 1));
            Assert.True(c.IsPresenting);          // the shield did not end itself
            Assert.False(c.IsDismissing);
            Assert.True(await Ui.Until(2, () => slot.ShownAtMs > shownBefore));
            Assert.True(await Ui.UntilAsync(2, async () => await Fixture.Text(web, "String(document.querySelector('.prayed').disabled)") == "true"));
            Assert.Contains(await Fixture.Text(web, "document.querySelector('.ring-time').textContent"), new[] { "5:00", "4:59", "4:58" });
        }
        finally { c.TearDown(); }
    });

    /// <summary>0.3.5 late block: the gate sends lock 0, nothing left, no Athan. The real page opens "I prayed" by
    /// itself (no forced enable) and a plain click reaches the gate.</summary>
    [Fact]
    public void aLateBlockPageOpensPrayedAtOnce() => Ui.Run(async () =>
    {
        var spy = new SpyDelegate();
        var c = Fixture.Controller();
        c.Delegate = spy;
        try
        {
            c.Show(Fixture.Ctx(prayer: Prayer.Isha, remainingMs: 0, athanMs: 0, lockSeconds: 0));
            var slot = c.Slots[0];
            Assert.True(await Ui.Until(4, () => slot.Ready));
            var web = slot.Web!;
            Assert.True(await Ui.UntilAsync(2, () => Fixture.BlockBuilt(web)));
            Assert.True(await Ui.UntilAsync(4, async () => await Fixture.Text(web, "String(document.querySelector('.prayed')?.disabled)") == "false"));
            await web.Js("(function(){ document.querySelector('.prayed').click(); return 'clicked'; })()");
            Assert.True(await Ui.Until(2, () => spy.Confirms == 1));
        }
        finally { c.TearDown(); }
    });

    [Fact]
    public void unknownMessagesAreDroppedAndNeverReachTheGate() => Ui.Run(async () =>
    {
        var spy = new SpyDelegate();
        var c = Fixture.Controller();
        c.Delegate = spy;
        try
        {
            c.Show(Fixture.Ctx());
            var slot = c.Slots[0];
            Assert.True(await Ui.Until(4, () => slot.Ready));
            var web = slot.Web!;
            await web.Js("""
              (function(){ const h = window.webkit.messageHandlers.gopray, w = window.chrome.webview;
              h.postMessage({type:'end'}); h.postMessage('prayed'); h.postMessage({type:'prayed', force:true});
              h.postMessage({type:'quit'}); h.postMessage(7); h.postMessage(null);
              w.postMessage({type:'PRAYED'}); w.postMessage('{"type":"prayed"}'); return 'sent'; })()
            """);
            Assert.True(await Ui.Until(2, () => web.DroppedMessages.Count == 8), $"dropped {web.DroppedMessages.Count}: {string.Join(" | ", web.DroppedMessages)}");
            Assert.Equal(0, spy.Confirms);
            Assert.Equal(0, spy.Silences);
            Assert.Equal("undefined/undefined", await Fixture.Text(web, "typeof window.webkit.messageHandlers.system + '/' + typeof window.webkit.messageHandlers.gopray2"));
            // the shim cannot be replaced by the page
            await web.Js("try { window.webkit.messageHandlers.gopray = { postMessage: function(){} }; } catch (e) {} 'x'");
            Assert.Equal("true", await Fixture.Text(web, "String(Object.isFrozen(window.webkit.messageHandlers))"));
        }
        finally { c.TearDown(); }
    });

    [Fact]
    public void reduceMotionReachesThePage() => Ui.Run(async () =>
    {
        var c = Fixture.Controller();
        try
        {
            c.Show(Fixture.Ctx(reduce: true));
            var slot = c.Slots[0];
            Assert.True(await Ui.Until(4, () => slot.Ready));
            Assert.True(await Ui.UntilAsync(2, () => Fixture.BlockBuilt(slot.Web!)));
            Assert.Equal("true", await Fixture.Text(slot.Web!, "String(document.documentElement.classList.contains('reduce'))"));
        }
        finally { c.TearDown(); }
    });

    [Fact]
    public void threeDisplaysGiveThreeWindowsAndUIOnlyOnTheMainOne() => Ui.Run(async () =>
    {
        var c = Fixture.Controller([Fixture.D("1", 0, 1512, 982), Fixture.D("2", 1512, 1920, 1080), Fixture.D("3", -2560, 2560, 1440)]);
        try
        {
            c.Show(Fixture.Ctx(Prayer.Fajr));
            Assert.Equal(3, c.Slots.Count);
            bool all = await Ui.Until(8, () => c.Slots.All(s => s.Ready));
            output.WriteLine($"ready={string.Join(",", c.Slots.Select(s => s.Ready))} fallback={string.Join(";", c.FallbackReasons)}");
            Assert.True(all);
            foreach (var s in c.Slots)
            {
                Native.Win32.GetWindowRect(s.Window.Handle, out var r);
                Assert.Equal((s.Display.Width, s.Display.Height), (r.Right - r.Left, r.Bottom - r.Top));   // exact device-pixel size
            }
            Assert.True(await Ui.UntilAsync(2, () => Fixture.BlockBuilt(c.Slots[0].Web!)));
            await Task.Delay(300);
            var counts = new List<string>();
            foreach (var s in c.Slots) counts.Add(await Fixture.Text(s.Web!, "String(document.querySelectorAll('.block').length)"));
            Assert.Equal(["1", "0", "0"], counts);
            Assert.Equal([ShieldLayout.Full, ShieldLayout.Art, ShieldLayout.Art], c.Slots.Select(s => s.Layout).ToArray());
        }
        finally { c.TearDown(); }
    });

    // MARK: monitors changing mid-block (PM ruling 2026-10-23: only what changed is touched, no flash)

    [Fact]
    public void unplugAMonitorKeepsTheOtherWindowsAndPagesUp() => Ui.Run(async () =>
    {
        var list = new List<Display> { Fixture.D("1", 0, 1920, 1080), Fixture.D("2", 1920, 2560, 1440) };
        var c = Fixture.Controller(list);
        try
        {
            c.Show(Fixture.Ctx());
            Assert.True(await Ui.Until(8, () => c.Slots.All(s => s.Ready)));
            var main = c.Slots[0];
            var mainWindow = main.Window; var mainWeb = main.Web;
            list.RemoveAt(1);
            c.DisplaysChanged();
            Assert.True(await Ui.Until(2, () => c.Slots.Count == 1));
            Assert.Same(main, c.Slots[0]);
            Assert.Same(mainWindow, c.Slots[0].Window);       // never closed: nothing flashed
            Assert.Same(mainWeb, c.Slots[0].Web);
            Assert.True(c.Slots[0].Ready);
            Assert.True(mainWindow.IsVisible);
            Assert.True(c.IsPresenting);

            list.Add(Fixture.D("3", 1920, 1920, 1080));        // plugged back in (a new id)
            c.DisplaysChanged();
            Assert.True(await Ui.Until(2, () => c.Slots.Count == 2));
            Assert.Same(mainWindow, c.Slots[0].Window);
            Assert.Equal(ShieldLayout.Art, c.Slots[1].Layout);
            Assert.Equal("3", c.Slots[1].Display.Id);
            Assert.True(await Ui.Until(8, () => c.Slots[1].Ready));
            Assert.Empty(c.FallbackReasons);
        }
        finally { c.TearDown(); }
    });

    [Fact]
    public void primaryChangeMovesTheMainWindowInPlace() => Ui.Run(async () =>
    {
        var a = Fixture.D("1", 0, 1920, 1080);
        var b = Fixture.D("2", 1920, 2560, 1440);
        var list = new List<Display> { a, b };
        var c = Fixture.Controller(list);
        try
        {
            c.Show(Fixture.Ctx());
            Assert.True(await Ui.Until(8, () => c.Slots.All(s => s.Ready)));
            var mainWindow = c.Slots[0].Window; var artWindow = c.Slots[1].Window;
            list.Clear(); list.Add(b); list.Add(a);            // "2" is the primary now
            c.DisplaysChanged();
            Assert.True(await Ui.Until(2, () => c.Slots[0].Display == b));
            Assert.Same(mainWindow, c.Slots[0].Window);
            Assert.Equal(ShieldLayout.Full, c.Slots[0].Layout);
            Assert.Equal(b, mainWindow.Frame);
            Assert.Same(artWindow, c.Slots[1].Window);          // the art window took the monitor the main one left
            Assert.Equal(a, artWindow.Frame);
            Native.Win32.GetWindowRect(mainWindow.Handle, out var r);
            Assert.Equal((2560, 1440), (r.Right - r.Left, r.Bottom - r.Top));
        }
        finally { c.TearDown(); }
    });

    [Fact]
    public void noMonitorsForAMomentChangesNothing() => Ui.Run(async () =>
    {
        var list = new List<Display> { Fixture.D("1", 0, 1920, 1080) };
        var c = Fixture.Controller(list);
        try
        {
            c.Show(Fixture.Ctx());
            var w = c.Slots[0].Window;
            list.Clear();
            c.DisplaysChanged();
            await Task.Delay(600);
            Assert.Single(c.Slots);
            Assert.Same(w, c.Slots[0].Window);
        }
        finally { c.TearDown(); }
    });

    [Fact]
    public void codingModeShowsOneNoticeWithTheAppName() => Ui.Run(async () =>
    {
        var c = Fixture.Controller([Fixture.D("1", 0, 1920, 1080), Fixture.D("2", 1920, 1920, 1080)]);
        try
        {
            c.Show(Fixture.Ctx(mode: BlockMode.CodingApps, app: "Cursor"));
            Assert.Single(c.Slots);
            var slot = c.Slots[0];
            Assert.Equal(ShieldLayout.Notice, slot.Layout);
            Native.Win32.GetWindowRect(slot.Window.Handle, out var r);
            Assert.Equal((420, 520), (r.Right - r.Left, r.Bottom - r.Top));
            Assert.Equal((750, 280), (slot.Window.Frame.X, slot.Window.Frame.Y));   // centred on the primary (scale 1)
            Assert.True(await Ui.Until(4, () => slot.Ready));
            Assert.True(await Ui.UntilAsync(2, () => Fixture.BlockBuilt(slot.Web!)));
            Assert.Contains("Cursor is resting until you pray.", await Fixture.Text(slot.Web!, "document.querySelector('.copy')?.textContent ?? ''"));
        }
        finally { c.TearDown(); }
    });

    [Fact]
    public void athanStoppedFadesTheSilenceButtonWithoutEchoingToTheGate() => Ui.Run(async () =>
    {
        var spy = new SpyDelegate();
        var c = Fixture.Controller();
        c.Delegate = spy;
        try
        {
            c.Show(Fixture.Ctx(remainingMs: 600_000, athanMs: 180_000));
            var slot = c.Slots[0];
            Assert.True(await Ui.Until(4, () => slot.Ready));
            var web = slot.Web!;
            Assert.True(await Ui.UntilAsync(2, () => Fixture.BlockBuilt(web)));
            Assert.Equal("false", await Fixture.Text(web, "String(document.querySelector('.silence').classList.contains('is-quiet'))"));
            c.Update(Fixture.Ctx(remainingMs: 600_000, athanMs: 0));           // audio finished, gate says so
            Assert.True(await Ui.UntilAsync(2, async () => await Fixture.Text(web, "String(document.querySelector('.silence').classList.contains('is-quiet'))") == "true"));
            await Task.Delay(200);
            Assert.Equal(0, spy.Silences);
        }
        finally { c.TearDown(); }
    });

    [Fact]
    public void gateConfirmDismissesThroughThePageAndCallsIdleOnce() => Ui.Run(async () =>
    {
        var c = Fixture.Controller();
        c.Show(Fixture.Ctx(remainingMs: 0));
        var slot = c.Slots[0];
        Assert.True(await Ui.Until(4, () => slot.Ready));
        int idle = 0;
        var sw = Stopwatch.StartNew();
        c.Dismiss(() => idle++);
        Assert.True(await Ui.Until(4, () => idle == 1));
        output.WriteLine($"DISMISS idle after {sw.ElapsedMilliseconds} ms");
        Assert.True(sw.ElapsedMilliseconds < Ui.Upper(2600));
        Assert.False(c.IsPresenting);
        Assert.Empty(c.Slots);
        await Task.Delay(300);
        Assert.Equal(1, idle);
    });

    [Fact]
    public void tearDownDuringDismissNeverCallsIdleAndLeavesNothingBehind() => Ui.Run(async () =>
    {
        var c = Fixture.Controller();
        c.Show(Fixture.Ctx(remainingMs: 0));
        Assert.True(await Ui.Until(4, () => c.Slots[0].Ready));
        int idle = 0;
        c.Dismiss(() => idle++);
        Assert.True(c.IsDismissing);
        c.TearDown();                          // fail-open while the accept fade runs
        Assert.True(!c.IsPresenting && c.Slots.Count == 0);
        await Task.Delay(1800);
        Assert.Equal(0, idle);
    });

    [Fact]
    public void tearDownWorksFromEveryState() => Ui.Run(async () =>
    {
        var c = Fixture.Controller();
        c.TearDown();                                        // idle
        c.Show(Fixture.Ctx()); c.TearDown();                 // right after show, page not even loaded
        c.Show(Fixture.Ctx()); c.Show(Fixture.Ctx(Prayer.Asr));   // overlap: new prayer replaces
        Assert.Single(c.Slots);
        c.TearDown(); c.TearDown();
        Assert.False(c.IsPresenting);
        await Task.Delay(100);
    });

    [Fact]
    public void theRingStartsAtItsTrueProgressAfterARelaunch() => Ui.Run(async () =>
    {
        var c = Fixture.Controller();
        try
        {
            c.Show(Fixture.Ctx(remainingMs: 300_000, lockSeconds: 600));     // halfway through a 10-minute lock
            var slot = c.Slots[0];
            Assert.True(await Ui.Until(4, () => slot.Ready));
            var web = slot.Web!;
            Assert.True(await Ui.UntilAsync(2, () => Fixture.BlockBuilt(web)));
            await Task.Delay(300);
            double circ = 2 * Math.PI * 47;
            double off = double.Parse(await Fixture.Text(web, "document.querySelector('.ring-fill').getAttribute('stroke-dashoffset')"), System.Globalization.CultureInfo.InvariantCulture);
            output.WriteLine($"ring offset {off:0} of {circ:0} (half = {circ / 2:0})");
            Assert.True(Math.Abs(off - circ / 2) < circ * 0.03, $"ring offset {off}");
            c.TearDown();
            c.Show(Fixture.Ctx(remainingMs: 300_000));                         // control: no lock length → ring starts empty
            var s2 = c.Slots[0];
            Assert.True(await Ui.Until(4, () => s2.Ready));
            Assert.True(await Ui.UntilAsync(2, () => Fixture.BlockBuilt(s2.Web!)));
            double off2 = double.Parse(await Fixture.Text(s2.Web!, "document.querySelector('.ring-fill').getAttribute('stroke-dashoffset')"), System.Globalization.CultureInfo.InvariantCulture);
            Assert.True(off2 > circ * 0.9, $"control offset {off2}");
        }
        finally { c.TearDown(); }
    });

    // MARK: failures fall open to the native shield

    [Fact]
    public void killingTheRendererProcessShowsTheFallbackWithinOneSecond() => Ui.Run(async () =>
    {
        var spy = new SpyDelegate();
        var c = Fixture.Controller();
        c.Delegate = spy;
        try
        {
            c.Show(Fixture.Ctx(remainingMs: 300_000));
            var slot = c.Slots[0];
            Assert.True(await Ui.Until(4, () => slot.Ready));
            var web = slot.Web!;
            Assert.True(await Ui.UntilAsync(2, () => Fixture.BlockBuilt(web)));
            var pids = await web.RendererProcessIds();
            Assert.NotEmpty(pids);
            var sw = Stopwatch.StartNew();
            foreach (var pid in pids) Process.GetProcessById(pid).Kill();      // OUR web view's own renderer(s), by id
            Assert.True(await Ui.Until(1.0, () => slot.Fallback != null), $"no fallback after {sw.ElapsedMilliseconds} ms");
            output.WriteLine($"FALLBACK after kill: {sw.ElapsedMilliseconds} ms; reasons={string.Join(";", c.FallbackReasons)}");
            var left = (slot.Fallback!.CanConfirmAt - DateTime.UtcNow).TotalSeconds;
            Assert.StartsWith("processFailed:", c.FallbackReasons.Single());
            Assert.True(left > 296 && left < 300.5, $"remaining was {left} s");
            Assert.Null(slot.Web);
            slot.Fallback.OnPrayed();                                          // the fallback button asks the gate, nothing else
            Assert.Equal(1, spy.Confirms);
            Assert.True(c.IsPresenting);
        }
        finally { c.TearDown(); }
    });

    [Fact]
    public void aBlankPageGetsTheFallbackWithinFourSeconds() => Ui.Run(async () =>
    {
        var blank = Fixture.Scratch(new() { ["shield.html"] = "<!doctype html><html><body></body></html>" });
        var c = Fixture.Controller(scenesRoot: blank);
        try
        {
            var sw = Stopwatch.StartNew();
            var startUtc = DateTime.UtcNow;
            c.Show(Fixture.Ctx(remainingMs: 120_000));
            var slot = c.Slots[0];
            Assert.True(await Ui.Until(5, () => slot.Fallback != null));
            output.WriteLine($"FALLBACK blank page: {sw.ElapsedMilliseconds} ms");
            Assert.InRange(sw.ElapsedMilliseconds, 3900, Ui.CI ? 9000 : 4600);   // never early (the product timer stays 4 s); late only on a loaded CI VM
            Assert.Equal(["ready timeout"], c.FallbackReasons);
            Assert.InRange((slot.Fallback!.CanConfirmAt - startUtc).TotalSeconds, 119, 121);   // the same 120 s, however late
        }
        finally { c.TearDown(); }
    });

    [Fact]
    public void aMissingPageFallsBackWithoutWaitingForTheTimeout() => Ui.Run(async () =>
    {
        var empty = Fixture.Scratch([]);
        var c = Fixture.Controller(scenesRoot: empty);
        try
        {
            var sw = Stopwatch.StartNew();
            c.Show(Fixture.Ctx());
            var slot = c.Slots[0];
            Assert.True(await Ui.Until(3, () => slot.Fallback != null));
            output.WriteLine($"FALLBACK missing page: {sw.ElapsedMilliseconds} ms; {string.Join(";", c.FallbackReasons)}");
            Assert.True(sw.ElapsedMilliseconds < Ui.Upper(3500));
            Assert.DoesNotContain("ready timeout", c.FallbackReasons);   // it did not wait for the 4 s timer
            Assert.True(c.IsPresenting);
        }
        finally { c.TearDown(); }
    });

    [Fact]
    public void fallbackFollowsTheGatesUpdatesAndDismisses() => Ui.Run(async () =>
    {
        var c = Fixture.Controller(scenesRoot: Fixture.Scratch([]));
        try
        {
            c.Show(Fixture.Ctx(remainingMs: 100_000, athanMs: 60_000));
            var slot = c.Slots[0];
            Assert.True(await Ui.Until(3, () => slot.Fallback != null));
            var model = slot.Fallback!;
            c.Update(Fixture.Ctx(remainingMs: 30_000, athanMs: 0));
            Assert.True((model.CanConfirmAt - DateTime.UtcNow).TotalSeconds < 31);
            Assert.Null(model.AthanEndsAt);
            int idle = 0;
            c.Dismiss(() => idle++);
            Assert.True(model.Accepting);
            Assert.True(await Ui.Until(3, () => idle == 1));
        }
        finally { c.TearDown(); }
    });

    // MARK: the scenes still render under the CSP

    [Theory]
    [InlineData(Prayer.Fajr)]
    [InlineData(Prayer.Dhuhr)]
    [InlineData(Prayer.Asr)]
    [InlineData(Prayer.Maghrib)]
    [InlineData(Prayer.Isha)]
    public void sceneRendersUnderTheCSP(Prayer prayer) => Ui.Run(async () =>
    {
        var w = new System.Windows.Window { Left = -32000, Top = -32000, Width = 1440, Height = 900, ShowActivated = false, ShowInTaskbar = false, WindowStyle = System.Windows.WindowStyle.None };
        var web = new SceneWebView(SceneWebView.BundledScenesRoot, System.Windows.Media.Colors.Black, Fixture.Web());
        w.Content = web.View;
        w.Show();
        try
        {
            bool ready = false;
            web.OnMessage = m => { if (m == BridgeMessage.Ready) ready = true; };
            web.Load($"prayer={prayer.ToString().ToLowerInvariant()}&layout=full&reduce=0&ms=600000");
            Assert.True(await Ui.Until(6, () => ready));
            Assert.True(await Ui.UntilAsync(10, async () => await Fixture.Text(web, "document.getElementById('scene').dataset.state ?? ''") == "lived"),
                        "scene never reached data-state=lived");
            var layers = await Fixture.Text(web, "String(document.querySelectorAll('#scene canvas, #scene svg').length)");
            var violations = await Fixture.Text(web, "String(GoPrayBridge.violations())");
            output.WriteLine($"{prayer}: layers={layers} cspViolations={violations} blockedRequests={web.BlockedRequests.Count}");
            Assert.True(int.Parse(layers) > 0);
            Assert.Equal("0", violations);
            Assert.True(web.DroppedMessages.Count == 0 && web.BlockedNavigations.Count == 0 && web.BlockedRequests.Count == 0);
        }
        finally { web.ShutDown(); w.Close(); }
    });
}
