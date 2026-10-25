// Settings.cs — defaults, sanitising, validation and the settings.json coding for `Settings`.
// Port of Prayer/Settings.swift (the parts that are law, not UI copy). The raw values are
// adhan-swift's, so a settings.json from the Mac validates here unchanged.

using System;
using System.Linq;
using System.Text.Json;

namespace GoPray.Core;

public enum SettingsValidationError { InvalidCoordinates, UnknownMethod, UnknownMadhab, UnknownHighLatitudeRule }

public sealed class SettingsValidationException(SettingsValidationError error) : ArgumentException(error.ToString())
{
    public SettingsValidationError Error { get; } = error;
}

public static class SettingsRules
{
    /// <summary>adhan-swift CalculationMethod raw values. "other" (bring your own angles) is not a choice.</summary>
    public static readonly string[] Methods =
    [
        "muslimWorldLeague", "egyptian", "karachi", "ummAlQura", "dubai", "moonsightingCommittee",
        "northAmerica", "kuwait", "qatar", "singapore", "tehran", "turkey",
    ];
    /// <summary>adhan-swift Madhab raw values: 1 shafi ("Standard"), 2 hanafi.</summary>
    public static readonly int[] Madhabs = [1, 2];
    /// <summary>adhan-swift HighLatitudeRule raw values; null = the library's recommendation.</summary>
    public static readonly string[] HighLatitudeRules = ["middleOfTheNight", "seventhOfTheNight", "twilightAngle"];

    public static readonly Voice DefaultVoice = Voice.Sunni("Adhan-Makkah");

    /// <summary>What a fresh install starts with. Setup is not complete, so nothing blocks.</summary>
    public static readonly Settings Defaults = new()
    {
        City = "", Latitude = 0, Longitude = 0, Method = "muslimWorldLeague", Madhab = 1, HighLatitudeRule = null,
        Mode = BlockMode.WholeScreen, Voice = DefaultVoice, AthanVolume = 0.8f, LaunchAtLogin = true,
        SetupComplete = false, ReduceMotion = null, LockMinutes = LockPolicy.DefaultMinutes, PausedUntil = null,
    };

    /// <summary>Clamp what has a natural range: break length 10–30, volume 0–1. A NaN volume falls back
    /// to the default. Everything else is checked by Validate().</summary>
    public static Settings Sanitized(this Settings s)
    {
        var (disabled, custom) = BlockedApps.Sanitize(s.DisabledDefaultApps, s.CustomApps);
        return s with
        {
            LockMinutes = LockPolicy.Clamp(s.LockMinutes),
            AthanVolume = float.IsFinite(s.AthanVolume) ? Math.Min(Math.Max(s.AthanVolume, 0f), 1f) : Defaults.AthanVolume,
            DisabledDefaultApps = disabled,
            CustomApps = custom,
            Tvs = TvRules.Sanitize(s.Tvs),
        };
    }

    /// <summary>Throws for values that cannot be turned into a schedule. Never repairs them.</summary>
    public static void Validate(this Settings s)
    {
        if (!double.IsFinite(s.Latitude) || !double.IsFinite(s.Longitude) || s.Latitude is < -90 or > 90 || s.Longitude is < -180 or > 180)
            throw new SettingsValidationException(SettingsValidationError.InvalidCoordinates);
        if (!Methods.Contains(s.Method)) throw new SettingsValidationException(SettingsValidationError.UnknownMethod);
        if (!Madhabs.Contains(s.Madhab)) throw new SettingsValidationException(SettingsValidationError.UnknownMadhab);
        if (s.HighLatitudeRule is { } rule && !HighLatitudeRules.Contains(rule))
            throw new SettingsValidationException(SettingsValidationError.UnknownHighLatitudeRule);
    }

    // MARK: settings.json (Swift JSONEncoder .sortedKeys + .iso8601: whole-second dates, nil omitted)

    public static byte[] Encode(this Settings s)
    {
        using var w = SwiftJson.Writer(out var buffer);
        w.WriteStartObject();
        w.WriteNumber("athanVolume", s.AthanVolume);
        w.WriteBoolean("checkForUpdates", s.CheckForUpdates);
        w.WriteString("city", s.City);
        // v2 keys are always written, even empty (the Mac's non-optional fields), in sorted position.
        w.WriteStartArray("customApps");
        foreach (var a in s.CustomApps)
        {
            w.WriteStartObject();
            w.WriteString("id", a.Id);
            w.WriteString("name", a.Name);
            w.WriteString("platform", SwiftJson.Name(a.Platform));
            w.WriteEndObject();
        }
        w.WriteEndArray();
        w.WriteStartArray("disabledDefaultApps");
        foreach (var d in s.DisabledDefaultApps) w.WriteStringValue(d);
        w.WriteEndArray();
        w.WriteBoolean("emergencyExitsEnabled", s.EmergencyExitsEnabled);
        if (s.HighLatitudeRule is { } r) w.WriteString("highLatitudeRule", r);
        w.WriteNumber("latitude", s.Latitude);
        w.WriteBoolean("launchAtLogin", s.LaunchAtLogin);
        w.WriteNumber("lockMinutes", s.LockMinutes);
        w.WriteNumber("longitude", s.Longitude);
        w.WriteNumber("madhab", s.Madhab);
        w.WriteString("method", s.Method);
        w.WriteString("mode", SwiftJson.Name(s.Mode));
        if (s.PausedUntil is { } p) SwiftJson.WriteDate(w, "pausedUntil", p, fractional: false);
        if (s.ReduceMotion is { } rm) w.WriteBoolean("reduceMotion", rm);
        w.WriteBoolean("setupComplete", s.SetupComplete);
        TvRules.Write(w, s.Tvs);
        SwiftJson.WriteVoice(w, "voice", s.Voice);
        w.WriteEndObject();
        w.Flush();
        return buffer.WrittenSpan.ToArray();
    }

    /// <summary>Strict, like Swift's synthesized Decodable: every non-optional key is required.</summary>
    public static Settings DecodeSettings(ReadOnlySpan<byte> json)
    {
        using var doc = JsonDocument.Parse(json.ToArray());
        var o = SwiftJson.Object(doc.RootElement, "settings");
        return new Settings
        {
            City = SwiftJson.String(SwiftJson.Required(o, "city")),
            Latitude = SwiftJson.Double(SwiftJson.Required(o, "latitude")),
            Longitude = SwiftJson.Double(SwiftJson.Required(o, "longitude")),
            Method = SwiftJson.String(SwiftJson.Required(o, "method")),
            Madhab = SwiftJson.Int(SwiftJson.Required(o, "madhab")),
            HighLatitudeRule = SwiftJson.Optional(o, "highLatitudeRule") is { } r ? SwiftJson.String(r) : null,
            Mode = SwiftJson.ParseMode(SwiftJson.Required(o, "mode")),
            Voice = SwiftJson.ParseVoice(SwiftJson.Required(o, "voice")),
            AthanVolume = (float)SwiftJson.Double(SwiftJson.Required(o, "athanVolume")),
            LaunchAtLogin = SwiftJson.Bool(SwiftJson.Required(o, "launchAtLogin")),
            SetupComplete = SwiftJson.Bool(SwiftJson.Required(o, "setupComplete")),
            ReduceMotion = SwiftJson.Optional(o, "reduceMotion") is { } rm ? SwiftJson.Bool(rm) : null,
            LockMinutes = SwiftJson.Int(SwiftJson.Required(o, "lockMinutes")),
            PausedUntil = SwiftJson.Optional(o, "pausedUntil") is { } p ? SwiftJson.Date(p) : null,
            // v2 keys: absent in a 0.1.x file → [] / true (Swift decodeIfPresent).
            DisabledDefaultApps = SwiftJson.Optional(o, "disabledDefaultApps") is { } dd
                ? SwiftJson.Array(dd, "disabledDefaultApps").Select(SwiftJson.String).ToList() : [],
            CustomApps = SwiftJson.Optional(o, "customApps") is { } ca
                ? SwiftJson.Array(ca, "customApps").Select(ReadCustomApp).ToList() : [],
            EmergencyExitsEnabled = SwiftJson.Optional(o, "emergencyExitsEnabled") is not { } ee || SwiftJson.Bool(ee),
            CheckForUpdates = SwiftJson.Optional(o, "checkForUpdates") is not { } cu || SwiftJson.Bool(cu),
            // 0.3.0: absent → []; decoded per entry, a bad entry is dropped.
            Tvs = TvRules.Read(SwiftJson.Optional(o, "tvs")),
        };
    }

    static CustomApp ReadCustomApp(JsonElement e)
    {
        var o = SwiftJson.Object(e, "customApp");
        return new CustomApp(SwiftJson.String(SwiftJson.Required(o, "id")), SwiftJson.String(SwiftJson.Required(o, "name")),
                             SwiftJson.ParsePlatform(SwiftJson.Required(o, "platform")));
    }
}
