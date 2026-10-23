// MenuSnapshot.cs — everything the tray popover shows, as one plain value computed from (settings,
// schedule, gate, time), plus the time formatting the three screens share. Port of UI/MenuViewModel.swift
// and TimeText in UI/SetupViewComponents.swift. No views here, so the rules are unit-tested.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;

namespace GoPray.Core;

public static class TimeText
{
    /// <summary>"3:41 PM" in the person's own time zone and culture.</summary>
    public static string Clock(DateTime utc, TimeZoneInfo? zone = null, CultureInfo? culture = null) =>
        TimeZoneInfo.ConvertTimeFromUtc(DateTime.SpecifyKind(utc, DateTimeKind.Utc), zone ?? TimeZoneInfo.Local)
            .ToString("t", culture ?? CultureInfo.CurrentCulture);

    /// <summary>"1 h 49 min", "49 min", "less than a minute". Rounds up so it never says 0 min early.</summary>
    public static string Duration(double seconds)
    {
        int total = Math.Max(0, (int)Math.Ceiling(seconds));
        if (total < 60) return "less than a minute";
        int minutes = (total + 59) / 60;
        if (minutes < 60) return $"{minutes} min";
        int h = minutes / 60, m = minutes % 60;
        return m == 0 ? $"{h} h" : $"{h} h {m} min";
    }

    /// <summary>"6:12" for a lock countdown.</summary>
    public static string Countdown(double seconds)
    {
        int total = Math.Max(0, (int)Math.Ceiling(seconds));
        return $"{total / 60}:{total % 60:00}";
    }

    /// <summary>"Thu Oct 23".</summary>
    public static string Day(DateTime utc, TimeZoneInfo? zone = null, CultureInfo? culture = null) =>
        TimeZoneInfo.ConvertTimeFromUtc(DateTime.SpecifyKind(utc, DateTimeKind.Utc), zone ?? TimeZoneInfo.Local)
            .ToString("ddd MMM d", culture ?? CultureInfo.CurrentCulture);
}

public enum MenuStatus
{
    /// <summary>Setup not finished: "Add your city…" + Set up.</summary>
    NeedsSetup,
    /// <summary>Setup done but the schedule gave nothing (bad place, polar night).</summary>
    NoSchedule,
    Ready,
}

public sealed record MenuRow(Prayer Prayer, DateTime Time, bool IsNext, bool IsPast);

public sealed record MenuSnapshot
{
    public MenuStatus Status { get; init; }
    public IReadOnlyList<MenuRow> Rows { get; init; } = [];
    public Prayer? NextPrayer { get; init; }
    public double? UntilNext { get; init; }
    /// <summary>During a block: the prayer and the header line ("6:12 left").</summary>
    public Prayer? BlockPrayer { get; init; }
    public string? BlockLine { get; init; }
    public string? PausedLine { get; init; }
    public BlockMode Mode { get; init; }
    public string Footer { get; init; } = "";
    public bool IsBlocked { get; init; }

    /// <summary>The header subtitle.</summary>
    public string Subtitle => BlockLine ?? PausedLine ?? (UntilNext is { } u ? "in " + TimeText.Duration(u) : "");
    /// <summary>The prayer the header shows (and whose still/colours it uses).</summary>
    public Prayer HeaderPrayer => BlockPrayer ?? NextPrayer ?? Prayer.Fajr;
}

public sealed class MenuModel(SettingsStore store, BlockGate gate, IPrayerScheduleProviding schedule, IClock clock, Func<TimeZoneInfo>? zone = null)
{
    readonly Func<TimeZoneInfo> _zone = zone ?? (() => TimeZoneInfo.Local);
    public IClock Clock => clock;

    public void Resume() { try { store.Resume(clock.Now); } catch (Exception) { /* blocked: the popover just keeps showing paused */ } }

    public MenuSnapshot Snapshot(DateTime now)
    {
        var s = store.Settings;
        var snap = new MenuSnapshot { Status = MenuStatus.Ready, Mode = s.Mode, Footer = Footer(s), IsBlocked = gate.IsBlocked };
        if (!s.SetupComplete) return snap with { Status = MenuStatus.NeedsSetup };

        if (s.IsPaused(now) && s.PausedUntil is { } until)
            snap = snap with { PausedLine = until == DateTimes.DistantFuture ? "Paused until you resume" : "Paused until " + TimeText.Day(until, _zone()) };
        if (snap.IsBlocked && gate.CurrentBlock is { } b)
        {
            var phase = gate.Phase;
            string? line = phase.Kind switch
            {
                PhaseKind.Locked => TimeText.Countdown((phase.Until!.Value - now).TotalSeconds) + " left",
                PhaseKind.CanConfirm => "Ready when you are",
                PhaseKind.Leaving => "May Allah accept it.",
                _ => null,
            };
            snap = snap with { BlockPrayer = b.Prayer, BlockLine = line };
        }

        if (schedule.Times(now) is not { } today || schedule.NextAthan(now) is not { } next) return snap with { Status = MenuStatus.NoSchedule };
        snap = snap with { NextPrayer = next.Prayer, UntilNext = (next.At - now).TotalSeconds };

        // After Isha the useful list is tomorrow's, headed by its Fajr.
        var day = today;
        if (now >= today.Isha && schedule.Times(ZoneCalendar.AddDays(now, 1, _zone())) is { } tomorrow) day = tomorrow;
        var rows = PrayerSchedule.Prayers(day)
            .Select(p => new MenuRow(p.Prayer, p.At, p.Prayer == next.Prayer && p.At == next.At, p.At <= now)).ToList();
        return snap with { Rows = rows };
    }

    /// <summary>"Toronto · ISNA · Standard".</summary>
    static string Footer(Settings s)
    {
        if (!s.SetupComplete) return "";
        var city = s.City.Split(',')[0];
        var method = Labels.Method(s.Method)?.ShortName ?? "Custom";
        return string.Join(" · ", new[] { city, method, Labels.MadhabName(s.Madhab) }.Where(x => x.Length > 0));
    }
}
