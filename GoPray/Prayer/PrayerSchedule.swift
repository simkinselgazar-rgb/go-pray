// PrayerSchedule.swift — adhan-swift behind `PrayerScheduleProviding` (§C, lane A).
// Pure local math: no network, no clock of its own. Reads the current settings
// through a closure, so a settings change is picked up on the next call.
//
// "No valid schedule" is always `nil`, never a made-up time (CONTRACT-NOTES #1):
// setup not finished, bad place, unknown method, or the library gave up for that
// day (extreme latitudes). The gate then never blocks (§G).
//
// A day is the calendar day in the system time zone (`calendar()`), turned into
// year/month/day for the library. Results are absolute `Date`s, so a time zone
// change moves no instant (E.6). Inside our module `Prayer` is ours; the library's
// is `Adhan.Prayer` (CONTRACT-NOTES #4) and is never used here.

import Adhan
import Foundation

@MainActor final class PrayerSchedule: PrayerScheduleProviding {
    private struct DayKey: Hashable {
        let year, month, day: Int
        let latitude, longitude: Double
        let method: String
        let madhab: Int
        let rule: String
    }

    private struct Athan {
        let prayer: Prayer
        let at: Date
        let sunrise: Date
    }

    private let settings: @MainActor () -> Settings
    private let calendar: @MainActor () -> Calendar
    /// Negative results are cached too (`Optional` value), so a failing day is computed once.
    private var cache: [DayKey: DayTimes?] = [:]

    init(settings: @escaping @MainActor () -> Settings,
         calendar: @escaping @MainActor () -> Calendar = { Calendar.autoupdatingCurrent }) {
        self.settings = settings
        self.calendar = calendar
    }

    // MARK: PrayerScheduleProviding

    func times(on day: Date) -> DayTimes? {
        guard let s = usableSettings() else { return nil }
        return dayTimes(for: day, offsetDays: 0, settings: s)
    }

    func window(containing t: Date) -> PrayerWindow? {
        guard let list = athans(around: t) else { return nil }
        // The last Athan at or before t, then its end: the next Athan, or sunrise for Fajr.
        guard let i = list.lastIndex(where: { $0.at <= t }), i + 1 < list.count else { return nil }
        let a = list[i]
        let next = list[i + 1].at
        let end = a.prayer == .fajr ? min(a.sunrise, next) : next
        return PrayerWindow(prayer: a.prayer, athan: a.at, end: max(end, a.at))
    }

    func nextAthan(after t: Date) -> (prayer: Prayer, at: Date)? {
        guard let list = athans(around: t), let n = list.first(where: { $0.at > t }) else { return nil }
        return (prayer: n.prayer, at: n.at)
    }

    // MARK: Internals

    /// Settings that can make a schedule at all; nil otherwise.
    private func usableSettings() -> Settings? {
        let s = settings()
        guard s.setupComplete, s.calculationParameters() != nil else { return nil }
        return s
    }

    private func dayTimes(for date: Date, offsetDays: Int, settings s: Settings) -> DayTimes? {
        let cal = calendar()
        guard let start = cal.date(byAdding: .day, value: offsetDays, to: cal.startOfDay(for: date)) else { return nil }
        let c = cal.dateComponents([.year, .month, .day], from: start)
        guard let y = c.year, let m = c.month, let d = c.day else { return nil }
        let key = DayKey(year: y, month: m, day: d, latitude: s.latitude, longitude: s.longitude,
                         method: s.method, madhab: s.madhab, rule: s.effectiveHighLatitudeRule.rawValue)
        if let hit = cache[key] { return hit }
        var result: DayTimes?
        if let params = s.calculationParameters(),
           let p = PrayerTimes(coordinates: s.coordinates, date: c, calculationParameters: params) {
            result = DayTimes(fajr: p.fajr, sunrise: p.sunrise, dhuhr: p.dhuhr, asr: p.asr, maghrib: p.maghrib, isha: p.isha)
        }
        if cache.count > 64 { cache.removeAll() }
        cache[key] = result
        return result
    }

    /// Every Athan of yesterday, today and tomorrow, oldest first. Yesterday's Isha can
    /// fall after midnight, and today's Isha ends at tomorrow's Fajr. nil if any of the
    /// three days has no schedule: one rule, and it errs toward "never block".
    private func athans(around t: Date) -> [Athan]? {
        guard let s = usableSettings() else { return nil }
        var all: [Athan] = []
        for off in -1...1 {
            guard let d = dayTimes(for: t, offsetDays: off, settings: s) else { return nil }
            for (prayer, at) in d.prayers { all.append(Athan(prayer: prayer, at: at, sunrise: d.sunrise)) }
        }
        let order = Prayer.allCases
        return all.sorted { ($0.at, order.firstIndex(of: $0.prayer)!) < ($1.at, order.firstIndex(of: $1.prayer)!) }
    }
}
