// SettingsStoreTests.swift — lane A. The store asks the gate first (E, lane A:
// "mutate throws when the gate is blocked and the file is unchanged"), clamps, rejects
// invalid values, saves atomically, and knows the pause options.

import Adhan
import Foundation
import Testing
@testable import GoPray

@MainActor @Suite("Settings store")
struct SettingsStoreTests {
    let asr = FakeSchedule.at(.asr)

    func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("gopray-settings-\(UUID().uuidString)", isDirectory: true)
    }

    /// A store over a temp dir, attached to a real gate (with the core fakes).
    func make(at start: Date? = nil) -> (SettingsStore, Harness, URL) {
        let dir = tempDir()
        let h = Harness(at: start ?? asr.addingTimeInterval(-3600))
        let store = SettingsStore(directory: dir)
        store.attach(h.gate)
        return (store, h, dir)
    }

    func startBlock(_ h: Harness) {
        h.clock.now = asr
        h.gate.athanFired(.asr, at: asr)
        #expect(h.gate.isBlocked)
    }

    // MARK: through the gate

    @Test func everyChangeIsRefusedDuringABlockAndTheFileIsUnchanged() throws {
        let (store, h, dir) = make(); defer { h.cleanup(); try? FileManager.default.removeItem(at: dir) }
        try store.mutate { $0.city = "Toronto" }                     // saved while idle
        let before = try Data(contentsOf: store.fileURL)
        let snapshot = store.settings
        startBlock(h)

        var ran = 0
        let changes: [(String, (inout Settings) -> Void)] = [
            ("mode", { $0.mode = .codingApps }),
            ("lockMinutes", { $0.lockMinutes = 30 }),
            ("pause", { $0.pausedUntil = .distantFuture }),
            ("city", { $0.city = "Cairo" }),
            ("method", { $0.method = "egyptian" }),
            ("madhab", { $0.madhab = 2 }),
            ("volume", { $0.athanVolume = 0.1 }),
            ("voice", { $0.voice = .shia("Salimi") }),
            ("launchAtLogin", { $0.launchAtLogin.toggle() }),
        ]
        for (name, change) in changes {
            #expect(throws: SettingsError.blocked, "\(name) must be refused") {
                try store.mutate { s in ran += 1; change(&s) }
            }
        }
        #expect(ran == 0, "a refused change must not even run")
        #expect(store.settings == snapshot)
        #expect(try Data(contentsOf: store.fileURL) == before)
        #expect(throws: SettingsError.blocked) { try store.pause(.oneDay, now: asr) }
        #expect(throws: SettingsError.blocked) { try store.authorize() }
    }

    @Test func resumeIsRefusedDuringABlock() throws {
        let (store, h, dir) = make(); defer { h.cleanup(); try? FileManager.default.removeItem(at: dir) }
        try store.pause(.untilResumed, now: h.clock.now)
        startBlock(h)
        #expect(throws: SettingsError.blocked) { try store.resume(now: asr) }
        #expect(store.settings.pausedUntil == .distantFuture)
    }

    @Test func changesWorkAgainAfterThePrayerIsConfirmed() throws {
        let (store, h, dir) = make(); defer { h.cleanup(); try? FileManager.default.removeItem(at: dir) }
        startBlock(h)
        h.clock.now = asr.addingTimeInterval(600)
        #expect(h.gate.requestConfirm())
        h.shield.pendingDismiss?()
        try store.mutate { $0.mode = .codingApps }
        #expect(store.settings.mode == .codingApps)
    }

    @Test func aStoreWithNoGateRefusesEverything() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        #expect(throws: SettingsError.blocked) { try store.mutate { $0.mode = .codingApps } }
        #expect(store.settings == .defaults)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    // MARK: saving, loading, notifying

    @Test func savesAtomicallyAndReloads() throws {
        let (store, h, dir) = make(); defer { h.cleanup(); try? FileManager.default.removeItem(at: dir) }
        try store.mutate {
            $0.city = "Cairo, Egypt"; $0.latitude = 30.03; $0.longitude = 31.25
            $0.method = "egyptian"; $0.mode = .codingApps; $0.setupComplete = true
            $0.voice = .shia("Salimi"); $0.lockMinutes = 20
        }
        let again = SettingsStore(directory: dir)
        #expect(again.settings == store.settings)
        #expect(again.settings.voice == .shia("Salimi"))
        #expect(!again.loadedFromCorruptFile)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(leftovers == ["settings.json"], "no temp files left behind: \(leftovers)")
    }

    @Test func onChangeFiresOncePerRealChangeAfterTheValueIsLive() throws {
        let (store, h, dir) = make(); defer { h.cleanup(); try? FileManager.default.removeItem(at: dir) }
        var seen: [Settings] = []
        store.onChange = { seen.append($0) }
        try store.mutate { $0.mode = .codingApps }
        try store.mutate { $0.mode = .codingApps }          // same value: nothing to do
        try store.mutate { _ in }
        #expect(seen.count == 1)
        #expect(seen.first?.mode == .codingApps)
        #expect(store.settings.mode == .codingApps)
    }

    @Test func aCorruptFileIsSetAsideAndTheAppStartsFresh() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: dir.appendingPathComponent("settings.json"))
        let store = SettingsStore(directory: dir)
        #expect(store.settings == .defaults)
        #expect(store.settings.setupComplete == false)        // nothing blocks until setup is redone
        #expect(store.loadedFromCorruptFile)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.contains { $0.hasPrefix("settings.corrupt-") })
        #expect(!names.contains("settings.json"))
    }

    @Test func aFileWithAnImpossiblePlaceIsTreatedAsCorrupt() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var bad = Settings.test(); bad.latitude = 999
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(bad).write(to: dir.appendingPathComponent("settings.json"))
        #expect(SettingsStore(directory: dir).settings == .defaults)
    }

    // MARK: clamping and validation

    @Test(arguments: [(0, 10), (5, 10), (10, 10), (17, 17), (30, 30), (45, 30), (-3, 10)])
    func lockMinutesAreClamped(_ given: Int, _ stored: Int) throws {
        let (store, h, dir) = make(); defer { h.cleanup(); try? FileManager.default.removeItem(at: dir) }
        try store.mutate { $0.lockMinutes = given }
        #expect(store.settings.lockMinutes == stored)
    }

    @Test func volumeIsClampedAndNaNFallsBack() throws {
        let (store, h, dir) = make(); defer { h.cleanup(); try? FileManager.default.removeItem(at: dir) }
        try store.mutate { $0.athanVolume = 3 }
        #expect(store.settings.athanVolume == 1)
        try store.mutate { $0.athanVolume = -1 }
        #expect(store.settings.athanVolume == 0)
        try store.mutate { $0.athanVolume = .nan }
        #expect(store.settings.athanVolume == Settings.defaults.athanVolume)
    }

    @Test func invalidValuesAreRejectedAndNothingChanges() throws {
        let (store, h, dir) = make(); defer { h.cleanup(); try? FileManager.default.removeItem(at: dir) }
        let before = store.settings
        #expect(throws: SettingsValidationError.invalidCoordinates) { try store.mutate { $0.latitude = 91 } }
        #expect(throws: SettingsValidationError.invalidCoordinates) { try store.mutate { $0.longitude = .nan } }
        #expect(throws: SettingsValidationError.unknownMethod) { try store.mutate { $0.method = "bogus" } }
        #expect(throws: SettingsValidationError.unknownMadhab) { try store.mutate { $0.madhab = 7 } }
        #expect(throws: SettingsValidationError.unknownHighLatitudeRule) { try store.mutate { $0.highLatitudeRule = "x" } }
        #expect(store.settings == before)
    }

    @Test func defaultsAreValidAndBlockNothing() throws {
        try Settings.defaults.validate()
        #expect(Settings.defaults.setupComplete == false)
        #expect(Settings.defaults.lockMinutes == LockPolicy.defaultMinutes)
        #expect(Settings.defaults.mode == .wholeScreen)
        #expect(Settings.defaults.pausedUntil == nil)
    }

    // MARK: pause

    @Test func pauseOptionsMakeTheRightDates() throws {
        let (store, h, dir) = make(); defer { h.cleanup(); try? FileManager.default.removeItem(at: dir) }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let now = FakeSchedule.day0.addingTimeInterval(9 * 3600)
        let expected: [(PauseOption, Date)] = [
            (.oneDay, now.addingTimeInterval(1 * 86_400)), (.threeDays, now.addingTimeInterval(3 * 86_400)),
            (.oneWeek, now.addingTimeInterval(7 * 86_400)), (.untilResumed, .distantFuture),
        ]
        #expect(PauseOption.allCases.count == 4)
        for (option, until) in expected {
            try store.pause(option, now: now, calendar: cal)
            #expect(store.settings.pausedUntil == until, "\(option)")
            #expect(store.settings.isPaused(at: now))
        }
    }

    @Test func pauseSurvivesARestartAndResumeEndsIt() throws {
        let (store, h, dir) = make(); defer { h.cleanup(); try? FileManager.default.removeItem(at: dir) }
        let now = h.clock.now
        try store.pause(.untilResumed, now: now)
        #expect(SettingsStore(directory: dir).settings.pausedUntil == .distantFuture)
        try store.resume(now: now.addingTimeInterval(60))
        #expect(store.settings.pausedUntil == now.addingTimeInterval(60))
        #expect(!store.settings.isPaused(at: now.addingTimeInterval(61)))
    }

    @Test func pauseCallsTheSchedulerHook() throws {
        let (store, h, dir) = make(); defer { h.cleanup(); try? FileManager.default.removeItem(at: dir) }
        var calls = 0
        store.onChange = { _ in calls += 1 }
        try store.pause(.oneDay, now: h.clock.now)
        try store.resume(now: h.clock.now)
        try store.resume(now: h.clock.now)                  // already resumed: no-op
        #expect(calls == 2)
    }

    // MARK: voices and labels

    @Test func theVoicePickerHasThe28Voices() {
        #expect(VoiceChoices.sunni.count == 16)
        #expect(VoiceChoices.shia.count == 12)
        #expect(Set(VoiceChoices.all.map(\.voice)).count == 28)
        #expect(VoiceChoices.all.contains { $0.voice == VoiceChoices.defaultVoice })
        #expect(VoiceChoices.fajrNote.contains("Sheikh Hamed"))
    }

    @Test func suggestedMethodsFollowTheCountry() {
        #expect(CalculationMethod.suggested(forCountryCode: "CA") == .northAmerica)
        #expect(CalculationMethod.suggested(forCountryCode: "sa") == .ummAlQura)
        #expect(CalculationMethod.suggested(forCountryCode: "EG") == .egyptian)
        #expect(CalculationMethod.suggested(forCountryCode: nil) == .muslimWorldLeague)
        #expect(CalculationMethod.choices.count == 12)
        #expect(CalculationMethod.choices.allSatisfy { !$0.displayName.isEmpty && !$0.detail.isEmpty })
    }

    @Test func coordinateInputParses() {
        #expect(CoordinateInput.parse("43.65, -79.38")?.latitude == 43.65)
        #expect(CoordinateInput.parse("43.65 -79.38")?.longitude == -79.38)
        #expect(CoordinateInput.parse("91, 0") == nil)
        #expect(CoordinateInput.parse("hello") == nil)
        #expect(CoordinateInput.parse("1,2,3") == nil)
    }
}
