// LoginAgent.swift — LoginAgentManaging on SMAppService.agent. Owner: lane C.
// The plist (Launch/com.ahmedelgazar.gopray.agent.plist) is copied to
// Contents/Library/LaunchAgents by the PM build phase. Spike Q3: register() needs no
// approval, macOS shows one "Go Pray can run in the background" banner.

import Foundation
import ServiceManagement

enum LoginAgentCopy {
    static let plistName = "com.ahmedelgazar.gopray.agent.plist"
    /// For lane A's first-run screen, shown right before register().
    static let firstRunNote = "macOS will show a note that Go Pray can run in the background. That is expected. It keeps the Athan on time."
}

enum LoginAgentError: Error, Equatable {
    /// The copy that would take over could not be started: unregistering now would end the app.
    case successorFailed
}

/// The part of SMAppService this file uses, so tests never touch the real registration.
protocol AgentService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}
extension SMAppService: AgentService {}

@MainActor final class LoginAgent: LoginAgentManaging {
    private let service: AgentService
    private let isAgentProcess: () -> Bool
    private let startSuccessor: () -> Bool

    init(service: AgentService = SMAppService.agent(plistName: LoginAgentCopy.plistName),
         isAgentProcess: @escaping () -> Bool = { SingleInstance.role(environment: ProcessInfo.processInfo.environment) == .agent },
         startSuccessor: @escaping () -> Bool = LoginAgent.openSuccessor) {
        self.service = service
        self.isAgentProcess = isAgentProcess
        self.startSuccessor = startSuccessor
    }

    var isRegistered: Bool { service.status == .enabled }

    func register() throws {
        guard service.status != .enabled else { return }
        try service.register()
    }

    /// Unregistering stops the launchd job. When this process IS that job (the usual case),
    /// start a successor first: it waits for the instance lock and takes over when this copy
    /// is gone, so turning launch at login off never closes the app (App/SingleInstance.swift).
    /// If the successor cannot be started, throw and stay registered (the view model rolls back).
    func unregister() throws {
        guard service.status != .notRegistered else { return }
        if isAgentProcess(), !startSuccessor() { throw LoginAgentError.successorFailed }
        try service.unregister()
    }

    /// True if `open` started and exited 0.
    nonisolated static func openSuccessor() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", "-g", Bundle.main.bundleURL.path, "--args", SingleInstance.successorArgument, "YES"]
        do { try p.run(); p.waitUntilExit() } catch { return false }
        return p.terminationStatus == 0
    }

    /// The raw SMAppService status (the repair decision is `SingleInstance.shouldRepairAgent`).
    var status: SMAppService.Status { service.status }
}
