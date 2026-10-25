// Tvs.cs — TV support (0.3.0, PM brief 2026-10-24): at each Athan the PC asks the Roku TVs on the home Wi-Fi to
// open the Go Pray Roku app. The PC block is unchanged; the TV is extra and can never change or delay a block.
//
// Here: the stored shape (settings.json `tvs`), the host rule, the channel id rule, and the interfaces. The only
// code that talks to a TV is GoPray.App/Tv/TvController.cs (guard rule 4).

using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace GoPray.Core;

/// <summary>JSON "roku". The only kind so far.</summary>
public enum TvKind { Roku }

/// <summary>One TV in settings.json, field for field the Mac's TVDevice (CONTRACT-NOTES #56). <c>ChannelId</c>: the Go Pray
/// app's id on that TV, "dev" (sideloaded, the default) or a published number. <c>Installed</c>: false once a lookup
/// found no Go Pray app on the TV (shown in Settings, skipped at Athan time).</summary>
public sealed record TvDevice(string Id, string Name, TvKind Kind, string Host, string ChannelId = TvRules.DefaultChannelId, bool Enabled = true, bool Installed = true);

public static partial class TvRules
{
    public const int MaxTvs = 8, MaxNameLength = 60, MaxIdLength = 64;
    public const string DefaultChannelId = "dev", DefaultName = "Roku TV";
    /// <summary>A TV is called only this long after the prayer's real Athan (several PCs can share one Wi-Fi).</summary>
    public static readonly TimeSpan LaunchWindow = TimeSpan.FromMinutes(3);

    [GeneratedRegex("^(dev|[0-9]{1,10})$")] private static partial Regex ChannelIdPattern();

    public static bool IsValidChannelId(string? id) => id != null && ChannelIdPattern().IsMatch(id);

    /// <summary>An IPv4 literal ("a.b.c.d", no leading zeros) in 10/8, 172.16/12, 192.168/16 or 169.254/16. Never a
    /// hostname. Checked when a TV is saved and again before every request.</summary>
    public static bool IsAllowedHost(string? host)
    {
        if (ParseIPv4(host) is not { } b) return false;
        return b[0] == 10 || (b[0] == 172 && b[1] is >= 16 and <= 31) || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254);
    }

    static byte[]? ParseIPv4(string? s)
    {
        if (s == null) return null;
        var parts = s.Split('.');
        if (parts.Length != 4) return null;
        var b = new byte[4];
        for (int i = 0; i < 4; i++)
        {
            var p = parts[i];
            if (p.Length is 0 or > 3 || !p.All(c => c is >= '0' and <= '9') || (p.Length > 1 && p[0] == '0')) return null;
            int v = int.Parse(p, System.Globalization.CultureInfo.InvariantCulture);
            if (v > 255) return null;
            b[i] = (byte)v;
        }
        return b;
    }

    /// <summary>The prayer value: "fajr" … "isha".</summary>
    public static string PrayerParam(Prayer p) => SwiftJson.Name(p);

    /// <summary>The voice value the Roku app expects: "sunni.&lt;stem&gt;" or "shia.&lt;stem&gt;".</summary>
    public static string VoiceParam(Voice v) => (v.Kind == VoiceKind.Sunni ? "sunni." : "shia.") + v.Stem;

    /// <summary>True when a block that started at <paramref name="now"/> for the Athan at <paramref name="athanAt"/>
    /// may call the TVs: no later than 3 minutes after the Athan (a clock a little behind still counts).</summary>
    public static bool InLaunchWindow(DateTime athanAt, DateTime now) =>
        now - athanAt <= LaunchWindow && athanAt - now <= TimeSpan.FromSeconds(60);

    /// <summary>Settings.Sanitized's part (the Mac's cleanTVs): host and name trimmed, an empty name → "Roku TV", a junk
    /// channel id → "dev", a host that is not a private IPv4 literal dropped, one entry per id and per host, at most 8.</summary>
    public static IReadOnlyList<TvDevice> Sanitize(IEnumerable<TvDevice> tvs)
    {
        var list = new List<TvDevice>();
        var ids = new HashSet<string>(StringComparer.Ordinal);
        var hosts = new HashSet<string>(StringComparer.Ordinal);
        foreach (var t in tvs)
        {
            if (list.Count == MaxTvs) break;
            var id = t.Id ?? "";
            var host = (t.Host ?? "").Trim();
            if (id.Length is 0 or > MaxIdLength || !IsAllowedHost(host) || !ids.Add(id) || !hosts.Add(host)) continue;
            var name = (t.Name ?? "").Trim();
            if (name.Length > MaxNameLength) name = name[..MaxNameLength];
            list.Add(t with { Host = host, Name = name.Length == 0 ? DefaultName : name, ChannelId = IsValidChannelId(t.ChannelId) ? t.ChannelId : DefaultChannelId });
        }
        return list;
    }

    // MARK: settings.json

    public static void Write(Utf8JsonWriter w, IReadOnlyList<TvDevice> tvs)
    {
        w.WriteStartArray("tvs");
        foreach (var t in tvs)
        {
            w.WriteStartObject();
            w.WriteString("channelId", t.ChannelId);
            w.WriteBoolean("enabled", t.Enabled);
            w.WriteString("host", t.Host);
            w.WriteString("id", t.Id);
            w.WriteBoolean("installed", t.Installed);
            w.WriteString("kind", "roku");
            w.WriteString("name", t.Name);
            w.WriteEndObject();
        }
        w.WriteEndArray();
    }

    /// <summary>Per entry, tolerant like the Mac: only id, host and kind are needed (name → "", channelId → "dev",
    /// enabled and installed → true). A bad entry is dropped, so one bad TV never breaks the settings; a `tvs` that is
    /// not an array reads as []. A host that is not a private IPv4 literal is dropped here already.</summary>
    public static IReadOnlyList<TvDevice> Read(JsonElement? e)
    {
        if (e is not { ValueKind: JsonValueKind.Array } arr) return [];
        var list = new List<TvDevice>();
        foreach (var item in arr.EnumerateArray())
        {
            try
            {
                var o = SwiftJson.Object(item, "tv");
                if (SwiftJson.String(SwiftJson.Required(o, "kind")) != "roku") continue;
                var host = SwiftJson.String(SwiftJson.Required(o, "host"));
                if (!IsAllowedHost(host)) continue;
                var channel = SwiftJson.Optional(o, "channelId") is { } c ? SwiftJson.String(c) : DefaultChannelId;
                list.Add(new TvDevice(
                    SwiftJson.String(SwiftJson.Required(o, "id")), SwiftJson.Optional(o, "name") is { } n ? SwiftJson.String(n) : "", TvKind.Roku, host,
                    IsValidChannelId(channel) ? channel : DefaultChannelId,
                    SwiftJson.Optional(o, "enabled") is not { } en || SwiftJson.Bool(en),
                    SwiftJson.Optional(o, "installed") is not { } i || SwiftJson.Bool(i)));
            }
            catch (Exception ex) when (ex is JsonException or FormatException or InvalidOperationException or KeyNotFoundException)
            {
                CoreLog.Notice("settings: a bad tv entry was dropped");
            }
        }
        return list;
    }
}

/// <summary>What the gate needs: called once at block start. Must return at once (the calls run in the background)
/// and never throw back into the gate.</summary>
public interface ITvLaunching
{
    void AthanStarted(IReadOnlyList<TvDevice> tvs, Prayer prayer, Voice voice);
}

/// <summary>A TV found on the network: the reply's sender address and its friendly name.</summary>
public sealed record TvFound(string Host, string Name);

/// <summary>Find TVs. <c>FirewallBlocks</c>: Windows Firewall is set to drop the replies (checked, not guessed).</summary>
public sealed record TvDiscovery(IReadOnlyList<TvFound> Found, bool FirewallBlocks);

/// <summary>A look at one TV: reachable, its name, and the Go Pray channel id (null = not installed).</summary>
public sealed record TvProbe(bool Reachable, string? Name, string? ChannelId);

/// <summary>What Settings needs (the App's TvController).</summary>
public interface ITvControlling : ITvLaunching
{
    Task<TvDiscovery> Discover(CancellationToken cancel);
    Task<TvProbe> Probe(string host, CancellationToken cancel);
    /// <summary>The Test button's launch (adds test=1). True on a 2xx.</summary>
    Task<bool> TestLaunch(string host, string channelId, Prayer prayer, Voice voice, CancellationToken cancel);
}
