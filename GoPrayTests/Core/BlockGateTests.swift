// BlockGateTests.swift — §E PM tests 1–5, 7–9 plus the fail-open rules of §G. Owner: PM.
// All against FakeClock + a temp state directory. Lock = 600 s unless stated.

import Foundation
import Testing
@testable import GoPray

@MainActor @Suite("BlockGate")
struct BlockGateTests {
    let asr = FakeSchedule.at(.asr)
    let maghrib = FakeSchedule.at(.maghrib)

    // MARK: E.1 normal flow + the 10-minute lock

    @Test func athanLocksForTenMinutesThenConfirmEndsBlock() throws {
        let h = Harness(at: asr); defer { h.cleanup() }
        h.gate.athanFired(.asr, at: asr)

        #expect(h.gate.phase == .locked(until: asr.addingTimeInterval(600)))
        #expect(h.shield.shows.count == 1)
        #expect(h.shield.shows[0].remainingMs == 600_000)
        #expect(h.audio.plays.count == 1)
        #expect(h.audio.plays[0].0 == .asr)
        let onDisk = try h.diskState()
        #expect(onDisk.block?.blockStartedAt == asr)
        #expect(onDisk.block?.athanPlayed == true)

        h.clock.now = asr.addingTimeInterval(599)
        #expect(h.gate.requestConfirm() == false)
        #expect(try h.diskState().block != nil)

        h.clock.now = asr.addingTimeInterval(600)
        #expect(h.gate.phase == .canConfirm)
        #expect(h.gate.requestConfirm() == true)
        let after = try h.diskState()
        #expect(after.block == nil)
        #expect(after.lastConfirmed == .init(prayer: .asr, athanAt: asr))
        #expect(h.shield.dismissCount == 1)
        #expect(h.shield.tearDownCount == 0)
        #expect(h.gate.phase == .idle)
        #expect(h.hider.startCount == 0)      // whole-screen mode never hides apps
    }

    @Test func leavingPhaseHoldsUntilDismissCompletes() throws {
        let h = Harness(at: asr); defer { h.cleanup() }
        h.shield.autoCompleteDismiss = false
        h.gate.athanFired(.asr, at: asr)
        h.clock.now = asr.addingTimeInterval(600)
        #expect(h.gate.requestConfirm())
        #expect(h.gate.phase == .leaving)
        #expect(h.gate.shouldAllowQuit() == false)
        h.shield.pendingDismiss?()
        #expect(h.gate.phase == .idle)
        #expect(h.gate.shouldAllowQuit())
    }

    @Test func dismissThatNeverCallsBackFailsOpen() async throws {
        let h = Harness(at: asr); defer { h.cleanup() }
        h.shield.autoCompleteDismiss = false
        h.gate.athanFired(.asr, at: asr)
        h.clock.now = asr.addingTimeInterval(600)
        #expect(h.gate.requestConfirm())
        #expect(h.gate.phase == .leaving)
        try await Task.sleep(for: .milliseconds(600))     // harness leavingTimeout = 200 ms
        #expect(h.gate.phase == .idle)
        #expect(h.shield.tearDownCount == 1)
    }

    // MARK: E.2 relaunch mid-block

    @Test func relaunchMidBlockResumesOriginalStartWithoutReplay() throws {
        let h = Harness(at: asr); defer { h.cleanup() }
        h.gate.athanFired(.asr, at: asr)
        h.clock.now = asr.addingTimeInterval(300)
        h.relaunch()

        #expect(h.gate.phase == .locked(until: asr.addingTimeInterval(600)))
        #expect(h.gate.currentBlock?.blockStartedAt == asr)
        #expect(h.audio.plays.isEmpty)                    // athanPlayed: no replay
        #expect(h.shield.shows.count == 1)
        #expect(h.shield.shows[0].remainingMs == 300_000)
        #expect(h.gate.requestConfirm() == false)
        h.clock.now = asr.addingTimeInterval(600)
        #expect(h.gate.requestConfirm())
    }

    @Test func relaunchInCodingModeHidesAgain() throws {
        let h = Harness(at: asr, settings: .test(mode: .codingApps)); defer { h.cleanup() }
        h.gate.athanFired(.asr, at: asr)
        #expect(h.hider.startCount == 1)
        h.clock.now = asr.addingTimeInterval(60)
        h.relaunch()
        #expect(h.hider.startCount == 1)
        #expect(h.shield.shows.first?.mode == .codingApps)
    }

    // MARK: E.3 sleep / wake

    @Test func wakeInsideWindowStartsBlockAtWake() throws {
        let h = Harness(at: asr.addingTimeInterval(-60)); defer { h.cleanup() }
        let wake = asr.addingTimeInterval(20 * 60)
        h.clock.now = wake                                // asleep through the Athan
        h.gate.reevaluate(.wake)
        #expect(h.gate.currentBlock?.prayer == .asr)
        #expect(h.gate.currentBlock?.athanAt == asr)
        #expect(h.gate.currentBlock?.blockStartedAt == wake)
        #expect(h.gate.phase == .locked(until: wake.addingTimeInterval(600)))
        #expect(h.audio.plays.count == 1)
    }

    @Test func wakeAfterSunriseMissesFajr() throws {
        let fajr = FakeSchedule.at(.fajr)
        let h = Harness(at: fajr.addingTimeInterval(-3600)); defer { h.cleanup() }
        h.clock.now = FakeSchedule.sunrise().addingTimeInterval(60)
        h.gate.reevaluate(.wake)
        #expect(h.gate.phase == .idle)
        #expect(h.shield.shows.isEmpty)
        #expect(h.audio.plays.isEmpty)
    }

    @Test func wakeBeforeSunriseBlocksFajr() throws {
        let fajr = FakeSchedule.at(.fajr)
        let h = Harness(at: fajr.addingTimeInterval(-3600)); defer { h.cleanup() }
        h.clock.now = FakeSchedule.sunrise().addingTimeInterval(-60)
        h.gate.reevaluate(.wake)
        #expect(h.gate.currentBlock?.prayer == .fajr)
    }

    @Test func wakeAfterNextAthanMissesOldPrayerAndBlocksTheCurrentOne() throws {
        let h = Harness(at: FakeSchedule.at(.dhuhr)); defer { h.cleanup() }
        h.gate.athanFired(.dhuhr, at: FakeSchedule.at(.dhuhr))
        h.clock.now = FakeSchedule.at(.dhuhr).addingTimeInterval(600)
        #expect(h.gate.requestConfirm())
        // Asleep through Asr, wake after Maghrib.
        let wake = maghrib.addingTimeInterval(5 * 60)
        h.clock.now = wake
        h.gate.reevaluate(.wake)
        #expect(h.gate.currentBlock?.prayer == .maghrib)   // Asr missed: never blocked
        #expect(h.gate.currentBlock?.blockStartedAt == wake)
        #expect(try h.diskState().lastConfirmed == .init(prayer: .dhuhr, athanAt: FakeSchedule.at(.dhuhr)))
    }

    @Test func sleepDuringBlockCountsTowardTheLock() throws {
        let h = Harness(at: asr); defer { h.cleanup() }
        h.gate.athanFired(.asr, at: asr)
        h.clock.now = asr.addingTimeInterval(15 * 60)       // lid closed 15 min
        h.gate.reevaluate(.wake)
        #expect(h.gate.phase == .canConfirm)
        #expect(h.gate.currentBlock?.blockStartedAt == asr)
        #expect(h.shield.shows.count == 1)                 // same block, re-synced
        #expect(h.shield.updates.last?.remainingMs == 0)
        #expect(h.gate.requestConfirm())
    }

    @Test func wakeAfterBlockWindowClosedDropsItAndBlocksTheNewPrayer() throws {
        let h = Harness(at: asr); defer { h.cleanup() }
        h.gate.athanFired(.asr, at: asr)
        let wake = maghrib.addingTimeInterval(60)
        h.clock.now = wake
        h.gate.reevaluate(.wake)
        #expect(h.shield.tearDownCount == 1)
        #expect(h.gate.currentBlock?.prayer == .maghrib)
        #expect(h.gate.currentBlock?.blockStartedAt == wake)
        #expect(try h.diskState().lastConfirmed == nil)
    }

    // MARK: E.4 overlap

    @Test func nextAthanDuringBlockReplacesIt() throws {
        let h = Harness(at: asr); defer { h.cleanup() }
        h.gate.athanFired(.asr, at: asr)
        h.clock.now = maghrib
        h.gate.athanFired(.maghrib, at: maghrib)
        #expect(h.shield.tearDownCount == 1)
        #expect(h.shield.shows.count == 2)
        #expect(h.gate.currentBlock?.prayer == .maghrib)
        #expect(h.gate.currentBlock?.blockStartedAt == maghrib)
        #expect(h.gate.phase == .locked(until: maghrib.addingTimeInterval(600)))
        #expect(try h.diskState().block?.prayer == .maghrib)
    }

    @Test func duplicateAthanFireIsIgnored() throws {
        let h = Harness(at: asr); defer { h.cleanup() }
        h.gate.athanFired(.asr, at: asr)
        h.clock.now = asr.addingTimeInterval(5)
        h.gate.athanFired(.asr, at: asr)
        #expect(h.shield.shows.count == 1)
        #expect(h.shield.tearDownCount == 0)
        #expect(h.gate.currentBlock?.blockStartedAt == asr)
    }

    // MARK: E.5 clock jumps

    @Test func clockForwardMidLockOpensTheButton() throws {
        let h = Harness(at: asr); defer { h.cleanup() }
        h.gate.athanFired(.asr, at: asr)
        h.clock.now = asr.addingTimeInterval(120 + 3600)
        h.gate.reevaluate(.clockChanged)
        #expect(h.gate.phase == .canConfirm)
        #expect(h.gate.requestConfirm())
    }

    @Test func clockBackMidLockOpensTheButton() throws {
        let h = Harness(at: asr); defer { h.cleanup() }
        h.gate.athanFired(.asr, at: asr)
        h.clock.now = asr.addingTimeInterval(120 - 3600)    // before blockStartedAt
        h.gate.reevaluate(.clockChanged)
        #expect(h.gate.phase == .canConfirm)                // clamp: never locked for an hour
        #expect(h.gate.currentBlock?.prayer == .asr)
        #expect(h.gate.requestConfirm())
    }

    @Test func clockBackBeforeConfirmedAthanDoesNotBlockAgain() throws {
        let h = Harness(at: asr); defer { h.cleanup() }
        h.gate.athanFired(.asr, at: asr)
        h.clock.now = asr.addingTimeInterval(600)
        #expect(h.gate.requestConfirm())
        h.clock.now = FakeSchedule.at(.dhuhr).addingTimeInterval(30 * 60)   // back into Dhuhr
        h.gate.reevaluate(.clockChanged)
        #expect(h.gate.phase == .idle)
        h.clock.now = asr                                   // the Athan "fires" again
        h.gate.athanFired(.asr, at: asr)
        #expect(h.gate.phase == .idle)
        #expect(h.shield.shows.count == 1)
    }

    // MARK: E.7 corrupt state.json

    @Test(arguments: [
        "{\"schemaVersion\": 1, \"block\": {\"prayer\": \"asr\", \"athanAt\": \"2026-10-22T15:3",   // truncated
        "{\"schemaVersion\": 2, \"block\": null, \"launches\": []}",                                  // wrong version
        "{\"schemaVersion\": 1, \"block\": {\"prayer\": \"zuhr\", \"athanAt\": \"2026-10-22T15:30:00Z\", \"blockStartedAt\": \"2026-10-22T15:30:00Z\", \"silenced\": false, \"athanPlayed\": true}}",
        "not json at all",
    ])
    func corruptFileFailsOpen(_ contents: String) throws {
        let h = Harness(at: asr.addingTimeInterval(120)); defer { h.cleanup() }
        try FileManager.default.createDirectory(at: h.dir, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: h.stateURL)
        h.relaunch()
        #expect(h.gate.phase == .idle)                      // even inside an open, unconfirmed window
        #expect(h.shield.shows.isEmpty)
        #expect(h.corruptFiles().count == 1)
        let fresh = try h.diskState()                       // a clean file replaced it
        #expect(fresh.block == nil)
        #expect(fresh.lastDropped?.prayer == .asr)
    }

    @Test func blockStartedIn2099FailsOpen() throws {
        let h = Harness(at: asr.addingTimeInterval(120)); defer { h.cleanup() }
        let future = ISO8601DateFormatter().date(from: "2099-01-01T00:00:00Z")!
        let tampered = BlockStateFile(block: .init(prayer: .asr, athanAt: asr, blockStartedAt: future,
                                                   silenced: false, athanPlayed: true))
        try StateStore(directory: h.dir).save(tampered)
        h.relaunch()
        #expect(h.gate.phase == .idle)
        #expect(h.shield.shows.isEmpty)
        #expect(h.corruptFiles().count == 1)
        #expect(try h.diskState().block == nil)
    }

    @Test(arguments: [true, false])
    func farFutureDoneDateIsQuarantinedAndLaterPrayersStillBlock(confirmed: Bool) throws {
        let h = Harness(at: asr.addingTimeInterval(120)); defer { h.cleanup() }
        let future = ISO8601DateFormatter().date(from: "2099-01-01T00:00:00Z")!
        let done = BlockStateFile.Done(prayer: .asr, athanAt: future)
        try StateStore(directory: h.dir).save(BlockStateFile(lastConfirmed: confirmed ? done : nil,
                                                             lastDropped: confirmed ? nil : done))
        h.relaunch()
        #expect(h.corruptFiles().count == 1)
        #expect(h.gate.phase == .idle)                     // quarantine fails open on the open window
        h.clock.now = maghrib
        h.gate.athanFired(.maghrib, at: maghrib)
        #expect(h.gate.currentBlock?.prayer == .maghrib)   // and the next prayer is not silently skipped
    }

    @Test func missingFileIsAFreshStartAndRunsTheWakeRule() throws {
        // No file = first run. Not corrupt, so nothing is dropped: the open,
        // unconfirmed window blocks (plan §3 wake rule; CONTRACT-NOTES #7).
        let at = asr.addingTimeInterval(-60)                 // inside Dhuhr's window
        let h = Harness(at: at); defer { h.cleanup() }
        h.relaunch()
        #expect(h.corruptFiles().isEmpty)
        #expect(h.gate.currentBlock?.prayer == .dhuhr)
        #expect(h.gate.currentBlock?.blockStartedAt == at)
    }

    @Test func stateFileIsOwnerOnly() throws {
        let h = Harness(at: asr); defer { h.cleanup() }
        h.gate.athanFired(.asr, at: asr)
        let attrs = try FileManager.default.attributesOfItem(atPath: h.stateURL.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: h.dir.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    // MARK: E.8 crash loop

    @Test func threeLaunchesInTwoMinutesWhileBlockedFailOpen() throws {
        let h = Harness(at: asr); defer { h.cleanup() }
        h.gate.athanFired(.asr, at: asr)
        h.clock.now = asr.addingTimeInterval(10); h.relaunch()
        #expect(h.gate.isBlocked)
        h.clock.now = asr.addingTimeInterval(20); h.relaunch()
        #expect(h.gate.isBlocked)
        #expect(try h.diskState().launches.count == 2)
        h.clock.now = asr.addingTimeInterval(30); h.relaunch()
        #expect(h.gate.phase == .idle)
        #expect(h.shield.shows.isEmpty)
        let s = try h.diskState()
        #expect(s.block == nil)
        #expect(s.launches.isEmpty)
        #expect(s.lastDropped == .init(prayer: .asr, athanAt: asr))
        // That prayer stays given up; the next one works normally.
        h.clock.now = asr.addingTimeInterval(60); h.relaunch()
        #expect(h.gate.phase == .idle)
        h.clock.now = maghrib
        h.gate.athanFired(.maghrib, at: maghrib)
        #expect(h.gate.currentBlock?.prayer == .maghrib)
    }

    @Test func launchesSpreadOverMoreThanTwoMinutesKeepTheBlock() throws {
        let h = Harness(at: asr); defer { h.cleanup() }
        h.gate.athanFired(.asr, at: asr)
        for t in [10.0, 140, 270] { h.clock.now = asr.addingTimeInterval(t); h.relaunch() }
        #expect(h.gate.isBlocked)
        #expect(h.gate.currentBlock?.blockStartedAt == asr)
    }

    // MARK: E.9 quit + settings

    @Test func quitAndSettingsRefusedWhileBlocked() throws {
        let h = Harness(at: asr); defer { h.cleanup() }
        #expect(h.gate.shouldAllowQuit())
        #expect(h.gate.allowsSettingsChange())
        h.gate.athanFired(.asr, at: asr)
        #expect(h.gate.shouldAllowQuit() == false)
        #expect(h.gate.allowsSettingsChange() == false)
        h.clock.now = asr.addingTimeInterval(600)
        #expect(h.gate.shouldAllowQuit() == false)          // canConfirm is still blocked
        #expect(h.gate.allowsSettingsChange() == false)
        #expect(h.gate.requestConfirm())
        #expect(h.gate.shouldAllowQuit())
        #expect(h.gate.allowsSettingsChange())
    }

    // MARK: prayed refused while locked (bridge `prayed` → shieldDidRequestConfirm)

    @Test func prayedWhileLockedIsRefusedAndResyncs() throws {
        let h = Harness(at: asr); defer { h.cleanup() }
        h.gate.athanFired(.asr, at: asr)
        h.clock.now = asr.addingTimeInterval(100)
        h.gate.shieldDidRequestConfirm()
        #expect(h.gate.isBlocked)
        #expect(h.gate.currentBlock != nil)
        #expect(h.shield.dismissCount == 0)
        #expect(h.shield.updates.last?.remainingMs == 500_000)
        h.clock.now = asr.addingTimeInterval(600)
        h.gate.shieldDidRequestConfirm()
        #expect(h.shield.dismissCount == 1)
    }

    @Test func confirmWhenIdleIsRefused() {
        let h = Harness(at: asr); defer { h.cleanup() }
        #expect(h.gate.requestConfirm() == false)
        #expect(h.shield.dismissCount == 0)
    }

    // MARK: silence

    @Test func silenceStopsSoundOnlyAndSurvivesRelaunch() throws {
        let h = Harness(at: asr); defer { h.cleanup() }
        h.gate.athanFired(.asr, at: asr)
        #expect(h.shield.shows[0].athanRemainingMs > 0)
        h.gate.shieldDidRequestSilence()
        #expect(h.audio.isPlaying == false)
        #expect(h.gate.isBlocked)
        #expect(h.gate.phase == .locked(until: asr.addingTimeInterval(600)))
        #expect(h.shield.updates.last?.athanRemainingMs == 0)
        #expect(try h.diskState().block?.silenced == true)
        h.clock.now = asr.addingTimeInterval(30); h.relaunch()
        #expect(h.audio.plays.isEmpty)
    }

    @Test func athanFinishingUpdatesTheShield() throws {
        let h = Harness(at: asr); defer { h.cleanup() }
        h.gate.athanFired(.asr, at: asr)
        h.audio.finish()
        #expect(h.shield.updates.last?.athanRemainingMs == 0)
        #expect(h.gate.isBlocked)
    }

    @Test func audioFailureStillBlocks() throws {
        let h = Harness(at: asr); defer { h.cleanup() }
        h.audio.throwOnPlay = true
        h.gate.athanFired(.asr, at: asr)
        #expect(h.gate.isBlocked)
        #expect(h.shield.shows.count == 1)
    }

    // MARK: coding-apps mode

    @Test func codingModeHidesForTheBlockAndNamesTheApp() throws {
        let h = Harness(at: asr, settings: .test(mode: .codingApps)); defer { h.cleanup() }
        h.gate.athanFired(.asr, at: asr)
        #expect(h.hider.startCount == 1)
        h.hider.onReHide?("Cursor")
        #expect(h.shield.updates.last?.hiddenAppName == "Cursor")
        h.clock.now = asr.addingTimeInterval(600)
        #expect(h.gate.requestConfirm())
        #expect(h.hider.stopCount == 1)
        h.hider.onReHide?("Cursor")                         // late callback after the block: ignored
        #expect(h.gate.hiddenAppName == nil)
    }

    // MARK: §G: no valid schedule / setup incomplete → never block

    @Test func badScheduleNeverBlocks() throws {
        let h = Harness(at: asr); defer { h.cleanup() }
        h.schedule.valid = false
        h.gate.athanFired(.asr, at: asr)
        h.gate.reevaluate(.wake)
        h.gate.reevaluate(.launch)
        #expect(h.gate.phase == .idle)
        #expect(h.shield.shows.isEmpty)
    }

    @Test func scheduleLostMidBlockFailsOpen() throws {
        let h = Harness(at: asr); defer { h.cleanup() }
        h.gate.athanFired(.asr, at: asr)
        h.schedule.valid = false
        h.gate.reevaluate(.clockChanged)
        #expect(h.gate.phase == .idle)
        #expect(h.shield.tearDownCount == 1)
    }

    @Test func setupIncompleteNeverBlocks() throws {
        let h = Harness(at: asr, settings: .test(setupComplete: false)); defer { h.cleanup() }
        h.gate.athanFired(.asr, at: asr)
        h.gate.reevaluate(.wake)
        #expect(h.gate.phase == .idle)
    }

    @Test func athanTheScheduleDoesNotKnowIsIgnored() throws {
        let h = Harness(at: asr.addingTimeInterval(1800)); defer { h.cleanup() }
        h.gate.athanFired(.isha, at: asr.addingTimeInterval(1800))
        #expect(h.gate.phase == .idle)
    }
}
