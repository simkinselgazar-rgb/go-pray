// SwiftJson.cs — read and write JSON the way the Mac app's Swift Codable does, so a state.json or
// settings.json moves between the two apps unchanged in meaning:
//   - same key names, keys sorted (Swift `.sortedKeys`), nil optionals omitted, idle `block` = null;
//   - dates: state.json ISO 8601 UTC with milliseconds ("2026-10-22T15:30:00.000Z"), settings.json
//     whole seconds ("2026-10-22T15:30:00Z"); both read either form, and any UTC offset;
//   - enums as Swift raw values ("asr", "codingApps"); Voice as {"sunni":{"_0":"stem"}}.
// Non-ASCII is written as raw UTF-8 like Swift. Whitespace and Swift's "\/" escaping differ;
// every JSON reader ignores both.

using System;
using System.Buffers;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace GoPray.Core;

internal static partial class SwiftJson
{
    public static Utf8JsonWriter Writer(out ArrayBufferWriter<byte> buffer)
    {
        buffer = new ArrayBufferWriter<byte>();
        return new Utf8JsonWriter(buffer, new JsonWriterOptions { Indented = true, Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping });
    }

    public static string FormatDate(DateTime d, bool fractional)
    {
        var u = d.Kind == DateTimeKind.Local ? d.ToUniversalTime() : DateTime.SpecifyKind(d, DateTimeKind.Utc);
        return u.ToString(fractional ? "yyyy-MM-dd'T'HH:mm:ss.fff'Z'" : "yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);
    }

    public static void WriteDate(Utf8JsonWriter w, string key, DateTime d, bool fractional) => w.WriteString(key, FormatDate(d, fractional));

    [GeneratedRegex(@"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-]\d{2}:?\d{2})$")]
    private static partial Regex IsoPattern();

    public static DateTime Date(JsonElement e)
    {
        if (e.ValueKind != JsonValueKind.String) throw new FormatException("date is not a string");
        var s = e.GetString()!;
        if (!IsoPattern().IsMatch(s)) throw new FormatException($"bad date {s}");
        return DateTimeOffset.Parse(s, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal).UtcDateTime;
    }

    public static Dictionary<string, JsonElement> Object(JsonElement e, string what)
    {
        if (e.ValueKind != JsonValueKind.Object) throw new FormatException($"{what} is not an object");
        var d = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
        foreach (var p in e.EnumerateObject()) d[p.Name] = p.Value;
        return d;
    }

    public static IEnumerable<JsonElement> Array(JsonElement e, string what) =>
        e.ValueKind == JsonValueKind.Array ? e.EnumerateArray().ToList() : throw new FormatException($"{what} is not an array");

    public static JsonElement Required(Dictionary<string, JsonElement> o, string key) =>
        o.TryGetValue(key, out var v) && v.ValueKind != JsonValueKind.Null ? v : throw new FormatException($"missing {key}");

    /// <summary>Missing or null → null (Swift decodeIfPresent).</summary>
    public static JsonElement? Optional(Dictionary<string, JsonElement> o, string key) =>
        o.TryGetValue(key, out var v) && v.ValueKind != JsonValueKind.Null ? v : null;

    public static bool Bool(JsonElement e) => e.ValueKind switch
    {
        JsonValueKind.True => true,
        JsonValueKind.False => false,
        _ => throw new FormatException("not a bool"),
    };

    public static int Int(JsonElement e) =>
        e.ValueKind == JsonValueKind.Number && e.TryGetInt32(out var i) ? i : throw new FormatException("not an integer");

    public static double Double(JsonElement e) =>
        e.ValueKind == JsonValueKind.Number ? e.GetDouble() : throw new FormatException("not a number");

    public static string String(JsonElement e) =>
        e.ValueKind == JsonValueKind.String ? e.GetString()! : throw new FormatException("not a string");

    // MARK: enums as Swift raw values

    public static string Name(Prayer p) => p switch
    {
        Prayer.Fajr => "fajr", Prayer.Dhuhr => "dhuhr", Prayer.Asr => "asr", Prayer.Maghrib => "maghrib", _ => "isha",
    };

    public static Prayer ParsePrayer(JsonElement e) => String(e) switch
    {
        "fajr" => Prayer.Fajr, "dhuhr" => Prayer.Dhuhr, "asr" => Prayer.Asr, "maghrib" => Prayer.Maghrib, "isha" => Prayer.Isha,
        var s => throw new FormatException($"unknown prayer {s}"),
    };

    public static string Name(BlockMode m) => m == BlockMode.WholeScreen ? "wholeScreen" : "codingApps";

    public static BlockMode ParseMode(JsonElement e) => String(e) switch
    {
        "wholeScreen" => BlockMode.WholeScreen, "codingApps" => BlockMode.CodingApps,
        var s => throw new FormatException($"unknown mode {s}"),
    };

    public static void WriteVoice(Utf8JsonWriter w, string key, Voice v)
    {
        w.WriteStartObject(key);
        w.WriteStartObject(v.Kind == VoiceKind.Sunni ? "sunni" : "shia");
        w.WriteString("_0", v.Stem);
        w.WriteEndObject();
        w.WriteEndObject();
    }

    public static Voice ParseVoice(JsonElement e)
    {
        var o = Object(e, "voice");
        if (o.Count != 1) throw new FormatException("voice must have exactly one case");
        var (name, payload) = o.First();
        var kind = name switch
        {
            "sunni" => VoiceKind.Sunni, "shia" => VoiceKind.Shia,
            _ => throw new FormatException($"unknown voice case {name}"),
        };
        return new Voice(kind, String(Required(Object(payload, "voice payload"), "_0")));
    }
}
