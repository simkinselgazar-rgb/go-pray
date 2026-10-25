// TvController.cs — the only code that talks to TVs (0.3.0, PM brief 2026-10-24; guard rule 4). Roku ECP on :8060:
//   launch    POST /launch/<channelId>?prayer=<p>&voice=<sunni|shia>.<stem>[&test=1], empty body; only the status counts
//   channel   GET  /query/apps         the <app> whose name starts with "Go Pray"; a numeric id beats "dev"
//   name      GET  /query/device-info  <friendly-device-name>
//   playing?  GET  /query/active-app   before an Athan launch (not Test): ours already active → no launch (a repeat
//                                      launch restarts the channel); any error → launch anyway (the TV de-dupes)
//   discovery SSDP M-SEARCH (ST roku:ecp) from every private IPv4 interface, 3 s; the reply's SENDER is the TV
// Hosts are private IPv4 literals only (TvRules.IsAllowedHost), checked again before every request; no hostnames,
// no redirects, no proxy, 3 s per request. LAN replies are untrusted: at most 512 KB is read (streamed, then we stop),
// the XML reader has DTDs and external entities off, and a junk channel id is dropped.
// At Athan time every enabled TV gets one background call; any failure is one log line and nothing else.

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Xml;
using GoPray.Core;

namespace GoPray.App.Tv;

internal sealed class TvController : ITvControlling
{
    const int EcpPort = 8060;
    public const int MaxBody = 512 * 1024;
    static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(3);
    static readonly TimeSpan DiscoveryWait = TimeSpan.FromSeconds(3);
    static readonly IPEndPoint SsdpGroup = new(IPAddress.Parse("239.255.255.250"), 1900);

    readonly int _port;
    readonly Func<string, bool> _allowHost;
    readonly IPEndPoint _ssdpTarget;
    readonly Func<IEnumerable<IPAddress>> _localAddresses;
    readonly Func<bool> _firewallBlocks;
    readonly HttpClient _http = new(new SocketsHttpHandler
    {
        AllowAutoRedirect = false,
        UseProxy = false,                         // a LAN TV, never through a proxy
        UseCookies = false,
        AutomaticDecompression = DecompressionMethods.None,
        ConnectTimeout = RequestTimeout,
        MaxResponseHeadersLength = 16,            // KB
    }) { Timeout = Timeout.InfiniteTimeSpan };

    public TvController() : this(EcpPort, TvRules.IsAllowedHost, SsdpGroup, PrivateInterfaceAddresses, FirewallDropsReplies) { }

    /// <summary>Test seam only: a fake TV on this machine (its port and host rule), a fake SSDP responder.</summary>
    internal TvController(int port, Func<string, bool> allowHost, IPEndPoint ssdpTarget, Func<IEnumerable<IPAddress>> localAddresses, Func<bool> firewallBlocks)
    {
        _port = port; _allowHost = allowHost; _ssdpTarget = ssdpTarget; _localAddresses = localAddresses; _firewallBlocks = firewallBlocks;
    }

    /// <summary>Tests only: the calls the last AthanStarted began.</summary>
    internal Task LastAthanCalls { get; private set; } = Task.CompletedTask;

    // MARK: Athan time

    public void AthanStarted(IReadOnlyList<TvDevice> tvs, Prayer prayer, Voice voice)
    {
        var calls = new List<Task>();
        foreach (var tv in tvs.Where(t => t.Enabled))
        {
            var channel = tv.ChannelId;
            if (!tv.Installed)
            {
                CoreLog.Notice($"tv {tv.Name}: skipped, Go Pray isn't installed");
                continue;
            }
            if (!_allowHost(tv.Host))
            {
                CoreLog.Notice($"tv {tv.Name}: host refused, not a private IPv4 address");
                continue;
            }
            calls.Add(Task.Run(async () =>
            {
                try
                {
                    if (await IsActive(tv.Host, channel)) { CoreLog.Notice($"tv: already playing ({tv.Name})"); return; }
                    using var cts = new CancellationTokenSource(RequestTimeout);
                    var status = await Launch(tv.Host, channel, prayer, voice, test: false, cts.Token);
                    if (status is not (>= 200 and < 300)) CoreLog.Notice($"tv {tv.Name}: launch answered {status}");
                }
                catch (Exception e) { CoreLog.Notice($"tv {tv.Name}: launch failed ({Short(e)})"); }
            }));
        }
        LastAthanCalls = Task.WhenAll(calls);
    }

    /// <summary>True only when the TV says our channel is the active app. Any failure → false (send the launch).</summary>
    async Task<bool> IsActive(string host, string channel)
    {
        try
        {
            using var cts = new CancellationTokenSource(RequestTimeout);
            return ActiveAppId(await GetCapped(host, "/query/active-app", cts.Token)) == channel;
        }
        catch (Exception e) when (IsLanFailure(e)) { return false; }    // no line of its own: the launch that follows logs
    }

    // MARK: Settings

    public async Task<bool> TestLaunch(string host, string channelId, Prayer prayer, Voice voice, CancellationToken cancel)
    {
        try { return await Launch(host, channelId, prayer, voice, test: true, cancel) is >= 200 and < 300; }
        catch (Exception e) when (IsLanFailure(e))
        {
            CoreLog.Notice($"tv: test launch failed ({Short(e)})");
            return false;
        }
    }

    public async Task<TvProbe> Probe(string host, CancellationToken cancel)
    {
        if (!_allowHost(host)) { CoreLog.Notice("tv: refused a host that is not a private IPv4 address"); return new TvProbe(false, null, null); }
        string? name = null;
        try { name = DeviceName(await GetCapped(host, "/query/device-info", cancel)); }
        catch (Exception e) when (IsLanFailure(e)) { CoreLog.Notice($"tv: device-info failed ({Short(e)})"); }
        try { return new TvProbe(true, name, PickChannel(await GetCapped(host, "/query/apps", cancel))); }
        catch (Exception e) when (IsLanFailure(e))
        {
            CoreLog.Notice($"tv: app list failed ({Short(e)})");
            return new TvProbe(false, name, null);
        }
    }

    public async Task<TvDiscovery> Discover(CancellationToken cancel)
    {
        var hosts = new List<string>();
        var sockets = new List<UdpClient>();
        try
        {
            var search = Encoding.ASCII.GetBytes("M-SEARCH * HTTP/1.1\r\nHost: 239.255.255.250:1900\r\nMan: \"ssdp:discover\"\r\nST: roku:ecp\r\nMX: 2\r\n\r\n");
            // One socket per interface: Windows sends multicast on its first route only (often a Hyper-V or VPN adapter).
            foreach (var local in _localAddresses())
            {
                try
                {
                    var u = new UdpClient(new IPEndPoint(local, 0));
                    sockets.Add(u);
                    await u.SendAsync(search, search.Length, _ssdpTarget);
                }
                catch (SocketException e) { CoreLog.Notice($"tv: search not sent on one interface ({e.SocketErrorCode})"); }
            }
            using var wait = CancellationTokenSource.CreateLinkedTokenSource(cancel);
            wait.CancelAfter(DiscoveryWait);
            await Task.WhenAll(sockets.Select(async u =>
            {
                while (!wait.IsCancellationRequested)
                {
                    UdpReceiveResult r;
                    try { r = await u.ReceiveAsync(wait.Token); }
                    catch (OperationCanceledException) { return; }
                    catch (SocketException) { return; }
                    var from = r.RemoteEndPoint.Address.MapToIPv4().ToString();        // the sender, never LOCATION
                    var text = Encoding.ASCII.GetString(r.Buffer, 0, Math.Min(r.Buffer.Length, 2048));
                    if (!text.Contains("roku:ecp", StringComparison.OrdinalIgnoreCase) || !_allowHost(from)) continue;
                    lock (hosts) if (!hosts.Contains(from) && hosts.Count < TvRules.MaxTvs) hosts.Add(from);
                }
            }));
        }
        finally { foreach (var u in sockets) u.Dispose(); }

        var found = await Task.WhenAll(hosts.Select(async h =>
        {
            string? name = null;
            try { name = DeviceName(await GetCapped(h, "/query/device-info", cancel)); }
            catch (Exception e) when (IsLanFailure(e)) { CoreLog.Notice($"tv: device-info failed ({Short(e)})"); }
            return new TvFound(h, name ?? "Roku TV");
        }));
        bool blocks = found.Length == 0 && _firewallBlocks();
        CoreLog.Notice($"tv: find found {found.Length}{(blocks ? ", firewall drops the replies" : "")}");
        return new TvDiscovery(found, blocks);
    }

    // MARK: HTTP

    /// <summary>The status code of the launch. The body is never read.</summary>
    async Task<int> Launch(string host, string channelId, Prayer prayer, Voice voice, bool test, CancellationToken cancel)
    {
        if (!_allowHost(host)) throw new InvalidOperationException("host refused: not a private IPv4 address");
        if (!TvRules.IsValidChannelId(channelId)) throw new InvalidOperationException("channel id refused");
        var query = "prayer=" + Uri.EscapeDataString(TvRules.PrayerParam(prayer)) + "&voice=" + Uri.EscapeDataString(TvRules.VoiceParam(voice))
                    + (test ? "&test=1" : "");
        using var req = new HttpRequestMessage(HttpMethod.Post, Url(host, "/launch/" + channelId, query)) { Content = new ByteArrayContent([]) };
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        cts.CancelAfter(RequestTimeout);
        using var res = await _http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, cts.Token);
        return (int)res.StatusCode;
    }

    Uri Url(string host, string path, string? query = null) => new UriBuilder("http", host, _port, path) { Query = query ?? "" }.Uri;

    /// <summary>GET with the 512 KB cap: streamed, and we stop as soon as the reply goes over.</summary>
    async Task<byte[]> GetCapped(string host, string path, CancellationToken cancel)
    {
        if (!_allowHost(host)) throw new InvalidOperationException("host refused: not a private IPv4 address");
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        cts.CancelAfter(RequestTimeout);
        using var req = new HttpRequestMessage(HttpMethod.Get, Url(host, path));
        using var res = await _http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, cts.Token);
        if (!res.IsSuccessStatusCode) throw new HttpRequestException($"HTTP {(int)res.StatusCode}");
        if (res.Content.Headers.ContentLength is > MaxBody) throw new InvalidDataException("reply over 512 KB");
        await using var s = await res.Content.ReadAsStreamAsync(cts.Token);
        return await ReadCapped(s, cts.Token);
    }

    internal static async Task<byte[]> ReadCapped(Stream s, CancellationToken cancel)
    {
        var buf = new byte[MaxBody + 1];
        int total = 0;
        while (total < buf.Length)
        {
            int n = await s.ReadAsync(buf.AsMemory(total, buf.Length - total), cancel);
            if (n == 0) return buf[..total];
            total += n;
        }
        throw new InvalidDataException("reply over 512 KB");
    }

    // MARK: XML (untrusted)

    static XmlReader Reader(byte[] xml) => XmlReader.Create(new MemoryStream(xml), new XmlReaderSettings
    {
        DtdProcessing = DtdProcessing.Prohibit,
        XmlResolver = null,
        MaxCharactersFromEntities = 0,
        MaxCharactersInDocument = MaxBody,
        IgnoreComments = true,
        IgnoreProcessingInstructions = true,
    });

    /// <summary>The Go Pray app's id: an &lt;app&gt; whose name starts with "Go Pray" and whose id is "dev" or digits.
    /// A numeric (published) id beats "dev". null = not installed.</summary>
    internal static string? PickChannel(byte[] xml)
    {
        string? dev = null, published = null;
        using var r = Reader(xml);
        while (r.Read())
        {
            if (r.NodeType != XmlNodeType.Element || r.Name != "app") continue;
            var id = r.GetAttribute("id");
            var name = r.IsEmptyElement ? "" : r.ReadElementContentAsString();
            if (!name.Trim().StartsWith("Go Pray", StringComparison.Ordinal) || !TvRules.IsValidChannelId(id)) continue;
            if (id == "dev") dev ??= id; else published ??= id;
        }
        return published ?? dev;
    }

    /// <summary>The id of &lt;active-app&gt;&lt;app id=…&gt;, if it is a valid channel id.</summary>
    internal static string? ActiveAppId(byte[] xml)
    {
        using var r = Reader(xml);
        bool inActive = false;
        while (r.Read())
        {
            if (r.NodeType != XmlNodeType.Element) continue;
            if (r.Name == "active-app") { inActive = true; continue; }
            if (inActive && r.Name == "app") { var id = r.GetAttribute("id"); return TvRules.IsValidChannelId(id) ? id : null; }
        }
        return null;
    }

    internal static string? DeviceName(byte[] xml)
    {
        using var r = Reader(xml);
        while (r.Read())
        {
            if (r.NodeType != XmlNodeType.Element || r.Name != "friendly-device-name" || r.IsEmptyElement) continue;
            var n = new string(r.ReadElementContentAsString().Where(c => !char.IsControl(c)).ToArray()).Trim();
            if (n.Length == 0) return null;
            return n.Length > TvRules.MaxNameLength ? n[..TvRules.MaxNameLength] : n;
        }
        return null;
    }

    static bool IsLanFailure(Exception e) =>
        e is HttpRequestException or OperationCanceledException or InvalidOperationException or IOException or InvalidDataException or XmlException or SocketException;

    static string Short(Exception e) => e is OperationCanceledException ? "timed out" : e.GetBaseException().Message;

    // MARK: this PC

    /// <summary>The PC's own private IPv4 addresses on interfaces that are up and can multicast.</summary>
    static IEnumerable<IPAddress> PrivateInterfaceAddresses()
    {
        try
        {
            return NetworkInterface.GetAllNetworkInterfaces()
                .Where(n => n.OperationalStatus == OperationalStatus.Up && n.SupportsMulticast && n.NetworkInterfaceType != NetworkInterfaceType.Loopback)
                .SelectMany(n => n.GetIPProperties().UnicastAddresses)
                .Select(a => a.Address)
                .Where(a => a.AddressFamily == AddressFamily.InterNetwork && TvRules.IsAllowedHost(a.ToString()))
                .ToList();
        }
        catch (NetworkInformationException) { return []; }
    }

    /// <summary>Windows Firewall really set to drop the TVs' replies: on, for a current profile, with "Allow unicast
    /// response" off (replies to our search are unicast), or an enabled inbound block rule for this exe. Read through
    /// the firewall's own COM policy object (readable as a standard user). Unknown → false.</summary>
    internal static bool FirewallDropsReplies()
    {
        try
        {
            var t = Type.GetTypeFromProgID("HNetCfg.FwPolicy2");
            if (t == null) return false;
            var policy = Activator.CreateInstance(t)!;
            object Get(string name, params object[] args) => t.InvokeMember(name, BindingFlags.GetProperty, null, policy, args)!;
            int current = Convert.ToInt32(Get("CurrentProfileTypes"));
            foreach (int p in new[] { 1, 2, 4 })                              // domain, private, public
            {
                if ((current & p) == 0 || !Convert.ToBoolean(Get("FirewallEnabled", p))) continue;
                if (Convert.ToBoolean(Get("UnicastResponsesToMulticastBroadcastDisabled", p))) return true;
            }
            var exe = Environment.ProcessPath ?? "";
            var rules = (System.Collections.IEnumerable)Get("Rules");
            foreach (var rule in rules)
            {
                var rt = rule.GetType();
                object R(string name) => rt.InvokeMember(name, BindingFlags.GetProperty, null, rule, null)!;
                if (!string.Equals(R("ApplicationName") as string, exe, StringComparison.OrdinalIgnoreCase)) continue;
                if (Convert.ToBoolean(R("Enabled")) && Convert.ToInt32(R("Direction")) == 1 && Convert.ToInt32(R("Action")) == 0
                    && (Convert.ToInt32(R("Profiles")) & current) != 0) return true;
            }
            return false;
        }
        catch (Exception e) { CoreLog.Notice("tv: firewall check not available: " + e.GetBaseException().Message); return false; }
    }
}
