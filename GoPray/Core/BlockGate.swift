// BlockGate.swift — THE choke point (§C.3). Owner: PM.
//
// Only this type starts a block, ends a block, or says whether "I prayed" is
// allowed. Two rules, in this order (§A):
//   1. Never trap him. Every failure fails OPEN.
//   2. No escape by reflex. Only requestConfirm() after the lock ends a block.
//
// Two private exits, both in this file:
//   endBlock(_ kind) — a deliberate end. Exactly two callers: requestConfirm() (confirmed, after the
//                 lock) and requestEmergencyExit() (one of the yearly exits; v2, recorded as dropped).
//   failOpen()  — a §G fail-open rule (window closed, next Athan, crash loop,
//                 no schedule). Never reachable from the shield, the menu or
//                 a page message.
// scripts/guard.sh checks both.

import AppKit
import Foundation
import Observation
import os

@MainActor @Observable final class BlockGate {
    enum Phase: Equatable { case idle, locked(until: Date), canConfirm, leaving }

    enum FailOpenReason: String {
        case windowClosed = "window-closed"            // block outlived its prayer window: missed
        case replacedByNextAthan = "next-athan"        // overlap: the new prayer replaces the old
        case crashLoop = "crash-loop fail-open"        // 3 launches in 120 s while blocked
        case noSchedule = "no-schedule"                // the block's window cannot be found

        /// Record the prayer as done so the wake rule does not block it again.
        var recordsDropped: Bool { self == .crashLoop }
    }

    // MARK: Dependencies

    @ObservationIgnored private let clock: Clock
    @ObservationIgnored private let store: StateStore
    @ObservationIgnored private let schedule: PrayerScheduleProviding
    @ObservationIgnored private let shield: ShieldPresenting
    @ObservationIgnored private let audio: AthanPlaying
    @ObservationIgnored private let hider: AppHiding
    @ObservationIgnored private let ledger: EmergencyLedger
    /// TV control (CONTRACT-NOTES #56). Fire and forget; the gate never waits on it.
    @ObservationIgnored private let tv: TVSending
    /// The compiled-in defaults (Mac wiring passes `CodingApps.bundleIDs`). The effective list is
    /// computed from them and the settings ONCE, at block start.
    @ObservationIgnored private let defaultApps: Set<String>
    @ObservationIgnored private let settings: @MainActor () -> Settings
    @ObservationIgnored private let systemReduceMotion: @MainActor () -> Bool
    @ObservationIgnored private let log = Logger(subsystem: "com.ahmedelgazar.gopray", category: "gate")
    /// A dismiss that never calls back is torn down after this (fail open).
    let leavingTimeout: Duration

    static let crashLoopLaunches = 3
    /// The TV is called only within this long after the prayer's real Athan time (CONTRACT-NOTES #66).
    static let tvLateWakeLimit: TimeInterval = 180
    /// Late-start rule (Late Wake Fix Spec): a block that starts more than this long after the prayer's
    /// Athan shows with no Athan and no lock ("I prayed" is open at once). Same name and value on Windows.
    static let lateStartLimit: TimeInterval = 30 * 60
    static let crashLoopWindow: TimeInterval = 120

    // MARK: State

    private(set) var state: BlockStateFile
    private(set) var hiddenAppName: String?
    private var leavingToken: Int?
    @ObservationIgnored private var tokenCounter = 0
    @ObservationIgnored private var presented = false
    @ObservationIgnored private var loadedCorrupt = false
    /// Settings as last seen by reevaluate, to catch "setup just finished" and
    /// "pause just ended" (neither may block the window that is already open).
    @ObservationIgnored private var lastSeen: (setupComplete: Bool, paused: Bool)

    init(clock: Clock, store: StateStore, schedule: PrayerScheduleProviding, shield: ShieldPresenting,
         audio: AthanPlaying, hider: AppHiding, ledger: EmergencyLedger, defaultApps: Set<String>, tv: TVSending = NoTV(),
         settings: @escaping @MainActor () -> Settings,
         leavingTimeout: Duration = .seconds(4),
         systemReduceMotion: @escaping @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.clock = clock
        self.store = store
        self.schedule = schedule
        self.shield = shield
        self.audio = audio
        self.hider = hider
        self.ledger = ledger
        self.tv = tv
        self.defaultApps = defaultApps
        self.settings = settings
        self.leavingTimeout = leavingTimeout
        self.systemReduceMotion = systemReduceMotion
        switch store.load() {
        case .missing: state = BlockStateFile()
        case .loaded(let s): state = s
        case .corrupt: state = BlockStateFile(); loadedCorrupt = true
        }
        let s0 = settings()
        lastSeen = (s0.setupComplete, s0.isPaused(at: clock.now))
        shield.delegate = self
        audio.onFinished = { [weak self] in self?.athanFinished() }
        hider.onReHide = { [weak self] name in self?.appReHidden(name) }
    }

    // MARK: Read-only views

    var phase: Phase {
        guard let b = state.block else { return leavingToken != nil ? .leaving : .idle }
        let elapsed = clock.now.timeIntervalSince(b.blockStartedAt)
        let lock = Self.lock(of: b)
        // Clamp: a clock behind blockStartedAt opens the button. A lock is
        // never longer than the block's captured lock (≤ 30 min) from any moment.
        if elapsed >= 0 && elapsed < lock {
            return .locked(until: b.blockStartedAt.addingTimeInterval(lock))
        }
        return .canConfirm
    }

    var isBlocked: Bool { phase != .idle }

    /// Exits left this calendar year (the menu line). Not blocked-specific.
    var emergencyExitsLeft: Int { ledger.remaining(at: clock.now) }
    var currentBlock: BlockStateFile.Block? { state.block }

    func shouldAllowQuit() -> Bool { !isBlocked }
    func allowsSettingsChange() -> Bool { !isBlocked }

    /// SettingsStore.mutate calls this first. Covers every setting, including
    /// mode, lockMinutes and pause/resume: none may change during a block.
    func authorizeSettingsChange() throws {
        guard allowsSettingsChange() else { throw SettingsError.blocked }
    }

    /// What the shield should show right now; nil when no block is active.
    func shieldContext() -> ShieldContext? {
        guard let b = state.block else { return nil }
        let s = settings()
        var remaining = 0
        if case .locked(let until) = phase {
            remaining = Int((until.timeIntervalSince(clock.now) * 1000).rounded(.up))
            remaining = min(max(remaining, 0), Int(Self.lock(of: b) * 1000))
        }
        return ShieldContext(prayer: b.prayer, mode: s.mode, remainingMs: remaining,
                             athanRemainingMs: audio.isPlaying ? max(0, audio.remainingMs()) : 0,
                             reduceMotion: s.reduceMotion ?? systemReduceMotion(),
                             hiddenAppName: hiddenAppName,
                             blockStartedAt: b.blockStartedAt, lockSeconds: Int(Self.lock(of: b)),
                             emergencyExitsLeft: b.emergencyExitsEnabled ? ledger.remaining(at: clock.now) : 0)
    }

    // MARK: Inputs

    /// Scheduler only. Starts a block if the schedule agrees this Athan is now.
    func athanFired(_ prayer: Prayer, at: Date) {
        let now = clock.now
        let s = settings()
        guard s.setupComplete else { return }
        guard let w = schedule.window(containing: max(now, at)), w.prayer == prayer,
              abs(w.athan.timeIntervalSince(at)) < 60, w.end > now else {
            log.notice("athanFired(\(prayer.rawValue, privacy: .public)) ignored: schedule disagrees")
            return
        }
        if let b = state.block, abs(b.athanAt.timeIntervalSince(w.athan)) < 1 { return }   // already blocking it
        if isDone(w) { return }
        if Self.coveredByPause(w, s) {
            log.notice("athanFired(\(prayer.rawValue, privacy: .public)) skipped: paused")
            return
        }
        if state.block != nil { failOpen(.replacedByNextAthan) }
        startBlock(prayer: w.prayer, athanAt: w.athan, now: now, lockSeconds: LockPolicy.seconds(forMinutes: s.lockMinutes))
    }

    /// Launch, wake, clock, time zone, settings, midnight. Applies the wake
    /// rule and every fail-open rule. Never stacks two blocks.
    func reevaluate(_ reason: ReevalReason) {
        let now = clock.now
        if reason == .launch, !launchChecks(now: now) { return }

        let s = settings()
        let paused = s.isPaused(at: now)
        let setupJustFinished = !lastSeen.setupComplete && s.setupComplete
        let pauseJustEnded = lastSeen.paused && !paused
        lastSeen = (s.setupComplete, paused)

        if let b = state.block {
            if let bw = window(of: b) {
                if bw.prayer == b.prayer, abs(bw.athan.timeIntervalSince(b.athanAt)) < 1, bw.end > now {
                    if presented { shield.update(shieldContext()!) } else { present(freshAthan: false) }
                    return
                }
                failOpen(.windowClosed)
            } else {
                failOpen(.noSchedule)
            }
        }

        // First setup and resume never block the window already open (PM ruling 2026-10-22).
        if setupJustFinished || pauseJustEnded {
            dropOpenWindow(now: now, reason: setupJustFinished ? "setup just finished" : "pause just ended")
            return
        }

        // Wake rule (§3): the open window's prayer, if not done and not paused, blocks now.
        guard s.setupComplete,
              let w = schedule.window(containing: now), w.athan <= now, now < w.end, !isDone(w),
              !Self.coveredByPause(w, s) else { return }
        startBlock(prayer: w.prayer, athanAt: w.athan, now: now, lockSeconds: LockPolicy.seconds(forMinutes: s.lockMinutes))
    }

    /// "I prayed": allowed only once the lock is over. False while locked (or idle).
    @discardableResult func requestConfirm() -> Bool {
        guard phase == .canConfirm else { return false }
        endBlock(.confirmed)
        return true
    }

    /// One of the yearly emergency exits (PM amendment §9). The SECOND and LAST caller of
    /// endBlock. Allowed while locked and while canConfirm; refused when idle or leaving, when
    /// this block was started with exits off, when none are left, or when the use cannot be
    /// written (the person is never trapped: the normal lock path is untouched). The ledger write
    /// comes first; the block ends right after it with no work in between.
    @discardableResult func requestEmergencyExit() -> Bool {
        guard let b = state.block, b.emergencyExitsEnabled else {
            if state.block == nil { log.notice("emergency exit refused: idle") }
            else { log.notice("emergency exit refused: exits off") }
            return false
        }
        switch phase {
        case .locked, .canConfirm: break
        case .idle:
            log.notice("emergency exit refused: idle")
            return false
        case .leaving:
            log.notice("emergency exit refused: leaving")
            return false
        }
        let now = clock.now
        guard ledger.remaining(at: now) > 0 else {
            log.notice("emergency exit refused: none left")
            return false
        }
        do { try ledger.recordUse(.init(prayer: b.prayer, athanAt: b.athanAt, at: now), now: now) }
        catch {
            log.error("emergency exit refused: ledger write failed")
            return false
        }
        endBlock(.emergency)
        return true
    }

    /// Stops the sound. The block is untouched.
    func requestSilence() {
        guard var b = state.block else { return }
        audio.stop()
        if !b.silenced {
            b.silenced = true
            state.block = b
            persist()
        }
        shield.update(shieldContext()!)
    }

    // MARK: Private

    /// The lock a block honours: its captured length, never above the 30-min
    /// maximum (a tampered file cannot trap), never negative.
    static func lock(of b: BlockStateFile.Block) -> TimeInterval {
        min(max(b.lockSeconds, 0), LockPolicy.maxSeconds)
    }

    /// A window whose Athan came before `pausedUntil` was skipped by the pause.
    /// Stateless, so it also holds after a relaunch or a pause that ran out while asleep.
    static func coveredByPause(_ w: PrayerWindow, _ s: Settings) -> Bool {
        guard let until = s.pausedUntil else { return false }
        return w.athan < until
    }

    /// The window a running block belongs to. Real blocks: the schedule's. DEBUG builds also
    /// accept a "Trigger Athan now" block's synthetic window (at most 1 h long).
    private func window(of b: BlockStateFile.Block) -> PrayerWindow? {
        #if DEBUG
        if let end = b.debugWindowEnd {
            return PrayerWindow(prayer: b.prayer, athan: b.athanAt, end: min(end, b.athanAt.addingTimeInterval(3600)))
        }
        #endif
        return schedule.window(containing: b.athanAt)
    }

    private func isDone(_ w: PrayerWindow) -> Bool {
        guard let done = state.latestDoneAthan else { return false }
        return w.athan.timeIntervalSince(done) < 1
    }

    /// Launch-only fail-open checks. Returns false when it already settled the state.
    private func launchChecks(now: Date) -> Bool {
        if loadedCorrupt {
            loadedCorrupt = false
            dropOpenWindow(now: now, reason: "corrupt state.json")
            return false
        }

        // A far-future "done" date would make every later prayer look finished: quarantine it.
        if let done = state.latestDoneAthan, done > now.addingTimeInterval(86_400) {
            store.quarantine(reason: "future done date")
            state = BlockStateFile()
            dropOpenWindow(now: now, reason: "future done date in state.json")
            return false
        }
        guard let b = state.block else { return true }

        // A block cannot start before its Athan or in the future.
        if b.blockStartedAt < b.athanAt.addingTimeInterval(-60) || b.blockStartedAt > now.addingTimeInterval(60) {
            store.quarantine(reason: "impossible dates")
            state = BlockStateFile()
            dropOpenWindow(now: now, reason: "impossible dates in state.json")
            return false
        }

        // Crash loop: 3 launches in 120 s while blocked → give this prayer up.
        var launches = state.launches.filter { now.timeIntervalSince($0) >= 0 && now.timeIntervalSince($0) <= Self.crashLoopWindow }
        launches.append(now)
        state.launches = Array(launches.suffix(5))
        if state.launches.count >= Self.crashLoopLaunches {
            failOpen(.crashLoop)
            return false
        }
        persist()
        return true
    }

    /// No block in memory: mark the open window as done so the wake rule does
    /// not block it, write a clean file. Used by fail-open (corrupt file) and
    /// by "setup just finished" / "pause just ended".
    private func dropOpenWindow(now: Date, reason: String) {
        log.notice("open window dropped: \(reason, privacy: .public)")
        if let w = schedule.window(containing: now), w.athan <= now, now < w.end {
            state.lastDropped = .init(prayer: w.prayer, athanAt: w.athan)
        }
        persist()
    }

    private func startBlock(prayer: Prayer, athanAt: Date, now: Date, lockSeconds: TimeInterval) {
        if leavingToken != nil {          // a dismiss is still fading: cut it
            leavingToken = nil
            shield.tearDown()
        }
        let s = settings()
        // The one choke point for the late-start rule: every block start (live Athan, wake, launch, stale timer) lands here.
        // A zero lock is the existing "canConfirm at once" state, so no new mode is needed; it is persisted like any lock,
        // so a relaunch resumes the same late block (present(freshAthan: false)): no Athan, no fresh lock.
        let late = now.timeIntervalSince(athanAt) > Self.lateStartLimit
        state.block = .init(prayer: prayer, athanAt: athanAt, blockStartedAt: now, silenced: false, athanPlayed: !late,
                            lockSeconds: late ? 0 : lockSeconds,   // captured: later settings changes cannot touch it
                            hiddenApps: BlockedApps.effective(s, defaults: defaultApps).sorted(),
                            emergencyExitsEnabled: s.emergencyExitsEnabled)
        state.launches = []
        persist()                         // on disk BEFORE the shield goes up
        if late {
            log.notice("block late \(prayer.rawValue, privacy: .public): no athan, prayed open")
        } else {
            log.notice("block start \(prayer.rawValue, privacy: .public)")
        }
        present(freshAthan: !late)
    }

    private func present(freshAthan: Bool) {
        let s = settings()
        presented = true
        if s.mode == .codingApps { hider.start(hiding: capturedApps()) }
        if freshAthan, let b = state.block, !b.silenced {
            do { try audio.play(prayer: b.prayer, voice: s.voice, volume: s.athanVolume) }
            catch { log.error("athan play failed: \(error.localizedDescription, privacy: .public)") }
            // The household's Athan too: only here, so only when the Mac's Athan fires (live, or wake into an
            // open window). Not on a relaunch (freshAthan false), not silenced, not paused (no block starts).
            // Several computers can share one Wi-Fi: only the Athan itself starts the TV. Waking into an open window
            // more than 3 min after the real prayer time still blocks the Mac, but leaves the TV alone.
            if clock.now.timeIntervalSince(b.athanAt) <= Self.tvLateWakeLimit {
                tv.athanStarted(prayer: b.prayer, voice: s.voice, tvs: s.tvs)
            } else {
                log.notice("tv: skipped, late wake")
            }
        }
        shield.show(shieldContext()!)
    }

    /// The block's captured list, denylist and cap applied on read. A 0.1.x file (no list) gets the
    /// list computed from today's settings once, and it is written back.
    private func capturedApps() -> Set<String> {
        guard var b = state.block else { return [] }
        if let ids = b.hiddenApps { return BlockedApps.sanitizeCaptured(ids) }
        let ids = BlockedApps.effective(settings(), defaults: defaultApps)
        b.hiddenApps = ids.sorted()
        state.block = b
        persist()
        return ids
    }

    private func endBlock(_ kind: EndKind) {
        guard let b = state.block else { return }
        switch kind {
        case .confirmed: state.lastConfirmed = .init(prayer: b.prayer, athanAt: b.athanAt)
        case .emergency: state.lastDropped = .init(prayer: b.prayer, athanAt: b.athanAt)   // missed, never "prayed"
        }
        state.block = nil
        state.launches = []
        persist()
        log.notice("block ended (\(kind == .confirmed ? "confirmed" : "emergency", privacy: .public)) \(b.prayer.rawValue, privacy: .public)")
        audio.stop()
        hider.stop()
        presented = false
        hiddenAppName = nil
        tokenCounter += 1
        let token = tokenCounter
        leavingToken = token
        shield.dismiss(kind: kind) { [weak self] in self?.finishLeaving(token) }
        // Fail open: a dismiss that never calls back cannot keep us "blocked".
        let timeout = leavingTimeout
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, self.leavingToken == token else { return }
            self.shield.tearDown()
            self.finishLeaving(token)
        }
    }

    private func finishLeaving(_ token: Int) {
        guard leavingToken == token else { return }
        leavingToken = nil
    }

    private func failOpen(_ reason: FailOpenReason) {
        guard let b = state.block else { return }
        log.error("\(reason.rawValue, privacy: .public): \(b.prayer.rawValue, privacy: .public) block dropped")
        if reason.recordsDropped { state.lastDropped = .init(prayer: b.prayer, athanAt: b.athanAt) }
        state.block = nil
        state.launches = []
        persist()
        audio.stop()
        hider.stop()
        shield.tearDown()
        presented = false
        hiddenAppName = nil
        leavingToken = nil
    }

    private func persist() {
        do { try store.save(state) }
        catch { log.error("state.json write failed: \(error.localizedDescription, privacy: .public)") }
    }

    private func athanFinished() {
        guard let ctx = shieldContext() else { return }
        shield.update(ctx)
    }

    private func appReHidden(_ name: String) {
        guard state.block != nil else { return }
        hiddenAppName = name
        shield.update(shieldContext()!)
    }

    // MARK: Debug

    #if DEBUG
    /// Debug menu only. Starts a block now with a short lock. It can start a
    /// block, never end one.
    func debugTriggerAthan(_ prayer: Prayer, lockSeconds: TimeInterval) {
        let now = clock.now
        if state.block != nil { failOpen(.replacedByNextAthan) }
        startBlock(prayer: prayer, athanAt: now, now: now, lockSeconds: lockSeconds)
        // A synthetic window (athan = now, end = now + 1 h) through the same state.json, so a
        // relaunch mid-block resumes it like a real block.
        state.block?.debugWindowEnd = now.addingTimeInterval(3600)
        persist()
    }

    /// Debug menu only, idle only.
    func debugWipeState() {
        guard !isBlocked else { return }
        store.wipe()
        state = BlockStateFile()
    }
    #endif
}

extension BlockGate: ShieldDelegate {
    func shieldDidRequestConfirm() {
        // Refused → re-sync the page with the gate's own remaining time.
        if !requestConfirm(), let ctx = shieldContext() { shield.update(ctx) }
    }

    func shieldDidRequestSilence() { requestSilence() }

    func shieldDidRequestEmergencyExit() {
        // Refused → re-sync the page with the true count (and its own "couldn't" line).
        if !requestEmergencyExit(), let ctx = shieldContext() { shield.update(ctx) }
    }
}

extension BlockGate: SettingsChangeAuthorizing {}
