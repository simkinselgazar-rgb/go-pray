// Contracts.cs — every type and interface shared between parts of the app.
// Port of GoPray/Core/Contracts.swift (Final plan §C.1, §C.5). Same names, same meaning;
// a change here is a PM amendment recorded in CONTRACT-NOTES.md.
//
// Dates are UTC `DateTime`s (Kind = Utc) everywhere in Core, the equivalent of Swift's `Date`.

using System;
using System.Collections.Generic;
using System.Linq;

namespace GoPray.Core;

// MARK: - Prayer + windows

/// <summary>Our five prayers (no sunrise). JSON uses the lower-case names: "fajr" … "isha".</summary>
public enum Prayer { Fajr, Dhuhr, Asr, Maghrib, Isha }

/// <summary>JSON: "wholeScreen" / "codingApps".</summary>
public enum BlockMode { WholeScreen, CodingApps }

public sealed record DayTimes(DateTime Fajr, DateTime Sunrise, DateTime Dhuhr, DateTime Asr, DateTime Maghrib, DateTime Isha);

/// <summary><c>End</c> = the next Athan; for Fajr, sunrise.</summary>
public readonly record struct PrayerWindow(Prayer Prayer, DateTime Athan, DateTime End);

public interface IClock { DateTime Now { get; } }

/// <summary>
/// The schedule (CONTRACT-NOTES #1): <c>null</c> means "no valid schedule" (bad lat/lon, library
/// error). The gate and scheduler then never block: bad schedule → no Athan → no block (§G).
/// </summary>
public interface IPrayerScheduleProviding
{
    DayTimes? Times(DateTime day);
    /// <summary>null only before today's Fajr with yesterday's Isha closed, or no valid schedule.</summary>
    PrayerWindow? Window(DateTime t);
    (Prayer Prayer, DateTime At)? NextAthan(DateTime t);
}

// MARK: - Shield

public sealed record ShieldContext
{
    public Prayer Prayer { get; init; }
    public BlockMode Mode { get; init; }
    /// <summary>ms until canConfirm, 0 when open.</summary>
    public int RemainingMs { get; init; }
    /// <summary>0 when not playing.</summary>
    public int AthanRemainingMs { get; init; }
    public bool ReduceMotion { get; init; }
    /// <summary>Coding-apps mode: "Cursor is resting…".</summary>
    public string? HiddenAppName { get; init; }
    /// <summary>CONTRACT-NOTES #31: the ring's true progress after a relaunch. 0 seconds = unknown.</summary>
    public DateTime? BlockStartedAt { get; init; }
    public int LockSeconds { get; init; }
    /// <summary>v2 (PLAN-v2 §2, §9): exits left this year; 0 when none are left or the block's captured switch
    /// is off. 0 → no exit button.</summary>
    public int EmergencyExitsLeft { get; init; }
}

/// <summary>How a block ended through the gate's one private EndBlock. Confirmed = "I prayed" after the lock
/// (LastConfirmed, "May Allah accept it."). Emergency = an emergency exit (LastDropped, a plain fade).</summary>
public enum EndKind { Confirmed, Emergency }

/// <summary>PLAN-v2 §2.2 + §9.1: 5 a local calendar year, a 3 s hold before the confirm card.</summary>
public static class EmergencyExitPolicy
{
    public const int Total = 5;
    public const double HoldSeconds = 3;
    public const string Period = "calendar year";
}

public interface IShieldDelegate
{
    /// <summary>→ gate.RequestConfirm(); the shield never ends itself.</summary>
    void ShieldDidRequestConfirm();
    void ShieldDidRequestSilence();
    /// <summary>→ gate.RequestEmergencyExit(); refused → the shield gets Update(ctx) with the true count.</summary>
    void ShieldDidRequestEmergencyExit();
}

public interface IShieldPresenting
{
    IShieldDelegate? Delegate { get; set; }
    /// <summary>Idempotent; one window per monitor.</summary>
    void Show(ShieldContext ctx);
    /// <summary>Remaining/athan changes; re-sync the page.</summary>
    void Update(ShieldContext ctx);
    /// <summary>Confirmed: plays "May Allah accept it." (≈1.3 s) then closes everything. Emergency: a plain
    /// fade, no line.</summary>
    void Dismiss(Action thenIdle, EndKind kind = EndKind.Confirmed);
    /// <summary>Immediate, no animation (overlap, fail-open).</summary>
    void TearDown();
}

// MARK: - Audio

public enum VoiceKind { Sunni, Shia }

/// <summary>A voice = its folder and file stem. JSON is Swift's synthesized enum shape:
/// <c>{"sunni":{"_0":"Adhan-Makkah"}}</c> (CONTRACT-NOTES #2).</summary>
public readonly record struct Voice(VoiceKind Kind, string Stem)
{
    public static Voice Sunni(string stem) => new(VoiceKind.Sunni, stem);
    public static Voice Shia(string stem) => new(VoiceKind.Shia, stem);
}

public interface IAthanPlaying
{
    bool IsPlaying { get; }
    Action? OnFinished { get; set; }
    /// <summary>Fajr ignores the voice and plays the Fajr file from 9.0 s.</summary>
    void Play(Prayer prayer, Voice voice, float volume);
    void Stop();
    int RemainingMs();
}

// MARK: - Coding-apps mode

public interface IAppHiding
{
    /// <summary>Display name of the app that was minimised again, for the notice copy.</summary>
    Action<string>? OnReHide { get; set; }
    /// <summary>Minimise the apps in <paramref name="ids"/> (process names in BlockedApps.Normalize form) and watch
    /// for them coming forward. The gate passes the list captured in state.json at block start, never the
    /// settings. Safe to call twice.</summary>
    void Start(IReadOnlySet<string> ids);
    void Stop();
}

/// <summary>PLAN-v2 §1.2. JSON "mac" / "windows".</summary>
public enum AppPlatform { Mac, Windows }

/// <summary>An app the person added. Id: Mac bundle id; Windows process name (BlockedApps.Normalize form).</summary>
public sealed record CustomApp(string Id, string Name, AppPlatform Platform);

/// <summary>The blocked-apps list (PLAN-v2 §1.1): the compiled-in defaults minus the ones turned off, plus the
/// person's own apps for this platform, minus the apps that are never blockable. The one place it is computed.</summary>
public static class BlockedApps
{
    public const AppPlatform Current = AppPlatform.Windows;
    public const int MaxCustom = 50, MaxDisabled = 200, MaxIdLength = 200, MaxNameLength = 60, MaxHidden = 200;

    /// <summary>Windows: the shell and what keeps the machine usable (Task Manager stays reachable, PLAN.md §6).
    /// Normalised form.</summary>
    public static readonly IReadOnlySet<string> NeverBlock = new HashSet<string>(StringComparer.Ordinal)
    {
        "gopray", "explorer", "taskmgr", "systemsettings", "applicationframehost", "shellexperiencehost",
        "startmenuexperiencehost", "searchhost", "searchapp", "lockapp", "logonui", "winlogon", "dwm", "csrss",
        "sihost", "ctfmon", "textinputhost", "runtimebroker", "securityhealthsystray",
    };

    /// <summary>The Mac's list (PLAN-v2 §1.1 rule 4), so a shared settings.json is cleaned the same way here.</summary>
    public static readonly IReadOnlySet<string> NeverBlockMac = new HashSet<string>(StringComparer.Ordinal)
    {
        "com.ahmedelgazar.gopray", "com.apple.finder", "com.apple.dock", "com.apple.systemuiserver", "com.apple.controlcenter",
        "com.apple.notificationcenterui", "com.apple.Spotlight", "com.apple.loginwindow", "com.apple.systempreferences",
        "com.apple.WindowManager", "com.apple.ActivityMonitor",
    };

    /// <summary>Windows: trimmed, lower case, a trailing ".exe" dropped ("Code.EXE" → "code").</summary>
    public static string Normalize(string? id)
    {
        var t = (id ?? "").Trim();
        if (t.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) t = t[..^4].TrimEnd();
        return t.ToLowerInvariant();
    }

    static string NormalizeFor(string? id, AppPlatform p) => p == AppPlatform.Windows ? Normalize(id) : (id ?? "").Trim();

    public static bool IsNeverBlock(string? id, AppPlatform platform = Current) =>
        platform == AppPlatform.Windows ? NeverBlock.Contains(Normalize(id)) : NeverBlockMac.Contains((id ?? "").Trim());

    /// <summary>(defaults − disabled) ∪ custom[this platform] − NeverBlock; normalised, deduped.</summary>
    public static IReadOnlySet<string> Effective(Settings s, IEnumerable<string> defaults)
    {
        var off = new HashSet<string>(s.DisabledDefaultApps.Select(Normalize), StringComparer.Ordinal);
        var set = new HashSet<string>(StringComparer.Ordinal);
        foreach (var d in defaults) { var n = Normalize(d); if (n.Length > 0 && !off.Contains(n)) set.Add(n); }
        foreach (var c in s.CustomApps)
            if (c.Platform == Current && Normalize(c.Id) is { Length: > 0 } n) set.Add(n);
        set.ExceptWith(NeverBlock);
        return set;
    }

    /// <summary>A list read back from state.json: never-blockable ids dropped (compared normalised), at most 200
    /// (tamper rule). Ids are kept as written (trimmed), so a Mac file's bundle ids round-trip; the hider normalises.</summary>
    public static IReadOnlyList<string> CleanCaptured(IEnumerable<string> ids) =>
        ids.Select(i => (i ?? "").Trim()).Where(i => i.Length is > 0 and <= MaxIdLength && !NeverBlock.Contains(Normalize(i)))
           .Distinct(StringComparer.Ordinal).Take(MaxHidden).ToList();

    /// <summary>Settings.Sanitized's part: trim, drop empty / too long / never-blockable ids, dedupe, cap 200/50,
    /// names trimmed to 60. Windows ids are normalised; Mac ids are kept as written (trimmed).</summary>
    public static (IReadOnlyList<string> Disabled, IReadOnlyList<CustomApp> Custom) Sanitize(IEnumerable<string> disabled, IEnumerable<CustomApp> custom)
    {
        var d = new List<string>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var raw in disabled)
        {
            if (d.Count == MaxDisabled) break;
            var t = (raw ?? "").Trim();
            if (t.Length is 0 or > MaxIdLength || NeverBlockMac.Contains(t) || NeverBlock.Contains(Normalize(t))) continue;
            if (seen.Add(t)) d.Add(t);
        }
        var c = new List<CustomApp>();
        var seenC = new HashSet<(AppPlatform, string)>();
        foreach (var a in custom)
        {
            if (c.Count == MaxCustom) break;
            var id = NormalizeFor(a.Id, a.Platform);
            if (id.Length is 0 or > MaxIdLength || IsNeverBlock(id, a.Platform) || !seenC.Add((a.Platform, id))) continue;
            var name = (a.Name ?? "").Trim();
            if (name.Length > MaxNameLength) name = name[..MaxNameLength];
            c.Add(new CustomApp(id, name.Length == 0 ? id : name, a.Platform));
        }
        return (d, c);
    }
}

// MARK: - Gate re-evaluation

/// <summary>CONTRACT-NOTES #26: <c>PauseEnded</c> = the scheduler's timer reached Settings.PausedUntil.</summary>
public enum ReevalReason { Launch, Wake, ClockChanged, TimeZoneChanged, SettingsChanged, Midnight, PauseEnded }

// MARK: - Settings shape (§C.5)

/// <summary>
/// The settings.json shape (CONTRACT-NOTES #3), field for field the Mac's. Adhan enums are stored as
/// adhan-swift raw values so Core never needs a prayer library: <c>Method</c> = CalculationMethod raw
/// value ("muslimWorldLeague" …), <c>Madhab</c> 1 shafi / 2 hanafi, <c>HighLatitudeRule</c> raw value or
/// null = the library's recommendation.
/// </summary>
public sealed record Settings
{
    public string City { get; init; } = "";
    public double Latitude { get; init; }
    public double Longitude { get; init; }
    public string Method { get; init; } = "";
    public int Madhab { get; init; }
    public string? HighLatitudeRule { get; init; }
    public BlockMode Mode { get; init; }
    public Voice Voice { get; init; }
    /// <summary>0–1.</summary>
    public float AthanVolume { get; init; }
    public bool LaunchAtLogin { get; init; }
    public bool SetupComplete { get; init; }
    /// <summary>null = follow the system.</summary>
    public bool? ReduceMotion { get; init; }
    /// <summary>CONTRACT-NOTES #26. Clamped with LockPolicy.Clamp; copied into state.json at block start.</summary>
    public int LockMinutes { get; init; }
    /// <summary>CONTRACT-NOTES #27. null = active; DistantFuture = until resumed; past = active again.</summary>
    public DateTime? PausedUntil { get; init; }
    /// <summary>v2: default app ids the person turned off (either platform's ids; each platform matches its own).</summary>
    public IReadOnlyList<string> DisabledDefaultApps { get; init; } = [];
    /// <summary>v2: apps the person added; both platforms are kept, only this platform's are applied.</summary>
    public IReadOnlyList<CustomApp> CustomApps { get; init; } = [];
    /// <summary>v2 "Allow emergency exits". Absent in a file → true. Captured into state.json at block start.</summary>
    public bool EmergencyExitsEnabled { get; init; } = true;
    /// <summary>v2 "Check for updates automatically". Absent in a file → true.</summary>
    public bool CheckForUpdates { get; init; } = true;

    /// <summary>Value equality for the two lists too (a record would compare the list references), so
    /// SettingsStore.Mutate's "nothing changed" check holds.</summary>
    public bool Equals(Settings? o) =>
        o is not null && City == o.City && Latitude.Equals(o.Latitude) && Longitude.Equals(o.Longitude) && Method == o.Method
        && Madhab == o.Madhab && HighLatitudeRule == o.HighLatitudeRule && Mode == o.Mode && Voice == o.Voice
        && AthanVolume.Equals(o.AthanVolume) && LaunchAtLogin == o.LaunchAtLogin && SetupComplete == o.SetupComplete
        && ReduceMotion == o.ReduceMotion && LockMinutes == o.LockMinutes && PausedUntil == o.PausedUntil
        && DisabledDefaultApps.SequenceEqual(o.DisabledDefaultApps) && CustomApps.SequenceEqual(o.CustomApps)
        && EmergencyExitsEnabled == o.EmergencyExitsEnabled && CheckForUpdates == o.CheckForUpdates;

    public override int GetHashCode() => HashCode.Combine(City, Latitude, Longitude, Method, Mode, LockMinutes, DisabledDefaultApps.Count, CustomApps.Count);

    /// <summary>True while a pause is running at <paramref name="now"/>.</summary>
    public bool IsPaused(DateTime now) => (PausedUntil ?? DateTimes.DistantPast) > now;
}

public sealed class SettingsBlockedException : InvalidOperationException
{
    public SettingsBlockedException() : base("Settings cannot change during a block.") { }
}

/// <summary>Swift's Date.distantPast / distantFuture, which the Mac writes into settings.json.</summary>
public static class DateTimes
{
    public static readonly DateTime DistantFuture = new(4001, 1, 1, 0, 0, 0, DateTimeKind.Utc);
    public static readonly DateTime DistantPast = new(1, 1, 1, 0, 0, 0, DateTimeKind.Utc);
}
