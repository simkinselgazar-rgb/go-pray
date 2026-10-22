// DebugBlockTests.swift — DEBUG "Trigger Athan now" blocks resume after a relaunch. Owner: PM.
// They carry a synthetic window (athan = trigger time, end = +1 h) in state.json, so the
// gate's normal resume rule matches them instead of failing them open.

#if DEBUG
import Foundation
import Testing
@testable import GoPray

@MainActor @Suite("Debug block resume")
struct DebugBlockTests {
    /// 09:00 in FakeSchedule: after sunrise, before Dhuhr. No real window is open.
    let nine = FakeSchedule.day0.addingTimeInterval(9 * 3600)

    @Test func aDebugBlockSurvivesARelaunchWithItsOriginalStart() throws {
        let h = Harness(at: nine); defer { h.cleanup() }
        h.gate.debugTriggerAthan(.dhuhr, lockSeconds: 20)
        #expect(try h.diskState().block?.debugWindowEnd == nine.addingTimeInterval(3600))

        h.clock.now = nine.addingTimeInterval(5)
        h.relaunch()
        #expect(h.gate.phase == .locked(until: nine.addingTimeInterval(20)))
        #expect(h.gate.currentBlock?.blockStartedAt == nine)
        #expect(h.shield.shows.count == 1)
        #expect(h.shield.shows[0].remainingMs == 15_000)
        #expect(h.audio.plays.isEmpty)                         // no replay
        #expect(h.gate.requestConfirm() == false)
        h.clock.now = nine.addingTimeInterval(20)
        #expect(h.gate.requestConfirm())
    }

    @Test func withoutTheSyntheticWindowItFailsOpenAsBefore() throws {
        let h = Harness(at: nine); defer { h.cleanup() }
        h.gate.debugTriggerAthan(.dhuhr, lockSeconds: 20)
        var s = try h.diskState()
        s.block?.debugWindowEnd = nil                          // negative control: the old file shape
        try BlockStateFile.makeEncoder().encode(s).write(to: h.stateURL)
        h.clock.now = nine.addingTimeInterval(5)
        h.relaunch()
        #expect(h.gate.phase == .idle)
    }

    @Test func theSyntheticWindowEndsAfterAnHour() throws {
        let h = Harness(at: nine); defer { h.cleanup() }
        h.gate.debugTriggerAthan(.dhuhr, lockSeconds: 20)
        h.clock.now = nine.addingTimeInterval(3601)
        h.relaunch()
        #expect(h.gate.phase == .idle)
    }
}
#endif
