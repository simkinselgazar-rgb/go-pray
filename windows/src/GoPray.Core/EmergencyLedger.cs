// EmergencyLedger.cs — the count of emergency exits (PLAN-v2 §2.3, §2.4, §9.1). Port of Core/EmergencyLedger.swift.
// The ONLY file that names emergency.json or records a use (guard.ps1 rule 14).
//
// Rules:
//  - 5 a LOCAL calendar year: remaining = 5 − (uses whose `at` is in this year, plus every use dated after now;
//    a clock moved back still counts them: fail safe). Earlier years stay in the file as history and stop counting.
//  - Two stores, same bytes: %LOCALAPPDATA%\GoPray\emergency.json (primary) and %APPDATA%\GoPray\emergency.json
//    (mirror; Core stays registry-free, guard rule 12). Each is counted with the year rule and the SMALLER remaining
//    wins, so deleting or emptying one file changes nothing while the other stands.
//  - Missing file = no uses. Unreadable, wrong schemaVersion, a bad entry or more than 1000 uses = 0 left (fail safe: it cannot trap,
//    the block still ends after its lock).
//  - RecordUse writes the primary atomically FIRST (a failure throws, and the gate then refuses the exit), then the
//    mirror (a failure there is logged: the primary already counts it). Both get the union of what they held.
//  - Nothing is cached: every read goes to disk.

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;

namespace GoPray.Core;

public sealed class EmergencyLedger
{
    public readonly record struct Use(Prayer Prayer, DateTime AthanAt, DateTime At);

    public const int SchemaVersion = 1;
    /// <summary>More uses than this in one store = unreadable = 0 left (the Mac's rule).</summary>
    public const int MaxUses = 1000;
    const string FileName = "emergency.json";

    readonly TimeZoneInfo? _zone;
    public string PrimaryPath { get; }
    public string MirrorPath { get; }

    public EmergencyLedger(string? directory = null, string? mirrorDirectory = null, TimeZoneInfo? zone = null)
    {
        PrimaryPath = Path.Combine(directory ?? StateStore.DefaultDirectory(), FileName);
        MirrorPath = Path.Combine(mirrorDirectory ?? DefaultMirrorDirectory(), FileName);
        _zone = zone;
    }

    /// <summary>%APPDATA%\GoPray. DEBUG: under GOPRAY_DEBUG_STATE_DIR\mirror, so tests and debug runs never touch the real one.</summary>
    public static string DefaultMirrorDirectory()
    {
#if DEBUG
        var o = Environment.GetEnvironmentVariable("GOPRAY_DEBUG_STATE_DIR");
        if (!string.IsNullOrEmpty(o)) return Path.Combine(o, "mirror");
#endif
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "GoPray");
    }

    /// <summary>Exits left at <paramref name="now"/>: 0…5.</summary>
    public int Remaining(DateTime now)
    {
        int counted = Math.Max(Counted(Read(PrimaryPath), now), Counted(Read(MirrorPath), now));
        return Math.Clamp(EmergencyExitPolicy.Total - counted, 0, EmergencyExitPolicy.Total);
    }

    /// <summary>Record one use. Throws if the primary file cannot be written (the caller refuses the exit) or if either
    /// store is unreadable (0 left: the gate never gets here).</summary>
    public void RecordUse(Use use)
    {
        var primary = Read(PrimaryPath) ?? throw new InvalidOperationException("emergency ledger unreadable");
        var mirror = Read(MirrorPath) ?? throw new InvalidOperationException("emergency ledger mirror unreadable");
        var all = primary.Concat(mirror).Append(Normal(use)).Distinct().OrderBy(u => u.At).ToList();
        Write(PrimaryPath, all);                                   // first; throws → no exit
        try { Write(MirrorPath, all); }
        catch (Exception e) { CoreLog.Error($"emergency mirror write failed: {e.Message}"); }
    }

    // MARK: year rule

    int Counted(List<Use>? uses, DateTime now)
    {
        if (uses == null) return EmergencyExitPolicy.Total;       // unreadable → 0 left
        var zone = _zone ?? TimeZoneInfo.Local;
        int year = Local(now, zone).Year;
        return uses.Count(u => u.At > now || Local(u.At, zone).Year == year);
    }

    static DateTime Local(DateTime utc, TimeZoneInfo zone) => TimeZoneInfo.ConvertTimeFromUtc(DateTime.SpecifyKind(utc, DateTimeKind.Utc), zone);

    static Use Normal(Use u) => new(u.Prayer, DateTime.SpecifyKind(u.AthanAt, DateTimeKind.Utc), DateTime.SpecifyKind(u.At, DateTimeKind.Utc));

    // MARK: disk (same bytes as the Mac: sorted keys, ISO dates with milliseconds)

    /// <summary>null = unreadable; empty = missing.</summary>
    internal static List<Use>? Read(string path)
    {
        byte[] data;
        try { if (!File.Exists(path)) return []; data = File.ReadAllBytes(path); }
        catch (Exception) { return null; }
        try { var u = Decode(data); return u.Count > MaxUses ? null : u; }   // more than 1000 uses: not a real history
        catch (Exception e) when (e is FormatException or JsonException or InvalidOperationException) { return null; }
    }

    public static List<Use> Decode(ReadOnlySpan<byte> json)
    {
        using var doc = JsonDocument.Parse(json.ToArray());
        var root = SwiftJson.Object(doc.RootElement, "emergency");
        if (SwiftJson.Int(SwiftJson.Required(root, "schemaVersion")) != SchemaVersion) throw new FormatException("emergency.json schemaVersion");
        return SwiftJson.Array(SwiftJson.Required(root, "used"), "used").Select(e =>
        {
            var o = SwiftJson.Object(e, "use");
            return new Use(SwiftJson.ParsePrayer(SwiftJson.Required(o, "prayer")), SwiftJson.Date(SwiftJson.Required(o, "athanAt")),
                           SwiftJson.Date(SwiftJson.Required(o, "at")));
        }).ToList();
    }

    public static byte[] Encode(IEnumerable<Use> uses)
    {
        using var w = SwiftJson.Writer(out var buffer);
        w.WriteStartObject();
        w.WriteNumber("schemaVersion", SchemaVersion);
        w.WriteStartArray("used");
        foreach (var u in uses)
        {
            w.WriteStartObject();
            SwiftJson.WriteDate(w, "at", u.At, fractional: true);
            SwiftJson.WriteDate(w, "athanAt", u.AthanAt, fractional: true);
            w.WriteString("prayer", SwiftJson.Name(u.Prayer));
            w.WriteEndObject();
        }
        w.WriteEndArray();
        w.WriteEndObject();
        w.Flush();
        return buffer.WrittenSpan.ToArray();
    }

    static void Write(string path, IEnumerable<Use> uses)
    {
        var dir = Path.GetDirectoryName(path)!;
        Directory.CreateDirectory(dir);
        var tmp = Path.Combine(dir, $".emergency.{Guid.NewGuid():N}.tmp");
        try
        {
            File.WriteAllBytes(tmp, Encode(uses));
            File.Move(tmp, path, overwrite: true);
        }
        finally
        {
            try { if (File.Exists(tmp)) File.Delete(tmp); } catch { /* best effort */ }
        }
    }

#if DEBUG
    /// <summary>DEBUG menu only: make this year's count exactly <paramref name="used"/> in both stores (earlier years kept).</summary>
    public void DebugSetUsed(int used, DateTime now)
    {
        var zone = _zone ?? TimeZoneInfo.Local;
        int year = Local(now, zone).Year;
        var keep = (Read(PrimaryPath) ?? []).Where(u => u.At <= now && Local(u.At, zone).Year != year);
        var fake = Enumerable.Range(0, Math.Clamp(used, 0, EmergencyExitPolicy.Total)).Select(i => new Use(Prayer.Dhuhr, now.AddMinutes(-i - 1), now.AddMinutes(-i)));
        var all = keep.Concat(fake).OrderBy(u => u.At).ToList();
        Write(PrimaryPath, all);
        Write(MirrorPath, all);
    }
#endif
}
