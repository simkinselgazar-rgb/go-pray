// EmergencyLedger.swift — the count of emergency exits (v2, CONTRACT-NOTES #51). Owner: PM.
// The ONLY file that names emergency.json or the mirror's prefs keys (guard.sh rule 12).
//
// 5 exits per local calendar year (PM amendment, plan §9.1). Remaining = 5 − counted, where counted = uses
// dated in the current local calendar year plus every use dated after now (a clock moved back still counts).
// The uses live in two places, each holding the same used[] JSON, so deleting one is not a casual poke;
// the stores are counted separately and the LARGER count wins (never the sum):
//   - emergency.json in the support folder.
//   - the mirror (Mac: prefs string EmergencyExitsUsed).
// Fail safe, never trap: an unreadable or impossible store → 0 left (the block still ends after its lock).
// Moving the clock into next year refills while it is forward; set back, those uses count again (SEC table).

import Foundation
import os

protocol EmergencyMirror: AnyObject {
    /// The same used[] JSON as emergency.json, or nil when never written.
    var usedJSON: String? { get set }
}

/// Mac mirror: the app's prefs plist, one string.
final class UserDefaultsMirror: EmergencyMirror {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var usedJSON: String? {
        get { defaults.string(forKey: "EmergencyExitsUsed") }
        set { defaults.set(newValue, forKey: "EmergencyExitsUsed") }
    }
}

/// Held in memory only: the default in a DEBUG test host, so a test run never writes the real prefs.
final class InMemoryMirror: EmergencyMirror {
    var usedJSON: String?
}

@MainActor final class EmergencyLedger {
    struct Use: Codable, Equatable, Sendable { var prayer: Prayer; var athanAt: Date; var at: Date }
    struct File: Codable, Equatable, Sendable {
        var schemaVersion = 1
        var used: [Use] = []
    }

    /// More uses than this in a store can only be tampering: treated as unreadable. (History from earlier
    /// years stays in the file; 5 a year takes 200 years to reach this.)
    static let maxUses = 1000

    private let directory: URL
    private let mirror: EmergencyMirror
    private let calendar: Calendar
    private let log = Logger(subsystem: "com.ahmedelgazar.gopray", category: "emergency")

    var fileURL: URL { directory.appendingPathComponent("emergency.json") }

    init(directory: URL = StateStore.defaultDirectory(), mirror: EmergencyMirror = EmergencyLedger.defaultMirror(),
         calendar: Calendar = .autoupdatingCurrent) {
        self.directory = directory
        self.mirror = mirror
        self.calendar = calendar
    }

    nonisolated static func defaultMirror() -> EmergencyMirror {
        #if DEBUG
        if TestHost.isActive { return InMemoryMirror() }
        #endif
        return UserDefaultsMirror()
    }

    // MARK: Reading (recomputed on every call; nothing is cached across launches)

    /// Exits left this calendar year, 0…5.
    func remaining(at now: Date) -> Int {
        guard let used = usedThisYear(at: now) else { return 0 }
        return min(max(EmergencyExitPolicy.total - used, 0), EmergencyExitPolicy.total)
    }

    /// nil = a store cannot be trusted (0 left).
    private func usedThisYear(at now: Date) -> Int? {
        guard let file = readFile(), let mirrored = readMirror() else { return nil }
        return max(count(file, at: now), count(mirrored, at: now))
    }

    /// Uses in this local calendar year, plus every use dated after `now`.
    private func count(_ f: File, at now: Date) -> Int {
        let year = calendar.component(.year, from: now)
        return f.used.filter { calendar.component(.year, from: $0.at) == year || $0.at > now }.count
    }

    /// An empty file when none exists; nil when it exists but cannot be trusted.
    private func readFile() -> File? {
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch let e as CocoaError where e.code == .fileReadNoSuchFile { return File() }
        catch { log.error("emergency.json unreadable"); return nil }
        return parse(data)
    }

    private func readMirror() -> File? {
        guard let text = mirror.usedJSON else { return File() }
        return parse(Data(text.utf8))
    }

    private func parse(_ data: Data) -> File? {
        guard let file = try? Self.decoder.decode(File.self, from: data),
              file.schemaVersion == 1, file.used.count <= Self.maxUses else {
            log.error("an emergency store does not decode or is impossible")
            return nil
        }
        return file
    }

    // MARK: Writing

    /// Writes the file atomically FIRST, then the mirror. Throws → the caller refuses the exit.
    func recordUse(_ use: Use, now: Date) throws {
        guard var file = readFile(), var mirrored = readMirror() else { throw CocoaError(.fileReadCorruptFile) }
        file.used.append(use)
        try write(file)
        mirrored.used.append(use)
        mirror.usedJSON = String(data: try Self.encoder.encode(mirrored), encoding: .utf8)
    }

    private func write(_ file: File) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Self.encoder.encode(file).write(to: fileURL, options: .atomic)
    }

    #if DEBUG
    /// Debug menu and tests only: pretend `n` exits were used today.
    func debugSetEmergencyExitsUsed(_ n: Int, now: Date) {
        let f = File(used: (0..<max(n, 0)).map { _ in Use(prayer: .dhuhr, athanAt: now, at: now) })
        try? write(f)
        mirror.usedJSON = (try? Self.encoder.encode(f)).flatMap { String(data: $0, encoding: .utf8) }
    }
    #endif

    // MARK: JSON (ISO 8601 with fractional seconds, same bytes as state.json)

    private static let encoder: JSONEncoder = BlockStateFile.makeEncoder()
    private static let decoder = BlockStateFile.makeDecoder()
}
