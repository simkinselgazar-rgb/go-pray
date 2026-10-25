// SetupTVStepTests.swift — the optional "Play the Athan on your TV?" step of first-run setup.
// The TV rules live in TVListModel (shared with Settings); these tests check that setup
// places the step, saves through the normal path, and says the right thing per state.

import Foundation
import Testing
@testable import GoPray

/// Counts scans, so a test can prove the step uses the shared helper.
final class CountingDiscovery: TVDiscovering, @unchecked Sendable {
    var scans = 0
    var hang = false
    var result = TVScan(found: [FoundTV(host: "192.168.1.20", name: "Living room")])
    func scan() async -> TVScan {
        scans += 1
        if hang { try? await Task.sleep(for: .seconds(30)) }
        return result
    }
}

@MainActor @Suite("Setup: Your TV")
struct SetupTVStepTests {
    private func atTVStep(_ m: SetupViewModel) {
        m.pickedCity = .toronto
        m.next(); m.next(); m.next()
    }

    @Test func theStepComesAfterTheQuestionsAndBeforeFinish() {
        let f = UIFixture(configured: false); defer { f.cleanup() }
        #expect(SetupViewModel.Step.allCases == [.city, .method, .mode, .tv, .done])
        let m = f.setupModel()
        atTVStep(m)
        #expect(m.step == .tv && m.title == "Play the Athan on your TV?")
        #expect(f.store.settings.setupComplete == false)
        #expect(m.canGoNext)
        m.back(); #expect(m.step == .mode)
    }

    @Test func skipSavesNoTV() {
        let f = UIFixture(configured: false); defer { f.cleanup() }
        let m = f.setupModel()
        atTVStep(m)
        #expect(!m.hasTV)
        m.next()                                                // Skip
        #expect(m.step == .done && f.store.settings.setupComplete)
        #expect(f.store.settings.tvs.isEmpty)
    }

    @Test func addSavesThroughTheNormalPathAndFinishKeepsIt() async {
        let f = UIFixture(configured: false); defer { f.cleanup() }
        let s = RecordingSender(); s.resolution = .found("424242")
        let m = f.setupModel(tv: s)
        atTVStep(m)
        #expect(await m.tvs.addTVAndCheck(host: "192.168.1.20", name: "Den"))
        #expect(f.store.settings.tvs.map(\.host) == ["192.168.1.20"])
        #expect(f.store.settings.tvs[0].channelId == "424242")
        #expect(m.hasTV && m.tvs.status(of: f.store.settings.tvs[0].id) == .ready)
        m.next()                                                // Continue
        #expect(m.step == .done && f.store.settings.setupComplete)
        #expect(f.store.settings.tvs.count == 1 && f.store.settings.city == "Toronto, Ontario")
    }

    @Test func aBadAddressIsRefusedWithTheSettingsLine() async {
        let f = UIFixture(configured: false); defer { f.cleanup() }
        let m = f.setupModel()
        atTVStep(m)
        #expect(await m.tvs.addTyped("8.8.8.8") == false)
        #expect(m.notice == TVListModel.badAddressLine && f.store.settings.tvs.isEmpty)
    }

    @Test func notInstalledAndDeniedMapToTheRightText() async {
        let f = UIFixture(configured: false); defer { f.cleanup() }
        let s = RecordingSender(); s.resolution = .notInstalled
        let m = f.setupModel(tv: s)
        atTVStep(m)
        _ = await m.tvs.addTVAndCheck(host: "10.0.0.7", name: "Den")
        let id = f.store.settings.tvs[0].id
        #expect(m.tvs.status(of: id) == .notInstalled)
        #expect(TVListModel.notInstalledSetupLine == "Go Pray isn't installed on this TV yet. Search 'Go Pray' in the Roku Channel Store.")
        s.resolution = .localNetworkDenied
        await m.tvs.refreshTV(id)
        #expect(m.tvs.status(of: id) == .needsNetworkAccess)
        #expect(TVListModel.allowLocalNetworkLine == SettingsViewModel.allowLocalNetworkLine)
        s.resolution = .unreachable
        await m.tvs.refreshTV(id)
        #expect(m.tvs.status(of: id) == .notReached)
    }

    @Test func playATestUsesTheSharedTestPath() async {
        let f = UIFixture(configured: false); defer { f.cleanup() }
        let s = RecordingSender()
        let m = f.setupModel(tv: s)
        atTVStep(m)
        _ = await m.tvs.addTVAndCheck(host: "10.0.0.7", name: "Den")
        await m.tvs.testTV(f.store.settings.tvs[0].id)
        #expect(s.tests.count == 1)
        #expect(m.tvs.tvTestLines[f.store.settings.tvs[0].id] == TVListModel.testSentLine)
    }

    @Test func theScanGoesThroughTheSharedHelper() async {
        let f = UIFixture(configured: false); defer { f.cleanup() }
        let d = CountingDiscovery()
        let m = f.setupModel(discovery: d)
        atTVStep(m)
        #expect(m.tvs.scanState == .idle)
        await m.tvs.scanForTVs()
        #expect(d.scans == 1 && m.tvs.scanState == .done)
        #expect(m.tvs.foundTVs == [FoundTV(host: "192.168.1.20", name: "Living room")])
        d.result = TVScan(found: [], denied: true)
        await m.tvs.scanForTVs()
        #expect(m.tvs.scanNeedsNetworkAccess)
    }

    @Test func settingsAndSetupShareOneModelType() async {
        let f = UIFixture(); defer { f.cleanup() }
        let d = CountingDiscovery()
        let m = SettingsViewModel(store: f.store, gate: f.gate, clock: f.clock, audio: f.audio, loginAgent: f.login,
                                  geocoder: f.geocoder, discovery: d)
        await m.scanForTVs()
        #expect(d.scans == 1 && m.foundTVs.count == 1)
    }
}
