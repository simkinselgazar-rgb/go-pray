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
    /// v2 (CONTRACT-NOTES #50). Exits left this year; 0 = the page draws no button (none left,
    /// or the person turned exits off for this block).
    var emergencyExitsLeft: Int = 0
}

/// How a block ends. `confirmed` = "I prayed" (after the lock). `emergency` = one of the
/// yearly exits: recorded as dropped, never as confirmed, and no "May Allah accept it."
enum EndKind: Sendable { case confirmed, emergency }

@MainActor protocol ShieldDelegate: AnyObject {
    func shieldDidRequestConfirm()   // → gate.requestConfirm(); the shield never ends itself
    func shieldDidRequestSilence()
    func shieldDidRequestEmergencyExit()   // → gate.requestEmergencyExit(); refused → shield.update(ctx)
}

@MainActor protocol ShieldPresenting: AnyObject {
    var delegate: ShieldDelegate? { get set }
    func show(_ ctx: ShieldContext)          // idempotent; panels per screen
    func update(_ ctx: ShieldContext)        // remaining/athan changes; re-sync the page
    /// `.confirmed` plays "May Allah accept it." (≈1.3 s); `.emergency` is a plain fade. Then closes everything.
    func dismiss(kind: EndKind, thenIdle: @escaping () -> Void)
    func tearDown()                          // immediate, no animation (overlap, fail-open)
}

extension ShieldPresenting {
    func dismiss(thenIdle: @escaping () -> Void) { dismiss(kind: .confirmed, thenIdle: thenIdle) }
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
    /// v2 (CONTRACT-NOTES #49): the gate passes the set it captured at block start, never the settings.
    func start(hiding ids: Set<String>)   // hide those running apps, observe launch/activate
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
    /// v2 (CONTRACT-NOTES #49). Ids from the compiled-in defaults the user turned off. May hold
    /// ids of both platforms (one file works on both machines). Absent in old files → [].
    var disabledDefaultApps: [String] = []
    /// v2. User-added apps, both platforms kept; only `BlockedApps.current` ones apply. Absent → [].
    var customApps: [CustomApp] = []
    /// v2 (PM amendment §9.2). "Allow emergency exits". Absent → true. Captured into state.block.
    var emergencyExitsEnabled: Bool = true
    /// v2 (§8). "Check for updates automatically". Absent → true.
    var checkForUpdates: Bool = true
    /// TV control (CONTRACT-NOTES #56). Roku TVs the Athan also starts on. Absent → []. One bad entry is dropped, not fatal.
    var tvs: [TVDevice] = []
}

extension Settings {
    /// Old files lack the v2 keys: they decode as the defaults above.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        city = try c.decode(String.self, forKey: .city)
        latitude = try c.decode(Double.self, forKey: .latitude)
        longitude = try c.decode(Double.self, forKey: .longitude)
        method = try c.decode(String.self, forKey: .method)
        madhab = try c.decode(Int.self, forKey: .madhab)
        highLatitudeRule = try c.decodeIfPresent(String.self, forKey: .highLatitudeRule)
        mode = try c.decode(BlockMode.self, forKey: .mode)
        voice = try c.decode(Voice.self, forKey: .voice)
        athanVolume = try c.decode(Float.self, forKey: .athanVolume)
        launchAtLogin = try c.decode(Bool.self, forKey: .launchAtLogin)
        setupComplete = try c.decode(Bool.self, forKey: .setupComplete)
        reduceMotion = try c.decodeIfPresent(Bool.self, forKey: .reduceMotion)
        lockMinutes = try c.decode(Int.self, forKey: .lockMinutes)
        pausedUntil = try c.decodeIfPresent(Date.self, forKey: .pausedUntil)
        disabledDefaultApps = try c.decodeIfPresent([String].self, forKey: .disabledDefaultApps) ?? []
        customApps = try c.decodeIfPresent([CustomApp].self, forKey: .customApps) ?? []
        emergencyExitsEnabled = try c.decodeIfPresent(Bool.self, forKey: .emergencyExitsEnabled) ?? true
        checkForUpdates = try c.decodeIfPresent(Bool.self, forKey: .checkForUpdates) ?? true
        tvs = (try? c.decodeIfPresent([Lossy<TVDevice>].self, forKey: .tvs))?.compactMap(\.value) ?? []
    }
}

/// Decodes one element or nil, so a bad entry never makes the whole settings file unreadable.
private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

// MARK: - Blocked apps (v2, CONTRACT-NOTES #49)

enum AppPlatform: String, Codable, Sendable { case mac, windows }

struct CustomApp: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var platform: AppPlatform
}

enum BlockedApps {
    static let current: AppPlatform = .mac
    static let maxCustom = 50, maxDisabled = 200, maxIDLength = 200, maxNameLength = 60
    /// What the gate honours when it reads `hiddenApps` back from disk.
    static let maxCaptured = 200

    /// Never hidden, whatever the list says: Go Pray itself, the shell, and the user's
    /// Force Quit / settings routes. Applied in `Settings.sanitized()`, in the gate when it
    /// reads state.json, and again in the hider as the last line of defence.
    static let neverBlock: Set<String> = [
        "com.ahmedelgazar.gopray", "com.apple.finder", "com.apple.dock", "com.apple.systemuiserver",
        "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.Spotlight",
        "com.apple.loginwindow", "com.apple.systempreferences", "com.apple.WindowManager",
        "com.apple.ActivityMonitor",
    ]

    /// Mac: the exact bundle id, trimmed.
    static func normalize(_ id: String) -> String { id.trimmingCharacters(in: .whitespacesAndNewlines) }

    static func isBlockable(_ id: String) -> Bool {
        let n = normalize(id)
        return !n.isEmpty && !neverBlock.contains(n)
    }

    /// The one place the list is computed: (defaults − disabled) ∪ custom(this platform), minus
    /// `neverBlock`. `defaults` is injected (Core never imports Blocker).
    static func effective(_ s: Settings, defaults: Set<String>) -> Set<String> {
        let off = Set(s.disabledDefaultApps.map(normalize))
        let on = defaults.map(normalize).filter { !off.contains($0) }
        let mine = s.customApps.filter { $0.platform == current }.map { normalize($0.id) }
        return Set(on + mine).filter(isBlockable)
    }

    /// A captured list read back from state.json: denylisted ids and anything past the cap are dropped.
    static func sanitizeCaptured(_ ids: [String]) -> Set<String> {
        Set(ids.prefix(maxCaptured * 4).map(normalize).filter(isBlockable).sorted().prefix(maxCaptured))
    }
}

// MARK: - Emergency exits (v2, CONTRACT-NOTES #51; PM amendment §9.1)

enum EmergencyExitPolicy {
    /// 5 per local calendar year. A use dated in the future still counts (fail safe).
    static let total = 5
    static var perYear: Int { total }
    static let period = "calendar year"
    static let holdSeconds: TimeInterval = 3
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
