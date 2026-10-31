// TVControllerGoogleTVTests.swift — the PM wiring for Google TV (Google TV Plan §5, §8 "PM after"): the production
// driver table, remote pairing through the controller into the saved flag, the merged scan, and the video warm-up.
// No network: the Google TV driver here is a stub, and the remote is `FakePower`.

import Foundation
import Testing
@testable import GoPray

/// A Google TV driver that never opens a socket.
private struct StubCast: TVControlling {
    func findChannel(_ tv: TVDevice) async throws -> String? { TVDevice.defaultCastAppId }
    func launch(_ tv: TVDevice, prayer: Prayer, voice: Voice, test: Bool) async throws {}
}

/// Records every warm, in order.
private final class WarmLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _voices: [Voice] = []
    var voices: [Voice] { lock.withLock { _voices } }
    func add(_ v: Voice) { lock.withLock { _voices.append(v) } }
}

@Suite("Google TV wiring") struct TVControllerGoogleTVTests {
    private let gtv = TVDevice(id: "g", name: "Den TV", kind: .googleTV, host: "10.0.0.77")

    @Test func productionHasAGoogleTVDriverSharingOneRemote() throws {
        let c = TVController()
        let cast = try #require(c.drivers[.googleTV] as? CastTV)
        let remote = try #require(c.remote as? AndroidRemote)
        #expect((cast.power as? AndroidRemote) === remote)          // the session Settings opens is the one CastTV reads
        #expect(c.drivers[.roku] is RokuTV && c.drivers[.samsung] is SamsungTV)
        #expect(c.warmer != nil)
    }

    @Test func remotePairingGoesThroughTheSharedRemote() async throws {
        let power = FakePower()
        let c = TVController(drivers: [.googleTV: StubCast()], remote: power)
        #expect(try await c.startRemotePairing(gtv))
        #expect(try await c.pairRemote(gtv, code: "A1B2C3") == .paired)
        #expect(power.starts.map(\.id) == ["g"] && power.pairs.map(\.code) == ["A1B2C3"])
        power.pairResult = .denied
        #expect(try await c.pairRemote(gtv, code: "FFFFFF") == .denied)
    }

    @Test func onlyAGoogleTVWithARemotePairs() async {
        let power = FakePower()
        let roku = TVDevice(name: "Roku", kind: .roku, host: "10.0.0.78")
        await #expect(throws: TVError.badURL) { try await TVController(drivers: [.googleTV: StubCast()], remote: power).startRemotePairing(roku) }
        await #expect(throws: TVError.badURL) { try await TVController(drivers: [.googleTV: StubCast()]).pairRemote(gtv, code: "A1B2C3") }
        #expect(power.starts.isEmpty && power.pairs.isEmpty)
    }

    @MainActor @Test func pairingSavesTheFlagAndADeniedCodeLeavesItOff() async {
        let f = UIFixture(); defer { f.cleanup() }
        try? f.store.mutate { $0.tvs = [gtv] }
        let power = FakePower()
        let c = TVController(drivers: [.googleTV: StubCast()], remote: power)
        let m = SettingsViewModel(store: f.store, gate: f.gate, clock: f.clock, audio: f.audio, loginAgent: f.login,
                                  geocoder: f.geocoder, tv: c)
        power.pairResult = .denied
        #expect(await m.startRemotePairing("g"))
        #expect(await m.pairRemote("g", code: "A1B2C3") == .tryAgain)
        #expect(f.store.settings.tvs[0].remotePaired == false)
        power.pairResult = .paired
        #expect(await m.pairRemote("g", code: "A1B2C3") == .paired)
        #expect(f.store.settings.tvs[0].remotePaired == true)
    }

    @Test func theScanMergesRokuAndGoogleTVOneEntryPerAddress() async {
        let roku = FixedDiscovery(found: [FoundTV(host: "10.0.0.7", name: "Den")])
        let cast = FixedDiscovery(found: [FoundTV(host: "10.0.0.9", name: "Family Room TV (BRAVIA 4K VH21)", kind: .googleTV),
                                          FoundTV(host: "10.0.0.7", name: "Den again", kind: .googleTV)], denied: true)
        let scan = await AllTVDiscovery([roku, cast]).scan()
        #expect(scan.found == [FoundTV(host: "10.0.0.7", name: "Den"),
                               FoundTV(host: "10.0.0.9", name: "Family Room TV (BRAVIA 4K VH21)", kind: .googleTV)])
        #expect(scan.denied)
    }

    @MainActor @Test func aFoundGoogleTVIsAddedAsAGoogleTV() async {
        let f = UIFixture(); defer { f.cleanup() }
        let found = FoundTV(host: "10.0.0.9", name: "Family Room TV", kind: .googleTV)
        let m = SettingsViewModel(store: f.store, gate: f.gate, clock: f.clock, audio: f.audio, loginAgent: f.login,
                                  geocoder: f.geocoder, tv: TVController(drivers: [.googleTV: StubCast()]),
                                  discovery: FixedDiscovery(found: [found]))
        await m.scanForTVs()
        await m.addFound(found)
        let tv = f.store.settings.tvs.first
        #expect(tv?.kind == .googleTV && tv?.channelId == TVDevice.defaultCastAppId && tv?.installed == true)
    }

    // MARK: Warm-up

    private func settings(_ tvs: [TVDevice], voice: Voice = .sunni("Minshawi")) -> Settings {
        var s = Settings.defaults; s.tvs = tvs; s.voice = voice; return s
    }

    @Test func warmsWhenAGoogleTVIsOnAndAgainWhenTheVoiceChanges() async {
        let log = WarmLog()
        let c = TVController(drivers: [:], warm: { log.add($0) })
        let roku = TVDevice(name: "Roku", kind: .roku, host: "10.0.0.78")
        var off = gtv; off.enabled = false
        let steps: [Settings] = [
            settings([roku]),                                   // no Google TV: nothing
            settings([roku, gtv]),                              // added: warm
            settings([roku, gtv]),                              // same again: nothing
            settings([gtv], voice: .shia("Salimi")),            // voice changed: warm
            settings([off], voice: .shia("Salimi")),            // switched off: nothing
            settings([gtv], voice: .shia("Salimi")),            // back on: warm
        ]
        for s in steps { c.settingsChanged(s); await c.warmer?.settle() }
        #expect(log.voices == [.sunni("Minshawi"), .shia("Salimi"), .shia("Salimi")])
    }

    @Test func aStaleWarmIsSkipped() async {
        let log = WarmLog()
        let gate = AsyncGate()
        let w = CastWarmer { v in log.add(v); if v == .sunni("Minshawi") { await gate.wait() } }
        w.note(settings([gtv]))                                                 // starts, then blocks
        try? await Task.sleep(for: .milliseconds(100))
        w.note(settings([gtv], voice: .shia("Salimi")))                        // queued behind it
        w.note(settings([gtv], voice: .sunni("Afasy")))                        // supersedes Salimi
        gate.open()
        await w.settle()
        #expect(log.voices == [.sunni("Minshawi"), .sunni("Afasy")])
    }
}

/// One-shot latch for the stale-warm test.
private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { k in
            let go = lock.withLock { () -> Bool in if opened { return true }; waiters.append(k); return false }
            if go { k.resume() }
        }
    }
    func open() {
        let ws = lock.withLock { () -> [CheckedContinuation<Void, Never>] in opened = true; defer { waiters = [] }; return waiters }
        ws.forEach { $0.resume() }
    }
}
