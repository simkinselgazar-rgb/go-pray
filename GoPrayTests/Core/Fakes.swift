// Fakes.swift — recording fakes of the lane protocols for unit tests. Owner: PM.
// Lanes may reuse these in their own tests; do not edit, add your own beside them.

import Foundation
@testable import GoPray

/// A fixed timetable, the same every UTC day:
/// Fajr 05:00, sunrise 06:30, Dhuhr 12:00, Asr 15:30, Maghrib 18:00, Isha 19:30.
@MainActor final class FakeSchedule: PrayerScheduleProviding {
    static let day0 = ISO8601DateFormatter().date(from: "2026-10-22T00:00:00Z")!
    static let offsets: [(Prayer, TimeInterval)] = [
        (.fajr, 5 * 3600), (.dhuhr, 12 * 3600), (.asr, 15.5 * 3600), (.maghrib, 18 * 3600), (.isha, 19.5 * 3600),
    ]
    static let sunriseOffset: TimeInterval = 6.5 * 3600

    /// false → every call returns nil (bad lat/lon, library error).
    var valid = true

    static func at(_ prayer: Prayer, day: Int = 0) -> Date {
        let off = offsets.first { $0.0 == prayer }!.1
        return day0.addingTimeInterval(TimeInterval(day) * 86_400 + off)
    }
    static func sunrise(day: Int = 0) -> Date { day0.addingTimeInterval(TimeInterval(day) * 86_400 + sunriseOffset) }

    private func athans() -> [(Prayer, Date)] {
        (-2...3).flatMap { d in Self.offsets.map { ($0.0, Self.at($0.0, day: d)) } }.sorted { $0.1 < $1.1 }
    }

    func times(on day: Date) -> DayTimes? {
        guard valid else { return nil }
        let d = Int((day.timeIntervalSince(Self.day0) / 86_400).rounded(.down))
        return DayTimes(fajr: Self.at(.fajr, day: d), sunrise: Self.sunrise(day: d), dhuhr: Self.at(.dhuhr, day: d),
                        asr: Self.at(.asr, day: d), maghrib: Self.at(.maghrib, day: d), isha: Self.at(.isha, day: d))
    }

    func window(containing t: Date) -> PrayerWindow? {
        guard valid else { return nil }
        let all = athans()
        guard let i = all.lastIndex(where: { $0.1 <= t }), i + 1 < all.count else { return nil }
        let (p, at) = all[i]
        let d = Int((at.timeIntervalSince(Self.day0) / 86_400).rounded(.down))
        let end = p == .fajr ? Self.sunrise(day: d) : all[i + 1].1
        return PrayerWindow(prayer: p, athan: at, end: end)
    }

    func nextAthan(after t: Date) -> (prayer: Prayer, at: Date)? {
        guard valid else { return nil }
        return athans().first { $0.1 > t }.map { (prayer: $0.0, at: $0.1) }
    }
}

@MainActor final class FakeShield: ShieldPresenting {
    weak var delegate: ShieldDelegate?
    var shows: [ShieldContext] = []
    var updates: [ShieldContext] = []
    var dismissCount = 0
    var dismissKinds: [EndKind] = []
    var tearDownCount = 0
    /// true: dismiss completes at once. false: held in `pendingDismiss`.
    var autoCompleteDismiss = true
    var pendingDismiss: (() -> Void)?

    func show(_ ctx: ShieldContext) { shows.append(ctx) }
    func update(_ ctx: ShieldContext) { updates.append(ctx) }
    func dismiss(kind: EndKind, thenIdle: @escaping () -> Void) {
        dismissCount += 1
        dismissKinds.append(kind)
        if autoCompleteDismiss { thenIdle() } else { pendingDismiss = thenIdle }
    }
    func tearDown() { tearDownCount += 1 }
}

struct FakeAudioError: Error {}

@MainActor final class FakeAudio: AthanPlaying {
    var isPlaying = false
    var onFinished: (() -> Void)?
    var plays: [(Prayer, Voice, Float)] = []
    var stopCount = 0
    var throwOnPlay = false
    var remaining = 0

    func play(prayer: Prayer, voice: Voice, volume: Float) throws {
        if throwOnPlay { throw FakeAudioError() }
        plays.append((prayer, voice, volume))
        isPlaying = true
        remaining = 180_000
    }
    func stop() { stopCount += 1; isPlaying = false; remaining = 0 }
    func remainingMs() -> Int { remaining }
    func finish() { isPlaying = false; remaining = 0; onFinished?() }
}

@MainActor final class FakeHider: AppHiding {
    var onReHide: ((String) -> Void)?
    var startCount = 0
    var stopCount = 0
    /// Every set passed to `start(hiding:)`.
    var started: [Set<String>] = []
    func start(hiding ids: Set<String>) { startCount += 1; started.append(ids) }
    func stop() { stopCount += 1 }
}

extension Settings {
    static func test(mode: BlockMode = .wholeScreen, setupComplete: Bool = true,
                     lockMinutes: Int = LockPolicy.defaultMinutes, pausedUntil: Date? = nil,
                     emergencyExitsEnabled: Bool = true) -> Settings {
        Settings(city: "Testville", latitude: 40.7, longitude: -74.0, method: "moonsightingCommittee", madhab: 1,
                 highLatitudeRule: nil, mode: mode, voice: .sunni("test-voice"), athanVolume: 0.8,
                 launchAtLogin: false, setupComplete: setupComplete, reduceMotion: false,
                 lockMinutes: lockMinutes, pausedUntil: pausedUntil, emergencyExitsEnabled: emergencyExitsEnabled)
    }
}

/// One gate + its fakes over a temp state directory. `relaunch()` builds a new
/// gate from the same directory, like a crash + KeepAlive restart.
@MainActor final class Harness {
    let dir: URL
    let clock: FakeClock
    let schedule = FakeSchedule()
    var settings: Settings
    var shield = FakeShield()
    var audio = FakeAudio()
    var hider = FakeHider()
    /// The compiled-in defaults the gate computes the effective list from.
    var defaultApps: Set<String> = ["app.one", "app.two"]
    var mirror = FakeLedgerMirror()
    var tv = FakeTV()
    var gate: BlockGate!

    init(at start: Date, settings: Settings = .test(), dir: URL? = nil) {
        self.dir = dir ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("gopray-tests-\(UUID().uuidString)", isDirectory: true)
        self.clock = FakeClock(start)
        self.settings = settings
        makeGate()
    }

    func makeGate() {
        gate = BlockGate(clock: clock, store: StateStore(directory: dir), schedule: schedule, shield: shield,
                         audio: audio, hider: hider,
                         ledger: EmergencyLedger(directory: dir, mirror: mirror, calendar: Self.calendar),
                         defaultApps: defaultApps, tv: tv, settings: { [unowned self] in self.settings },
                         leavingTimeout: .milliseconds(200),
                         systemReduceMotion: { false })
    }

    /// New process: fresh fakes, same file on disk, then the launch re-evaluation.
    func relaunch() {
        shield = FakeShield(); audio = FakeAudio(); hider = FakeHider(); tv = FakeTV()
        makeGate()
        gate.reevaluate(.launch)
    }

    /// UTC, so "this calendar year" is the same on every machine.
    static var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    var ledger: EmergencyLedger { EmergencyLedger(directory: dir, mirror: mirror, calendar: Self.calendar) }
    var emergencyURL: URL { dir.appendingPathComponent("emergency.json") }

    var stateURL: URL { dir.appendingPathComponent("state.json") }

    func diskState() throws -> BlockStateFile {
        try BlockStateFile.makeDecoder().decode(BlockStateFile.self, from: Data(contentsOf: stateURL))
    }

    func corruptFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("state.corrupt-") }
    }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

/// The prefs mirror, in memory; survives `relaunch()` like the real prefs plist does.
final class FakeLedgerMirror: EmergencyMirror {
    var usedJSON: String?
}

/// Records what the gate asked the TVs to do. No network.
final class FakeTV: TVSending, @unchecked Sendable {
    struct Call: Equatable { var prayer: Prayer; var voice: Voice; var tvs: [TVDevice] }
    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] { lock.withLock { _calls } }
    func athanStarted(prayer: Prayer, voice: Voice, tvs: [TVDevice]) { lock.withLock { _calls.append(.init(prayer: prayer, voice: voice, tvs: tvs)) } }
    func resolve(_ tv: TVDevice) async -> TVResolution { .unreachable }
    func test(_ tv: TVDevice, prayer: Prayer, voice: Voice) async throws {}
}
