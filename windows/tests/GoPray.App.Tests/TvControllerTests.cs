// TvControllerTests.cs — 0.3.0 TV support, network side, against a fake Roku on this machine (127.0.0.1, any port).
// The fake is reachable only through TvController's test seam (its port and host rule); the production host rule
// (TvRules.IsAllowedHost) refuses loopback, which a test here proves too.
//
// The live check against Ahmed's Roku runs only when GOPRAY_LIVE_TV is set to the TV's address (see liveRoku).

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using GoPray.App.Tv;
using GoPray.Core;
using Xunit;

namespace GoPray.App.Tests;

/// <summary>A tiny HTTP/1.1 server: one request per connection, answers from <see cref="Handler"/>.</summary>
sealed class FakeTv : IDisposable
{
    public sealed record Request(string Method, string Target, int ContentLength, string Body);
    public sealed record Reply(int Status, byte[] Body, bool Endless = false);

    readonly TcpListener _listener = new(IPAddress.Loopback, 0);
    readonly CancellationTokenSource _stop = new();
    public List<Request> Requests { get; } = [];
    public Func<Request, Reply> Handler { get; set; } = _ => new(200, []);
    /// <summary>Bytes written for an endless body before the client hung up.</summary>
    public long EndlessSent;
    public int Port => ((IPEndPoint)_listener.LocalEndpoint).Port;

    public FakeTv()
    {
        _listener.Start();
        _ = Task.Run(Loop);
    }

    public static Reply Xml(string xml) => new(200, Encoding.UTF8.GetBytes(xml));
    public static string Apps(params (string Id, string Name)[] apps) =>
        "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<apps>\n" + string.Concat(apps.Select(a => $"\t<app id=\"{a.Id}\" type=\"appl\" version=\"1.0.0\">{System.Security.SecurityElement.Escape(a.Name)}</app>\n")) + "</apps>\n";
    public static string Active(string id) => $"<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<active-app>\n\t<app id=\"{id}\" type=\"appl\">x</app>\n</active-app>\n";
    public const string DeviceInfo = "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<device-info>\n\t<friendly-device-name>58\" Hisense Roku TV</friendly-device-name>\n</device-info>\n";

    public List<Request> Posts { get { lock (Requests) return Requests.Where(r => r.Method == "POST").ToList(); } }

    async Task Loop()
    {
        while (!_stop.IsCancellationRequested)
        {
            TcpClient c;
            try { c = await _listener.AcceptTcpClientAsync(_stop.Token); } catch { return; }
            _ = Task.Run(() => Serve(c));
        }
    }

    async Task Serve(TcpClient c)
    {
        using var _ = c;
        try
        {
            var s = c.GetStream();
            var head = new StringBuilder();
            var one = new byte[1];
            while (!head.ToString().EndsWith("\r\n\r\n") && head.Length < 16384)
            {
                if (await s.ReadAsync(one) == 0) return;
                head.Append((char)one[0]);
            }
            var lines = head.ToString().Split("\r\n");
            var parts = lines[0].Split(' ');
            int len = lines.Select(l => l.Split(':', 2)).Where(kv => kv.Length == 2 && kv[0].Trim().Equals("Content-Length", StringComparison.OrdinalIgnoreCase))
                           .Select(kv => int.Parse(kv[1].Trim())).FirstOrDefault(-1);
            var body = new byte[Math.Max(len, 0)];
            for (int got = 0; got < body.Length;) { int n = await s.ReadAsync(body.AsMemory(got)); if (n == 0) break; got += n; }
            var req = new Request(parts[0], parts[1], len, Encoding.UTF8.GetString(body));
            lock (Requests) Requests.Add(req);
            var reply = Handler(req);
            if (reply.Endless)
            {
                await s.WriteAsync(Encoding.ASCII.GetBytes($"HTTP/1.1 {reply.Status} OK\r\nContent-Type: text/xml\r\nConnection: close\r\n\r\n"));
                var chunk = Encoding.ASCII.GetBytes(new string('x', 64 * 1024));
                try { for (int i = 0; i < 256; i++) { await s.WriteAsync(chunk); Interlocked.Add(ref EndlessSent, chunk.Length); } }   // 16 MB
                catch (IOException) { }
                return;
            }
            await s.WriteAsync(Encoding.ASCII.GetBytes($"HTTP/1.1 {reply.Status} X\r\nContent-Type: text/xml\r\nContent-Length: {reply.Body.Length}\r\nConnection: close\r\n\r\n"));
            await s.WriteAsync(reply.Body);
        }
        catch (IOException) { }
        catch (SocketException) { }
    }

    public void Dispose() { _stop.Cancel(); _listener.Stop(); }
}

public class TvControllerTests
{
    const string Lo = "127.0.0.1";
    static readonly Voice Makkah = Voice.Sunni("Adhan-Makkah");

    static TvController Controller(FakeTv tv, IPEndPoint? ssdp = null) =>
        new(tv.Port, h => h == Lo, ssdp ?? new IPEndPoint(IPAddress.Loopback, 9), () => [IPAddress.Loopback], () => false);

    static TvDevice Device(string channel = "dev", bool enabled = true, bool installed = true, string host = Lo) =>
        new("TV-1", "Test TV", TvKind.Roku, host, channel, enabled, installed);

    /// <summary>Collects CoreLog lines while <paramref name="run"/> runs (App tests run one at a time).</summary>
    static async Task<List<string>> Logged(Func<Task> run)
    {
        var lines = new List<string>();
        var old = CoreLog.Sink;
        CoreLog.Sink = m => { lock (lines) lines.Add(m); };
        try { await run(); } finally { CoreLog.Sink = old; }
        return lines;
    }

    // MARK: the launch

    [Fact]
    public async Task athanLaunchIsTheExactUrlWithAnEmptyBodyAndNoTest()
    {
        using var tv = new FakeTv { Handler = r => r.Target.StartsWith("/query/active-app") ? FakeTv.Xml(FakeTv.Active("562859")) : new(200, []) };
        var c = Controller(tv);
        c.AthanStarted([Device()], Prayer.Asr, Makkah);
        await c.LastAthanCalls;
        var post = Assert.Single(tv.Posts);
        Assert.Equal("/launch/dev?prayer=asr&voice=sunni.Adhan-Makkah", post.Target);
        Assert.Equal(0, post.ContentLength);
        Assert.DoesNotContain("test", post.Target);
        Assert.Equal("/query/active-app", tv.Requests[0].Target);           // checked first
    }

    [Fact]
    public async Task fajrSendsTheChosenVoiceAndShiaVoicesWork()
    {
        using var tv = new FakeTv();
        var c = Controller(tv);
        c.AthanStarted([Device("12345")], Prayer.Fajr, Voice.Shia("Aghati"));
        await c.LastAthanCalls;
        c.AthanStarted([Device()], Prayer.Isha, Voice.Sunni("Abdul-Basit"));
        await c.LastAthanCalls;
        Assert.Equal(["/launch/12345?prayer=fajr&voice=shia.Aghati", "/launch/dev?prayer=isha&voice=sunni.Abdul-Basit"], tv.Posts.Select(p => p.Target));
    }

    [Fact]
    public async Task valuesAreUrlEncoded()
    {
        using var tv = new FakeTv();
        var c = Controller(tv);
        c.AthanStarted([Device()], Prayer.Dhuhr, Voice.Sunni("A b&c=d/é"));
        await c.LastAthanCalls;
        Assert.Equal("/launch/dev?prayer=dhuhr&voice=sunni.A%20b%26c%3Dd%2F%C3%A9", tv.Posts.Single().Target);
    }

    [Fact]
    public async Task testLaunchAddsTest1AndSkipsTheActiveCheck()
    {
        using var tv = new FakeTv { Handler = r => r.Target.StartsWith("/query/active-app") ? FakeTv.Xml(FakeTv.Active("dev")) : new(200, []) };
        var c = Controller(tv);
        Assert.True(await c.TestLaunch(Lo, "dev", Prayer.Maghrib, Makkah, CancellationToken.None));
        Assert.Equal("/launch/dev?prayer=maghrib&voice=sunni.Adhan-Makkah&test=1", Assert.Single(tv.Requests).Target);
    }

    [Fact]
    public async Task testLaunchReportsANon2xx()
    {
        using var tv = new FakeTv { Handler = _ => new(404, []) };
        Assert.False(await Controller(tv).TestLaunch(Lo, "dev", Prayer.Asr, Makkah, CancellationToken.None));
    }

    // MARK: the active-app check (amendment 2)

    [Fact]
    public async Task oursAlreadyActiveMeansNoPost()
    {
        using var tv = new FakeTv { Handler = r => FakeTv.Xml(FakeTv.Active("dev")) };
        var c = Controller(tv);
        var log = await Logged(async () => { c.AthanStarted([Device()], Prayer.Asr, Makkah); await c.LastAthanCalls; });
        Assert.Empty(tv.Posts);
        Assert.Contains(log, l => l.Contains("tv: already playing"));
    }

    [Fact]
    public async Task anotherActiveAppMeansPost()
    {
        using var tv = new FakeTv { Handler = r => r.Method == "GET" ? FakeTv.Xml(FakeTv.Active("12")) : new(200, []) };
        var c = Controller(tv);
        c.AthanStarted([Device()], Prayer.Asr, Makkah);
        await c.LastAthanCalls;
        Assert.Single(tv.Posts);
    }

    [Theory]
    [InlineData("500")] [InlineData("junk")] [InlineData("dtd")] [InlineData("endless")]
    public async Task aFailedCheckStillPosts(string how)
    {
        using var tv = new FakeTv
        {
            Handler = r => r.Method == "POST" ? new(200, []) : how switch
            {
                "500" => new(500, []),
                "junk" => FakeTv.Xml("<active-app><app id=\"dev\""),
                "dtd" => FakeTv.Xml("<!DOCTYPE a [<!ENTITY x \"dev\">]><active-app><app id=\"&x;\"/></active-app>"),
                _ => new(200, [], Endless: true),
            },
        };
        var c = Controller(tv);
        c.AthanStarted([Device()], Prayer.Asr, Makkah);
        await c.LastAthanCalls;
        Assert.Single(tv.Posts);
    }

    // MARK: failures never reach the block

    [Fact]
    public async Task aTvThatIsOffIsOneLogLineAndNoThrow()
    {
        int port;
        using (var l = new TcpListener(IPAddress.Loopback, 0)) { l.Start(); port = ((IPEndPoint)l.LocalEndpoint).Port; }   // nothing listens now
        var c = new TvController(port, h => h == Lo, new IPEndPoint(IPAddress.Loopback, 9), () => [], () => false);
        var log = await Logged(async () =>
        {
            c.AthanStarted([Device()], Prayer.Asr, Makkah);                 // returns at once
            await c.LastAthanCalls;
        });
        Assert.Single(log, l => l.Contains("tv Test TV: launch failed"));
    }

    [Fact]
    public async Task athanStartedReturnsAtOnceEvenWhenTheTvHangs()
    {
        // A TV that accepts and never answers: the hand-off must not wait for it.
        var hang = new TcpListener(IPAddress.Loopback, 0);
        hang.Start();
        try
        {
            var c = new TvController(((IPEndPoint)hang.LocalEndpoint).Port, h => h == Lo, new IPEndPoint(IPAddress.Loopback, 9), () => [], () => false);
            var sw = System.Diagnostics.Stopwatch.StartNew();
            c.AthanStarted([Device()], Prayer.Asr, Makkah);
            Assert.True(sw.ElapsedMilliseconds < 200, $"{sw.ElapsedMilliseconds} ms");
            await c.LastAthanCalls;                                         // the 3 s timeouts end it
            Assert.True(sw.Elapsed.TotalSeconds < 8 * Ui.Slack, $"{sw.Elapsed.TotalSeconds:0.0} s");
        }
        finally { hang.Stop(); }
    }

    [Fact]
    public async Task aDisabledTvIsNotCalledAndANotInstalledOneIsSkipped()
    {
        using var tv = new FakeTv();
        var c = Controller(tv);
        var log = await Logged(async () =>
        {
            c.AthanStarted([Device(enabled: false), Device(installed: false) with { Name = "Bedroom" }], Prayer.Asr, Makkah);
            await c.LastAthanCalls;
        });
        Assert.Empty(tv.Requests);
        Assert.Single(log, l => l.Contains("tv Bedroom: skipped, Go Pray isn't installed"));
    }

    [Fact]
    public async Task theProductionHostRuleRefusesPublicHostsAndLoopbackBeforeAnySocket()
    {
        using var tv = new FakeTv();
        var c = new TvController(tv.Port, TvRules.IsAllowedHost, new IPEndPoint(IPAddress.Loopback, 9), () => [], () => false);
        var log = await Logged(async () =>
        {
            c.AthanStarted([Device(host: "8.8.8.8"), Device(host: Lo) with { Id = "TV-2" }], Prayer.Asr, Makkah);
            await c.LastAthanCalls;
        });
        Assert.Empty(tv.Requests);
        Assert.Equal(2, log.Count(l => l.Contains("host refused")));
        Assert.False((await c.Probe("8.8.8.8", CancellationToken.None)).Reachable);
        Assert.False(await c.TestLaunch("example.com", "dev", Prayer.Asr, Makkah, CancellationToken.None));
    }

    [Fact]
    public async Task aJunkChannelIdIsNeverSent()
    {
        using var tv = new FakeTv();
        var c = Controller(tv);
        Assert.False(await c.TestLaunch(Lo, "../keypress/Home", Prayer.Asr, Makkah, CancellationToken.None));
        c.AthanStarted([Device("dev?x=1")], Prayer.Asr, Makkah);
        await c.LastAthanCalls;
        Assert.Empty(tv.Posts);
    }

    // MARK: channel lookup

    [Fact]
    public void channelLookup()
    {
        static string? Pick(string xml) => TvController.PickChannel(Encoding.UTF8.GetBytes(xml));
        Assert.Equal("dev", Pick(FakeTv.Apps(("12", "Netflix"), ("dev", "Go Pray: Athan & Adhan"))));
        Assert.Equal("888895", Pick(FakeTv.Apps(("dev", "Go Pray: Athan & Adhan"), ("888895", "Go Pray: Athan & Adhan"))));
        Assert.Equal("888895", Pick(FakeTv.Apps(("888895", "Go Pray"), ("dev", "Go Pray dev"))));
        Assert.Null(Pick(FakeTv.Apps(("12", "Netflix"), ("13", "YouTube"))));                            // none installed
        Assert.Null(Pick(FakeTv.Apps(("../launch", "Go Pray"), ("12345678901", "Go Pray"), ("DEV", "Go Pray"))));   // junk ids
        Assert.Null(Pick(FakeTv.Apps(("dev", "Not Go Pray"))));
        Assert.Null(Pick("<apps></apps>"));
        Assert.Throws<System.Xml.XmlException>(() => Pick("<!DOCTYPE apps [<!ENTITY e SYSTEM \"file:///c:/windows/win.ini\">]><apps><app id=\"dev\">Go Pray &e;</app></apps>"));
    }

    [Fact]
    public async Task probeReadsTheNameAndTheChannel()
    {
        using var tv = new FakeTv
        {
            Handler = r => r.Target switch
            {
                "/query/device-info" => FakeTv.Xml(FakeTv.DeviceInfo),
                "/query/apps" => FakeTv.Xml(FakeTv.Apps(("dev", "Go Pray: Athan & Adhan"))),
                _ => new(404, []),
            },
        };
        var p = await Controller(tv).Probe(Lo, CancellationToken.None);
        Assert.Equal(new TvProbe(true, "58\" Hisense Roku TV", "dev"), p);
        Assert.All(tv.Requests, r => Assert.Equal("GET", r.Method));
    }

    [Fact]
    public async Task probeOfATvWithoutGoPray()
    {
        using var tv = new FakeTv { Handler = r => r.Target == "/query/apps" ? FakeTv.Xml(FakeTv.Apps(("12", "Netflix"))) : new(404, []) };
        Assert.Equal(new TvProbe(true, null, null), await Controller(tv).Probe(Lo, CancellationToken.None));
    }

    [Fact]
    public async Task aRedirectIsNotFollowed()
    {
        using var tv = new FakeTv { Handler = r => r.Target == "/query/apps" ? new(302, []) : new(200, []) };
        var p = await Controller(tv).Probe(Lo, CancellationToken.None);
        Assert.False(p.Reachable);
        Assert.Equal(2, tv.Requests.Count);                                 // device-info + apps, nothing more
    }

    // MARK: the 512 KB cap

    [Fact]
    public async Task anOverCapBodyStopsEarly()
    {
        using var tv = new FakeTv { Handler = r => new(200, [], Endless: true) };
        var p = await Controller(tv).Probe(Lo, CancellationToken.None);
        Assert.False(p.Reachable);
        await Task.Delay(300);
        Assert.True(tv.EndlessSent < 8L * 1024 * 1024, $"sent {tv.EndlessSent} bytes");     // we hung up long before 16 MB
    }

    [Fact]
    public async Task readCappedTakesExactly512KbAndRefusesOneMore()
    {
        Assert.Equal(TvController.MaxBody, (await TvController.ReadCapped(new MemoryStream(new byte[TvController.MaxBody]), default)).Length);
        await Assert.ThrowsAsync<InvalidDataException>(() => TvController.ReadCapped(new MemoryStream(new byte[TvController.MaxBody + 1]), default));
    }

    [Fact]
    public async Task aContentLengthOverTheCapIsRefusedBeforeReading()
    {
        using var tv = new FakeTv { Handler = r => new(200, new byte[TvController.MaxBody + 10]) };
        Assert.False((await Controller(tv).Probe(Lo, CancellationToken.None)).Reachable);
    }

    // MARK: discovery

    [Fact]
    public async Task discoveryUsesTheSenderNeverLocation()
    {
        using var tv = new FakeTv { Handler = r => FakeTv.Xml(FakeTv.DeviceInfo) };
        using var responder = new UdpClient(new IPEndPoint(IPAddress.Loopback, 0));
        var got = new TaskCompletionSource<string>();
        _ = Task.Run(async () =>
        {
            var r = await responder.ReceiveAsync();
            got.TrySetResult(Encoding.ASCII.GetString(r.Buffer));
            var reply = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nCache-Control: max-age=3600\r\nST: roku:ecp\r\nLOCATION: http://10.9.9.9:8060/\r\nUSN: uuid:roku:ecp:X\r\n\r\n");
            await responder.SendAsync(reply, reply.Length, r.RemoteEndPoint);
            var other = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nST: urn:dial-multiscreen-org:service:dial:1\r\n\r\n");
            await responder.SendAsync(other, other.Length, r.RemoteEndPoint);   // not a Roku reply: ignored
        });
        var c = Controller(tv, (IPEndPoint)responder.Client.LocalEndPoint!);
        var d = await c.Discover(CancellationToken.None);
        var search = await got.Task;
        Assert.Contains("M-SEARCH * HTTP/1.1", search);
        Assert.Contains("ST: roku:ecp", search);
        Assert.Equal([new TvFound(Lo, "58\" Hisense Roku TV")], d.Found);
        Assert.False(d.FirewallBlocks);
        Assert.Equal("/query/device-info", tv.Requests.Single().Target);
    }

    [Fact]
    public async Task discoveryWithNoRepliesReportsTheFirewallOnlyWhenItReallyBlocks()
    {
        using var tv = new FakeTv();
        using var silent = new UdpClient(new IPEndPoint(IPAddress.Loopback, 0));
        var target = (IPEndPoint)silent.Client.LocalEndPoint!;
        var open = await new TvController(tv.Port, h => h == Lo, target, () => [IPAddress.Loopback], () => false).Discover(CancellationToken.None);
        Assert.Empty(open.Found);
        Assert.False(open.FirewallBlocks);
        var blocked = await new TvController(tv.Port, h => h == Lo, target, () => [IPAddress.Loopback], () => true).Discover(CancellationToken.None);
        Assert.True(blocked.FirewallBlocks);
    }

    // MARK: live (only with GOPRAY_LIVE_TV=<the TV's address>)

    [Fact]
    public async Task liveRoku()
    {
        var host = Environment.GetEnvironmentVariable("GOPRAY_LIVE_TV");
        if (string.IsNullOrEmpty(host)) return;                             // not on the TV's network: nothing to check
        var c = new TvController();
        var p = await c.Probe(host, CancellationToken.None);
        Assert.True(p.Reachable);
        Assert.NotNull(p.ChannelId);
        Console.WriteLine($"live: {p.Name} channel {p.ChannelId}");
        c.AthanStarted([new TvDevice("LIVE", p.Name ?? "TV", TvKind.Roku, host, p.ChannelId!)], Prayer.Asr, Makkah);
        await c.LastAthanCalls;
        // Confirm Go Pray is the active app, then press Back (the brief's live check). Plain HTTP from the test, not
        // through the app.
        using var http = new System.Net.Http.HttpClient { Timeout = TimeSpan.FromSeconds(3) };
        string active = "";
        for (int i = 0; i < 20 && !active.Contains($"id=\"{p.ChannelId}\""); i++)
        {
            await Task.Delay(500);
            active = await http.GetStringAsync($"http://{host}:8060/query/active-app");
        }
        Console.WriteLine("live active-app: " + active.Replace("\n", " "));
        try { Assert.Contains($"id=\"{p.ChannelId}\"", active); }
        finally { await http.PostAsync($"http://{host}:8060/keypress/Back", new System.Net.Http.ByteArrayContent([])); }
    }
}

/// <summary>Settings → TVs drawn for real (never shown on screen): the help line, a TV row with its controls, the
/// not-installed line, and the whole section read-only during a block.</summary>
public class TvSettingsUiTests
{
    sealed class NoGeo : ICityGeocoding { public Task<IReadOnlyList<CityMatch>> SearchAsync(string q, CancellationToken c) => Task.FromResult<IReadOnlyList<CityMatch>>([]); }
    sealed class NoLogon : ILogonTask { public bool IsRegistered => false; public void Register() { } public void Unregister() { } }

    static IEnumerable<object> Tree(object o)
    {
        yield return o;
        if (o is System.Windows.DependencyObject d)
            foreach (var c in System.Windows.LogicalTreeHelper.GetChildren(d)) foreach (var x in Tree(c)) yield return x;
    }

    static List<string> Texts(object root) => Tree(root).Select(o => o switch
    {
        System.Windows.Controls.TextBlock t => t.Text,
        System.Windows.Controls.ContentControl { Content: string s } => s,
        _ => null,
    }).Where(s => s != null).Select(s => s!).ToList();

    [Fact]
    public void theTvsSectionDrawsAndGoesReadOnlyDuringABlock() => Ui.Run(async () =>
    {
        using var tv = new FakeTv
        {
            Handler = r => r.Target switch
            {
                "/query/device-info" => FakeTv.Xml(FakeTv.DeviceInfo),
                "/query/apps" => FakeTv.Xml(FakeTv.Apps(("12", "Netflix"))),
                _ => new(200, []),
            },
        };
        var asr = GoPray.Core.Tests.FakeSchedule.At(Prayer.Asr);
        using var h = new GoPray.Core.Tests.Harness(asr.AddHours(1), SettingsRules.Defaults);
        var store = new SettingsStore(Path.Combine(Path.GetTempPath(), "gopray-tvui-" + Guid.NewGuid().ToString("N")));
        store.Attach(h.Gate);
        store.Mutate(_ => GoPray.Core.Tests.TestSettings.Test());
        h.Settings = store.Settings;
        store.OnChange = s => h.Settings = s;
        var c = new TvController(tv.Port, x => x == "127.0.0.1", new IPEndPoint(IPAddress.Loopback, 9), () => [], () => false);
        var m = new SettingsModel(store, h.Gate, h.Clock, h.Audio, new NoLogon(), new NoGeo(), () => TimeZoneInfo.Utc, tvs: c, schedule: h.Schedule);
        var w = new GoPray.App.UI.SettingsWindow(m, () => { });
        w.Render();
        var texts = Texts(w);
        Assert.Contains("TVs", texts);
        Assert.Contains(Copy.TvHelp, texts);
        Assert.Contains("Find TVs", texts);
        Assert.Contains("Add by address…", texts);

        // Loopback is refused like any non-LAN host; a LAN TV row is put in through the store (nothing is called).
        Assert.False(await m.Tvs!.AddTv("127.0.0.1"));
        Assert.Equal(Copy.TvHostRefused, m.Tvs!.Notice);
        store.Mutate(s => s with { Tvs = [new TvDevice("T1", "Den TV", TvKind.Roku, "10.0.0.5", "dev", true, false)] });
        w.Render();
        texts = Texts(w);
        Assert.Contains("Den TV", texts);
        Assert.Contains("10.0.0.5", texts);
        Assert.Contains("Test", texts);
        Assert.Contains("Remove", texts);
        Assert.Contains(Copy.TvNotInstalled, texts);

        h.Clock.Now = GoPray.Core.Tests.FakeSchedule.At(Prayer.Maghrib);
        h.Gate.AthanFired(Prayer.Maghrib, h.Clock.Now);
        w.Render();
        Assert.Contains(Copy.BlockedLine, Texts(w));
        var find = Tree(w).OfType<System.Windows.Controls.Button>().First(b => (b.Content as string) == "Find TVs");
        Assert.False(IsEffectivelyEnabled(find));
        w.Close();
    });

    [Fact]
    public void theSetupTvStepDrawsASkeletonWhileScanningThenSkipOrContinue() => Ui.Run(async () =>
    {
        using var tv = new FakeTv();
        using var silent = new UdpClient(new IPEndPoint(IPAddress.Loopback, 0));    // a network with no TV on it
        var asr = GoPray.Core.Tests.FakeSchedule.At(Prayer.Asr);
        using var h = new GoPray.Core.Tests.Harness(asr.AddHours(1), SettingsRules.Defaults);
        var store = new SettingsStore(Path.Combine(Path.GetTempPath(), "gopray-tvsetup-" + Guid.NewGuid().ToString("N")));
        store.Attach(h.Gate);
        var c = new TvController(tv.Port, x => x == "127.0.0.1", (IPEndPoint)silent.Client.LocalEndPoint!, () => [IPAddress.Loopback], () => false);
        var m = new SetupModel(store, h.Schedule, h.Clock, h.Audio, new NoLogon(), new NoGeo(), h.Gate, () => TimeZoneInfo.Utc, tvs: c);
        var w = new GoPray.App.UI.SetupWindow(m);
        m.PickedCity = new CityMatch("Cairo", null, "Egypt", "EG", 30.0444, 31.2357);
        m.Next(); m.Next(); m.Next();
        Assert.Equal(SetupStep.Tv, m.Step);
        w.Refresh();
        var texts = Texts(w);
        Assert.Contains("Step 4 of 4", texts);
        Assert.Contains(Copy.SetupTvTitle, texts);
        Assert.Contains(Copy.SetupTvLine, texts);
        Assert.Contains(Tree(w).OfType<System.Windows.Controls.StackPanel>(), p => System.Windows.Automation.AutomationProperties.GetName(p) == "Looking for TVs");
        foreach (var b in new[] { "Back", "Skip", "Continue", "Find TVs again", "Add by address…" }) Assert.Contains(b, texts);
        var skip = Tree(w).OfType<System.Windows.Controls.Button>().First(b => (b.Content as string) == "Skip");
        Assert.True(skip.IsDefault);
        await m.TvScan!;
        w.Refresh();
        Assert.DoesNotContain(Tree(w).OfType<System.Windows.Controls.StackPanel>(), p => System.Windows.Automation.AutomationProperties.GetName(p) == "Looking for TVs");
        Assert.Contains(Copy.TvNoneFound, Texts(w));
        store.Mutate(s => s with { Tvs = [new TvDevice("T1", "Den TV", TvKind.Roku, "10.0.0.5")] });   // a TV added
        w.Refresh();
        Assert.Contains("Play a test", Texts(w));
        var go = Tree(w).OfType<System.Windows.Controls.Button>().First(b => (b.Content as string) == "Continue");
        Assert.True(go.IsDefault);
        Assert.False(Tree(w).OfType<System.Windows.Controls.Button>().First(b => (b.Content as string) == "Skip").IsDefault);
        w.Close();
    });

    static bool IsEffectivelyEnabled(System.Windows.FrameworkElement e)
    {
        for (System.Windows.DependencyObject? d = e; d != null; d = System.Windows.LogicalTreeHelper.GetParent(d))
            if (d is System.Windows.UIElement u && !u.IsEnabled) return false;
        return true;
    }
}
