// MenuViewModel.swift — everything the popover shows, as one plain value computed
// from (settings, schedule, gate, time). Owner: lane A. No views here, so the rules
// ("after Isha show tomorrow's list", "paused", "blocked") are unit-tested.

import Adhan
import Foundation
import Observation

struct MenuSnapshot: Equatable {
    struct Row: Equatable {
        let prayer: Prayer
        let time: Date
        let isNext: Bool
        let isPast: Bool
    }

    enum Status: Equatable {
        /// Setup not finished: "Add your city…" + Set up.
        case needsSetup
        /// Setup done but the schedule gave nothing (bad place, polar night).
        case noSchedule
        case ready
    }

    var status: Status
    var rows: [Row] = []
    var nextPrayer: Prayer?
    var untilNext: TimeInterval?
    /// During a block: the prayer and the line for the header ("6:12 left").
    var blockPrayer: Prayer?
    var blockLine: String?
    var pausedLine: String?
    var mode: BlockMode
    var footer: String
    var isBlocked: Bool
    /// "Emergency exits: 3 of 5 left this year"; nil while blocked.
    var exitsLine: String?
    /// The update row (v2 §8): nil when there is nothing to say.
    var update: UpdateLine?
    /// "Check for updates…" is disabled while blocked or while a check or download runs.
    var canCheckForUpdates = false
}

struct UpdateLine: Equatable {
    enum Action: Equatable { case none, download, getFromGitHub }
    var text: String
    var action: Action
}

extension EmergencyExitPolicy {
    /// The one wording, for the menu and Settings.
    static func line(left: Int) -> String {
        left <= 0 ? "Emergency exits: none left until 1 January" : "Emergency exits: \(left) of \(total) left this year"
    }
    static let offLine = "Emergency exits: off"
}

@MainActor final class MenuViewModel {
    let store: SettingsStore
    let gate: BlockGate
    let schedule: PrayerScheduleProviding
    let clock: Clock
    private let calendar: @MainActor () -> Calendar
    /// Set by the app wiring; nil in most tests.
    var updater: UpdateChecker?

    init(store: SettingsStore, gate: BlockGate, schedule: PrayerScheduleProviding, clock: Clock,
         calendar: @escaping @MainActor () -> Calendar = { Calendar.autoupdatingCurrent }) {
        self.store = store
        self.gate = gate
        self.schedule = schedule
        self.clock = clock
        self.calendar = calendar
    }

    func resume() { try? store.resume(now: clock.now) }

    func snapshot(at now: Date) -> MenuSnapshot {
        let s = store.settings
        var snap = MenuSnapshot(status: .ready, mode: s.mode, footer: footer(for: s), isBlocked: gate.isBlocked)
        snap.update = updater.flatMap(Self.updateLine)
        snap.canCheckForUpdates = updater != nil && !snap.isBlocked && ![.checking, .downloading].contains(updater?.status)
        guard s.setupComplete else { snap.status = .needsSetup; return snap }
        if !snap.isBlocked { snap.exitsLine = s.emergencyExitsEnabled ? EmergencyExitPolicy.line(left: gate.emergencyExitsLeft) : EmergencyExitPolicy.offLine }

        if s.isPaused(at: now), let until = s.pausedUntil {
            snap.pausedLine = until == .distantFuture ? "Paused until you resume" : "Paused until \(TimeText.day(until))"
        }
        if snap.isBlocked, let b = gate.currentBlock {
            snap.blockPrayer = b.prayer
            switch gate.phase {
            case .locked(let until): snap.blockLine = "\(TimeText.countdown(until.timeIntervalSince(now))) left"
            case .canConfirm: snap.blockLine = "Ready when you are"
            case .leaving: snap.blockLine = "May Allah accept it."
            case .idle: break
            }
        }

        guard let today = schedule.times(on: now), let next = schedule.nextAthan(after: now) else {
            snap.status = .noSchedule
            return snap
        }
        snap.nextPrayer = next.prayer
        snap.untilNext = next.at.timeIntervalSince(now)

        // After Isha the useful list is tomorrow's, headed by its Fajr.
        var day = today
        if now >= today.isha, let t = calendar().date(byAdding: .day, value: 1, to: now), let tomorrow = schedule.times(on: t) {
            day = tomorrow
        }
        snap.rows = day.prayers.map { p in
            MenuSnapshot.Row(prayer: p.prayer, time: p.at, isNext: p.prayer == next.prayer && p.at == next.at,
                             isPast: p.at <= now)
        }
        return snap
    }

    static func updateLine(_ u: UpdateChecker) -> UpdateLine? {
        switch u.status {
        case .idle: return nil
        case .checking: return UpdateLine(text: "Checking…", action: .none)
        case .upToDate: return UpdateLine(text: "You're up to date.", action: .none)
        case .downloading: return UpdateLine(text: "Downloading…", action: .none)
        case .available(let v):
            return u.isHomebrewInstall ? UpdateLine(text: "Update available: \(v). \(UpdateChecker.brewLine)", action: .none)
                                       : UpdateLine(text: "Update available: \(v)", action: .download)
        case .failed(let msg):
            return UpdateLine(text: msg, action: msg == UpdateChecker.couldntVerify ? .getFromGitHub : .none)
        }
    }

    /// "Toronto · ISNA · Standard"
    private func footer(for s: Settings) -> String {
        guard s.setupComplete else { return "" }
        let city = s.city.split(separator: ",").first.map(String.init) ?? s.city
        let method = s.calculationMethod?.shortName ?? "Custom"
        let asr = s.asrMadhab?.displayName ?? ""
        return [city, method, asr].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
