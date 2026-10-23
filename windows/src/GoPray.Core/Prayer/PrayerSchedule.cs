// PrayerSchedule.cs — the adhan-swift port behind IPrayerScheduleProviding. Port of
// Prayer/PrayerSchedule.swift. Pure local math: no network, no clock of its own. Reads the current
// settings through a closure, so a settings change is picked up on the next call.
//
// "No valid schedule" is always null, never a made-up time (CONTRACT-NOTES #1): setup not finished,
// bad place, unknown method, or the library gave up for that day (extreme latitudes). The gate then
// never blocks (§G).
//
// A day is the calendar day in the system time zone (zone()), turned into year/month/day for the
// library. Results are absolute UTC instants, so a time zone change moves no instant (E.6).

using System;
using System.Collections.Generic;
using System.Linq;
using GoPray.Core.Adhan;

namespace GoPray.Core;

public sealed class PrayerSchedule : IPrayerScheduleProviding
{
    readonly record struct DayKey(int Year, int Month, int Day, double Latitude, double Longitude, string Method, int Madhab, string Rule);
    readonly record struct Athan(Prayer Prayer, DateTime At, DateTime Sunrise);

    readonly Func<Settings> _settings;
    readonly Func<TimeZoneInfo> _zone;
    /// <summary>Negative results are cached too, so a failing day is computed once.</summary>
    readonly Dictionary<DayKey, DayTimes?> _cache = [];

    public PrayerSchedule(Func<Settings> settings, Func<TimeZoneInfo>? zone = null)
    {
        _settings = settings;
        _zone = zone ?? (() => TimeZoneInfo.Local);
    }

    // MARK: IPrayerScheduleProviding

    public DayTimes? Times(DateTime day) => UsableSettings() is { } s ? DayTimesFor(day, 0, s) : null;

    public PrayerWindow? Window(DateTime t)
    {
        if (AthansAround(t) is not { } list) return null;
        // The last Athan at or before t, then its end: the next Athan, or sunrise for Fajr.
        int i = list.FindLastIndex(a => a.At <= t);
        if (i < 0 || i + 1 >= list.Count) return null;
        var a = list[i];
        var next = list[i + 1].At;
        var end = a.Prayer == Prayer.Fajr ? (a.Sunrise < next ? a.Sunrise : next) : next;
        return new PrayerWindow(a.Prayer, a.At, end > a.At ? end : a.At);
    }

    public (Prayer Prayer, DateTime At)? NextAthan(DateTime t)
    {
        if (AthansAround(t) is not { } list) return null;
        foreach (var a in list) if (a.At > t) return (a.Prayer, a.At);
        return null;
    }

    // MARK: Settings → library parameters (Prayer/Settings.swift calculationParameters())

    /// <summary>The rule the schedule really uses: the saved one, or the library's pick for this latitude.</summary>
    public static string EffectiveHighLatitudeRule(Settings s) =>
        s.HighLatitudeRule is { } r && AdhanNames.Rule(r) != null ? r
        : AdhanNames.Recommended(new Coordinates(s.Latitude, s.Longitude)) == HighLatitudeRule.SeventhOfTheNight ? "seventhOfTheNight" : "middleOfTheNight";

    /// <summary>null when the settings cannot make a valid schedule (bad place, unknown method).</summary>
    internal static CalculationParameters? Parameters(Settings s)
    {
        try { s.Validate(); } catch (SettingsValidationException) { return null; }
        if (AdhanNames.Method(s.Method) is not { } method) return null;
        var p = CalculationParameters.For(method);
        p.Madhab = (Madhab)s.Madhab;
        p.HighLatitudeRule = AdhanNames.Rule(EffectiveHighLatitudeRule(s));
        return p;
    }

    // MARK: Internals

    /// <summary>Settings that can make a schedule at all; null otherwise.</summary>
    Settings? UsableSettings()
    {
        var s = _settings();
        return s.SetupComplete && Parameters(s) != null ? s : null;
    }

    DayTimes? DayTimesFor(DateTime date, int offsetDays, Settings s)
    {
        var local = TimeZoneInfo.ConvertTimeFromUtc(DateTime.SpecifyKind(date, DateTimeKind.Utc), _zone()).Date.AddDays(offsetDays);
        var key = new DayKey(local.Year, local.Month, local.Day, s.Latitude, s.Longitude, s.Method, s.Madhab, EffectiveHighLatitudeRule(s));
        if (_cache.TryGetValue(key, out var hit)) return hit;
        DayTimes? result = null;
        if (Parameters(s) is { } p && Adhan.PrayerTimes.Create(new Coordinates(s.Latitude, s.Longitude), local.Year, local.Month, local.Day, p) is { } t)
            result = new DayTimes(t.Fajr, t.Sunrise, t.Dhuhr, t.Asr, t.Maghrib, t.Isha);
        if (_cache.Count > 64) _cache.Clear();
        _cache[key] = result;
        return result;
    }

    /// <summary>Every Athan of yesterday, today and tomorrow, oldest first. Yesterday's Isha can fall
    /// after midnight, and today's Isha ends at tomorrow's Fajr. null if any of the three days has no
    /// schedule: one rule, and it errs toward "never block".</summary>
    List<Athan>? AthansAround(DateTime t)
    {
        if (UsableSettings() is not { } s) return null;
        var all = new List<Athan>();
        for (int off = -1; off <= 1; off++)
        {
            if (DayTimesFor(t, off, s) is not { } d) return null;
            foreach (var (prayer, at) in Prayers(d)) all.Add(new Athan(prayer, at, d.Sunrise));
        }
        return all.OrderBy(a => a.At).ThenBy(a => (int)a.Prayer).ToList();
    }

    /// <summary>The five prayers in order (sunrise is not a prayer).</summary>
    public static IEnumerable<(Prayer Prayer, DateTime At)> Prayers(DayTimes d) =>
        [(Prayer.Fajr, d.Fajr), (Prayer.Dhuhr, d.Dhuhr), (Prayer.Asr, d.Asr), (Prayer.Maghrib, d.Maghrib), (Prayer.Isha, d.Isha)];
}
