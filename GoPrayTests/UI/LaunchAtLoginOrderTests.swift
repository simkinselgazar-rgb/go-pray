// LaunchAtLoginOrderTests.swift — turning launch at login off saves first. Owner: PM (wiring).
// Unregistering stops the launchd copy of the app, so the setting must already be on disk
// when unregister() runs (found live 2026-10-22: the setting stayed true and the app quit).

import Foundation
import Testing
@testable import GoPray

@MainActor private final class SpyLoginAgent: LoginAgentManaging {
    var isRegistered = true
    var failure: Error?
    var sawOnDisk: Bool?
    var unregisterCalls = 0
    let settingsFile: URL
    init(settingsFile: URL) { self.settingsFile = settingsFile }
    func register() throws { isRegistered = true }
    func unregister() throws {
        unregisterCalls += 1
        let json = (try? String(contentsOf: settingsFile, encoding: .utf8)) ?? ""
        sawOnDisk = json.contains("\"launchAtLogin\" : true")
        if let failure { throw failure }
        isRegistered = false
    }
}

private struct Boom: Error {}

@MainActor @Suite("Launch at login off: save first")
struct LaunchAtLoginOrderTests {
    private func model(_ f: UIFixture, _ spy: SpyLoginAgent) -> SettingsViewModel {
        SettingsViewModel(store: f.store, gate: f.gate, clock: f.clock, audio: f.audio, loginAgent: spy, geocoder: f.geocoder)
    }

    @Test func theSettingIsOnDiskBeforeUnregisterRuns() {
        let f = UIFixture(); defer { f.cleanup() }
        try? f.store.mutate { $0.launchAtLogin = true }
        let spy = SpyLoginAgent(settingsFile: f.store.fileURL)
        model(f, spy).setLaunchAtLogin(false)
        #expect(spy.unregisterCalls == 1)
        #expect(spy.sawOnDisk == false, "launchAtLogin must already read false on disk")
        #expect(f.store.settings.launchAtLogin == false)
    }

    @Test func aFailedUnregisterPutsTheSettingBack() {
        let f = UIFixture(); defer { f.cleanup() }
        try? f.store.mutate { $0.launchAtLogin = true }
        let spy = SpyLoginAgent(settingsFile: f.store.fileURL)
        spy.failure = Boom()
        let m = model(f, spy)
        m.setLaunchAtLogin(false)
        #expect(f.store.settings.launchAtLogin == true)
        #expect(m.notice?.contains("launch at login") == true)
    }

    #if DEBUG
    @Test func duringABlockNothingIsUnregistered() {
        let f = UIFixture(); defer { f.cleanup() }
        try? f.store.mutate { $0.launchAtLogin = true }
        f.gate.debugTriggerAthan(.maghrib, lockSeconds: 20)
        let spy = SpyLoginAgent(settingsFile: f.store.fileURL)
        model(f, spy).setLaunchAtLogin(false)
        #expect(spy.unregisterCalls == 0)
        #expect(f.store.settings.launchAtLogin == true)
    }
    #endif
}
