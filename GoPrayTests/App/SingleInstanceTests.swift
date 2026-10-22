// SingleInstanceTests.swift — the one-copy rule (App/SingleInstance.swift). Owner: PM.
// The decision function, and the lock itself across two real processes: a separate
// `perl` process holds or tries the same flock, and is killed with SIGKILL.

import Foundation
import ServiceManagement
import Testing
@testable import GoPray

@Suite("Single instance")
struct SingleInstanceTests {
    @Test func roleComesFromTheLaunchdLabel() {
        #expect(SingleInstance.role(environment: ["XPC_SERVICE_NAME": "com.ahmedelgazar.gopray.agent"]) == .agent)
        #expect(SingleInstance.role(environment: ["XPC_SERVICE_NAME": "application.com.ahmedelgazar.gopray.123.456"]) == .byHand)
        #expect(SingleInstance.role(environment: [:]) == .byHand)
    }

    @Test func theLockHolderWires() {
        #expect(SingleInstance.launchPlan(role: .agent, gotLock: true) == .wire)
        #expect(SingleInstance.launchPlan(role: .byHand, gotLock: true) == .wire)
    }

    @Test func withoutTheLockTheAgentWaitsAndAHandCopyLeaves() {
        #expect(SingleInstance.launchPlan(role: .agent, gotLock: false) == .waitForLock)
        #expect(SingleInstance.launchPlan(role: .byHand, gotLock: false) == .askHolderToShowAndExit)
    }

    @Test func aSuccessorWaitsForTheLockInsteadOfLeaving() {
        #expect(SingleInstance.isSuccessor(arguments: ["Go Pray", "-GoPraySuccessor", "YES"]))
        #expect(!SingleInstance.isSuccessor(arguments: ["Go Pray"]))
        #expect(!SingleInstance.isSuccessor(arguments: ["Go Pray", "-GoPraySuccessor"]))
        #expect(SingleInstance.launchPlan(role: .byHand, gotLock: false, successor: true) == .waitForLock)
        #expect(SingleInstance.launchPlan(role: .byHand, gotLock: true, successor: true) == .wire)
    }

    @Test func repairsOnlyALostRegistrationThePersonChoseAfterSetup() {
        func r(_ st: SMAppService.Status, setup: Bool = true, login: Bool = true) -> Bool {
            SingleInstance.shouldRepairAgent(status: st, setupComplete: setup, launchAtLogin: login)
        }
        #expect(r(.notFound))
        #expect(r(.notRegistered))
        #expect(!r(.enabled))
        #expect(!r(.requiresApproval))          // turned off in System Settings: respected
        #expect(!r(.notRegistered, login: false))
        #expect(!r(.notRegistered, setup: false))   // first run: the default "on" is not a choice yet
    }

    @Test func anUnusableLockFileNeverStopsTheApp() {
        #expect(SingleInstance.launchPlan(role: .agent, gotLock: nil) == .wire)
        #expect(SingleInstance.launchPlan(role: .byHand, gotLock: nil) == .wire)
    }

    @Test func handOverOnlyWhenRegisteredIdleWithNoWindowAndSomeoneToTakeOver() {
        func h(_ role: InstanceRole = .byHand, reg: Bool = true, other: Bool = true, blocked: Bool = false, window: Bool = false) -> Bool {
            SingleInstance.shouldHandOver(role: role, agentRegistered: reg, otherCopyRunning: other, isBlocked: blocked, hasOpenWindow: window)
        }
        #expect(h())
        #expect(!h(blocked: true))        // never mid-block
        #expect(!h(window: true))         // not while Setup or Settings is open
        #expect(!h(other: false))         // nobody to take over
        #expect(!h(reg: false))           // launch at login off: the hand copy is the only one
        #expect(!h(.agent))               // the launchd copy never leaves
    }
}

@Suite("Instance lock across processes", .serialized)
struct InstanceLockProcessTests {
    @Test func theLockLivesInTheOneSupportFolder() {
        #expect(InstanceLock.defaultURL() == StateStore.defaultDirectory().appendingPathComponent("instance.lock"))
    }

    private func tempLockURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("gopray-lock-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("instance.lock")
    }

    /// A second process: perl takes LOCK_EX (blocking, or non-blocking with `nb`) on `url`,
    /// prints "held" (or exits 1 if it could not get it), then sleeps.
    private func perlLocker(_ url: URL, nonBlocking: Bool = false) throws -> (Process, Pipe) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        let flags = nonBlocking ? "LOCK_EX|LOCK_NB" : "LOCK_EX"
        p.arguments = ["-e", "use Fcntl qw(:flock); $|=1; open(my $f, '>>', $ARGV[0]) or die; flock($f, \(flags)) or exit 1; print \"held\\n\"; sleep 30;", url.path]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        return (p, out)
    }

    private func waitForLine(_ pipe: Pipe, timeout: Double = 5) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        var buf = Data()
        let h = pipe.fileHandleForReading
        while Date() < deadline {
            let chunk = h.availableData
            if chunk.isEmpty { return String(data: buf, encoding: .utf8) }
            buf.append(chunk)
            if let s = String(data: buf, encoding: .utf8), s.contains("\n") { return s }
        }
        return nil
    }

    @Test func aHeldLockIsRefusedThenGrantedWithin2sAfterTheHolderIsKilled() async throws {
        let url = tempLockURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let lock = try #require(InstanceLock(url: url))
        let (holder, out) = try perlLocker(url)
        defer { if holder.isRunning { kill(holder.processIdentifier, SIGKILL) } }
        #expect(waitForLine(out)?.contains("held") == true)

        #expect(!lock.tryAcquire(), "another process holds the lock")

        let got = Got()
        lock.acquireInBackground { got.set() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!got.value, "must keep waiting while the holder lives")

        let killedAt = Date()
        kill(holder.processIdentifier, SIGKILL)
        while !got.value, Date().timeIntervalSince(killedAt) < 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(got.value, "the kernel must hand the lock over within 2 s of a kill -9")
        print("INFO lock granted \(Int(Date().timeIntervalSince(killedAt) * 1000)) ms after kill -9")
    }

    @Test func whileWeHoldItAnotherProcessIsRefused() throws {
        let url = tempLockURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let lock = try #require(InstanceLock(url: url))
        #expect(lock.tryAcquire())
        let (other, _) = try perlLocker(url, nonBlocking: true)
        other.waitUntilExit()
        #expect(other.terminationStatus == 1, "the second process must not get the lock")
    }

    @Test func anUnopenableLockFileGivesNil() {
        #expect(InstanceLock(url: URL(fileURLWithPath: "/dev/null/nope/instance.lock")) == nil)
    }
}

private final class Got: @unchecked Sendable {
    private let q = DispatchQueue(label: "got")
    private var v = false
    func set() { q.sync { v = true } }
    var value: Bool { q.sync { v } }
}
