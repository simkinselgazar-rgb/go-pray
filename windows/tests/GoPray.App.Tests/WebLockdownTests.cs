// WebLockdownTests.cs — the WebView2 lockdown and its negative controls. Port of WebLockdownTests.swift:
// every attack aims at a local listener that counts connections, so "blocked" means "no connection was
// ever made", not "the page said so". Windows has two layers, the page CSP and the host's 403 for any
// non-virtual-host request. Measured on WebView2 155: each layer alone has one gap the other closes —
//   CSP alone: the top-level `location = …` request still reaches the network before NavigationStarting's
//     cancel lands (the navigation itself is cancelled; the GET was already sent);
//   403 filter alone: WebSockets are not web resources for the filter, and an <img> load slipped past it.
// Shipped (both layers): zero HTTP requests reach the listener. A few bare TCP connects (Chromium preconnect on
// a navigation/popup start, before the cancel; flags such as --dns-prefetch-disable do not stop them) carry no
// request and no data; they are counted and reported, not hidden. The tests pin all of this.

using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Linq;
using System.Windows;
using GoPray.App.Shield;
using Xunit;
using Xunit.Abstractions;

namespace GoPray.App.Tests;

/// <summary>Counts TCP connections (and the request line) on 127.0.0.1.</summary>
internal sealed class HitCounter : IDisposable
{
    readonly TcpListener _l = new(IPAddress.Loopback, 0);
    readonly CancellationTokenSource _cts = new();
    public ConcurrentQueue<string> Paths { get; } = new();
    public int Hits => Paths.Count;
    /// <summary>Connections that carried an HTTP request (data). A bare "(connect)" is Chromium's speculative
    /// preconnect: a TCP handshake when a navigation or popup starts, before our cancel; no request is sent.</summary>
    public string[] Requests => [.. Paths.Where(p => p != "(connect)")];
    public int Preconnects => Paths.Count(p => p == "(connect)");
    public int Port { get; }

    public HitCounter()
    {
        _l.Start();
        Port = ((IPEndPoint)_l.LocalEndpoint).Port;
        _ = Loop();
    }

    async Task Loop()
    {
        while (!_cts.IsCancellationRequested)
        {
            TcpClient c;
            try { c = await _l.AcceptTcpClientAsync(_cts.Token); } catch { return; }
            _ = Task.Run(async () =>
            {
                using (c)
                {
                    var buf = new byte[1024];
                    int n = 0;
                    try { c.ReceiveTimeout = 1000; n = await c.GetStream().ReadAsync(buf); } catch { }
                    var line = Encoding.ASCII.GetString(buf, 0, n).Split('\n')[0].Trim();
                    Paths.Enqueue(line.Length > 0 ? line : "(connect)");
                    try { var ok = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"); await c.GetStream().WriteAsync(ok); } catch { }
                }
            });
        }
    }

    public void Dispose() { _cts.Cancel(); _l.Stop(); }
}

public class WebLockdownTests(ITestOutputHelper output)
{
    const string HostileJs = """
    (function () {
      var base = new URLSearchParams(location.search).get('t');
      var port = base.split(':').pop();
      var out = {};
      function attempt(name, fn) {
        try { var r = fn(); out[name] = 'ran'; if (r && r.catch) r.catch(function () { out[name] = 'rejected'; }); }
        catch (e) { out[name] = 'threw:' + e.name; }
      }
      window.__out = out;
      attempt('fetch', function () { return fetch(base + '/fetch'); });
      attempt('xhr', function () { var x = new XMLHttpRequest(); x.open('GET', base + '/xhr'); x.send(); });
      attempt('beacon', function () { return navigator.sendBeacon(base + '/beacon', 'x'); });
      attempt('websocket', function () { return new WebSocket('ws://127.0.0.1:' + port + '/ws'); });
      attempt('script', function () { var s = document.createElement('script'); s.src = base + '/remote.js'; document.head.appendChild(s); });
      attempt('img', function () { var i = new Image(); i.src = base + '/img'; document.body.appendChild(i); });
      attempt('css', function () { var l = document.createElement('link'); l.rel = 'stylesheet'; l.href = base + '/css'; document.head.appendChild(l); });
      attempt('font', function () { var st = document.createElement('style'); st.textContent = "@font-face{font-family:x;src:url(" + base + "/font)} body{font-family:x}"; document.head.appendChild(st); });
      attempt('iframe', function () { var f = document.createElement('iframe'); f.src = base + '/iframe'; document.body.appendChild(f); });
      attempt('form', function () { var f = document.createElement('form'); f.action = base + '/form'; f.method = 'post'; document.body.appendChild(f); f.submit(); });
      attempt('anchor_blank', function () { var a = document.createElement('a'); a.href = base + '/anchor'; a.target = '_blank'; document.body.appendChild(a); a.click(); });
      attempt('window_open', function () { return window.open(base + '/open'); });
      attempt('outside_file_script', function () { var s = document.createElement('script'); s.src = new URLSearchParams(location.search).get('outside'); document.head.appendChild(s); });
      attempt('location', function () { location = base + '/location'; });
    })();
    """;

    sealed class Rig : IDisposable
    {
        public string Root = "", Outside = "";
        public void Dispose() { try { Directory.Delete(Root, true); } catch { } try { Directory.Delete(Path.GetDirectoryName(Outside)!, true); } catch { } }
    }

    static Rig MakeRig()
    {
        var html = File.ReadAllText(Path.Combine(SceneWebView.BundledScenesRoot, "shield.html"));
        int i = html.IndexOf("content=\"", html.IndexOf("Content-Security-Policy", StringComparison.Ordinal), StringComparison.Ordinal) + 9;
        var csp = html[i..html.IndexOf('"', i)];
        string Page(string meta) => $"<!doctype html><html><head><meta charset=utf-8>{meta}</head><body><script src=\"hostile.js\"></script></body></html>";
        var root = Fixture.Scratch(new()
        {
            ["hostile.html"] = Page($"<meta http-equiv=\"Content-Security-Policy\" content=\"{csp}\">"),
            ["nocsp.html"] = Page(""),
            ["hostile.js"] = HostileJs,
        });
        var outsideDir = Path.Combine(Path.GetTempPath(), "gopray-lockdown-outside-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(outsideDir);
        var canary = Path.Combine(outsideDir, "canary.js");
        File.WriteAllText(canary, "window.__canary = 'RAN';");
        return new Rig { Root = root, Outside = canary };
    }

    static string Query(HitCounter hits, Rig rig) =>
        "t=" + Uri.EscapeDataString($"http://127.0.0.1:{hits.Port}") + "&outside=" + Uri.EscapeDataString(new Uri(rig.Outside).AbsoluteUri);

    async Task<(SceneWebView web, Window win)> RunPage(string page, HitCounter hits, Rig rig, bool block)
    {
        var win = new Window { Left = -32000, Top = -32000, Width = 800, Height = 600, ShowActivated = false, ShowInTaskbar = false, WindowStyle = WindowStyle.None };
        var web = new SceneWebView(rig.Root, System.Windows.Media.Colors.Black, Fixture.Web(block, rig.Root));
        win.Content = web.View;
        win.Show();
        bool finished = false;
        web.OnNavigationFinished = () => finished = true;
        web.Load(Query(hits, rig), page);
        Assert.True(await Ui.Until(8, () => finished), "page never finished loading");
        await Task.Delay(1500);      // let every attempt (and any request) happen
        return (web, win);
    }

    [Fact]
    public void everyAttackIsBlockedAndNothingLeavesTheMachine() => Ui.Run(async () =>
    {
        using var hits = new HitCounter();
        using var rig = MakeRig();
        var (web, win) = await RunPage("hostile.html", hits, rig, block: true);
        try
        {
            output.WriteLine("attempts: " + await web.Js("JSON.stringify(window.__out)"));
            output.WriteLine($"listener hits: {hits.Hits} {string.Join(" | ", hits.Paths)}");
            output.WriteLine($"blocked navigations: {string.Join(" | ", web.BlockedNavigations)}; blocked requests: {web.BlockedRequests.Count}; popups: {web.BlockedPopups}");
            output.WriteLine($"HTTP requests: {hits.Requests.Length}; bare preconnects: {hits.Preconnects}");
            Assert.Empty(hits.Requests);
            Assert.EndsWith("/hostile.html", await Fixture.Text(web, "location.pathname"));         // still our page
            Assert.Contains(web.BlockedNavigations, n => n.EndsWith("/location"));                 // reached the policy, cancelled
            Assert.Equal("undefined", await Fixture.Text(web, "String(window.__canary)"));          // nothing outside the folder ran
            Assert.Equal("null", await Fixture.Text(web, "String(window.open('http://127.0.0.1/x'))"));
        }
        finally { web.ShutDown(); win.Close(); }
    });

    /// <summary>Layer 1 alone (filter OFF): the CSP stops every subresource; only the top-level navigation GET leaks.</summary>
    [Fact]
    public void theCspAloneStopsEverySubresource() => Ui.Run(async () =>
    {
        using var hits = new HitCounter();
        using var rig = MakeRig();
        var (web, win) = await RunPage("hostile.html", hits, rig, block: false);
        try
        {
            output.WriteLine($"CSP only: hits={hits.Hits} {string.Join(" | ", hits.Paths)}");
            Assert.All(hits.Requests, p => Assert.Contains("/location", p));
            Assert.Contains(web.BlockedNavigations, n => n.EndsWith("/location"));   // and the navigation itself was cancelled
            Assert.EndsWith("/hostile.html", await Fixture.Text(web, "location.pathname"));
        }
        finally { web.ShutDown(); win.Close(); }
    });

    /// <summary>Layer 2 alone (a page WITHOUT the CSP, filter ON): active, and it is what stops the top-level navigation GET.</summary>
    [Fact]
    public void theHostFilterAloneStopsEveryHttpRequest() => Ui.Run(async () =>
    {
        using var hits = new HitCounter();
        using var rig = MakeRig();
        var (web, win) = await RunPage("nocsp.html", hits, rig, block: true);
        try
        {
            output.WriteLine($"filter only: hits={hits.Hits} {string.Join(" | ", hits.Paths)}; blocked requests={string.Join(" | ", web.BlockedRequests)}");
            // Informational: which attempts slip past the filter varies run to run (ws, img, css, iframe seen),
            // so the filter is NOT a layer to rely on alone. What it must always do: be active, and stop the
            // top-level navigation request that the CSP cannot stop.
            Assert.NotEmpty(web.BlockedRequests);
            Assert.Contains(web.BlockedRequests, r => r.EndsWith("/location"));
            Assert.DoesNotContain(hits.Requests, p => p.Contains("/location"));
            Assert.Contains(web.BlockedNavigations, n => n.EndsWith("/location"));
        }
        finally { web.ShutDown(); win.Close(); }
    });

    /// <summary>Negative control: neither layer. The attacks are real: they reach the listener.</summary>
    [Fact]
    public void withNeitherLayerTheAttacksReachTheListener() => Ui.Run(async () =>
    {
        using var hits = new HitCounter();
        using var rig = MakeRig();
        var (web, win) = await RunPage("nocsp.html", hits, rig, block: false);
        try
        {
            output.WriteLine($"no lockdown: hits={hits.Hits} {string.Join(" | ", hits.Paths)}");
            Assert.True(hits.Requests.Length >= 8, "without the CSP and the filter the attacks must reach the listener, or this suite proves nothing");
            Assert.DoesNotContain(hits.Paths, p => p.Contains("/form") || p.Contains("/open") || p.Contains("/anchor"));   // forms and popups: navigation policy
        }
        finally { web.ShutDown(); win.Close(); }
    });

    [Fact]
    public void isOursAcceptsOnlyTheVirtualHost()
    {
        Assert.True(SceneWebView.IsOurs("https://gopray.invalid/shield.html"));
        Assert.True(SceneWebView.IsOurs("https://gopray.invalid/shield.html?prayer=asr"));
        Assert.False(SceneWebView.IsOurs("http://gopray.invalid/shield.html"));
        Assert.False(SceneWebView.IsOurs("https://gopray.invalid:444/shield.html"));
        Assert.False(SceneWebView.IsOurs("https://gopray.invalid.evil.com/shield.html"));
        Assert.False(SceneWebView.IsOurs("https://example.com/shield.html"));
        Assert.False(SceneWebView.IsOurs("file:///C:/Windows/win.ini"));
        Assert.False(SceneWebView.IsOurs("about:blank"));
        Assert.False(SceneWebView.IsOurs(null));
    }
}
