// EmergencyExitTests.swift — v2 gate + ledger tests (Architecture Plan v2 §5, PM amendment §9). Owner: PM.
// FakeClock, a temp directory, an in-memory prefs mirror. UTC calendar, so "this year" is fixed.

import Foundation
import Testing
@testable import GoPray

@MainActor @Suite("Emergency exits")
struct EmergencyExitTests {
    let asr = FakeSchedule.at(.asr)
    let isha = FakeSchedule.at(.isha)

    private func blocked(_ settings: Settings = .test()) -> Harness {
        let h = Harness(at: asr, settings: settings)
        h.gate.athanFired(.asr, at: asr)
        return h
    }

    private func write(_ h: Harness, uses: Int, at: Date, raw: String? = nil) throws {
        try FileManager.default.createDirectory(at: h.dir, withIntermediateDirectories: true)
        if let raw { try raw.write(to: h.emergencyURL, atomically: true, encoding: .utf8); return }
        let f = EmergencyLedger.File(used: (0..<uses).map { _ in .init(prayer: .dhuhr, athanAt: at, at: at) })
        try BlockStateFile.makeEncoder().encode(f).write(to: h.emergencyURL)
    }

    private func mirrorJSON(_ h: Harness, uses: Int, at: Date) throws {
        let f = EmergencyLedger.File(used: (0..<uses).map { _ in .init(prayer: .dhuhr, athanAt: at, at: at) })
        h.mirror.usedJSON = String(data: try BlockStateFile.makeEncoder().encode(f), encoding: .utf8)
    }

    private func mirrorUseCount(_ h: Harness) throws -> Int {
        let text = try #require(h.mirror.usedJSON)
        return try BlockStateFile.makeDecoder().decode(EmergencyLedger.File.self, from: Data(text.utf8)).used.count
    }

    private func utc(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    // MARK: 1–2. The exit

    @Test func exitMidLockEndsTheBlockAndRecordsDroppedNeverConfirmed() throws {
        let h = blocked(); defer { h.cleanup() }
        h.clock.now = asr.addingTimeInterval(120)
        #expect(h.ledger.remaining(at: h.clock.now) == 5)
        #expect(h.gate.requestEmergencyExit())
        let disk = try h.diskState()
        #expect(disk.block == nil)
        #expect(disk.lastDropped == .init(prayer: .asr, athanAt: asr))
        #expect(disk.lastConfirmed == nil)
        #expect(h.ledger.remaining(at: h.clock.now) == 4)
        #expect(try mirrorUseCount(h) == 1)
        let file = try BlockStateFile.makeDecoder().decode(EmergencyLedger.File.self, from: Data(contentsOf: h.emergencyURL))
        #expect(file.used.count == 1 && file.used[0].prayer == .asr && file.used[0].athanAt == asr)
        #expect(h.shield.dismissKinds == [.emergency])
        #expect(h.audio.stopCount >= 1)
        #expect(h.gate.phase == .idle)
    }

    @Test func exitAlsoWorksAtCanConfirmAndInCodingMode() throws {
        let h = blocked(.test(mode: .codingApps)); defer { h.cleanup() }
        h.clock.now = asr.addingTimeInterval(700)
        #expect(h.gate.phase == .canConfirm)
        #expect(h.gate.requestEmergencyExit())
        #expect(h.hider.stopCount >= 1)
    }

    @Test func exitIsRefusedWhenIdleAndWhenLeaving() throws {
        let h = Harness(at: asr); defer { h.cleanup() }
        #expect(!h.gate.requestEmergencyExit())
        h.shield.autoCompleteDismiss = false
        h.gate.athanFired(.asr, at: asr)
        h.clock.now = asr.addingTimeInterval(700)
        #expect(h.gate.requestConfirm())
        #expect(h.gate.phase == .leaving)
        #expect(!h.gate.requestEmergencyExit())
        #expect(h.ledger.remaining(at: h.clock.now) == 5)
    }

    @Test func oneExitPerBlockByConstruction() throws {
        let h = blocked(); defer { h.cleanup() }
        #expect(h.gate.requestEmergencyExit())
        #expect(!h.gate.requestEmergencyExit())
        #expect(h.ledger.remaining(at: h.clock.now) == 4)
    }

    // MARK: 3–4. Refusals leave the block exactly as it was

    @Test func noneLeftRefusesAndResyncsTheCount() throws {
        let h = blocked(); defer { h.cleanup() }
        h.ledger.debugSetEmergencyExitsUsed(5, now: h.clock.now)
        #expect(!h.gate.requestEmergencyExit())
        #expect(try h.diskState().block != nil)
        h.gate.shieldDidRequestEmergencyExit()          // the delegate path re-syncs the page
        #expect(h.shield.updates.last?.emergencyExitsLeft == 0)
        #expect(h.shield.dismissCount == 0)
    }

    @Test func aFailedLedgerWriteRefusesTheExit() throws {
        let h = blocked(); defer { h.cleanup() }
        // A directory where the file should be: the atomic write cannot replace it with a file.
        try FileManager.default.createDirectory(at: h.emergencyURL.appendingPathComponent("x"), withIntermediateDirectories: true)
        // A directory is also "unreadable" → 0 left, which refuses too. Either way: never trapped, block intact.
        #expect(!h.gate.requestEmergencyExit())
        #expect(try h.diskState().block != nil)
        #expect(h.mirror.usedJSON == nil)
        #expect(h.shield.dismissCount == 0)
    }

    @Test func exitsOffAtBlockStartRemovesTheButtonAndRefusesTheExit() throws {
        let h = blocked(.test(emergencyExitsEnabled: false)); defer { h.cleanup() }
        #expect(h.shield.shows.last?.emergencyExitsLeft == 0)
        #expect(!h.gate.requestEmergencyExit())
        #expect(try h.diskState().block?.emergencyExitsEnabled == false)
    }

    @Test func flippingTheSwitchMidBlockChangesNothing() throws {
        let h = blocked(.test(emergencyExitsEnabled: true)); defer { h.cleanup() }
        h.settings.emergencyExitsEnabled = false           // a bypassed store
        h.gate.reevaluate(.settingsChanged)
        #expect(h.gate.shieldContext()?.emergencyExitsLeft == 5)
        #expect(h.gate.requestEmergencyExit())
        // ...and the other way round
        let h2 = blocked(.test(emergencyExitsEnabled: false)); defer { h2.cleanup() }
        h2.settings.emergencyExitsEnabled = true
        h2.gate.reevaluate(.settingsChanged)
        #expect(!h2.gate.requestEmergencyExit())
    }

    // MARK: 5. Relaunch

    @Test func relaunchMidBlockKeepsTheCountAndTheContext() throws {
        let h = blocked(); defer { h.cleanup() }
        h.ledger.debugSetEmergencyExitsUsed(2, now: h.clock.now)
        h.clock.now = asr.addingTimeInterval(60)
        h.relaunch()
        #expect(h.gate.isBlocked)
        #expect(h.gate.shieldContext()?.emergencyExitsLeft == 3)
        #expect(h.gate.emergencyExitsLeft == 3)
    }

    // MARK: 6. Count rules

    @Test func countRules() throws {
        let h = Harness(at: asr); defer { h.cleanup() }
        let now = h.clock.now
        #expect(h.ledger.remaining(at: now) == 5)                       // both missing
        try mirrorJSON(h, uses: 3, at: now)
        #expect(h.ledger.remaining(at: now) == 2)                       // file missing, mirror 3
        try mirrorJSON(h, uses: 0, at: now)
        try write(h, uses: 3, at: now)
        #expect(h.ledger.remaining(at: now) == 2)                       // mirror 0, file 3
        try write(h, uses: 9, at: now)
        #expect(h.ledger.remaining(at: now) == 0)                       // more than 5 this year
        try write(h, uses: 0, at: now, raw: "{ not json")
        #expect(h.ledger.remaining(at: now) == 0)                       // corrupt file → 0 (fail safe)
        try write(h, uses: 0, at: now, raw: #"{"schemaVersion":7,"used":[]}"#)
        #expect(h.ledger.remaining(at: now) == 0)                       // wrong version → 0
        try write(h, uses: 0, at: now)
        h.mirror.usedJSON = "garbage"
        #expect(h.ledger.remaining(at: now) == 0)                       // corrupt mirror → 0 (fail safe)
    }

    @Test func theLargerStoreWinsNeverTheSum() throws {
        let h = Harness(at: asr); defer { h.cleanup() }
        let now = h.clock.now
        try write(h, uses: 3, at: now); try mirrorJSON(h, uses: 3, at: now)
        #expect(h.ledger.remaining(at: now) == 2)                       // 3 and 3 → 3, not 6
        try write(h, uses: 2, at: now); try mirrorJSON(h, uses: 4, at: now)
        #expect(h.ledger.remaining(at: now) == 1)                       // file 2, mirror 4 → 1 left
    }

    @Test func yearRuleFromThePlan() throws {
        let h = Harness(at: asr); defer { h.cleanup() }
        let now = h.clock.now                                           // 2026-10-22 15:30 UTC
        try write(h, uses: 5, at: utc("2025-06-01T10:00:00Z"))
        #expect(h.ledger.remaining(at: now) == 5)                       // last year's uses do not count
        try write(h, uses: 3, at: utc("2026-02-01T10:00:00Z"))
        #expect(h.ledger.remaining(at: now) == 2)
        let mixed = EmergencyLedger.File(used: [
            .init(prayer: .asr, athanAt: now, at: utc("2026-03-01T10:00:00Z")), .init(prayer: .asr, athanAt: now, at: utc("2026-04-01T10:00:00Z")),
            .init(prayer: .asr, athanAt: now, at: utc("2026-10-23T10:00:00Z")), .init(prayer: .asr, athanAt: now, at: utc("2026-10-24T10:00:00Z"))])
        try BlockStateFile.makeEncoder().encode(mixed).write(to: h.emergencyURL)
        #expect(h.ledger.remaining(at: now) == 1)                       // 2 this year + 2 dated tomorrow
        try write(h, uses: 6, at: utc("2026-01-05T10:00:00Z"))
        #expect(h.ledger.remaining(at: now) == 0)
    }

    @Test func theYearFlipsAtLocalMidnightOnNewYear() throws {
        let h = Harness(at: asr); defer { h.cleanup() }
        try write(h, uses: 2, at: utc("2026-12-31T23:59:59Z"))
        #expect(h.ledger.remaining(at: utc("2026-12-31T23:59:59Z")) == 3)    // counts for 2026
        #expect(h.ledger.remaining(at: utc("2027-01-01T00:00:00Z")) == 5)    // not for 2027
        try write(h, uses: 2, at: utc("2027-01-01T00:00:00Z"))
        #expect(h.ledger.remaining(at: utc("2027-01-01T00:00:01Z")) == 3)    // counts for 2027
    }

    @Test func deletingStateJsonOrTheLedgerFileDoesNotRefill() throws {
        let h = blocked(); defer { h.cleanup() }
        h.ledger.debugSetEmergencyExitsUsed(3, now: h.clock.now)
        try? FileManager.default.removeItem(at: h.stateURL)
        #expect(h.ledger.remaining(at: h.clock.now) == 2)               // negative control: state.json is not the count
        try FileManager.default.removeItem(at: h.emergencyURL)
        #expect(h.ledger.remaining(at: h.clock.now) == 2)               // the mirror still holds 3 uses
        h.mirror.usedJSON = nil
        #expect(h.ledger.remaining(at: h.clock.now) == 5)               // both gone → refill (accepted: uninstall-grade)
    }

    @Test func theCountIsPerCalendarYear() throws {
        let h = Harness(at: asr); defer { h.cleanup() }
        let now = h.clock.now
        h.ledger.debugSetEmergencyExitsUsed(4, now: now)
        #expect(h.ledger.remaining(at: now) == 1)
        let nextYear = ISO8601DateFormatter().date(from: "2027-01-02T10:00:00Z")!
        #expect(h.ledger.remaining(at: nextYear) == 5)                  // a new year refills
        let lastYear = ISO8601DateFormatter().date(from: "2025-06-01T10:00:00Z")!
        #expect(h.ledger.remaining(at: lastYear) == 1)                  // a clock moved back: the future uses still count
    }

    @Test func aUseDatedInTheFutureStillCounts() throws {
        let h = Harness(at: asr); defer { h.cleanup() }
        try write(h, uses: 2, at: ISO8601DateFormatter().date(from: "2099-01-01T00:00:00Z")!)
        #expect(h.ledger.remaining(at: h.clock.now) == 3)
    }

    @Test func recordUseRaisesTheMirrorEvenWhenTheFileWasDeleted() throws {
        let h = Harness(at: asr); defer { h.cleanup() }
        try mirrorJSON(h, uses: 3, at: asr)
        try h.ledger.recordUse(.init(prayer: .asr, athanAt: asr, at: asr), now: asr)
        #expect(try mirrorUseCount(h) == 4)
        #expect(h.ledger.remaining(at: asr) == 1)
    }

    // MARK: 7–8. The wake rule and the confirmed path

    @Test func afterAnEmergencyExitTheSameWindowIsNotBlockedAgainButTheNextAthanIs() throws {
        let h = blocked(); defer { h.cleanup() }
        #expect(h.gate.requestEmergencyExit())
        h.clock.now = asr.addingTimeInterval(1800)
        h.gate.reevaluate(.wake)
        #expect(h.gate.phase == .idle)
        h.relaunch()
        #expect(h.gate.phase == .idle)
        h.clock.now = FakeSchedule.at(.maghrib)
        h.gate.athanFired(.maghrib, at: FakeSchedule.at(.maghrib))
        #expect(h.gate.isBlocked)
    }

    @Test func confirmedEndStillSetsLastConfirmedAndNeverLastDropped() throws {
        let h = blocked(); defer { h.cleanup() }
        h.clock.now = asr.addingTimeInterval(600)
        #expect(h.gate.requestConfirm())
        let d = try h.diskState()
        #expect(d.lastConfirmed == .init(prayer: .asr, athanAt: asr) && d.lastDropped == nil)
        #expect(h.shield.dismissKinds == [.confirmed])
        #expect(h.ledger.remaining(at: h.clock.now) == 5)
    }

    // MARK: 9–10. The captured app list

    @Test func theListIsCapturedAtBlockStartAndNeverRead_AgainFromSettings() throws {
        var s1 = Settings.test(mode: .codingApps)
        s1.customApps = [.init(id: "x.custom", name: "X", platform: .mac), .init(id: "win.exe", name: "W", platform: .windows)]
        s1.disabledDefaultApps = ["app.two"]
        let h = blocked(s1); defer { h.cleanup() }
        #expect(h.hider.started == [["app.one", "x.custom"]])
        #expect(try h.diskState().block?.hiddenApps == ["app.one", "x.custom"])

        var s2 = s1; s2.disabledDefaultApps = ["app.one"]; s2.customApps = []
        h.settings = s2                                              // a bypassed store
        h.gate.reevaluate(.settingsChanged)
        #expect(h.hider.startCount == 1)                             // not restarted with S2
        h.clock.now = asr.addingTimeInterval(30)
        h.relaunch()                                                 // resumes with the FILE's list
        #expect(h.hider.started == [["app.one", "x.custom"]])
    }

    @Test func aTamperedHiddenAppsListLosesDenylistedIdsAndIsCapped() throws {
        let h = blocked(.test(mode: .codingApps)); defer { h.cleanup() }
        var disk = try h.diskState()
        disk.block?.hiddenApps = ["com.apple.finder", "com.ahmedelgazar.gopray", "keep.me"] + (0..<500).map { "bulk.\($0)" }
        try StateStore(directory: h.dir).save(disk)
        h.clock.now = asr.addingTimeInterval(30)
        h.relaunch()
        let got = try #require(h.hider.started.last)
        #expect(!got.contains("com.apple.finder") && !got.contains("com.ahmedelgazar.gopray"))
        #expect(got.count <= BlockedApps.maxCaptured)
    }

    @Test func aZeroPointOneStateFileResumesAndWritesTheListBack() throws {
        let h = blocked(.test(mode: .codingApps)); defer { h.cleanup() }
        var disk = try h.diskState()
        disk.block?.hiddenApps = nil
        try StateStore(directory: h.dir).save(disk)
        h.clock.now = asr.addingTimeInterval(30)
        h.relaunch()
        #expect(h.hider.started == [["app.one", "app.two"]])
        #expect(try h.diskState().block?.hiddenApps == ["app.one", "app.two"])
    }

    @Test func oldStateJsonWithoutTheNewKeysDecodes() throws {
        let json = """
        {"schemaVersion":1,"block":{"prayer":"asr","athanAt":"2026-10-22T15:30:00.000Z","blockStartedAt":"2026-10-22T15:30:00.000Z",
        "silenced":false,"athanPlayed":true},"launches":[]}
        """
        let s = try BlockStateFile.makeDecoder().decode(BlockStateFile.self, from: Data(json.utf8))
        #expect(s.block?.hiddenApps == nil && s.block?.emergencyExitsEnabled == true && s.block?.lockSeconds == 600)
    }

    #if DEBUG
    @Test func debugHookSetsTheCount() throws {
        let h = Harness(at: asr); defer { h.cleanup() }
        h.ledger.debugSetEmergencyExitsUsed(5, now: asr)
        #expect(h.ledger.remaining(at: asr) == 0)
    }
    #endif
}
