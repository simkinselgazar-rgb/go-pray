// AppHider.swift — AppHiding for "Coding apps only" mode. Lane D.
// Rules (Architecture Plan §C Mode B + spike Q5):
//  - The list comes from the gate (captured at block start), never from settings (v2).
//  - HIDE only. Never quit, kill or force anything. No Accessibility.
//  - `hide()` returns false even when it works, so the return value is ignored.
//    The truth is `isHidden`, checked later on the run loop (never a blocking poll).
//  - Hide is retried once; an app that still refuses is logged and left alone.
//  - `stop()` does NOT unhide. Apps he had open stay hidden until he brings them back;
//    unhiding on our own would pop windows over the "May Allah accept it." fade.

import AppKit
import os

private let log = Logger(subsystem: "com.ahmedelgazar.gopray", category: "apphider")

/// What AppHider needs from a running app. NSRunningApplication on the real path.
@MainActor protocol HidableApp: AnyObject {
    var bundleIdentifier: String? { get }
    var localizedName: String? { get }
    var isHidden: Bool { get }
    var isFinishedLaunching: Bool { get }
    @discardableResult func hide() -> Bool
}

enum WorkspaceEvent: Sendable { case didActivate, didLaunch }

/// The NSWorkspace surface AppHider uses. A fake stands in for it in tests.
@MainActor protocol RunningApps: AnyObject {
    var runningApps: [any HidableApp] { get }
    /// Returns a token; pass it to `removeObserver`.
    func observe(_ handler: @escaping @MainActor (WorkspaceEvent, any HidableApp) -> Void) -> AnyObject
    func removeObserver(_ token: AnyObject)
}

@MainActor final class AppHider: AppHiding {
    var onReHide: ((String) -> Void)?

    private let workspace: RunningApps
    /// The set the gate passed to `start(hiding:)`. Never the settings.
    private var bundleIDs: Set<String> = []
    private let retryDelay: TimeInterval
    private let schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void
    private var token: AnyObject?
    /// Bumped by `stop()` so checks scheduled earlier do nothing afterwards.
    private var generation = 0

    init(workspace: RunningApps = SystemRunningApps(),
         retryDelay: TimeInterval = 0.1,
         schedule: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void = AppHider.runLoopSchedule) {
        self.workspace = workspace
        self.retryDelay = retryDelay
        self.schedule = schedule
    }

    /// Safe to call more than once (block start, and again on a relaunch that resumes a block).
    func start(hiding ids: Set<String>) {
        // Last line of defence: never hide what the denylist protects, whatever the caller passed.
        bundleIDs = Set(ids.map(BlockedApps.normalize).filter(BlockedApps.isBlockable))
        if token == nil {
            token = workspace.observe { [weak self] event, app in self?.handle(event, app) }
        }
        for app in workspace.runningApps where isListed(app) { hide(app, attempt: 0) }
    }

    func stop() {
        generation += 1
        if let token { workspace.removeObserver(token) }
        token = nil
    }

    // MARK: Private

    private func isListed(_ app: any HidableApp) -> Bool {
        guard let id = app.bundleIdentifier else { return false }
        return bundleIDs.contains(id)
    }

    private func handle(_ event: WorkspaceEvent, _ app: any HidableApp) {
        guard token != nil, isListed(app) else { return }   // after stop(), late events are ignored
        hide(app, attempt: 0)
        onReHide?(app.localizedName ?? app.bundleIdentifier ?? "")
    }

    /// hide(), then look at `isHidden` one run-loop delay later. attempt 0 → retry once → give up.
    /// Found live: hide() does nothing while an app is still launching (`isFinishedLaunching` false,
    /// ~0.5 s for TextEdit). Waiting for launch to finish is not a retry; it is capped at `maxLaunchWaits`.
    private func hide(_ app: any HidableApp, attempt: Int, launchWaits: Int = 0) {
        app.hide()
        let gen = generation
        schedule(retryDelay) { [weak self, weak app] in
            guard let self, let app, gen == self.generation else { return }
            if app.isHidden { return }
            if !app.isFinishedLaunching, launchWaits < Self.maxLaunchWaits {
                self.hide(app, attempt: attempt, launchWaits: launchWaits + 1)
            } else if attempt == 0 {
                self.hide(app, attempt: 1, launchWaits: launchWaits)
            } else {
                log.error("app refused hide: \(app.bundleIdentifier ?? "?", privacy: .public)")
            }
        }
    }

    private static let maxLaunchWaits = 100   // 100 x 0.1 s = 10 s

    static let runLoopSchedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
    }
}

// MARK: - Real NSWorkspace

extension NSRunningApplication: HidableApp {}

@MainActor final class SystemRunningApps: RunningApps {
    private let center = NSWorkspace.shared.notificationCenter

    var runningApps: [any HidableApp] { NSWorkspace.shared.runningApplications }

    func observe(_ handler: @escaping @MainActor (WorkspaceEvent, any HidableApp) -> Void) -> AnyObject {
        let pairs: [(Notification.Name, WorkspaceEvent)] = [
            (NSWorkspace.didActivateApplicationNotification, .didActivate),
            (NSWorkspace.didLaunchApplicationNotification, .didLaunch),
        ]
        let tokens = pairs.map { name, event in
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                nonisolated(unsafe) let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated {
                    guard let app else { return }
                    handler(event, app)
                }
            }
        }
        return TokenBox(tokens)
    }

    func removeObserver(_ token: AnyObject) {
        guard let box = token as? TokenBox else { return }
        for t in box.tokens { center.removeObserver(t) }
    }

    private final class TokenBox { let tokens: [NSObjectProtocol]; init(_ t: [NSObjectProtocol]) { tokens = t } }
}
