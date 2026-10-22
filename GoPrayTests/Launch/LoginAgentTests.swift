// LoginAgentTests.swift — lane C. Never registers anything.

import Foundation
import ServiceManagement
import Testing
@testable import GoPray

@MainActor struct LoginAgentTests {
    @Test func plistIsValidAndHasTheSpikeSettings() throws {
        // The copy the build phase installs in the app (the test host), where SMAppService reads it.
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/com.ahmedelgazar.gopray.agent.plist")
        let d = try #require(NSDictionary(contentsOf: url) as? [String: Any])
        #expect(d["Label"] as? String == "com.ahmedelgazar.gopray.agent")
        #expect(d["RunAtLoad"] as? Bool == true)
        #expect((d["KeepAlive"] as? [String: Any])?["SuccessfulExit"] as? Bool == false)
        #expect(d["ThrottleInterval"] as? Int == 1)
        #expect(d["BundleProgram"] as? String == "Contents/MacOS/Go Pray")
    }

    @Test func plistNameMatchesTheFile() {
        #expect(LoginAgentCopy.plistName == "com.ahmedelgazar.gopray.agent.plist")
    }

    // MARK: unregister() never leaves the app with no successor

    private final class FakeService: AgentService {
        var status: SMAppService.Status = .enabled
        var unregisterCalls = 0
        func register() throws {}
        func unregister() throws { unregisterCalls += 1; status = .notRegistered }
    }

    @Test func agentCopyThatCannotStartASuccessorStaysRegistered() {
        let service = FakeService()
        let agent = LoginAgent(service: service, isAgentProcess: { true }, startSuccessor: { false })
        #expect(throws: LoginAgentError.successorFailed) { try agent.unregister() }
        #expect(service.unregisterCalls == 0)
    }

    @Test func agentCopyWithASuccessorUnregisters() throws {
        let service = FakeService()
        var started = 0
        let agent = LoginAgent(service: service, isAgentProcess: { true }, startSuccessor: { started += 1; return true })
        try agent.unregister()
        #expect(started == 1)
        #expect(service.unregisterCalls == 1)
    }

    @Test func aHandOpenedCopyNeedsNoSuccessor() throws {
        let service = FakeService()
        let agent = LoginAgent(service: service, isAgentProcess: { false }, startSuccessor: { false })
        try agent.unregister()
        #expect(service.unregisterCalls == 1)
    }
}
