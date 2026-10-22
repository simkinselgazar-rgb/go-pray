// Scheduler.swift — one timer + system notifications → the gate (§C.4). Owner: PM.
// One DispatchSourceTimer, armed for the next Athan or the next midnight,
// whichever is first. While paused it arms no Athan: only the pause end (or
// midnight, if that is sooner). Re-armed after it fires and on wake, clock, time zone
// and settings changes. No polling. Talks to the gate only through
// athanFired(_:at:) and reevaluate(_:).

import AppKit
import Foundation
import os

@MainActor final class Scheduler {
    struct Armed: Equatable {
        enum Kind: Equatable { case athan(Prayer), midnight, pauseEnds }
        let kind: Kind
        let at: Date
    }

    private let clock: Clock
    private let schedule: PrayerScheduleProviding
    private let gate: BlockGate
    private let settings: @MainActor () -> Settings
    private let calendar: @MainActor () -> Calendar
    private let log = Logger(subsystem: "com.ahmedelgazar.gopray", category: "scheduler")

    /// What the one timer is armed for; nil = not armed (setup incomplete, or stopped).
    private(set) var armed: Armed?
    private var timer: DispatchSourceTimer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(clock: Clock, schedule: PrayerScheduleProviding, gate: BlockGate,
         settings: @escaping @MainActor () -> Settings,
         calendar: @escaping @MainActor () -> Calendar = { Calendar.autoupdatingCurrent }) {
        self.clock = clock
        self.schedule = schedule
        self.gate = gate
        self.settings = settings
        self.calendar = calendar
    }

    /// Observe the system and arm. Call once after `gate.reevaluate(.launch)`.
    func start() {
        guard observers.isEmpty else { return }
        let ws = NSWorkspace.shared.notificationCenter
        let nc = NotificationCenter.default
        observe(ws, NSWorkspace.didWakeNotification, .wake)
        observe(nc, .NSSystemClockDidChange, .clockChanged)
        observe(nc, .NSSystemTimeZoneDidChange, .timeZoneChanged)
        rearm()
    }

    func stop() {
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        cancelTimer()
    }

    /// The single entry for system and settings events: let the gate apply its
    /// rules, then re-arm. SettingsStore's change hook calls this with `.settingsChanged`.
    func handle(_ reason: ReevalReason) {
        gate.reevaluate(reason)
        rearm()
    }

    /// Re-arm for the next Athan (or midnight) strictly after `after` (default: now).
    func rearm(after: Date? = nil) {
        cancelTimer()
        let s = settings()
        guard s.setupComplete else { return }               // setup incomplete → never armed
        let now = clock.now
        let from = max(now, after ?? now)
        guard let tomorrow = calendar().date(byAdding: .day, value: 1, to: calendar().startOfDay(for: from)) else { return }
        var target = Armed(kind: .midnight, at: tomorrow)
        if s.isPaused(at: from), let until = s.pausedUntil {
            // Paused: no Athan is armed. Wake at the pause end to re-arm.
            if until <= tomorrow { target = Armed(kind: .pauseEnds, at: until) }
        } else if let next = schedule.nextAthan(after: from), next.at > from, next.at <= tomorrow,
                  next.at.timeIntervalSince(from) <= 2 * 86_400 {
            // A schedule answer outside (from, 2 days] is treated as no schedule.
            target = Armed(kind: .athan(next.prayer), at: next.at)
        }
        armed = target
        let delay = max(0, target.at.timeIntervalSince(now))
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(wallDeadline: .now() + delay, leeway: .milliseconds(250))
        t.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.fire() } }
        t.resume()
        timer = t
        log.notice("armed \(String(describing: target.kind), privacy: .public) in \(Int(delay), privacy: .public) s")
    }

    /// The timer fired. Internal so tests can fire it without waiting.
    func fire() {
        guard let a = armed else { return }
        armed = nil
        switch a.kind {
        case .athan(let p):
            gate.athanFired(p, at: a.at)
            rearm(after: a.at)
        case .midnight:
            gate.reevaluate(.midnight)
            rearm(after: a.at)
        case .pauseEnds:
            gate.reevaluate(.pauseEnded)
            rearm(after: a.at)
        }
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
        armed = nil
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ reason: ReevalReason) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handle(reason) }
        }
        observers.append((center, token))
    }
}
