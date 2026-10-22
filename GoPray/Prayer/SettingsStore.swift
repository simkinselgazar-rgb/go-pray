// SettingsStore.swift — settings.json on disk, and the ONE door for changing settings.
// Owner: lane A (CONTRACT-NOTES #3, #5, #14, #26, #27).
//
// Every change goes through `mutate`, and `mutate` asks the gate first
// (`authorizeSettingsChange()`: throws `SettingsError.blocked` during a block). That
// covers mode, break length, pause and resume too. With no gate attached the store
// refuses everything (fail closed): a wiring slip can never open a hole in a block.
//
// Wiring (PM, in GoPrayApp.swift):
//   let store = SettingsStore()                       // loads settings.json
//   let gate = BlockGate(..., settings: { store.settings })
//   store.attach(gate)
//   store.onChange = { _ in scheduler.handle(.settingsChanged) }

import Foundation
import Observation
import os

/// What the store needs from the gate. `BlockGate` conforms (below).
@MainActor protocol SettingsChangeAuthorizing: AnyObject {
    func authorizeSettingsChange() throws
}

extension BlockGate: SettingsChangeAuthorizing {}

@MainActor @Observable final class SettingsStore {
    private(set) var settings: Settings
    /// True when settings.json could not be read and was set aside (the app starts fresh).
    private(set) var loadedFromCorruptFile = false
    /// True if the last write to disk failed. The change is still live in memory.
    private(set) var lastSaveFailed = false

    /// Called after a change was applied and saved. Wire to `scheduler.handle(.settingsChanged)`.
    @ObservationIgnored var onChange: (@MainActor (Settings) -> Void)?

    @ObservationIgnored private weak var gate: SettingsChangeAuthorizing?
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let log = Logger(subsystem: "com.ahmedelgazar.gopray", category: "settings")

    var fileURL: URL { directory.appendingPathComponent("settings.json") }

    init(directory: URL = StateStore.defaultDirectory()) {
        self.directory = directory
        self.settings = .defaults
        self.settings = load()
    }

    func attach(_ gate: SettingsChangeAuthorizing) { self.gate = gate }

    // MARK: Changing settings

    /// Ask the gate whether a change is allowed right now. Throws `SettingsError.blocked`
    /// during a block, and also when no gate is attached. Call it before any side effect
    /// that belongs to a setting (e.g. registering the login agent).
    func authorize() throws {
        guard let gate else { throw SettingsError.blocked }
        try gate.authorizeSettingsChange()
    }

    /// Apply `change`, clamp what has a range, reject what is invalid, save, notify.
    /// The gate is asked first, so a refused change never runs `change` at all.
    func mutate(_ change: (inout Settings) -> Void) throws {
        try authorize()
        var next = settings
        change(&next)
        next = next.sanitized()
        try next.validate()
        guard next != settings else { return }
        settings = next
        save()
        onChange?(next)
    }

    /// Pause (1 day / 3 days / 1 week / until resumed). Only between prayers.
    func pause(_ option: PauseOption, now: Date, calendar: Calendar = .autoupdatingCurrent) throws {
        let until = option.until(from: now, calendar: calendar)
        try mutate { $0.pausedUntil = until }
    }

    /// Resume now (CONTRACT-NOTES #27: set `pausedUntil` to now). Only between prayers.
    func resume(now: Date) throws {
        guard settings.pausedUntil != nil else { return }
        try mutate { $0.pausedUntil = now }
    }

    // MARK: Disk

    private func load() -> Settings {
        guard let data = try? Data(contentsOf: fileURL) else { return .defaults }   // first run
        do {
            let s = try Self.decoder.decode(Settings.self, from: data).sanitized()
            try s.validate()
            return s
        } catch {
            // Keep the unreadable file for inspection and start fresh. Fresh = setup not
            // complete = nothing blocks until the person sets up again.
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = directory.appendingPathComponent("settings.corrupt-\(stamp).json")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            loadedFromCorruptFile = true
            log.error("settings.json unreadable, set aside: \(String(describing: error), privacy: .public)")
            return .defaults
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.encoder.encode(settings).write(to: fileURL, options: .atomic)
            lastSaveFailed = false
        } catch {
            lastSaveFailed = true
            log.error("settings.json save failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
