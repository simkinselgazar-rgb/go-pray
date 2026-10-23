// LockPolicy.cs — lock length and pause choices (Ahmed, 2026-10-22). Port of the
// LockPolicy / PauseOption part of Contracts.swift.

using System;

namespace GoPray.Core;

/// <summary>Lock length rules: 10–30 minutes, default 10.</summary>
public static class LockPolicy
{
    public const int MinMinutes = 10;
    public const int MaxMinutes = 30;
    public const int DefaultMinutes = 10;
    public static double MaxSeconds => MaxMinutes * 60;

    public static int Clamp(int minutes) => Math.Min(Math.Max(minutes, MinMinutes), MaxMinutes);
    public static double SecondsForMinutes(int minutes) => Clamp(minutes) * 60;
}

/// <summary>Pause choices. Allowed only between prayers (no active block).</summary>
public enum PauseOption { OneDay, ThreeDays, OneWeek, UntilResumed }

public static class PauseOptions
{
    public static readonly PauseOption[] All = [PauseOption.OneDay, PauseOption.ThreeDays, PauseOption.OneWeek, PauseOption.UntilResumed];

    /// <summary>
    /// The pause end, counted in calendar days in <paramref name="zone"/> (Swift's
    /// <c>calendar.date(byAdding: .day)</c>: the same wall-clock time, across a DST change too).
    /// </summary>
    public static DateTime Until(this PauseOption option, DateTime now, TimeZoneInfo? zone = null)
    {
        int days = option switch
        {
            PauseOption.OneDay => 1,
            PauseOption.ThreeDays => 3,
            PauseOption.OneWeek => 7,
            _ => -1,
        };
        if (days < 0) return DateTimes.DistantFuture;
        return ZoneCalendar.AddDays(now, days, zone ?? TimeZoneInfo.Local);
    }
}

/// <summary>Wall-clock day arithmetic in one time zone (the Swift Calendar calls the Mac core uses).</summary>
public static class ZoneCalendar
{
    public static DateTime AddDays(DateTime utc, int days, TimeZoneInfo zone)
    {
        var local = TimeZoneInfo.ConvertTimeFromUtc(utc, zone).AddDays(days);
        return ToUtc(local, zone);
    }

    /// <summary>The UTC instant of the local midnight that starts the day after <paramref name="utc"/>'s local day.</summary>
    public static DateTime StartOfNextDay(DateTime utc, TimeZoneInfo zone)
    {
        var local = TimeZoneInfo.ConvertTimeFromUtc(utc, zone);
        return ToUtc(local.Date.AddDays(1), zone);
    }

    /// <summary>Local wall time → UTC. A time skipped by DST moves forward; an ambiguous one takes the first.</summary>
    static DateTime ToUtc(DateTime local, TimeZoneInfo zone)
    {
        local = DateTime.SpecifyKind(local, DateTimeKind.Unspecified);
        while (zone.IsInvalidTime(local)) local = local.AddMinutes(30);
        if (zone.IsAmbiguousTime(local))
        {
            var offsets = zone.GetAmbiguousTimeOffsets(local);
            var max = offsets[0] > offsets[1] ? offsets[0] : offsets[1];
            return DateTime.SpecifyKind(local - max, DateTimeKind.Utc);
        }
        return TimeZoneInfo.ConvertTimeToUtc(local, zone);
    }
}
