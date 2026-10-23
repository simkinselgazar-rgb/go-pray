// Contracts.cs — every type and interface shared between parts of the app.
// Port of GoPray/Core/Contracts.swift (Final plan §C.1, §C.5). Same names, same meaning;
// a change here is a PM amendment recorded in CONTRACT-NOTES.md.
//
// Dates are UTC `DateTime`s (Kind = Utc) everywhere in Core, the equivalent of Swift's `Date`.

using System;

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
}

public interface IShieldDelegate
{
    /// <summary>→ gate.RequestConfirm(); the shield never ends itself.</summary>
    void ShieldDidRequestConfirm();
    void ShieldDidRequestSilence();
}

public interface IShieldPresenting
{
    IShieldDelegate? Delegate { get; set; }
    /// <summary>Idempotent; one window per monitor.</summary>
    void Show(ShieldContext ctx);
    /// <summary>Remaining/athan changes; re-sync the page.</summary>
    void Update(ShieldContext ctx);
    /// <summary>Plays "May Allah accept it." (≈1.3 s) then closes everything.</summary>
    void Dismiss(Action thenIdle);
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
    /// <summary>Minimise listed apps, watch for them coming forward. Safe to call twice.</summary>
    void Start();
    void Stop();
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
