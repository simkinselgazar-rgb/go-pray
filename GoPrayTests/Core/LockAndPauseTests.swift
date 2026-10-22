// LockAndPauseTests.swift — PM amendment 2026-10-22: lockMinutes (10–30, captured
// at block start) and pause (1 day / 3 days / 1 week / until resumed), plus the
// rulings "first setup and resume never block the open window". Owner: PM.

import Foundation
import Testing
@testable import GoPray

@MainActor @Suite("Lock length + pause")
struct LockAndPauseTests {
    let asr = FakeSchedule.at(.asr)
    let maghrib = FakeSchedule.at(.maghrib)

    func makeScheduler(_ h: Harness) -> Scheduler {
        Scheduler(clock: h.clock, schedule: h.schedule, gate: h.gate, settings: { [unowned h] in h.settings },
                  calendar: { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c })
    }

    // MARK: lockMinutes

    @Test func lockPolicyClamps() {
        #expect(LockPolicy.minMinutes == 10)
        #expect(LockPolicy.maxMinutes == 30)
        #expect(LockPolicy.defaultMinutes == 10)
        #expect(LockPolicy.clamp(0) == 10)
        #expect(LockPolicy.clamp(5) == 10)
        #expect(LockPolicy.clamp(15) == 15)
        #expect(LockPolicy.clamp(45) == 30)
        #expect(LockPolicy.seconds(forMinutes: 99) == 1800)
    }

    @Test func blockUsesSettingsLockLength() throws {
        let h = Harness(at: asr, settings: .test(lockMinutes: 20)); defer { h.cleanup() }
        h.gate.athanFired(.asr, at: asr)
        #expect(h.gate.phase == .locked(until: asr.addingTimeInterval(1200)))
        #expect(h.shield.shows[0].remainingMs == 1_200_000)
        #expect(try h.diskState().block?.lockSeconds == 1200)
    }

    @Test(arguments: [(3, 600.0), (99, 1800.0)])
    func outOfRangeLockMinutesAreClamped(_ minutes: Int, _ expected: TimeInterval) throws {
        let h = Harness(at: asr, settings: .test(lockMinutes: minutes)); defer { h.cleanup() }
        h.gate.athanFired(.asr, at: asr)
        #expect(h.gate.phase == .locked(until: asr.addingTimeInterval(expected)))
    }

    @Test func capturedLockSurvivesRelaunchWithDifferentSettings() throws {
        let h = Harness(at: asr, settings: .test(lockMinutes: 20)); defer { h.cleanup() }
        h.gate.athanFired(.asr, at: asr)
        h.settings = .test(lockMinutes: 10)          // changed behind the store's back
        h.clock.now = asr.addingTimeInterval(700)
        h.relaunch()
        #expect(h.gate.phase == .locked(until: asr.addingTimeInterval(1200)))
        #expect(h.gate.requestConfirm() == false)
        h.clock.now = asr.addingTimeInterval(1200)
        #expect(h.gate.requestConfirm())
    }

    @Test func lockMinutesChangeMidBlockIsRefusedAndNeverMovesTheLock() throws {
        let h = Harness(at: asr, settings: .test(lockMinutes: 30)); defer { h.cleanup() }
        h.gate.athanFired(.asr, at: asr)
        #expect(throws: SettingsError.blocked) { try h.gate.authorizeSettingsChange() }
        // Even if a change slips past the store, the running block keeps its own lock.
        h.settings = .test(lockMinutes: 10)
        h.clock.now = asr.addingTimeInterval(601)
        h.gate.reevaluate(.settingsChanged)
        #expect(h.gate.phase == .locked(until: asr.addingTimeInterval(1800)))   // not shortened
        #expect(h.gate.requestConfirm() == false)
    }

    @Test func raisingLockMidBlockDoesNotExtendIt() throws {
        let h = Harness(at: asr, settings: .test(lockMinutes: 10)); defer { h.cleanup() }
        h.gate.athanFired(.asr, at: asr)
        h.settings = .test(lockMinutes: 30)
        h.clock.now = asr.addingTimeInterval(600)
        h.gate.reevaluate(.settingsChanged)
        #expect(h.gate.phase == .canConfirm)
        #expect(h.gate.requestConfirm())
    }

    @Test func tamperedHugeLockIsCappedAtThirtyMinutes() throws {
        let h = Harness(at: asr.addingTimeInterval(1800)); defer { h.cleanup() }
        let tampered = BlockStateFile(block: .init(prayer: .asr, athanAt: asr, blockStartedAt: asr,
                                                   silenced: false, athanPlayed: true, lockSeconds: 1_000_000))
        try StateStore(directory: h.dir).save(tampered)
        h.relaunch()
        #expect(h.gate.phase == .canConfirm)
        #expect(h.gate.requestConfirm())
    }

    @Test func fileWithoutLockSecondsUsesTheDefault() throws {
        let h = Harness(at: asr.addingTimeInterval(60)); defer { h.cleanup() }
        try FileManager.default.createDirectory(at: h.dir, withIntermediateDirectories: true)
        let json = """
        {"schemaVersion": 1, "block": {"prayer": "asr", "athanAt": "2026-10-22T15:30:00Z",
         "blockStartedAt": "2026-10-22T15:30:00Z", "silenced": false, "athanPlayed": true}, "launches": []}
        """
        try Data(json.utf8).write(to: h.stateURL)
        h.relaunch()
        #expect(h.gate.phase == .locked(until: asr.addingTimeInterval(600)))
    }

    // MARK: pause

    @Test func pauseOptions() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let now = asr
        #expect(PauseOption.oneDay.until(from: now, calendar: cal) == now.addingTimeInterval(86_400))
        #expect(PauseOption.threeDays.until(from: now, calendar: cal) == now.addingTimeInterval(3 * 86_400))
        #expect(PauseOption.oneWeek.until(from: now, calendar: cal) == now.addingTimeInterval(7 * 86_400))
        #expect(PauseOption.untilResumed.until(from: now, calendar: cal) == .distantFuture)
        #expect(PauseOption.allCases.count == 4)
    }

    @Test func pauseSkipsAthansAndTheWakeRule() throws {
        let h = Harness(at: asr.addingTimeInterval(-60), settings: .test(pausedUntil: .distantFuture)); defer { h.cleanup() }
        h.clock.now = asr
        h.gate.athanFired(.asr, at: asr)
        #expect(h.gate.phase == .idle)
        h.clock.now = asr.addingTimeInterval(600)
        h.gate.reevaluate(.wake)
        h.gate.reevaluate(.launch)
        #expect(h.gate.phase == .idle)
        #expect(h.shield.shows.isEmpty)
        #expect(h.audio.plays.isEmpty)
    }

    @Test func pausedSchedulerArmsNoAthan() {
        let h = Harness(at: asr.addingTimeInterval(-3600), settings: .test(pausedUntil: .distantFuture)); defer { h.cleanup() }
        let s = makeScheduler(h)
        s.rearm()
        #expect(s.armed?.kind == .midnight)
        s.stop()
    }

    @Test func pauseExpiresThenNextAthanBlocksButNotTheOpenWindow() {
        // Pause ends at Asr + 30 min, inside Asr's window.
        let until = asr.addingTimeInterval(1800)
        let h = Harness(at: asr.addingTimeInterval(-3600), settings: .test(pausedUntil: until)); defer { h.cleanup() }
        let s = makeScheduler(h)
        s.rearm()
        #expect(s.armed == .init(kind: .pauseEnds, at: until))     // Asr is not armed
        h.clock.now = until
        s.fire()                                                   // → reevaluate(.pauseEnded)
        #expect(h.gate.phase == .idle)                             // open Asr window is not blocked
        #expect(s.armed == .init(kind: .athan(.maghrib), at: maghrib))
        h.clock.now = maghrib
        s.fire()
        #expect(h.gate.currentBlock?.prayer == .maghrib)
        s.stop()
    }

    @Test func pauseThatRanOutWhileAppWasDownDoesNotBlockTheOpenWindow() {
        let until = asr.addingTimeInterval(1800)
        let h = Harness(at: asr.addingTimeInterval(2400), settings: .test(pausedUntil: until)); defer { h.cleanup() }
        h.relaunch()                                               // relaunch after expiry, Asr still open
        #expect(h.gate.phase == .idle)
        h.clock.now = maghrib
        h.gate.athanFired(.maghrib, at: maghrib)
        #expect(h.gate.currentBlock?.prayer == .maghrib)
    }

    @Test(arguments: [true, false])
    func resumeNeverBlocksTheOpenWindow(_ resumeWithNil: Bool) {
        let h = Harness(at: asr.addingTimeInterval(-3600), settings: .test(pausedUntil: .distantFuture)); defer { h.cleanup() }
        h.clock.now = asr.addingTimeInterval(120)
        h.gate.reevaluate(.wake)
        #expect(h.gate.phase == .idle)
        // Resume: pausedUntil = now (preferred) or nil.
        h.settings = .test(pausedUntil: resumeWithNil ? nil : h.clock.now)
        h.gate.reevaluate(.settingsChanged)
        #expect(h.gate.phase == .idle)
        h.gate.reevaluate(.wake)
        #expect(h.gate.phase == .idle)
        h.clock.now = maghrib
        h.gate.athanFired(.maghrib, at: maghrib)
        #expect(h.gate.currentBlock?.prayer == .maghrib)
    }

    @Test func pauseRefusedMidBlockAndCannotEndIt() throws {
        let h = Harness(at: asr); defer { h.cleanup() }
        h.gate.athanFired(.asr, at: asr)
        #expect(throws: SettingsError.blocked) { try h.gate.authorizeSettingsChange() }
        // A pause that slips past the store neither ends nor shortens the block.
        h.settings = .test(pausedUntil: .distantFuture)
        h.clock.now = asr.addingTimeInterval(60)
        h.gate.reevaluate(.settingsChanged)
        #expect(h.gate.phase == .locked(until: asr.addingTimeInterval(600)))
        #expect(h.gate.requestConfirm() == false)
        #expect(h.shield.tearDownCount == 0)
    }

    @Test func settingsChangesAllowedBetweenPrayers() throws {
        let h = Harness(at: asr); defer { h.cleanup() }
        try h.gate.authorizeSettingsChange()
        h.gate.athanFired(.asr, at: asr)
        h.clock.now = asr.addingTimeInterval(600)
        #expect(h.gate.requestConfirm())
        try h.gate.authorizeSettingsChange()
    }

    // MARK: first setup (PM ruling a)

    @Test func finishingSetupInsideAnOpenWindowDoesNotBlockIt() throws {
        let h = Harness(at: asr.addingTimeInterval(-3600), settings: .test(setupComplete: false)); defer { h.cleanup() }
        h.clock.now = asr.addingTimeInterval(120)
        h.settings = .test(setupComplete: true)
        h.gate.reevaluate(.settingsChanged)
        #expect(h.gate.phase == .idle)
        #expect(try h.diskState().lastDropped == .init(prayer: .asr, athanAt: asr))
        h.gate.reevaluate(.wake)
        #expect(h.gate.phase == .idle)
        h.clock.now = maghrib
        h.gate.athanFired(.maghrib, at: maghrib)
        #expect(h.gate.currentBlock?.prayer == .maghrib)
    }
}
