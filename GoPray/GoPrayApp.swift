// GoPrayApp.swift — entry point and wiring. Owner: PM.
// Menu bar only (.accessory, LSUIElement). Quit asks the gate.
// Wiring order (CONTRACT-NOTES #5, #14): settings store → gate reads the store →
// store.attach(gate) → store changes go to scheduler.handle(.settingsChanged).

import AppKit
import SwiftUI
import os

private let log = Logger(subsystem: "com.ahmedelgazar.gopray", category: "wire")

@MainActor final class AppEnvironment {
    let clock: Clock
    let store: StateStore
    let settingsStore: SettingsStore
    let schedule: PrayerScheduleProviding
    let shield: ShieldPresenting
    let audio: AthanPlaying
    let hider: AppHiding
    let loginAgent: LoginAgentManaging
    let geocoder: CityGeocoding
    let ledger: EmergencyLedger
    let gate: BlockGate
    let scheduler: Scheduler
    /// The update check (v2 §8). Created by `start()`, so only the live app has one.
    private(set) var updater: UpdateChecker?

    init(clock: Clock, store: StateStore, settingsStore: SettingsStore, schedule: PrayerScheduleProviding,
         shield: ShieldPresenting, audio: AthanPlaying, hider: AppHiding, loginAgent: LoginAgentManaging,
         geocoder: CityGeocoding, ledger: EmergencyLedger = EmergencyLedger(),
         defaultApps: Set<String> = CodingApps.bundleIDs) {
        self.clock = clock
        self.store = store
        self.settingsStore = settingsStore
        self.schedule = schedule
        self.shield = shield
        self.audio = audio
        self.hider = hider
        self.loginAgent = loginAgent
        self.geocoder = geocoder
        self.ledger = ledger
        let gate = BlockGate(clock: clock, store: store, schedule: schedule, shield: shield,
                             audio: audio, hider: hider, ledger: ledger, defaultApps: defaultApps,
                             settings: { settingsStore.settings })
        self.gate = gate
        settingsStore.attach(gate)                 // fail closed until this line: the store refuses everything
        let scheduler = Scheduler(clock: clock, schedule: schedule, gate: gate, settings: { settingsStore.settings })
        self.scheduler = scheduler
        settingsStore.onChange = { _ in scheduler.handle(.settingsChanged) }
    }

    /// True once the live wiring ran in this process. Tests assert it stays false.
    private(set) static var liveStarted = false

    static func live() -> AppEnvironment {
        liveStarted = true
        let settingsStore = SettingsStore()
        var hidden = CodingApps.bundleIDs
        #if DEBUG
        if let only = debugHideOnly() { hidden = only; log.notice("DEBUG hide list override: \(only.sorted().joined(separator: ","), privacy: .public)") }
        #endif
        return AppEnvironment(clock: SystemClock(),
                              store: StateStore(directory: StateStore.defaultDirectory()),
                              settingsStore: settingsStore,
                              schedule: PrayerSchedule(settings: { settingsStore.settings }),
                              shield: ShieldController(),
                              audio: AthanPlayer(),
                              hider: AppHider(),
                              loginAgent: LoginAgent(),
                              geocoder: Geocoder(),
                              ledger: EmergencyLedger(),
                              defaultApps: hidden)
    }

    func start() {
        gate.reevaluate(.launch)      // resume / wake rule / fail-open checks
        scheduler.start()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let updater = UpdateChecker(currentVersion: version, isBlocked: { [gate] in gate.isBlocked },
                                    automatic: { [settingsStore] in settingsStore.settings.checkForUpdates }, clock: clock)
        self.updater = updater
        updater.start()
    }
}

@MainActor @Observable final class AppDelegate: NSObject, NSApplicationDelegate {
    var env: AppEnvironment?     // internal set: the reopen test hands in a fake-backed environment
    /// True while this copy is not the lock holder (waiting, or about to exit): no menu icon.
    private(set) var isWaiting = false
    @ObservationIgnored private(set) var menuModel: MenuViewModel?
    @ObservationIgnored let windows = Windows()
    @ObservationIgnored private var role: InstanceRole = .byHand
    @ObservationIgnored private var lock: InstanceLock?
    @ObservationIgnored private var showObserver: NSObjectProtocol?
    @ObservationIgnored private var handOverTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        #if DEBUG
        // Hosted unit tests: do not touch the real state.json or arm timers.
        if TestHost.isActive { return }
        #endif
        // One copy at a time; the lock is the choke point (App/SingleInstance.swift).
        role = SingleInstance.role(environment: ProcessInfo.processInfo.environment)
        lock = InstanceLock()
        let successor = SingleInstance.isSuccessor(arguments: ProcessInfo.processInfo.arguments)
        let plan = SingleInstance.launchPlan(role: role, gotLock: lock?.tryAcquire(), successor: successor)
        log.notice("launch: role \(String(describing: self.role), privacy: .public)\(successor ? " (successor)" : "", privacy: .public), plan \(String(describing: plan), privacy: .public)")
        switch plan {
        case .wire:
            wire()
        case .waitForLock:
            isWaiting = true
            if successor {
                // A successor whose predecessor never went away (unregister failed) leaves quietly.
                Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.env == nil else { return }
                        log.notice("successor: the other copy stayed, leaving")
                        NSApp.terminate(nil)
                    }
                }
            }
            lock?.acquireInBackground { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        log.notice("lock acquired: wiring up")
                        self?.wire()
                    }
                }
            }
        case .askHolderToShowAndExit:
            isWaiting = true
            DistributedNotificationCenter.default().postNotificationName(SingleInstance.showRequest, object: nil,
                                                                         userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil)
        }
    }

    /// Opening the app (Finder, Dock, `open`) while it runs: macOS sends a reopen, not a new copy.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showRequested()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        (env?.gate.shouldAllowQuit() ?? true) ? .terminateNow : .terminateCancel
    }

    private func wire() {
        guard env == nil else { return }
        isWaiting = false
        let env = AppEnvironment.live()
        menuModel = MenuViewModel(store: env.settingsStore, gate: env.gate, schedule: env.schedule, clock: env.clock)
        self.env = env
        windows.onClose = { [weak self] in self?.considerHandOver() }
        showObserver = DistributedNotificationCenter.default().addObserver(forName: SingleInstance.showRequest,
                                                                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showRequested() }
        }
        env.start()
        menuModel?.updater = env.updater
        // After an upgrade or a move the agent registration can be gone; put it back if the
        // person chose it (only after setup: before that the default is not their choice).
        let s = env.settingsStore.settings
        if let agent = env.loginAgent as? LoginAgent,
           SingleInstance.shouldRepairAgent(status: agent.status, setupComplete: s.setupComplete, launchAtLogin: s.launchAtLogin) {
            do { try agent.register(); log.notice("login agent re-registered at launch") }
            catch { log.error("login agent repair failed: \(error.localizedDescription, privacy: .public)") }
        }
        #if DEBUG
        env.debugSeedIfAsked()
        #endif
        WebPrewarm.start()
        if !env.settingsStore.settings.setupComplete { windows.showSetup(env) }
        considerHandOver()
    }

    /// Someone opened Go Pray by hand while this copy runs: show Setup or Settings.
    /// Never during a block: a Settings/Setup window would take key focus under the shield.
    func showRequested() {
        guard let env, !env.gate.isBlocked else { return }
        if env.settingsStore.settings.setupComplete { windows.showSettings(env) } else { windows.showSetup(env) }
    }

    // MARK: Hand-over (a hand-opened holder gives way to the launchd copy)

    private func considerHandOver() {
        guard let env, role == .byHand, env.loginAgent.isRegistered else { return }
        if SingleInstance.shouldHandOver(role: role, agentRegistered: true, otherCopyRunning: SingleInstance.otherCopyRunning(),
                                         isBlocked: env.gate.isBlocked, hasOpenWindow: windows.hasOpenWindow) {
            log.notice("handing over to the login agent copy")
            handOverTimer?.invalidate(); handOverTimer = nil
            env.scheduler.stop()
            NSApp.terminate(nil)       // exit 0: the kernel drops the lock, the waiting copy wires up
            return
        }
        // A block, an open window, or a launchd copy still starting: look again shortly.
        guard handOverTimer == nil else { return }
        handOverTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.considerHandOver() }
        }
    }
}

@main struct GoPrayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Hidden while this copy is not the lock holder (App/SingleInstance.swift).
        MenuBarExtra(isInserted: .constant(!appDelegate.isWaiting)) {
            if let env = appDelegate.env, let model = appDelegate.menuModel {
                MenuContent(env: env, model: model, windows: appDelegate.windows)
            }
        } label: {
            Image("MenuBarIcon").accessibilityLabel("Go Pray")
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuContent: View {
    let env: AppEnvironment
    let model: MenuViewModel
    let windows: Windows

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuView(model: model,
                     still: { AnyView(SceneStill(prayer: $0)) },
                     openSettings: { closePopover(); windows.showSettings(env) },
                     openSetup: { closePopover(); windows.showSetup(env) },
                     quit: { NSApp.terminate(nil) },   // the gate refuses it while blocked
                     checkForUpdates: { Task { await env.updater?.checkNow() } },
                     downloadUpdate: { Task { await env.updater?.downloadAndOpen() } },
                     openReleases: { env.updater?.openReleasesPage() })
            #if DEBUG
            Divider()
            DebugMenu(env: env).padding(.horizontal, 16).padding(.vertical, 10)
            #endif
        }
    }

    /// The popover is the key window while its button runs; a MenuBarExtra window does not
    /// close itself when we open another window.
    private func closePopover() { NSApp.keyWindow?.close() }
}
