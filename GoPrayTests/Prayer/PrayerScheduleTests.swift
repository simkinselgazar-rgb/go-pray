// PrayerScheduleTests.swift — lane A. The schedule against published timetables,
// the window edges of Architecture Plan §E (lane A), DST days, high latitudes, and
// "bad input → nil, never a made-up time".

import Adhan
import Foundation
import Testing
@testable import GoPray

@MainActor @Suite("Prayer schedule")
struct PrayerScheduleTests {
    // MARK: helpers

    func calendar(_ zone: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        return c
    }

    func settings(lat: Double, lon: Double, method: CalculationMethod, madhab: Madhab = .shafi,
                  rule: HighLatitudeRule? = nil) -> Settings {
        var s = Settings.test()
        s.latitude = lat; s.longitude = lon
        s.method = method.rawValue; s.madhab = madhab.rawValue
        s.highLatitudeRule = rule?.rawValue
        return s
    }

    func schedule(_ s: @autoclosure @escaping () -> Settings, zone: String) -> PrayerSchedule {
        let cal = calendar(zone)
        return PrayerSchedule(settings: { s() }, calendar: { cal })
    }

    func local(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0, zone: String) -> Date {
        calendar(zone).date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    /// Minutes since local midnight, as the timetable shows them.
    func minutes(_ date: Date, zone: String) -> Int {
        let c = calendar(zone).dateComponents([.hour, .minute], from: date)
        return c.hour! * 60 + c.minute!
    }

    func hm(_ text: String) -> Int {
        let p = text.split(separator: ":").map { Int($0)! }
        return p[0] * 60 + p[1]
    }

    /// Compare all six times with a timetable written as "HH:mm" strings.
    func expectTimes(_ t: DayTimes?, _ ref: [String], zone: String, within tolerance: Int,
                     _ note: Comment, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let t else { Issue.record("no schedule: \(note)", sourceLocation: sourceLocation); return }
        let got = [t.fajr, t.sunrise, t.dhuhr, t.asr, t.maghrib, t.isha].map { minutes($0, zone: zone) }
        for (i, name) in ["Fajr", "Sunrise", "Dhuhr", "Asr", "Maghrib", "Isha"].enumerated() {
            let diff = abs(got[i] - hm(ref[i]))
            #expect(diff <= tolerance, "\(note) \(name): got \(got[i] / 60):\(got[i] % 60), want \(ref[i]) ±\(tolerance)",
                    sourceLocation: sourceLocation)
        }
    }

    // MARK: known cities and dates

    /// Cairo, 2020-01-01, Egyptian General Authority. Reference: api.aladhan.com
    /// (method 5), fetched 2026-10-22: 05:18 06:51 11:58 14:47 17:06 18:29. adhan-swift's own
    /// test gives 11:59 for Dhuhr; the one minute is rounding of the solar noon.
    @Test func cairoEgyptianMatchesAladhan() {
        let s = settings(lat: 30.028703, lon: 31.249528, method: .egyptian)
        let p = schedule(s, zone: "Africa/Cairo")
        expectTimes(p.times(on: local(2020, 1, 1, zone: "Africa/Cairo")),
                    ["05:18", "06:51", "11:58", "14:47", "17:06", "18:29"],
                    zone: "Africa/Cairo", within: 1, "Cairo 2020-01-01 Egyptian")
    }

    /// Raleigh NC, 2016-01-31, Moonsighting Committee. Reference: moonsighting.com/pray.php
    /// (the published page, quoted in adhan-swift's tests): 5:48 AM 7:16 AM 12:33 PM 3:20 PM 5:43 PM 7:05 PM.
    /// Isha is 00:05 UTC the next day: this also checks the day is the local one.
    @Test func raleighMoonsightingMatchesMoonsightingDotCom() {
        let s = settings(lat: 35.7750, lon: -78.6336, method: .moonsightingCommittee)
        let p = schedule(s, zone: "America/New_York")
        expectTimes(p.times(on: local(2016, 1, 31, zone: "America/New_York")),
                    ["05:48", "07:16", "12:33", "15:20", "17:43", "19:05"],
                    zone: "America/New_York", within: 0, "Raleigh 2016-01-31 Moonsighting")
    }

    /// Toronto, 2026-10-22, ISNA. Reference: api.aladhan.com (method 2), fetched 2026-10-22:
    /// 06:21 07:41 13:02 15:56 18:23 19:42. Today's date on purpose: a timetable that is still true.
    /// Five times match to the minute; Asr is 15:54 here vs 15:56 there (two calculators, two
    /// shadow-length roundings), so the tolerance is 2 minutes, stated rather than hidden.
    @Test func torontoIsnaMatchesAladhan() {
        let s = settings(lat: 43.6532, lon: -79.3832, method: .northAmerica)
        let p = schedule(s, zone: "America/Toronto")
        expectTimes(p.times(on: local(2026, 10, 22, zone: "America/Toronto")),
                    ["06:21", "07:41", "13:02", "15:56", "18:23", "19:42"],
                    zone: "America/Toronto", within: 2, "Toronto 2026-10-22 ISNA")
    }

    // MARK: high latitude

    /// Oslo (59.9° N), 2016-01-01, Moonsighting, Hanafi. Reference: moonsighting.com/pray.php
    /// (in adhan-swift's tests): 7:34 AM 9:19 AM 12:25 PM 1:36 PM 3:25 PM 5:02 PM.
    @Test func osloHighLatitudeMatchesMoonsightingDotCom() {
        let s = settings(lat: 59.9094, lon: 10.7349, method: .moonsightingCommittee, madhab: .hanafi)
        let p = schedule(s, zone: "Europe/Oslo")
        expectTimes(p.times(on: local(2016, 1, 1, zone: "Europe/Oslo")),
                    ["07:34", "09:19", "12:25", "13:36", "15:25", "17:02"],
                    zone: "Europe/Oslo", within: 0, "Oslo 2016-01-01 Moonsighting Hanafi")
    }

    /// Edinburgh (56° N), 2020-06-15, MWL: the rule changes Fajr and Isha, nothing else.
    /// adhan-swift's reference: seventh of the night → Fajr 3:31 AM, Isha 10:56 PM.
    /// With no rule saved, above 48° the library picks "seventh of the night".
    @Test func highLatitudeRuleIsApplied() {
        var s = settings(lat: 55.983226, lon: -3.216649, method: .muslimWorldLeague, rule: .seventhOfTheNight)
        let day = local(2020, 6, 15, zone: "Europe/London")
        let seventh = schedule(s, zone: "Europe/London").times(on: day)
        expectTimes(seventh, ["03:31", "04:26", "13:14", "17:46", "22:01", "22:56"],
                    zone: "Europe/London", within: 0, "Edinburgh seventh")

        s.highLatitudeRule = nil
        let auto = schedule(s, zone: "Europe/London").times(on: day)
        #expect(auto?.fajr == seventh?.fajr && auto?.isha == seventh?.isha)
        #expect(s.effectiveHighLatitudeRule == .seventhOfTheNight)

        s.highLatitudeRule = HighLatitudeRule.middleOfTheNight.rawValue
        let middle = schedule(s, zone: "Europe/London").times(on: day)
        #expect(middle?.fajr != seventh?.fajr)
        #expect(middle?.dhuhr == seventh?.dhuhr)
        #expect(settings(lat: 40, lon: -74, method: .northAmerica).effectiveHighLatitudeRule == .middleOfTheNight)
    }

    /// Edinburgh in June squeezes Isha and the next Fajr together. Windows must never
    /// overlap or run backwards, and the schedule keeps answering.
    @Test func midsummerWindowsNeverOverlap() {
        let s = settings(lat: 55.983226, lon: -3.216649, method: .muslimWorldLeague, rule: .middleOfTheNight)
        let p = schedule(s, zone: "Europe/London")
        var t = local(2020, 6, 15, 0, 0, zone: "Europe/London")
        var last: PrayerWindow?
        for _ in 0..<(24 * 6) {
            if let w = p.window(containing: t) {
                #expect(w.end >= w.athan)
                if let last, last.athan != w.athan { #expect(w.athan >= last.athan) }
                last = w
            } else { Issue.record("no window at \(t)") }
            t = t.addingTimeInterval(600)
        }
    }

    /// Utqiagvik (71.3° N) on 2018-01-01: polar night, the library returns nothing.
    /// We return nil for all three questions. Never a guessed time.
    @Test func polarNightGivesNoSchedule() {
        let s = settings(lat: 71.275009, lon: -156.761368, method: .muslimWorldLeague)
        let p = schedule(s, zone: "America/Anchorage")
        let noon = local(2018, 1, 1, zone: "America/Anchorage")
        #expect(p.times(on: noon) == nil)
        #expect(p.window(containing: noon) == nil)
        #expect(p.nextAthan(after: noon) == nil)
    }

    // MARK: bad input → nil

    @Test func badInputGivesNilNeverAMadeUpTime() {
        let day = local(2026, 10, 22, zone: "America/Toronto")
        var cases: [(String, Settings)] = []
        func bad(_ name: String, _ edit: (inout Settings) -> Void) {
            var s = settings(lat: 43.65, lon: -79.38, method: .northAmerica); edit(&s); cases.append((name, s))
        }
        bad("latitude 999") { $0.latitude = 999 }
        bad("longitude 999") { $0.longitude = 999 }
        bad("NaN latitude") { $0.latitude = .nan }
        bad("infinite longitude") { $0.longitude = .infinity }
        bad("unknown method") { $0.method = "bogus" }
        bad("custom method") { $0.method = CalculationMethod.other.rawValue }
        bad("unknown madhab") { $0.madhab = 3 }
        bad("unknown high-latitude rule") { $0.highLatitudeRule = "nonsense" }
        bad("setup not complete") { $0.setupComplete = false }
        for (name, s) in cases {
            let p = schedule(s, zone: "America/Toronto")
            #expect(p.times(on: day) == nil, "\(name): times")
            #expect(p.window(containing: day) == nil, "\(name): window")
            #expect(p.nextAthan(after: day) == nil, "\(name): nextAthan")
        }
        #expect(Settings.defaults.setupComplete == false)
        let fresh = schedule(Settings.defaults, zone: "America/Toronto")
        #expect(fresh.times(on: day) == nil)
    }

    // MARK: window edges (Raleigh, 2016-01-31, EST)

    let ny = "America/New_York"

    func raleigh() -> (PrayerSchedule, DayTimes, DayTimes, DayTimes) {
        let s = settings(lat: 35.7750, lon: -78.6336, method: .moonsightingCommittee)
        let p = schedule(s, zone: ny)
        return (p, p.times(on: local(2016, 1, 30, zone: ny))!, p.times(on: local(2016, 1, 31, zone: ny))!,
                p.times(on: local(2016, 2, 1, zone: ny))!)
    }

    @Test func windowExactlyAtAnAthanIsThatPrayer() {
        let (p, _, today, _) = raleigh()
        for (prayer, at) in today.prayers {
            let w = p.window(containing: at)
            #expect(w?.prayer == prayer)
            #expect(w?.athan == at)
        }
        #expect(p.window(containing: today.asr)?.end == today.maghrib)
        #expect(p.window(containing: today.dhuhr)?.end == today.asr)
    }

    @Test func oneSecondBeforeAnAthanIsThePreviousWindow() {
        let (p, _, today, _) = raleigh()
        let w = p.window(containing: today.asr.addingTimeInterval(-1))
        #expect(w?.prayer == .dhuhr)
        #expect(w?.end == today.asr)
    }

    @Test func oneSecondBeforeFajrIsYesterdaysIsha() {
        let (p, yesterday, today, _) = raleigh()
        let w = p.window(containing: today.fajr.addingTimeInterval(-1))
        #expect(w?.prayer == .isha)
        #expect(w?.athan == yesterday.isha)
        #expect(w?.end == today.fajr)
    }

    @Test func betweenIshaAndMidnightIshaIsOpen() {
        let (p, _, today, tomorrow) = raleigh()
        let t = local(2016, 1, 31, 23, 30, zone: ny)
        #expect(t > today.isha)
        let w = p.window(containing: t)
        #expect(w?.prayer == .isha)
        #expect(w?.athan == today.isha)
        #expect(w?.end == tomorrow.fajr)
    }

    @Test func afterMidnightBeforeFajrYesterdaysIshaIsStillOpen() {
        let (p, yesterday, today, _) = raleigh()
        let t = local(2016, 1, 31, 0, 30, zone: ny)
        let w = p.window(containing: t)
        #expect(w?.prayer == .isha)
        #expect(w?.athan == yesterday.isha)
        #expect(w?.athan ?? .distantFuture < t)
        #expect(w?.end == today.fajr)
        #expect((w?.end ?? .distantPast) > t)
    }

    @Test func fajrWindowEndsAtSunriseNotAtDhuhr() {
        let (p, _, today, _) = raleigh()
        #expect(p.window(containing: today.fajr)?.end == today.sunrise)
        // One second after sunrise the Fajr window is closed: end is not after t. The gate
        // reads that as "no block". It is the missed-Fajr case (E.3).
        let w = p.window(containing: today.sunrise.addingTimeInterval(1))
        #expect(w?.prayer == .fajr)
        #expect((w?.end ?? .distantFuture) <= today.sunrise.addingTimeInterval(1))
    }

    @Test func nextAthanIsStrictlyAfter() {
        let (p, _, today, tomorrow) = raleigh()
        let n = p.nextAthan(after: today.fajr)
        #expect(n?.prayer == .dhuhr && n?.at == today.dhuhr)
        // At the Athan itself the next one is the following prayer.
        #expect(p.nextAthan(after: today.asr.addingTimeInterval(-1))?.prayer == .asr)
        #expect(p.nextAthan(after: today.asr)?.prayer == .maghrib)
        // After Isha: tomorrow's Fajr.
        let after = p.nextAthan(after: today.isha)
        #expect(after?.prayer == .fajr && after?.at == tomorrow.fajr)
        // After midnight, before Fajr: today's Fajr.
        let early = p.nextAthan(after: local(2016, 2, 1, 0, 10, zone: ny))
        #expect(early?.prayer == .fajr && early?.at == tomorrow.fajr)
    }

    @Test func fivePrayersAreInOrderEveryDayOfAYear() {
        let s = settings(lat: 43.6532, lon: -79.3832, method: .northAmerica)
        let p = schedule(s, zone: "America/Toronto")
        var day = local(2026, 1, 1, zone: "America/Toronto")
        for _ in 0..<365 {
            guard let t = p.times(on: day) else { Issue.record("no schedule on \(day)"); return }
            let all = [t.fajr, t.sunrise, t.dhuhr, t.asr, t.maghrib, t.isha]
            #expect(all == all.sorted(), "out of order on \(day)")
            day = calendar("America/Toronto").date(byAdding: .day, value: 1, to: day)!
        }
    }

    // MARK: DST

    /// Spring forward: America/New_York, 2026-03-08 (a 23-hour day). The day's times match the
    /// library for that calendar date, and the windows around the missing hour are right.
    @Test func springForwardDay() {
        let s = settings(lat: 40.7128, lon: -74.0060, method: .northAmerica)
        let p = schedule(s, zone: ny)
        let day = local(2026, 3, 8, zone: ny)
        let t = p.times(on: day)!
        let direct = PrayerTimes(coordinates: s.coordinates, date: DateComponents(year: 2026, month: 3, day: 8),
                                 calculationParameters: s.calculationParameters()!)!
        #expect(t.fajr == direct.fajr && t.isha == direct.isha && t.dhuhr == direct.dhuhr)
        // Wall clock: Dhuhr is after 12:00 EDT, Fajr is in EDT (UTC-4) after the 2 AM jump.
        #expect(calendar(ny).timeZone.isDaylightSavingTime(for: t.dhuhr))
        // 03:30 EDT is 1.5 h after the jump; yesterday's Isha is still the open window.
        let after = local(2026, 3, 8, 3, 30, zone: ny)
        let w = p.window(containing: after)
        #expect(w?.prayer == .isha)
        #expect(w?.end == t.fajr)
        #expect(t.dhuhr.timeIntervalSince(t.fajr) > 0)
    }

    /// Fall back: America/New_York, 2026-11-01 (a 25-hour day). Still five prayers, in order, and
    /// the Athan after Isha is the next day's Fajr.
    @Test func fallBackDay() {
        let s = settings(lat: 40.7128, lon: -74.0060, method: .northAmerica)
        let p = schedule(s, zone: ny)
        let t = p.times(on: local(2026, 11, 1, zone: ny))!
        let all = [t.fajr, t.sunrise, t.dhuhr, t.asr, t.maghrib, t.isha]
        #expect(all == all.sorted())
        let n = p.nextAthan(after: t.isha)
        #expect(n?.prayer == .fajr)
        let next = p.times(on: local(2026, 11, 2, zone: ny))!
        #expect(n?.at == next.fajr)
        // The repeated 1:30 AM (the second one, EST) is still inside yesterday's Isha window.
        let repeated = Date(timeIntervalSince1970: local(2026, 11, 1, 0, 0, zone: ny).timeIntervalSince1970 + 2.5 * 3600)
        #expect(p.window(containing: repeated)?.prayer == .isha)
    }

    // MARK: settings changes and time zones

    @Test func settingsChangeIsPickedUpAtOnce() {
        var s = settings(lat: 43.6532, lon: -79.3832, method: .northAmerica)
        let cal = calendar("America/Toronto")
        let p = PrayerSchedule(settings: { s }, calendar: { cal })
        let day = local(2026, 10, 22, zone: "America/Toronto")
        let isna = p.times(on: day)!
        s.method = CalculationMethod.egyptian.rawValue
        let egyptian = p.times(on: day)!
        #expect(egyptian.fajr != isna.fajr)          // 19.5° vs 15°
        s.madhab = Madhab.hanafi.rawValue
        #expect(p.times(on: day)!.asr > egyptian.asr)
        s.latitude = 999
        #expect(p.times(on: day) == nil)
    }

    @Test func timeZoneChangeMovesNoInstant() {
        var zone = "America/Toronto"
        let s = settings(lat: 43.6532, lon: -79.3832, method: .northAmerica)
        let p = PrayerSchedule(settings: { s }, calendar: { Calendar(identifier: .gregorian).with(zone: zone) })
        let t = local(2026, 10, 22, 12, zone: "America/Toronto")
        let a = p.nextAthan(after: t)
        zone = "Europe/Paris"
        // Same absolute instant, now read in Paris: still the same Athan (Asr, 15:56 Toronto).
        let b = p.nextAthan(after: t)
        #expect(a?.prayer == b?.prayer)
        #expect(a?.at == b?.at)
    }
}

private extension Calendar {
    func with(zone: String) -> Calendar {
        var c = self
        c.timeZone = TimeZone(identifier: zone)!
        return c
    }
}
