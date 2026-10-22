// UIFakes.swift — lane A test doubles and one fixture for the UI tests. Beside the
// core fakes (Core/Fakes.swift), not in them.

import Foundation
@testable import GoPray

struct FakeNetworkError: Error {}

@MainActor final class FakeGeocoder: CityGeocoding {
    var calls: [String] = []
    var results: [CityMatch] = []
    var failure: Error?
    /// true: never answers (until cancelled). For the skeleton state.
    var hang = false

    func search(_ text: String) async throws -> [CityMatch] {
        calls.append(text)
        if hang { try await Task.sleep(for: .seconds(30)) }
        if let failure { throw failure }
        return results
    }
}

@MainActor final class FakeLoginAgent: LoginAgentManaging {
    var isRegistered = false
    var registerCalls = 0
    var unregisterCalls = 0
    var failure: Error?

    func register() throws { registerCalls += 1; if let failure { throw failure }; isRegistered = true }
    func unregister() throws { unregisterCalls += 1; if let failure { throw failure }; isRegistered = false }
}

extension CityMatch {
    static let toronto = CityMatch(name: "Toronto", region: "Ontario", country: "Canada", countryCode: "CA",
                                   latitude: 43.6532, longitude: -79.3832)
    static let cairo = CityMatch(name: "Cairo", region: "Cairo Governorate", country: "Egypt", countryCode: "EG",
                                 latitude: 30.0444, longitude: 31.2357)
    static let torontoOhio = CityMatch(name: "Toronto", region: "Ohio", country: "United States", countryCode: "US",
                                       latitude: 40.4642, longitude: -80.6009)
}

/// Everything the three screens need, over a temp directory. The gate runs on the core
/// fakes (its own FakeSchedule); the screens read the REAL `PrayerSchedule` for Toronto.
@MainActor final class UIFixture {
    static let zone = TimeZone(identifier: "America/Toronto")!
    static var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = zone; return c }
    /// 2026-10-22 14:10 in Toronto: after Dhuhr, before Asr.
    static let afternoon = calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 14, minute: 10))!

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gopray-ui-\(UUID().uuidString)", isDirectory: true)
    let harness: Harness
    let store: SettingsStore
    let schedule: PrayerSchedule
    let geocoder = FakeGeocoder()
    let login = FakeLoginAgent()

    var gate: BlockGate { harness.gate }
    var clock: FakeClock { harness.clock }
    var audio: FakeAudio { harness.audio }

    /// `configured: true` = setup done, Toronto, ISNA.
    init(configured: Bool = true, at now: Date = UIFixture.afternoon) {
        harness = Harness(at: now)
        let store = SettingsStore(directory: dir)
        store.attach(harness.gate)
        self.store = store
        let cal = Self.calendar
        schedule = PrayerSchedule(settings: { store.settings }, calendar: { cal })
        if configured {
            try? store.mutate {
                $0.city = "Toronto, Ontario"; $0.latitude = 43.6532; $0.longitude = -79.3832
                $0.method = "northAmerica"; $0.madhab = 1; $0.setupComplete = true
            }
        }
    }

    func cleanup() { harness.cleanup(); try? FileManager.default.removeItem(at: dir) }

    func settingsModel() -> SettingsViewModel {
        SettingsViewModel(store: store, gate: gate, clock: clock, audio: audio, loginAgent: login, geocoder: geocoder)
    }

    func setupModel() -> SetupViewModel {
        SetupViewModel(store: store, schedule: schedule, clock: clock, audio: audio, loginAgent: login,
                       geocoder: geocoder, gate: gate)
    }

    func menuModel() -> MenuViewModel {
        MenuViewModel(store: store, gate: gate, schedule: schedule, clock: clock, calendar: { Self.calendar })
    }

    /// Start a real block on the gate (its own fake schedule's Asr).
    func startBlock() {
        let asr = FakeSchedule.at(.asr)
        clock.now = asr
        gate.athanFired(.asr, at: asr)
    }
}
