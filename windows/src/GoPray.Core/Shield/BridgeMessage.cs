// BridgeMessage.cs — the JS <-> host vocabulary (Architecture Plan C.6). Port of Shield/BridgeMessage.swift.
// Pure value code, no WebView2: the validation rules are unit-tested on their own.

using System;
using System.Text.Encodings.Web;
using System.Text.Json;

namespace GoPray.Core;

/// <summary>What the page may ask. Five names (v2 adds "emergency", the last one), nothing else. Anything else is dropped.</summary>
public enum BridgeMessage { Ready, Prayed, Silence, Gone, Emergency }

/// <summary>Which page layout the host asks for.</summary>
public enum ShieldLayout { Full, Notice, Art }

public static class BridgeMessages
{
    /// <summary>The body must be exactly <c>{ "type": &lt;one of the four&gt; }</c> (WebView2's WebMessageAsJson).
    /// Any other shape, extra key, wrong type or unknown name is rejected (the caller logs and drops it).</summary>
    public static BridgeMessage? Parse(string? json)
    {
        if (string.IsNullOrEmpty(json)) return null;
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return null;
            int count = 0;
            JsonElement type = default;
            foreach (var p in root.EnumerateObject())
            {
                count++;
                if (p.Name == "type") type = p.Value;
            }
            if (count != 1 || type.ValueKind != JsonValueKind.String) return null;
            return type.GetString() switch
            {
                "ready" => BridgeMessage.Ready,
                "prayed" => BridgeMessage.Prayed,
                "silence" => BridgeMessage.Silence,
                "gone" => BridgeMessage.Gone,
                "emergency" => BridgeMessage.Emergency,
                _ => null,
            };
        }
        catch (JsonException) { return null; }
    }
}

/// <summary>Host -> JS: <c>GoPrayBridge.show(&lt;this as JSON&gt;)</c>. Built only from enums, ints and bools, plus
/// HiddenAppName, which the JSON encoder escapes and bridge.js renders with textContent.</summary>
public sealed record BridgePayload
{
    public const int MaxAppNameLength = 60;

    public Prayer Prayer { get; init; }
    public BlockMode Mode { get; init; }
    public int RemainingMs { get; init; }
    public int AthanRemainingMs { get; init; }
    /// <summary>Total lock length, so the ring starts at its true progress. 0 = unknown.</summary>
    public int LockMs { get; init; }
    public bool ReduceMotion { get; init; }
    public string? HiddenAppName { get; init; }
    public ShieldLayout Layout { get; init; }
    /// <summary>v2: 0…5; 0 → the page draws no exit button.</summary>
    public int EmergencyExitsLeft { get; init; }

    public static BridgePayload From(ShieldContext ctx, ShieldLayout layout, bool? reduceMotionOverride = null) => new()
    {
        Prayer = ctx.Prayer,
        Mode = ctx.Mode,
        RemainingMs = Math.Min(Math.Max(ctx.RemainingMs, 0), (int)(LockPolicy.MaxSeconds * 1000)),
        AthanRemainingMs = Math.Min(Math.Max(ctx.AthanRemainingMs, 0), 60 * 60 * 1000),
        LockMs = Math.Min(Math.Max(ctx.LockSeconds, 0), (int)LockPolicy.MaxSeconds) * 1000,
        ReduceMotion = reduceMotionOverride ?? ctx.ReduceMotion,
        HiddenAppName = ctx.HiddenAppName is { } n ? (n.Length > MaxAppNameLength ? n[..MaxAppNameLength] : n) : null,
        Layout = layout,
        EmergencyExitsLeft = Math.Clamp(ctx.EmergencyExitsLeft, 0, EmergencyExitPolicy.Total),
    };

    /// <summary>The JS call. The JSON comes from the encoder, never from string pasting. Keys sorted, as on the Mac;
    /// the default (strict) escaper also escapes &lt; &gt; &amp; ' and U+2028/2029, so nothing can end the string or the script.</summary>
    public string ShowScript()
    {
        using var w = SwiftJson.Writer(out var buffer, indented: false, encoder: JavaScriptEncoder.Default);
        w.WriteStartObject();
        w.WriteNumber("athanRemainingMs", AthanRemainingMs);
        w.WriteNumber("emergencyExitsLeft", EmergencyExitsLeft);
        if (HiddenAppName is { } n) w.WriteString("hiddenAppName", n);
        w.WriteString("layout", Layout switch { ShieldLayout.Full => "full", ShieldLayout.Notice => "notice", _ => "art" });
        w.WriteNumber("lockMs", LockMs);
        w.WriteString("mode", SwiftJson.Name(Mode));
        w.WriteString("prayer", SwiftJson.Name(Prayer));
        w.WriteBoolean("reduceMotion", ReduceMotion);
        w.WriteNumber("remainingMs", RemainingMs);
        w.WriteEndObject();
        w.Flush();
        return "GoPrayBridge.show(" + System.Text.Encoding.UTF8.GetString(buffer.WrittenSpan) + ")";
    }
}
