// BlockState.cs — the state.json shape, schema v1 (§C.2). Port of Core/BlockState.swift.
// Only Core reads or writes this file. Decoding is strict: an unknown schemaVersion, an unknown
// prayer or a missing required field throws, and StateStore turns that into "corrupt → idle".
// The JSON is the Mac's: same keys, sorted, ISO 8601 UTC dates with milliseconds, `block` written
// as an explicit null when idle (see SwiftJson for what "the same" means byte-wise).

using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;

namespace GoPray.Core;

public sealed record BlockStateFile
{
    public const int CurrentSchemaVersion = 1;

    public sealed record Block
    {
        public Prayer Prayer { get; init; }
        public DateTime AthanAt { get; init; }
        public DateTime BlockStartedAt { get; init; }
        public bool Silenced { get; init; }
        public bool AthanPlayed { get; init; }
        /// <summary>Copied from Settings.LockMinutes at block start (CONTRACT-NOTES #26). Missing in a
        /// file → the default 10 min. The gate never honours more than LockPolicy.MaxSeconds.</summary>
        public double LockSeconds { get; init; } = LockPolicy.SecondsForMinutes(LockPolicy.DefaultMinutes);
#if DEBUG
        /// <summary>DEBUG only (CONTRACT-NOTES #39): the synthetic window end of a "Trigger Athan now"
        /// block. Not in Release builds; a stray key in a file is ignored there.</summary>
        public DateTime? DebugWindowEnd { get; init; }
#endif
    }

    /// <summary>A prayer that is finished for the gate. LastConfirmed = "I prayed". LastDropped = given
    /// up by a fail-open rule while its window was still open (CONTRACT-NOTES #10).</summary>
    public readonly record struct Done(Prayer Prayer, DateTime AthanAt);

    public int SchemaVersion { get; init; } = CurrentSchemaVersion;
    public Block? CurrentBlock { get; init; }
    public Done? LastConfirmed { get; init; }
    public Done? LastDropped { get; init; }
    /// <summary>Launch times while a block is up, newest last, at most 5. Crash-loop guard.</summary>
    public IReadOnlyList<DateTime> Launches { get; init; } = [];

    /// <summary>The latest Athan the gate treats as finished (CONTRACT-NOTES #11).</summary>
    public DateTime? LatestDoneAthan
    {
        get
        {
            var all = new[] { LastConfirmed?.AthanAt, LastDropped?.AthanAt }.Where(d => d.HasValue).Select(d => d!.Value).ToList();
            return all.Count == 0 ? null : all.Max();
        }
    }

    public bool Equals(BlockStateFile? other) =>
        other is not null && SchemaVersion == other.SchemaVersion && Equals(CurrentBlock, other.CurrentBlock)
        && LastConfirmed == other.LastConfirmed && LastDropped == other.LastDropped && Launches.SequenceEqual(other.Launches);

    public override int GetHashCode() => HashCode.Combine(SchemaVersion, CurrentBlock, LastConfirmed, LastDropped, Launches.Count);

    // MARK: - JSON

    public sealed class UnsupportedVersionException(int found) : FormatException($"state.json schemaVersion {found} is not supported")
    {
        public int Found { get; } = found;
    }

    public byte[] Encode()
    {
        using var w = SwiftJson.Writer(out var buffer);
        w.WriteStartObject();
        w.WritePropertyName("block");
        if (CurrentBlock is { } b)
        {
            w.WriteStartObject();
            SwiftJson.WriteDate(w, "athanAt", b.AthanAt, fractional: true);
            w.WriteBoolean("athanPlayed", b.AthanPlayed);
            SwiftJson.WriteDate(w, "blockStartedAt", b.BlockStartedAt, fractional: true);
#if DEBUG
            if (b.DebugWindowEnd is { } dwe) SwiftJson.WriteDate(w, "debugWindowEnd", dwe, fractional: true);
#endif
            w.WriteNumber("lockSeconds", b.LockSeconds);
            w.WriteString("prayer", SwiftJson.Name(b.Prayer));
            w.WriteBoolean("silenced", b.Silenced);
            w.WriteEndObject();
        }
        else w.WriteNullValue();                       // explicit null when idle, as the Mac writes it
        if (LastConfirmed is { } c) WriteDone(w, "lastConfirmed", c);
        if (LastDropped is { } d) WriteDone(w, "lastDropped", d);
        w.WriteStartArray("launches");
        foreach (var l in Launches) w.WriteStringValue(SwiftJson.FormatDate(l, fractional: true));
        w.WriteEndArray();
        w.WriteNumber("schemaVersion", SchemaVersion);
        w.WriteEndObject();
        w.Flush();
        return buffer.WrittenSpan.ToArray();
    }

    static void WriteDone(Utf8JsonWriter w, string key, Done d)
    {
        w.WriteStartObject(key);
        SwiftJson.WriteDate(w, "athanAt", d.AthanAt, fractional: true);
        w.WriteString("prayer", SwiftJson.Name(d.Prayer));
        w.WriteEndObject();
    }

    /// <summary>Strict decode. Throws FormatException (or JsonException) for anything the Mac would reject.</summary>
    public static BlockStateFile Decode(ReadOnlySpan<byte> json)
    {
        using var doc = JsonDocument.Parse(json.ToArray());
        var root = SwiftJson.Object(doc.RootElement, "root");
        int version = SwiftJson.Int(SwiftJson.Required(root, "schemaVersion"));
        if (version != CurrentSchemaVersion) throw new UnsupportedVersionException(version);
        Block? block = null;
        if (SwiftJson.Optional(root, "block") is { } be)
        {
            var o = SwiftJson.Object(be, "block");
            block = new Block
            {
                Prayer = SwiftJson.ParsePrayer(SwiftJson.Required(o, "prayer")),
                AthanAt = SwiftJson.Date(SwiftJson.Required(o, "athanAt")),
                BlockStartedAt = SwiftJson.Date(SwiftJson.Required(o, "blockStartedAt")),
                Silenced = SwiftJson.Bool(SwiftJson.Required(o, "silenced")),
                AthanPlayed = SwiftJson.Bool(SwiftJson.Required(o, "athanPlayed")),
                LockSeconds = SwiftJson.Optional(o, "lockSeconds") is { } ls ? SwiftJson.Double(ls)
                    : LockPolicy.SecondsForMinutes(LockPolicy.DefaultMinutes),
#if DEBUG
                DebugWindowEnd = SwiftJson.Optional(o, "debugWindowEnd") is { } dw ? SwiftJson.Date(dw) : null,
#endif
            };
        }
        return new BlockStateFile
        {
            SchemaVersion = version,
            CurrentBlock = block,
            LastConfirmed = SwiftJson.Optional(root, "lastConfirmed") is { } lc ? ReadDone(lc) : null,
            LastDropped = SwiftJson.Optional(root, "lastDropped") is { } ld ? ReadDone(ld) : null,
            Launches = SwiftJson.Optional(root, "launches") is { } la
                ? SwiftJson.Array(la, "launches").Select(SwiftJson.Date).ToList() : [],
        };
    }

    static Done ReadDone(JsonElement e)
    {
        var o = SwiftJson.Object(e, "done");
        return new Done(SwiftJson.ParsePrayer(SwiftJson.Required(o, "prayer")), SwiftJson.Date(SwiftJson.Required(o, "athanAt")));
    }
}
