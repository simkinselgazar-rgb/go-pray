# Prayer math: a port of adhan-swift 1.5.0, not the Adhan NuGet

PLAN.md §2 said: use NuGet `Adhan` 0.9.0 if it is MIT, else port adhan-swift, and require minute
parity with the Mac either way. 0.9.0 is MIT (spike Q7), but it does not reach parity:

| Case (fixtures/mac-times.json) | Adhan 0.9.0 vs the Mac |
|---|---|
| Washington DC, northAmerica, Hanafi, 3 dates | exact |
| Cairo, egyptian, 2026-01-15 | Fajr −3, Isha +2 min |
| Cairo, egyptian, 2026-03-08 | Fajr −2, Isha +2 min |
| Cairo, egyptian, 2026-06-21 | Fajr −3, Isha +3 min |
| Oslo, MWL, middleOfTheNight, 3 dates | exact |

Why: 0.9.0 (2019) is a port of the older Java algorithm. Egyptian is 20°/18° there and 19.5°/17.5°
in adhan-swift. It also has no `tehran`/`turkey` methods (both are in our Settings), no Maghrib
angle, no rounding modes (Singapore rounds up), no Shafaq, and no `recommended(for:)` high-latitude
rule (our `highLatitudeRule: null`). It takes the night length from today's sunrise + 24 h instead
of tomorrow's sunrise.

So `src/GoPray.Core/Adhan/AdhanSwift.cs` is a line-for-line C# port of adhan-swift 1.5.0 (MIT,
© 2016 Batoul Apps, notice kept in the file). It covers only `PrayerTimes` and its astronomy.
Swift's rounding (`round` = half away from zero) and `DateComponents.settingHour` / `Calendar`
whole-second behaviour are reproduced on purpose.

Result: `macParityToTheMinute`, 9 cases × 6 times, exact. All the Mac's published-timetable tests
pass with the Mac's own tolerances: Cairo/aladhan ±1, Raleigh and Oslo/moonsighting.com 0,
Toronto ±2, Edinburgh 0.

Credits: the app's Credits screen already names adhan-swift (MIT). The Windows Credits keep that line.
