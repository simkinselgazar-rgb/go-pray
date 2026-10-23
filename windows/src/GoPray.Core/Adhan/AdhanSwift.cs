// AdhanSwift.cs — a line-for-line C# port of adhan-swift 1.5.0 (the prayer-time math the Mac app
// uses), so both apps compute the same minute (PLAN.md §2 "Prayer math", parity test in
// PrayerParityTests). Only what Go Pray needs: PrayerTimes and its astronomy. No Qibla, no Sunnah times.
//
// Why a port and not the Adhan 0.9.0 NuGet: that package is MIT too, but it is a 2019 port of the
// older Java algorithm. It lacks Tehran and Turkey, uses Egyptian 20°/18° (adhan-swift: 19.5°/17.5°),
// has no Maghrib angle, no rounding modes, no Shafaq, no recommended high-latitude rule, and takes
// the night length from today's sunrise + 24 h instead of tomorrow's sunrise. See windows/docs/adhan.md.
//
// Original: https://github.com/batoulapps/adhan-swift (tag 1.5.0), Sources/{PrayerTimes,Astronomy/*,
// Models/*,Extensions/*,Units/*}.swift.
//
// The MIT License (MIT)
// Copyright (c) 2016 Batoul Apps
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
// associated documentation files (the "Software"), to deal in the Software without restriction,
// including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense,
// and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so,
// subject to the following conditions: The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT
// LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN
// NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
// WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
// SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

using System;

namespace GoPray.Core.Adhan;

internal enum CalculationMethod
{
    MuslimWorldLeague, Egyptian, Karachi, UmmAlQura, Dubai, MoonsightingCommittee, NorthAmerica, Kuwait, Qatar,
    Singapore, Tehran, Turkey, Other,
}

internal enum Madhab { Shafi = 1, Hanafi = 2 }
internal enum HighLatitudeRule { MiddleOfTheNight, SeventhOfTheNight, TwilightAngle }
internal enum Rounding { Nearest, Up, None }
internal enum Shafaq { General, Ahmer, Abyad }

internal readonly record struct Coordinates(double Latitude, double Longitude)
{
    public Angle LatitudeAngle => new(Latitude);
    public Angle LongitudeAngle => new(Longitude);
}

/// <summary>Minutes added to each time.</summary>
internal readonly record struct PrayerAdjustments(int Fajr = 0, int Sunrise = 0, int Dhuhr = 0, int Asr = 0, int Maghrib = 0, int Isha = 0);

internal static class AdhanNames
{
    /// <summary>adhan-swift raw values (what settings.json stores) → the method; null if unknown.</summary>
    public static CalculationMethod? Method(string raw) => raw switch
    {
        "muslimWorldLeague" => CalculationMethod.MuslimWorldLeague, "egyptian" => CalculationMethod.Egyptian,
        "karachi" => CalculationMethod.Karachi, "ummAlQura" => CalculationMethod.UmmAlQura, "dubai" => CalculationMethod.Dubai,
        "moonsightingCommittee" => CalculationMethod.MoonsightingCommittee, "northAmerica" => CalculationMethod.NorthAmerica,
        "kuwait" => CalculationMethod.Kuwait, "qatar" => CalculationMethod.Qatar, "singapore" => CalculationMethod.Singapore,
        "tehran" => CalculationMethod.Tehran, "turkey" => CalculationMethod.Turkey, "other" => CalculationMethod.Other,
        _ => null,
    };

    public static HighLatitudeRule? Rule(string raw) => raw switch
    {
        "middleOfTheNight" => HighLatitudeRule.MiddleOfTheNight, "seventhOfTheNight" => HighLatitudeRule.SeventhOfTheNight,
        "twilightAngle" => HighLatitudeRule.TwilightAngle, _ => null,
    };

    /// <summary>HighLatitudeRule.recommended(for:): above 48° N/S… (adhan-swift checks latitude &gt; 48 only).</summary>
    public static HighLatitudeRule Recommended(Coordinates c) => c.Latitude > 48 ? HighLatitudeRule.SeventhOfTheNight : HighLatitudeRule.MiddleOfTheNight;
}

internal sealed class CalculationParameters
{
    public CalculationMethod Method = CalculationMethod.Other;
    public double FajrAngle;
    public double? MaghribAngle;
    public double IshaAngle;
    public int IshaInterval;
    public Madhab Madhab = Madhab.Shafi;
    public HighLatitudeRule? HighLatitudeRule;
    public PrayerAdjustments Adjustments;
    public Rounding Rounding = Rounding.Nearest;
    public Shafaq Shafaq = Shafaq.General;
    public PrayerAdjustments MethodAdjustments;

    CalculationParameters(double fajrAngle, double ishaAngle, CalculationMethod method) { FajrAngle = fajrAngle; IshaAngle = ishaAngle; Method = method; }

    /// <summary>CalculationMethod.params.</summary>
    public static CalculationParameters For(CalculationMethod m) => m switch
    {
        CalculationMethod.MuslimWorldLeague => new(18, 17, m) { MethodAdjustments = new(Dhuhr: 1) },
        CalculationMethod.Egyptian => new(19.5, 17.5, m) { MethodAdjustments = new(Dhuhr: 1) },
        CalculationMethod.Karachi => new(18, 18, m) { MethodAdjustments = new(Dhuhr: 1) },
        CalculationMethod.UmmAlQura => new(18.5, 0, m) { IshaInterval = 90 },
        CalculationMethod.Dubai => new(18.2, 18.2, m) { MethodAdjustments = new(Sunrise: -3, Dhuhr: 3, Asr: 3, Maghrib: 3) },
        CalculationMethod.MoonsightingCommittee => new(18, 18, m) { MethodAdjustments = new(Dhuhr: 5, Maghrib: 3) },
        CalculationMethod.NorthAmerica => new(15, 15, m) { MethodAdjustments = new(Dhuhr: 1) },
        CalculationMethod.Kuwait => new(18, 17.5, m),
        CalculationMethod.Qatar => new(18, 0, m) { IshaInterval = 90 },
        CalculationMethod.Singapore => new(20, 18, m) { MethodAdjustments = new(Dhuhr: 1), Rounding = Rounding.Up },
        CalculationMethod.Tehran => new(17.7, 14, m) { MaghribAngle = 4.5 },
        CalculationMethod.Turkey => new(18, 17, m) { MethodAdjustments = new(Fajr: 0, Sunrise: -7, Dhuhr: 5, Asr: 4, Maghrib: 7, Isha: 0) },
        _ => new(0, 0, m),
    };

    public (double Fajr, double Isha) NightPortions(Coordinates c) => (HighLatitudeRule ?? AdhanNames.Recommended(c)) switch
    {
        Adhan.HighLatitudeRule.MiddleOfTheNight => (1.0 / 2, 1.0 / 2),
        Adhan.HighLatitudeRule.SeventhOfTheNight => (1.0 / 7, 1.0 / 7),
        _ => (FajrAngle / 60, IshaAngle / 60),
    };
}

// MARK: - Units

internal readonly record struct Angle(double Degrees)
{
    public static Angle FromRadians(double r) => new(r * 180.0 / Math.PI);
    public double Radians => Degrees * Math.PI / 180.0;
    public Angle Unwound() => new(Normalized(Degrees, 360));
    public Angle QuadrantShifted() =>
        Degrees >= -180 && Degrees <= 180 ? this : new Angle(Degrees - 360 * Math.Round(Degrees / 360, MidpointRounding.AwayFromZero));
    public static Angle operator +(Angle a, Angle b) => new(a.Degrees + b.Degrees);
    public static Angle operator -(Angle a, Angle b) => new(a.Degrees - b.Degrees);
    public static Angle operator *(Angle a, Angle b) => new(a.Degrees * b.Degrees);
    public static Angle operator /(Angle a, Angle b) => new(a.Degrees / b.Degrees);
    public static Angle operator *(Angle a, double b) => new(a.Degrees * b);
    public static Angle operator /(Angle a, double b) => new(a.Degrees / b);

    /// <summary>Double.normalizedToScale.</summary>
    public static double Normalized(double v, double max) => v - max * Math.Floor(v / max);
}

// MARK: - Astronomy

internal static class Astronomical
{
    public static Angle MeanSolarLongitude(double T) => new Angle(280.4664567 + 36000.76983 * T + 0.0003032 * Math.Pow(T, 2)).Unwound();
    public static Angle MeanLunarLongitude(double T) => new Angle(218.3165 + 481267.8813 * T).Unwound();
    public static Angle AscendingLunarNodeLongitude(double T) =>
        new Angle(125.04452 - 1934.136261 * T + 0.0020708 * Math.Pow(T, 2) + Math.Pow(T, 3) / 450000).Unwound();
    public static Angle MeanSolarAnomaly(double T) => new Angle(357.52911 + 35999.05029 * T - 0.0001537 * Math.Pow(T, 2)).Unwound();

    public static Angle SolarEquationOfTheCenter(double T, Angle M)
    {
        double m = M.Radians;
        double term1 = (1.914602 - 0.004817 * T - 0.000014 * Math.Pow(T, 2)) * Math.Sin(m);
        double term2 = (0.019993 - 0.000101 * T) * Math.Sin(2 * m);
        double term3 = 0.000289 * Math.Sin(3 * m);
        return new Angle(term1 + term2 + term3);
    }

    public static Angle ApparentSolarLongitude(double T, Angle L0)
    {
        var longitude = L0 + SolarEquationOfTheCenter(T, MeanSolarAnomaly(T));
        var omega = new Angle(125.04 - 1934.136 * T);
        return new Angle(longitude.Degrees - 0.00569 - 0.00478 * Math.Sin(omega.Radians)).Unwound();
    }

    public static Angle MeanObliquityOfTheEcliptic(double T) =>
        new(23.439291 - 0.013004167 * T - 0.0000001639 * Math.Pow(T, 2) + 0.0000005036 * Math.Pow(T, 3));

    public static Angle ApparentObliquityOfTheEcliptic(double T, Angle e0)
    {
        double O = 125.04 - 1934.136 * T;
        return new Angle(e0.Degrees + 0.00256 * Math.Cos(new Angle(O).Radians));
    }

    public static Angle MeanSiderealTime(double T)
    {
        double JD = T * 36525 + 2451545.0;
        double theta = 280.46061837 + 360.98564736629 * (JD - 2451545) + 0.000387933 * Math.Pow(T, 2) - Math.Pow(T, 3) / 38710000;
        return new Angle(theta).Unwound();
    }

    public static double NutationInLongitude(Angle L0, Angle Lp, Angle omega) =>
        (-17.2 / 3600) * Math.Sin(omega.Radians) - (1.32 / 3600) * Math.Sin(2 * L0.Radians)
        - (0.23 / 3600) * Math.Sin(2 * Lp.Radians) + (0.21 / 3600) * Math.Sin(2 * omega.Radians);

    public static double NutationInObliquity(Angle L0, Angle Lp, Angle omega) =>
        (9.2 / 3600) * Math.Cos(omega.Radians) + (0.57 / 3600) * Math.Cos(2 * L0.Radians)
        + (0.10 / 3600) * Math.Cos(2 * Lp.Radians) - (0.09 / 3600) * Math.Cos(2 * omega.Radians);

    public static Angle AltitudeOfCelestialBody(Angle phi, Angle delta, Angle H) =>
        Angle.FromRadians(Math.Asin(Math.Sin(phi.Radians) * Math.Sin(delta.Radians) + Math.Cos(phi.Radians) * Math.Cos(delta.Radians) * Math.Cos(H.Radians)));

    public static double ApproximateTransit(Angle L, Angle theta0, Angle alpha2)
    {
        var Lw = L * -1;
        double m0 = Angle.Normalized(((alpha2 + Lw - theta0) / 360).Degrees, 1);
        // Near the International Date Line m0 can land on the wrong calendar date (adhan-swift 1.5.0).
        double expected = Angle.Normalized((12.0 - L.Degrees / 15.0) / 24.0, 1);
        if (m0 - expected > 0.5) return m0 - 1.0;
        if (expected - m0 > 0.5) return m0 + 1.0;
        return m0;
    }

    public static double CorrectedTransit(double m0, Angle L, Angle theta0, Angle alpha2, Angle alpha1, Angle alpha3)
    {
        var Lw = L * -1;
        var theta = new Angle(theta0.Degrees + 360.985647 * m0).Unwound();
        var alpha = InterpolateAngles(alpha2, alpha1, alpha3, m0).Unwound();
        var H = (theta - Lw - alpha).QuadrantShifted();
        var dm = H / new Angle(-360);
        return (m0 + dm.Degrees) * 24;
    }

    public static double CorrectedHourAngle(double m0, Angle h0, Coordinates c, bool afterTransit, Angle theta0,
                                            Angle alpha2, Angle alpha1, Angle alpha3, Angle delta2, Angle delta1, Angle delta3)
    {
        var Lw = c.LongitudeAngle * new Angle(-1);
        double term1 = Math.Sin(h0.Radians) - Math.Sin(c.LatitudeAngle.Radians) * Math.Sin(delta2.Radians);
        double term2 = Math.Cos(c.LatitudeAngle.Radians) * Math.Cos(delta2.Radians);
        var H0 = Angle.FromRadians(Math.Acos(term1 / term2));
        double m = afterTransit ? m0 + H0.Degrees / 360 : m0 - H0.Degrees / 360;
        var theta = new Angle(theta0.Degrees + 360.985647 * m).Unwound();
        var alpha = InterpolateAngles(alpha2, alpha1, alpha3, m).Unwound();
        var delta = new Angle(Interpolate(delta2.Degrees, delta1.Degrees, delta3.Degrees, m));
        var H = theta - Lw - alpha;
        var h = AltitudeOfCelestialBody(c.LatitudeAngle, delta, H);
        double term3 = (h - h0).Degrees;
        double term4 = 360 * Math.Cos(delta.Radians) * Math.Cos(c.LatitudeAngle.Radians) * Math.Sin(H.Radians);
        double dm = term3 / term4;
        return (m + dm) * 24;
    }

    public static double Interpolate(double y2, double y1, double y3, double n)
    {
        double a = y2 - y1, b = y3 - y2, c = b - a;
        return y2 + (n / 2) * (a + b + n * c);
    }

    public static Angle InterpolateAngles(Angle y2, Angle y1, Angle y3, double n)
    {
        var a = (y2 - y1).Unwound();
        var b = (y3 - y2).Unwound();
        var c = b - a;
        return new Angle(y2.Degrees + (n / 2) * (a.Degrees + b.Degrees + n * c.Degrees));
    }

    public static double JulianDay(int year, int month, int day, double hours = 0)
    {
        // Casting to int truncates on purpose (as in adhan-swift).
        int Y = month > 2 ? year : year - 1;
        int M = month > 2 ? month : month + 12;
        double D = day + hours / 24;
        int A = Y / 100;
        int B = 2 - A + A / 4;
        int i0 = (int)(365.25 * (Y + 4716.0));
        int i1 = (int)(30.6001 * (M + 1.0));
        return i0 + i1 + D + B - 1524.5;
    }

    public static double JulianCentury(double JD) => (JD - 2451545.0) / 36525;

    public static bool IsLeapYear(int year) => year % 4 == 0 && !(year % 100 == 0 && year % 400 != 0);

    static double Season(double dyy, double a, double b, double c, double d)
    {
        if (dyy < 91) return a + (b - a) / 91.0 * dyy;
        if (dyy < 137) return b + (c - b) / 46.0 * (dyy - 91);
        if (dyy < 183) return c + (d - c) / 46.0 * (dyy - 137);
        if (dyy < 229) return d + (c - d) / 46.0 * (dyy - 183);
        if (dyy < 275) return c + (b - c) / 46.0 * (dyy - 229);
        return b + (a - b) / 91.0 * (dyy - 275);
    }

    public static DateTime SeasonAdjustedMorningTwilight(double latitude, int day, int year, DateTime sunrise)
    {
        double lat = Math.Abs(latitude);
        double a = 75 + 28.65 / 55.0 * lat, b = 75 + 19.44 / 55.0 * lat, c = 75 + 32.74 / 55.0 * lat, d = 75 + 48.10 / 55.0 * lat;
        double adj = Season(DaysSinceSolstice(day, year, latitude), a, b, c, d);
        return sunrise.AddSeconds(Math.Round(adj * -60.0, MidpointRounding.AwayFromZero));
    }

    public static DateTime SeasonAdjustedEveningTwilight(double latitude, int day, int year, DateTime sunset, Shafaq shafaq)
    {
        double lat = Math.Abs(latitude);
        double a, b, c, d;
        switch (shafaq)
        {
            case Shafaq.Ahmer:
                a = 62 + 17.40 / 55.0 * lat; b = 62 - 7.160 / 55.0 * lat; c = 62 + 5.120 / 55.0 * lat; d = 62 + 19.44 / 55.0 * lat; break;
            case Shafaq.Abyad:
                a = 75 + 25.60 / 55.0 * lat; b = 75 + 7.160 / 55.0 * lat; c = 75 + 36.84 / 55.0 * lat; d = 75 + 81.84 / 55.0 * lat; break;
            default:
                a = 75 + 25.60 / 55.0 * lat; b = 75 + 2.050 / 55.0 * lat; c = 75 - 9.210 / 55.0 * lat; d = 75 + 6.140 / 55.0 * lat; break;
        }
        double adj = Season(DaysSinceSolstice(day, year, latitude), a, b, c, d);
        return sunset.AddSeconds(Math.Round(adj * 60.0, MidpointRounding.AwayFromZero));
    }

    public static int DaysSinceSolstice(int dayOfYear, int year, double latitude)
    {
        int northernOffset = 10;
        int southernOffset = IsLeapYear(year) ? 173 : 172;
        int daysInYear = IsLeapYear(year) ? 366 : 365;
        int d;
        if (latitude >= 0)
        {
            d = dayOfYear + northernOffset;
            if (d >= daysInYear) d -= daysInYear;
        }
        else
        {
            d = dayOfYear - southernOffset;
            if (d < 0) d += daysInYear;
        }
        return d;
    }
}

internal readonly struct SolarCoordinates
{
    public readonly Angle Declination;
    public readonly Angle RightAscension;
    public readonly Angle ApparentSiderealTime;

    public SolarCoordinates(double julianDay)
    {
        double T = Astronomical.JulianCentury(julianDay);
        var L0 = Astronomical.MeanSolarLongitude(T);
        var Lp = Astronomical.MeanLunarLongitude(T);
        var omega = Astronomical.AscendingLunarNodeLongitude(T);
        double lambda = Astronomical.ApparentSolarLongitude(T, L0).Radians;
        var theta0 = Astronomical.MeanSiderealTime(T);
        double dPsi = Astronomical.NutationInLongitude(L0, Lp, omega);
        double dEps = Astronomical.NutationInObliquity(L0, Lp, omega);
        var eps0 = Astronomical.MeanObliquityOfTheEcliptic(T);
        double epsApp = Astronomical.ApparentObliquityOfTheEcliptic(T, eps0).Radians;
        Declination = Angle.FromRadians(Math.Asin(Math.Sin(epsApp) * Math.Sin(lambda)));
        RightAscension = Angle.FromRadians(Math.Atan2(Math.Cos(epsApp) * Math.Sin(lambda), Math.Cos(lambda))).Unwound();
        ApparentSiderealTime = new Angle(theta0.Degrees + dPsi * 3600 * Math.Cos(new Angle(eps0.Degrees + dEps).Radians) / 3600);
    }
}

internal sealed class SolarTime
{
    readonly DateTime _midnight;     // the date at 0h UTC (adhan-swift: "calculations need to occur at 0h0m UTC")
    readonly Coordinates _observer;
    readonly SolarCoordinates _solar, _prev, _next;
    readonly double _approxTransit;
    public DateTime Transit { get; }
    public DateTime Sunrise { get; }
    public DateTime Sunset { get; }
    public SolarCoordinates Solar => _solar;

    SolarTime(DateTime midnight, Coordinates c, SolarCoordinates solar, SolarCoordinates prev, SolarCoordinates next, double m0,
              DateTime transit, DateTime sunrise, DateTime sunset)
    {
        _midnight = midnight; _observer = c; _solar = solar; _prev = prev; _next = next; _approxTransit = m0;
        Transit = transit; Sunrise = sunrise; Sunset = sunset;
    }

    public static SolarTime? Create(int year, int month, int day, Coordinates c)
    {
        double jd = Astronomical.JulianDay(year, month, day);
        var prev = new SolarCoordinates(jd - 1);
        var solar = new SolarCoordinates(jd);
        var next = new SolarCoordinates(jd + 1);
        double m0 = Astronomical.ApproximateTransit(c.LongitudeAngle, solar.ApparentSiderealTime, solar.RightAscension);
        var solarAltitude = new Angle(-50.0 / 60.0);
        double transitTime = Astronomical.CorrectedTransit(m0, c.LongitudeAngle, solar.ApparentSiderealTime, solar.RightAscension, prev.RightAscension, next.RightAscension);
        double sunriseTime = Astronomical.CorrectedHourAngle(m0, solarAltitude, c, false, solar.ApparentSiderealTime,
            solar.RightAscension, prev.RightAscension, next.RightAscension, solar.Declination, prev.Declination, next.Declination);
        double sunsetTime = Astronomical.CorrectedHourAngle(m0, solarAltitude, c, true, solar.ApparentSiderealTime,
            solar.RightAscension, prev.RightAscension, next.RightAscension, solar.Declination, prev.Declination, next.Declination);
        var midnight = new DateTime(year, month, day, 0, 0, 0, DateTimeKind.Utc);
        if (SettingHour(midnight, transitTime) is not { } t || SettingHour(midnight, sunriseTime) is not { } r || SettingHour(midnight, sunsetTime) is not { } s)
            return null;
        return new SolarTime(midnight, c, solar, prev, next, m0, t, r, s);
    }

    public DateTime? TimeForSolarAngle(Angle angle, bool afterTransit)
    {
        double hours = Astronomical.CorrectedHourAngle(_approxTransit, angle, _observer, afterTransit, _solar.ApparentSiderealTime,
            _solar.RightAscension, _prev.RightAscension, _next.RightAscension, _solar.Declination, _prev.Declination, _next.Declination);
        return SettingHour(_midnight, hours);
    }

    public DateTime? Afternoon(double shadowLength)
    {
        var tangent = new Angle(Math.Abs(_observer.Latitude - _solar.Declination.Degrees));
        double inverse = shadowLength + Math.Tan(tangent.Radians);
        var angle = Angle.FromRadians(Math.Atan(1.0 / inverse));
        return TimeForSolarAngle(angle, true);
    }

    /// <summary>DateComponents.settingHour + Calendar.date(from:): whole hours, minutes and seconds
    /// (each floored) added to the day's 0h UTC. Not a normal number (NaN, ∞, 0) → null.</summary>
    internal static DateTime? SettingHour(DateTime midnight, double value)
    {
        if (!double.IsNormal(value)) return null;
        double h = Math.Floor(value);
        double m = Math.Floor((value - h) * 60);
        double s = Math.Floor((value - (h + m / 60)) * 60 * 60);
        return midnight.AddSeconds(h * 3600 + m * 60 + s);
    }
}

internal sealed class PrayerTimes
{
    public DateTime Fajr { get; }
    public DateTime Sunrise { get; }
    public DateTime Dhuhr { get; }
    public DateTime Asr { get; }
    public DateTime Maghrib { get; }
    public DateTime Isha { get; }

    PrayerTimes(DateTime f, DateTime r, DateTime d, DateTime a, DateTime m, DateTime i) { Fajr = f; Sunrise = r; Dhuhr = d; Asr = a; Maghrib = m; Isha = i; }

    /// <summary>PrayerTimes.init?(coordinates:date:calculationParameters:). null = the library gave up.</summary>
    public static PrayerTimes? Create(Coordinates c, int year, int month, int day, CalculationParameters p)
    {
        DateTime prayerDate;
        try { prayerDate = new DateTime(year, month, day, 0, 0, 0, DateTimeKind.Utc); } catch (ArgumentOutOfRangeException) { return null; }
        var tomorrowDate = prayerDate.AddDays(1);
        int dayOfYear = prayerDate.DayOfYear;

        if (SolarTime.Create(year, month, day, c) is not { } solar
            || SolarTime.Create(tomorrowDate.Year, tomorrowDate.Month, tomorrowDate.Day, c) is not { } tomorrowSolar) return null;
        var sunriseDate = solar.Sunrise;
        var sunsetDate = solar.Sunset;
        var tomorrowSunrise = tomorrowSolar.Sunrise;

        DateTime? tempSunrise = solar.Sunrise, tempMaghrib = solar.Sunset, tempDhuhr = solar.Transit;
        DateTime? tempAsr = solar.Afternoon((double)p.Madhab);

        // night length
        double night = (tomorrowSunrise - sunsetDate).TotalSeconds;

        DateTime? tempFajr = solar.TimeForSolarAngle(new Angle(-p.FajrAngle), afterTransit: false);
        // special case for moonsighting committee above latitude 55
        if (p.Method == CalculationMethod.MoonsightingCommittee && c.Latitude >= 55) tempFajr = sunriseDate.AddSeconds(-(night / 7));

        DateTime safeFajr = p.Method == CalculationMethod.MoonsightingCommittee
            ? Astronomical.SeasonAdjustedMorningTwilight(c.Latitude, dayOfYear, year, sunriseDate)
            : sunriseDate.AddSeconds(-(p.NightPortions(c).Fajr * night));
        if (tempFajr == null || tempFajr.Value < safeFajr) tempFajr = safeFajr;

        DateTime? tempIsha = null;
        if (p.IshaInterval > 0)
        {
            tempIsha = tempMaghrib?.AddSeconds(p.IshaInterval * 60);
        }
        else
        {
            tempIsha = solar.TimeForSolarAngle(new Angle(-p.IshaAngle), afterTransit: true);
            if (p.Method == CalculationMethod.MoonsightingCommittee && c.Latitude >= 55) tempIsha = sunsetDate.AddSeconds(night / 7);
            DateTime safeIsha = p.Method == CalculationMethod.MoonsightingCommittee
                ? Astronomical.SeasonAdjustedEveningTwilight(c.Latitude, dayOfYear, year, sunsetDate, p.Shafaq)
                : sunsetDate.AddSeconds(p.NightPortions(c).Isha * night);
            if (tempIsha == null || tempIsha.Value > safeIsha) tempIsha = safeIsha;
        }

        // Maghrib with a check against the safe value: between sunset and Isha.
        if (p.MaghribAngle is { } ma && solar.TimeForSolarAngle(new Angle(-ma), afterTransit: true) is { } maghribDate
            && sunsetDate < maghribDate && (tempIsha == null || tempIsha.Value > maghribDate))
            tempMaghrib = maghribDate;

        if (tempFajr is not { } fajr || tempSunrise is not { } sunrise || tempDhuhr is not { } dhuhr || tempAsr is not { } asr
            || tempMaghrib is not { } maghrib || tempIsha is not { } isha) return null;

        DateTime Final(DateTime t, int adj, int methodAdj) => RoundedMinute(t.AddSeconds(adj * 60).AddSeconds(methodAdj * 60), p.Rounding);
        return new PrayerTimes(
            Final(fajr, p.Adjustments.Fajr, p.MethodAdjustments.Fajr),
            Final(sunrise, p.Adjustments.Sunrise, p.MethodAdjustments.Sunrise),
            Final(dhuhr, p.Adjustments.Dhuhr, p.MethodAdjustments.Dhuhr),
            Final(asr, p.Adjustments.Asr, p.MethodAdjustments.Asr),
            Final(maghrib, p.Adjustments.Maghrib, p.MethodAdjustments.Maghrib),
            Final(isha, p.Adjustments.Isha, p.MethodAdjustments.Isha));
    }

    /// <summary>Date.roundedMinute(rounding:): Calendar components drop the fraction of a second, then
    /// nearest = minute + round(second/60) (half away from zero), up = ceil, none = keep the second.</summary>
    internal static DateTime RoundedMinute(DateTime t, Rounding rounding)
    {
        var whole = new DateTime(t.Ticks - (t.Ticks % TimeSpan.TicksPerSecond), DateTimeKind.Utc);
        int second = whole.Second;
        var minuteStart = whole.AddSeconds(-second);
        return rounding switch
        {
            Rounding.Nearest => minuteStart.AddMinutes(Math.Round(second / 60.0, MidpointRounding.AwayFromZero)),
            Rounding.Up => minuteStart.AddMinutes(Math.Ceiling(second / 60.0)),
            _ => whole,
        };
    }
}
