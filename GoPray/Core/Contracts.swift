// Contracts.swift — every type and protocol shared between lanes.
// Owner: PM. Source: Architecture Plan "Final plan (2026-10-22)" §C.1 and §C.5.
// Nobody else edits this file. A change is a PM amendment, broadcast to all
// lanes, and recorded in CONTRACT-NOTES.md at the repo root.

import Foundation

// MARK: - Prayer + windows

/// Our five prayers. Note: adhan-swift also exports a `Prayer` (with `.sunrise`).
/// Inside this module `Prayer` means this enum; write `Adhan.Prayer` for theirs.
enum Prayer: String, Codable, CaseIterable, Sendable { case fajr, dhuhr, asr, maghrib, isha }

enum BlockMode: String, Codable, Sendable { case wholeScreen, codingApps }

struct DayTimes: Sendable { let fajr, sunrise, dhuhr, asr, maghrib, isha: Date }

/// `end` = the next Athan; for Fajr, sunrise.
struct PrayerWindow: Equatable, Sendable { let prayer: Prayer; let athan: Date; let end: Date }

protocol Clock: Sendable { var now: Date { get } }

/// Lane A. Amendment (CONTRACT-NOTES #1): `times` and `nextAthan` are optional.
/// `nil` means "no valid schedule" (bad lat/lon, library error). The gate and
/// scheduler then never block: bad schedule → no Athan → no block (§G).
@MainActor protocol PrayerScheduleProviding: AnyObject {
    func times(on day: Date) -> DayTimes?
    func window(containing t: Date) -> PrayerWindow?       // nil only before today's Fajr with yesterday's Isha closed, or no valid schedule
    func nextAthan(after t: Date) -> (prayer: Prayer, at: Date)?
}

// MARK: - Shield (lane B)

struct ShieldContext: Equatable, Sendable {
    var prayer: Prayer; var mode: BlockMode
    var remainingMs: Int            // ms until canConfirm, 0 when open
    var athanRemainingMs: Int       // 0 when not playing
    var reduceMotion: Bool
    var hiddenAppName: String?      // coding-apps mode: "Cursor is resting…"
    /// Amendment (CONTRACT-NOTES #31): lets the page draw the ring at its true progress after a
    /// relaunch or resync. `lockSeconds == 0` means "unknown": the ring then spans `remainingMs`.
    var blockStartedAt: Date? = nil
    var lockSeconds: Int = 0
}

@MainActor protocol ShieldDelegate: AnyObject {
    func shieldDidRequestConfirm()   // → gate.requestConfirm(); the shield never ends itself
    func shieldDidRequestSilence()
}

@MainActor protocol ShieldPresenting: AnyObject {
    var delegate: ShieldDelegate? { get set }
    func show(_ ctx: ShieldContext)          // idempotent; panels per screen
    func update(_ ctx: ShieldContext)        // remaining/athan changes; re-sync the page
    func dismiss(thenIdle: @escaping () -> Void)   // plays "May Allah accept it." (≈1.3 s) then closes everything
    func tearDown()                          // immediate, no animation (overlap, fail-open)
}

// MARK: - Audio (lane C)

/// File stem, validated against the bundle by lane C.
/// Amendment (CONTRACT-NOTES #2): also `Codable`, because `Settings.voice` is persisted.
enum Voice: Hashable, Codable, Sendable { case sunni(String), shia(String) }

@MainActor protocol AthanPlaying: AnyObject {
    var isPlaying: Bool { get }
    var onFinished: (() -> Void)? { get set }
    func play(prayer: Prayer, voice: Voice, volume: Float) throws   // Fajr ignores voice, uses the Fajr file from 9.0 s
    func stop()
    func remainingMs() -> Int
}

// MARK: - Coding-apps mode (lane D)

@MainActor protocol AppHiding: AnyObject {
    var onReHide: ((String) -> Void)? { get set }   // localized app name, for the notice copy
    func start()      // hide listed running apps, observe launch/activate
    func stop()
}

// MARK: - Login agent (lane C)

@MainActor protocol LoginAgentManaging: AnyObject {
    var isRegistered: Bool { get }
    func register() throws
    func unregister() throws
}

// MARK: - Gate re-evaluation

/// Amendment (CONTRACT-NOTES #26): `pauseEnded` = the scheduler's timer reached `Settings.pausedUntil`.
enum ReevalReason: Sendable { case launch, wake, clockChanged, timeZoneChanged, settingsChanged, midnight, pauseEnded }

// MARK: - Settings shape (§C.5)

/// The shape is the contract (fixed here so UI and gate agree).
/// Lane A owns defaults, validation and persistence in `Prayer/Settings.swift`
/// and `Prayer/SettingsStore.swift` as extensions; it does not add or rename
/// fields without a PM amendment (CONTRACT-NOTES #3).
/// adhan-swift enums are stored as their raw values so Core never imports Adhan:
/// `method` = `CalculationMethod.rawValue`, `madhab` = `Madhab.rawValue` (1 shafi, 2 hanafi),
/// `highLatitudeRule` = `HighLatitudeRule.rawValue`, nil = library `recommended(for:)`.
struct Settings: Codable, Equatable, Sendable {
    var city: String
    var latitude: Double
    var longitude: Double
    var method: String
    var madhab: Int
    var highLatitudeRule: String?
    var mode: BlockMode
    var voice: Voice
    var athanVolume: Float          // 0–1
    var launchAtLogin: Bool
    var setupComplete: Bool
    var reduceMotion: Bool?         // nil = follow the system
    /// Amendment (CONTRACT-NOTES #26). Clamped with `LockPolicy.clamp`. The gate
    /// copies the lock into state.json at block start; a later change never
    /// touches the running block.
    var lockMinutes: Int
    /// Amendment (CONTRACT-NOTES #27). nil = active. `.distantFuture` = until resumed.
    /// A date in the past = active again. Set it with `PauseOption.until(from:)`;
    /// to resume, set it to `now` (preferred) or nil.
    var pausedUntil: Date?
}

/// Lock length rules (Ahmed, 2026-10-22): 10–30 minutes, default 10.
enum LockPolicy {
    static let minMinutes = 10
    static let maxMinutes = 30
    static let defaultMinutes = 10
    static var maxSeconds: TimeInterval { TimeInterval(maxMinutes * 60) }

    static func clamp(_ minutes: Int) -> Int { min(max(minutes, minMinutes), maxMinutes) }
    static func seconds(forMinutes minutes: Int) -> TimeInterval { TimeInterval(clamp(minutes) * 60) }
}

/// Pause choices (Ahmed, 2026-10-22). Allowed only between prayers (no active block).
enum PauseOption: String, CaseIterable, Sendable {
    case oneDay, threeDays, oneWeek, untilResumed

    func until(from now: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        switch self {
        case .oneDay: return calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
        case .threeDays: return calendar.date(byAdding: .day, value: 3, to: now) ?? now.addingTimeInterval(3 * 86_400)
        case .oneWeek: return calendar.date(byAdding: .day, value: 7, to: now) ?? now.addingTimeInterval(7 * 86_400)
        case .untilResumed: return .distantFuture
        }
    }
}

extension Settings {
    /// True while a pause is running at `now`.
    func isPaused(at now: Date) -> Bool { (pausedUntil ?? .distantPast) > now }
}

enum SettingsError: Error, Equatable {
    case blocked                    // gate.allowsSettingsChange() == false
}
