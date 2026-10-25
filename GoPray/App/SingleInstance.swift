// SingleInstance.swift — one Go Pray at a time. Owner: PM (wiring).
//
// Why: the login agent plist has RunAtLoad, so `register()` in Setup (or the Settings
// toggle) makes launchd start a SECOND copy while the copy opened by hand keeps running.
// Two copies = two gates, two menu icons, two shields at the next Athan.
//
// The one choke point is an exclusive advisory lock (`flock(LOCK_EX)`) on
// `~/Library/Application Support/GoPray/instance.lock` (PM ruling 2026-10-22):
// - Whoever holds the lock wires the gate, menu and shield. Nobody else does.
// - The launchd copy that finds the lock taken waits for it on a background thread, with
//   no menu icon. The kernel drops the lock when the holder exits or dies (kill -9 too),
//   so the waiting copy then wires up and resumes any block from state.json.
// - A copy opened by hand that finds the lock taken asks the holder to show itself
//   (a distributed notification) and exits 0.
// - The launchd copy takes a second lock, `instance.waiter.lock`, BEFORE it waits for
//   `instance.lock`, and nothing else ever takes it. So "waiter lock held by someone else"
//   means a launchd copy is alive and waiting. Any other same-bundle-id process (a test
//   host, a DMG copy, an old build) does not count.
// - The hand-opened holder hands over (exits 0) once the login agent is registered, the
//   waiter lock is held by someone else, nothing is blocked and none of its windows is open.
//   A block is never handed over half-way.
// - If the lock file cannot be opened, the copy wires anyway (a broken lock must never
//   stop the app from working).
// - Turning "Launch at login" off from the launchd copy: unregistering stops that copy, so
//   `LoginAgent.unregister()` first starts a successor (`-GoPraySuccessor YES`). The successor
//   waits for the lock like the launchd copy and wires up when the old copy is gone.

import AppKit
import Foundation
import ServiceManagement

enum InstanceRole: Equatable, Sendable {
    case agent      // started by launchd from the login agent plist
    case byHand     // opened by the person (Finder, Dock, `open`)
}

enum InstancePlan: Equatable, Sendable {
    case wire                       // we hold the lock (or there is no usable lock)
    case waitForLock                // launchd copy: wait, then wire
    case askHolderToShowAndExit     // opened by hand while another copy runs
}

enum SingleInstance {
    static let agentLabel = "com.ahmedelgazar.gopray.agent"
    /// Posted by a hand-opened copy that found the lock taken; the holder shows itself.
    static let showRequest = Notification.Name("com.ahmedelgazar.gopray.show")
    /// Launch argument of a copy started to take over from the launchd copy.
    static let successorArgument = "-GoPraySuccessor"

    /// launchd sets XPC_SERVICE_NAME to the job label; LaunchServices sets "application.<id>.…".
    static func role(environment: [String: String]) -> InstanceRole {
        environment["XPC_SERVICE_NAME"] == agentLabel ? .agent : .byHand
    }

    static func isSuccessor(arguments: [String]) -> Bool {
        guard let i = arguments.firstIndex(of: successorArgument), i + 1 < arguments.count else { return false }
        return arguments[i + 1] == "YES"
    }

    /// `gotLock == nil` means the lock file could not be opened: wire anyway.
    static func launchPlan(role: InstanceRole, gotLock: Bool?, successor: Bool = false) -> InstancePlan {
        guard let gotLock, !gotLock else { return .wire }
        return (role == .agent || successor) ? .waitForLock : .askHolderToShowAndExit
    }

    /// At launch: put a lost login agent registration back (after an upgrade or a move), but
    /// only when the person chose launch at login, which they cannot have done before setup
    /// (the default is on). `.requiresApproval` = they turned it off in System Settings: respected.
    static func shouldRepairAgent(status: SMAppService.Status, setupComplete: Bool, launchAtLogin: Bool) -> Bool {
        setupComplete && launchAtLogin && (status == .notFound || status == .notRegistered)
    }

    static func shouldHandOver(role: InstanceRole, agentRegistered: Bool, agentCopyWaiting: Bool,
                               isBlocked: Bool, hasOpenWindow: Bool) -> Bool {
        role == .byHand && agentRegistered && agentCopyWaiting && !isBlocked && !hasOpenWindow
    }
}

/// An exclusive advisory lock on one file. The descriptor stays open for the life of the
/// process; the kernel releases the lock when the process exits or is killed.
final class InstanceLock: @unchecked Sendable {
    let url: URL
    private let fd: Int32

    static func defaultURL() -> URL {
        StateStore.defaultDirectory().appendingPathComponent("instance.lock")
    }

    /// The waiter lock: held only by a launchd copy that is waiting for `instance.lock`.
    static func waiterURL() -> URL {
        StateStore.defaultDirectory().appendingPathComponent("instance.waiter.lock")
    }

    /// nil if the file cannot be created or opened.
    init?(url: URL = InstanceLock.defaultURL()) {
        self.url = url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        self.fd = fd
    }

    /// Non-blocking. True if this process now holds the lock.
    func tryAcquire() -> Bool { flock(fd, LOCK_EX | LOCK_NB) == 0 }

    /// Blocks a background thread until the lock is ours, then calls `done` there.
    func acquireInBackground(_ done: @escaping @Sendable () -> Void) {
        let fd = self.fd
        DispatchQueue.global(qos: .userInitiated).async {
            while flock(fd, LOCK_EX) != 0 {
                if errno != EINTR { return }   // cannot wait (bad descriptor): stay out of the way
            }
            done()
        }
    }

    /// Blocks the calling (background) thread until the lock is ours. False if it cannot wait.
    func acquireBlocking() -> Bool {
        while flock(fd, LOCK_EX) != 0 {
            if errno != EINTR { return false }
        }
        return true
    }

    func release() { _ = flock(fd, LOCK_UN) }

    /// True only if another process holds the lock. A probe that gets it lets go at once;
    /// any other error means "not seen" (never hand over on doubt).
    func isHeldElsewhere() -> Bool {
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            _ = flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }
}
