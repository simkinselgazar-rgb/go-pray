// SchedulerTests.swift — §E PM test 6 + scheduler arming rules. Owner: PM.
// fire() is called directly; no test waits for a real timer.

import AppKit
import Foundation
import Testing
@testable import GoPray

@MainActor @Suite("Scheduler")
struct SchedulerTests {
    final class TZ { var zone = TimeZone(identifier: "UTC")! }

    func make(_ h: Harness, tz: TZ = TZ()) -> Scheduler {
        Scheduler(clock: h.clock, schedule: h.schedule, gate: h.gate, settings: { [unowned h] in h.settings },
                  calendar: { var c = Calendar(identifier: .gregorian); c.timeZone = tz.zone; return c })
    }

    @Test func armsTheNextAthanAndFiresIntoTheGate() {
        let asr = FakeSchedule.at(.asr)
        let h = Harness(at: asr.addingTimeInterval(-3600)); defer { h.cleanup() }
        let s = make(h)
        s.rearm()
        #expect(s.armed == .init(kind: .athan(.asr), at: asr))

        h.clock.now = asr
        s.fire()
        #expect(h.gate.currentBlock?.prayer == .asr)
        #expect(s.armed == .init(kind: .athan(.maghrib), at: FakeSchedule.at(.maghrib)))
        s.stop()
    }

    @Test func timeZoneChangeKeepsTheSameInstant() {
        let asr = FakeSchedule.at(.asr)
        let h = Harness(at: asr.addingTimeInterval(-5400)); defer { h.cleanup() }
        let tz = TZ()
        let s = make(h, tz: tz)
        s.rearm()
        let before = s.armed
        #expect(before == .init(kind: .athan(.asr), at: asr))
        tz.zone = TimeZone(identifier: "America/Los_Angeles")!
        s.handle(.timeZoneChanged)
        #expect(s.armed == before)
        #expect(h.schedule.times(on: asr)?.asr == asr)   // absolute Dates, unchanged
        s.stop()
    }

    @Test func armsMidnightWhenTheNextAthanIsTomorrow() {
        let isha = FakeSchedule.at(.isha)
        let h = Harness(at: isha.addingTimeInterval(60)); defer { h.cleanup() }
        let s = make(h)
        s.rearm()
        #expect(s.armed == .init(kind: .midnight, at: FakeSchedule.day0.addingTimeInterval(86_400)))
        h.clock.now = FakeSchedule.day0.addingTimeInterval(86_400)
        s.fire()
        #expect(s.armed == .init(kind: .athan(.fajr), at: FakeSchedule.at(.fajr, day: 1)))
        s.stop()
    }

    @Test func notArmedWhenSetupIncomplete() {
        let h = Harness(at: FakeSchedule.at(.dhuhr), settings: .test(setupComplete: false)); defer { h.cleanup() }
        let s = make(h)
        s.rearm()
        #expect(s.armed == nil)
        s.fire()                                          // nothing armed: no-op
        #expect(h.gate.phase == .idle)
    }

    @Test func noScheduleArmsOnlyMidnight() {
        let h = Harness(at: FakeSchedule.at(.dhuhr)); defer { h.cleanup() }
        h.schedule.valid = false
        let s = make(h)
        s.rearm()
        #expect(s.armed?.kind == .midnight)
        h.clock.now = s.armed!.at
        s.fire()
        #expect(h.gate.phase == .idle)
        s.stop()
    }

    @Test func settingsChangeReevaluatesAndRearms() {
        let asr = FakeSchedule.at(.asr)
        let h = Harness(at: asr.addingTimeInterval(120), settings: .test(setupComplete: false)); defer { h.cleanup() }
        let s = make(h)
        s.rearm()
        #expect(s.armed == nil)
        h.settings = .test(setupComplete: true)
        s.handle(.settingsChanged)
        #expect(s.armed == .init(kind: .athan(.maghrib), at: FakeSchedule.at(.maghrib)))
        #expect(h.gate.phase == .idle)                     // first setup never blocks the open window (PM ruling a)
        s.stop()
    }

    @Test func stopCancelsTheTimer() {
        let h = Harness(at: FakeSchedule.at(.dhuhr)); defer { h.cleanup() }
        let s = make(h)
        s.start()
        #expect(s.armed != nil)
        s.stop()
        #expect(s.armed == nil)
    }
}

@MainActor @Suite("Test host")
struct TestHostTests {
    /// The hosted test run must never wire the live app (real state.json, timers).
    @Test func liveEnvironmentIsNotStartedUnderTests() {
        #expect(AppEnvironment.liveStarted == false)
    }
}
