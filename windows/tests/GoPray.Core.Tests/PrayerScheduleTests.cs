// PrayerScheduleTests.cs — the schedule against published timetables, the window edges of §E (lane A),
// DST days, high latitudes, and "bad input → null, never a made-up time".
// Port of GoPrayTests/Prayer/PrayerScheduleTests.swift (same test names), plus the Mac parity fixture.

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using GoPray.Core;
using Xunit;

namespace GoPray.Core.Tests;

public class PrayerScheduleTests
{
    // MARK: helpers

    static TimeZoneInfo Zone(string id) => TimeZoneInfo.FindSystemTimeZoneById(id);

    static Settings S(double lat, double lon, string method, int madhab = 1, string? rule = null) =>
        TestSettings.Test() with { Latitude = lat, Longitude = lon, Method = method, Madhab = madhab, HighLatitudeRule = rule };

    static PrayerSchedule Schedule(Settings s, string zone) { var z = Zone(zone); return new PrayerSchedule(() => s, () => z); }

    static DateTime Local(int y, int m, int d, int h = 12, int min = 0, string zone = "UTC") =>
        TimeZoneInfo.ConvertTimeToUtc(new DateTime(y, m, d, h, min, 0, DateTimeKind.Unspecified), Zone(zone));

    /// <summary>Minutes since local midnight, as the timetable shows them.</summary>
    static int Minutes(DateTime utc, string zone) { var l = TimeZoneInfo.ConvertTimeFromUtc(utc, Zone(zone)); return l.Hour * 60 + l.Minute; }

    static int Hm(string text) { var p = text.Split(':').Select(int.Parse).ToArray(); return p[0] * 60 + p[1]; }

    static void ExpectTimes(DayTimes? t, string[] reference, string zone, int tolerance, string note)
    {
        Assert.True(t != null, $"no schedule: {note}");
        var got = new[] { t!.Fajr, t.Sunrise, t.Dhuhr, t.Asr, t.Maghrib, t.Isha }.Select(d => Minutes(d, zone)).ToArray();
        var names = new[] { "Fajr", "Sunrise", "Dhuhr", "Asr", "Maghrib", "Isha" };
        var bad = names.Select((n, i) => (n, i)).Where(x => Math.Abs(got[x.i] - Hm(reference[x.i])) > tolerance)
            .Select(x => $"{x.n}: got {got[x.i] / 60}:{got[x.i] % 60:00}, want {reference[x.i]} ±{tolerance}").ToList();
        Assert.True(bad.Count == 0, $"{note}: {string.Join("; ", bad)}");
    }

    // MARK: known cities and dates

    /// <summary>Cairo, 2020-01-01, Egyptian. Reference: api.aladhan.com (method 5): 05:18 06:51 11:58 14:47 17:06 18:29.</summary>
    [Fact]
    public void cairoEgyptianMatchesAladhan() =>
        ExpectTimes(Schedule(S(30.028703, 31.249528, "egyptian"), "Africa/Cairo").Times(Local(2020, 1, 1, zone: "Africa/Cairo")),
                    ["05:18", "06:51", "11:58", "14:47", "17:06", "18:29"], "Africa/Cairo", 1, "Cairo 2020-01-01 Egyptian");

    /// <summary>Raleigh NC, 2016-01-31, Moonsighting. Reference: moonsighting.com (in adhan-swift's tests).</summary>
    [Fact]
    public void raleighMoonsightingMatchesMoonsightingDotCom() =>
        ExpectTimes(Schedule(S(35.7750, -78.6336, "moonsightingCommittee"), "America/New_York").Times(Local(2016, 1, 31, zone: "America/New_York")),
                    ["05:48", "07:16", "12:33", "15:20", "17:43", "19:05"], "America/New_York", 0, "Raleigh 2016-01-31 Moonsighting");

    /// <summary>Toronto, 2026-10-22, ISNA. Reference: api.aladhan.com (method 2); Asr ±2 as on the Mac.</summary>
    [Fact]
    public void torontoIsnaMatchesAladhan() =>
        ExpectTimes(Schedule(S(43.6532, -79.3832, "northAmerica"), "America/Toronto").Times(Local(2026, 10, 22, zone: "America/Toronto")),
                    ["06:21", "07:41", "13:02", "15:56", "18:23", "19:42"], "America/Toronto", 2, "Toronto 2026-10-22 ISNA");

    // MARK: high latitude

    /// <summary>Oslo (59.9° N), 2016-01-01, Moonsighting, Hanafi. Reference: moonsighting.com (in adhan-swift's tests).</summary>
    [Fact]
    public void osloHighLatitudeMatchesMoonsightingDotCom() =>
        ExpectTimes(Schedule(S(59.9094, 10.7349, "moonsightingCommittee", madhab: 2), "Europe/Oslo").Times(Local(2016, 1, 1, zone: "Europe/Oslo")),
                    ["07:34", "09:19", "12:25", "13:36", "15:25", "17:02"], "Europe/Oslo", 0, "Oslo 2016-01-01 Moonsighting Hanafi");

    /// <summary>Edinburgh (56° N), 2020-06-15, MWL: the rule changes Fajr and Isha, nothing else.</summary>
    [Fact]
    public void highLatitudeRuleIsApplied()
    {
        var s = S(55.983226, -3.216649, "muslimWorldLeague", rule: "seventhOfTheNight");
        var day = Local(2020, 6, 15, zone: "Europe/London");
        var seventh = Schedule(s, "Europe/London").Times(day);
        ExpectTimes(seventh, ["03:31", "04:26", "13:14", "17:46", "22:01", "22:56"], "Europe/London", 0, "Edinburgh seventh");

        s = s with { HighLatitudeRule = null };
        var auto = Schedule(s, "Europe/London").Times(day);
        Assert.True(auto?.Fajr == seventh?.Fajr && auto?.Isha == seventh?.Isha);
        Assert.Equal("seventhOfTheNight", PrayerSchedule.EffectiveHighLatitudeRule(s));

        s = s with { HighLatitudeRule = "middleOfTheNight" };
        var middle = Schedule(s, "Europe/London").Times(day);
        Assert.NotEqual(seventh?.Fajr, middle?.Fajr);
        Assert.Equal(seventh?.Dhuhr, middle?.Dhuhr);
        Assert.Equal("middleOfTheNight", PrayerSchedule.EffectiveHighLatitudeRule(S(40, -74, "northAmerica")));
    }

    /// <summary>Edinburgh in June squeezes Isha and the next Fajr together. Windows never overlap or run backwards.</summary>
    [Fact]
    public void midsummerWindowsNeverOverlap()
    {
        var p = Schedule(S(55.983226, -3.216649, "muslimWorldLeague", rule: "middleOfTheNight"), "Europe/London");
        var t = Local(2020, 6, 15, 0, 0, "Europe/London");
        PrayerWindow? last = null;
        for (int i = 0; i < 24 * 6; i++)
        {
            var w = p.Window(t);
            Assert.True(w != null, $"no window at {t:o}");
            Assert.True(w!.Value.End >= w.Value.Athan);
            if (last is { } l && l.Athan != w.Value.Athan) Assert.True(w.Value.Athan >= l.Athan);
            last = w;
            t = t.AddSeconds(600);
        }
    }

    /// <summary>Utqiagvik (71.3° N) on 2018-01-01: polar night, the library returns nothing.</summary>
    [Fact]
    public void polarNightGivesNoSchedule()
    {
        var p = Schedule(S(71.275009, -156.761368, "muslimWorldLeague"), "America/Anchorage");
        var noon = Local(2018, 1, 1, zone: "America/Anchorage");
        Assert.Null(p.Times(noon));
        Assert.Null(p.Window(noon));
        Assert.Null(p.NextAthan(noon));
    }

    // MARK: bad input → null

    [Fact]
    public void badInputGivesNilNeverAMadeUpTime()
    {
        var day = Local(2026, 10, 22, zone: "America/Toronto");
        var good = S(43.65, -79.38, "northAmerica");
        var cases = new List<(string, Settings)>
        {
            ("latitude 999", good with { Latitude = 999 }),
            ("longitude 999", good with { Longitude = 999 }),
            ("NaN latitude", good with { Latitude = double.NaN }),
            ("infinite longitude", good with { Longitude = double.PositiveInfinity }),
            ("unknown method", good with { Method = "bogus" }),
            ("custom method", good with { Method = "other" }),
            ("unknown madhab", good with { Madhab = 3 }),
            ("unknown high-latitude rule", good with { HighLatitudeRule = "nonsense" }),
            ("setup not complete", good with { SetupComplete = false }),
        };
        foreach (var (name, s) in cases)
        {
            var p = Schedule(s, "America/Toronto");
            Assert.True(p.Times(day) == null, $"{name}: times");
            Assert.True(p.Window(day) == null, $"{name}: window");
            Assert.True(p.NextAthan(day) == null, $"{name}: nextAthan");
        }
        Assert.False(SettingsRules.Defaults.SetupComplete);
        Assert.Null(Schedule(SettingsRules.Defaults, "America/Toronto").Times(day));
    }

    // MARK: window edges (Raleigh, 2016-01-31, EST)

    const string ny = "America/New_York";

    static (PrayerSchedule, DayTimes, DayTimes, DayTimes) Raleigh()
    {
        var p = Schedule(S(35.7750, -78.6336, "moonsightingCommittee"), ny);
        return (p, p.Times(Local(2016, 1, 30, zone: ny))!, p.Times(Local(2016, 1, 31, zone: ny))!, p.Times(Local(2016, 2, 1, zone: ny))!);
    }

    [Fact]
    public void windowExactlyAtAnAthanIsThatPrayer()
    {
        var (p, _, today, _) = Raleigh();
        foreach (var (prayer, at) in PrayerSchedule.Prayers(today))
        {
            var w = p.Window(at);
            Assert.Equal(prayer, w?.Prayer);
            Assert.Equal(at, w?.Athan);
        }
        Assert.Equal(today.Maghrib, p.Window(today.Asr)?.End);
        Assert.Equal(today.Asr, p.Window(today.Dhuhr)?.End);
    }

    [Fact]
    public void oneSecondBeforeAnAthanIsThePreviousWindow()
    {
        var (p, _, today, _) = Raleigh();
        var w = p.Window(today.Asr.AddSeconds(-1));
        Assert.Equal(Prayer.Dhuhr, w?.Prayer);
        Assert.Equal(today.Asr, w?.End);
    }

    [Fact]
    public void oneSecondBeforeFajrIsYesterdaysIsha()
    {
        var (p, yesterday, today, _) = Raleigh();
        var w = p.Window(today.Fajr.AddSeconds(-1));
        Assert.Equal(Prayer.Isha, w?.Prayer);
        Assert.Equal(yesterday.Isha, w?.Athan);
        Assert.Equal(today.Fajr, w?.End);
    }

    [Fact]
    public void betweenIshaAndMidnightIshaIsOpen()
    {
        var (p, _, today, tomorrow) = Raleigh();
        var t = Local(2016, 1, 31, 23, 30, ny);
        Assert.True(t > today.Isha);
        var w = p.Window(t);
        Assert.Equal(Prayer.Isha, w?.Prayer);
        Assert.Equal(today.Isha, w?.Athan);
        Assert.Equal(tomorrow.Fajr, w?.End);
    }

    [Fact]
    public void afterMidnightBeforeFajrYesterdaysIshaIsStillOpen()
    {
        var (p, yesterday, today, _) = Raleigh();
        var t = Local(2016, 1, 31, 0, 30, ny);
        var w = p.Window(t);
        Assert.Equal(Prayer.Isha, w?.Prayer);
        Assert.Equal(yesterday.Isha, w?.Athan);
        Assert.True((w?.Athan ?? DateTimes.DistantFuture) < t);
        Assert.Equal(today.Fajr, w?.End);
        Assert.True((w?.End ?? DateTimes.DistantPast) > t);
    }

    [Fact]
    public void fajrWindowEndsAtSunriseNotAtDhuhr()
    {
        var (p, _, today, _) = Raleigh();
        Assert.Equal(today.Sunrise, p.Window(today.Fajr)?.End);
        // One second after sunrise the Fajr window is closed: end is not after t (the missed-Fajr case, E.3).
        var w = p.Window(today.Sunrise.AddSeconds(1));
        Assert.Equal(Prayer.Fajr, w?.Prayer);
        Assert.True((w?.End ?? DateTimes.DistantFuture) <= today.Sunrise.AddSeconds(1));
    }

    [Fact]
    public void nextAthanIsStrictlyAfter()
    {
        var (p, _, today, tomorrow) = Raleigh();
        var n = p.NextAthan(today.Fajr);
        Assert.True(n?.Prayer == Prayer.Dhuhr && n?.At == today.Dhuhr);
        Assert.Equal(Prayer.Asr, p.NextAthan(today.Asr.AddSeconds(-1))?.Prayer);
        Assert.Equal(Prayer.Maghrib, p.NextAthan(today.Asr)?.Prayer);
        var after = p.NextAthan(today.Isha);
        Assert.True(after?.Prayer == Prayer.Fajr && after?.At == tomorrow.Fajr);
        var early = p.NextAthan(Local(2016, 2, 1, 0, 10, ny));
        Assert.True(early?.Prayer == Prayer.Fajr && early?.At == tomorrow.Fajr);
    }

    [Fact]
    public void fivePrayersAreInOrderEveryDayOfAYear()
    {
        var p = Schedule(S(43.6532, -79.3832, "northAmerica"), "America/Toronto");
        var zone = Zone("America/Toronto");
        var day = Local(2026, 1, 1, zone: "America/Toronto");
        for (int i = 0; i < 365; i++)
        {
            var t = p.Times(day);
            Assert.True(t != null, $"no schedule on {day:o}");
            var all = new[] { t!.Fajr, t.Sunrise, t.Dhuhr, t.Asr, t.Maghrib, t.Isha };
            Assert.True(all.SequenceEqual(all.OrderBy(x => x)), $"out of order on {day:o}");
            day = ZoneCalendar.AddDays(day, 1, zone);
        }
    }

    // MARK: DST

    /// <summary>Spring forward: America/New_York, 2026-03-08 (a 23-hour day).</summary>
    [Fact]
    public void springForwardDay()
    {
        var s = S(40.7128, -74.0060, "northAmerica");
        var p = Schedule(s, ny);
        var t = p.Times(Local(2026, 3, 8, zone: ny))!;
        var direct = GoPray.Core.Adhan.PrayerTimes.Create(new GoPray.Core.Adhan.Coordinates(s.Latitude, s.Longitude), 2026, 3, 8, PrayerSchedule.Parameters(s)!)!;
        Assert.True(t.Fajr == direct.Fajr && t.Isha == direct.Isha && t.Dhuhr == direct.Dhuhr);
        Assert.True(Zone(ny).IsDaylightSavingTime(t.Dhuhr));
        // 03:30 EDT is 1.5 h after the jump; yesterday's Isha is still the open window.
        var w = p.Window(Local(2026, 3, 8, 3, 30, ny));
        Assert.Equal(Prayer.Isha, w?.Prayer);
        Assert.Equal(t.Fajr, w?.End);
        Assert.True(t.Dhuhr > t.Fajr);
    }

    /// <summary>Fall back: America/New_York, 2026-11-01 (a 25-hour day).</summary>
    [Fact]
    public void fallBackDay()
    {
        var p = Schedule(S(40.7128, -74.0060, "northAmerica"), ny);
        var t = p.Times(Local(2026, 11, 1, zone: ny))!;
        var all = new[] { t.Fajr, t.Sunrise, t.Dhuhr, t.Asr, t.Maghrib, t.Isha };
        Assert.True(all.SequenceEqual(all.OrderBy(x => x)));
        var n = p.NextAthan(t.Isha);
        Assert.Equal(Prayer.Fajr, n?.Prayer);
        Assert.Equal(p.Times(Local(2026, 11, 2, zone: ny))!.Fajr, n?.At);
        // The repeated 1:30 AM (the second one, EST) is still inside yesterday's Isha window.
        var repeated = Local(2026, 11, 1, 0, 0, ny).AddSeconds(2.5 * 3600);
        Assert.Equal(Prayer.Isha, p.Window(repeated)?.Prayer);
    }

    // MARK: settings changes and time zones

    [Fact]
    public void settingsChangeIsPickedUpAtOnce()
    {
        var s = S(43.6532, -79.3832, "northAmerica");
        var zone = Zone("America/Toronto");
        var p = new PrayerSchedule(() => s, () => zone);
        var day = Local(2026, 10, 22, zone: "America/Toronto");
        var isna = p.Times(day)!;
        s = s with { Method = "egyptian" };
        var egyptian = p.Times(day)!;
        Assert.NotEqual(isna.Fajr, egyptian.Fajr);   // 19.5° vs 15°
        s = s with { Madhab = 2 };
        Assert.True(p.Times(day)!.Asr > egyptian.Asr);
        s = s with { Latitude = 999 };
        Assert.Null(p.Times(day));
    }

    [Fact]
    public void timeZoneChangeMovesNoInstant()
    {
        var zone = "America/Toronto";
        var s = S(43.6532, -79.3832, "northAmerica");
        var p = new PrayerSchedule(() => s, () => Zone(zone));
        var t = Local(2026, 10, 22, 12, zone: "America/Toronto");
        var a = p.NextAthan(t);
        zone = "Europe/Paris";
        var b = p.NextAthan(t);
        Assert.Equal(a?.Prayer, b?.Prayer);
        Assert.Equal(a?.At, b?.At);
    }

    // MARK: Windows addition — parity with the Mac app (fixtures/mac-times.json, from adhan-swift 1.5.0)

    [Fact]
    public void macParityToTheMinute()
    {
        using var doc = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "fixtures", "mac-times.json")));
        var cases = doc.RootElement.GetProperty("cases").EnumerateArray().ToList();
        Assert.Equal(9, cases.Count);
        var deltas = new List<string>();
        foreach (var c in cases)
        {
            string zone = c.GetProperty("timeZone").GetString()!;
            var rule = c.GetProperty("highLatitudeRule");
            var s = S(c.GetProperty("latitude").GetDouble(), c.GetProperty("longitude").GetDouble(), c.GetProperty("method").GetString()!,
                      c.GetProperty("madhab").GetInt32(), rule.ValueKind == JsonValueKind.Null ? null : rule.GetString());
            var date = DateTime.ParseExact(c.GetProperty("date").GetString()!, "yyyy-MM-dd", null);
            var t = Schedule(s, zone).Times(Local(date.Year, date.Month, date.Day, zone: zone));
            string label = $"{c.GetProperty("city").GetString()} {c.GetProperty("date").GetString()}";
            if (t == null) { deltas.Add($"{label}: no schedule"); continue; }
            foreach (var (name, got) in new[] { ("fajr", t.Fajr), ("sunrise", t.Sunrise), ("dhuhr", t.Dhuhr), ("asr", t.Asr), ("maghrib", t.Maghrib), ("isha", t.Isha) })
            {
                var want = DateTime.Parse(c.GetProperty(name).GetString()!, null, System.Globalization.DateTimeStyles.AdjustToUniversal);
                if (got != want) deltas.Add($"{label} {name}: got {got:HH:mm}Z want {want:HH:mm}Z ({(got - want).TotalMinutes:+0;-0} min)");
            }
        }
        Assert.True(deltas.Count == 0, "parity deltas:\n" + string.Join("\n", deltas));
    }
}
