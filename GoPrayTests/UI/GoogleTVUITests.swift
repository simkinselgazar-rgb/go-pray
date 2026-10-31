// GoogleTVUITests.swift — Google TV in Settings: the remote-pairing flow in TVListModel, TV only in the Mode picker,
// and snapshots of the row, the code sheet and the TV-only Block section (PNG only when GOPRAY_SHOTS_DIR is set).

import Foundation
import SwiftUI
import Testing
@testable import GoPray

final class RemoteSender: TVSending, TVRemotePairing, @unchecked Sendable {
    var result: TVPairResult = .paired
    var error: TVError?
    var startResult = true
    var startError: TVError?
    private(set) var starts = 0
    private(set) var codes: [String] = []
    func startRemotePairing(_ tv: TVDevice) async throws -> Bool {
        starts += 1
        if let startError { throw startError }
        return startResult
    }
    func pairRemote(_ tv: TVDevice, code: String) async throws -> TVPairResult {
        codes.append(code)
        if let error { throw error }
        return result
    }
    func athanStarted(prayer: Prayer, voice: Voice, tvs: [TVDevice]) {}
    func resolve(_ tv: TVDevice) async -> TVResolution { .found(TVDevice.defaultCastAppId) }
    func test(_ tv: TVDevice, prayer: Prayer, voice: Voice) async throws {}
}

@MainActor @Suite("Google TV settings", .serialized)
struct GoogleTVUITests {
    private func model(_ f: UIFixture, sender: TVSending) -> (SettingsViewModel, String) {
        try? f.store.mutate { $0.tvs = [TVDevice(name: "Family Room TV", kind: .googleTV, host: "10.0.0.100")] }
        let m = SettingsViewModel(store: f.store, gate: f.gate, clock: f.clock, audio: f.audio, loginAgent: f.login,
                                  geocoder: f.geocoder, tv: sender)
        return (m, f.store.settings.tvs[0].id)
    }

    @Test func twoStepsPairAndSaveTheFlag() async {
        let f = UIFixture(); defer { f.cleanup() }
        let s = RemoteSender(); let (m, id) = model(f, sender: s)
        #expect(m.remoteHelp(for: m.tvs[0]) == "Pair remote to turn the TV back off")
        #expect(await m.startRemotePairing(id))                  // the TV now shows its code
        #expect(s.starts == 1 && s.codes.isEmpty)
        #expect(await m.pairRemote(id, code: " a1b2c3 ") == .paired)
        #expect(s.codes == ["A1B2C3"])                           // trimmed, upper-cased
        #expect(f.store.settings.tvs[0].remotePaired)
        #expect(m.remoteHelp(for: m.tvs[0]) == "Turns the TV back off after the Athan if it was off.")
        #expect(m.tvTestLines[id] == "Paired.")
    }

    @Test func startFailingPutsOneLineOnTheRowAndNoSheet() async {
        let f = UIFixture(); defer { f.cleanup() }
        let s = RemoteSender(); let (m, id) = model(f, sender: s)
        s.startResult = false
        #expect(await m.startRemotePairing(id) == false)
        #expect(m.tvTestLines[id] == "The TV did not answer")
        s.startError = .unreachable
        #expect(await m.startRemotePairing(id) == false)
        s.startError = .localNetworkDenied
        #expect(await m.startRemotePairing(id) == false)
        #expect(m.tvTestLines[id] == SettingsViewModel.allowLocalNetworkLine)
    }

    @Test func wrongCodeKeepsTheSheetAndRestartsTheHandshake() async {
        let f = UIFixture(); defer { f.cleanup() }
        let s = RemoteSender(); s.result = .denied; let (m, id) = model(f, sender: s)
        _ = await m.startRemotePairing(id)
        #expect(await m.pairRemote(id, code: "AAAAAA") == .tryAgain)
        #expect(m.tvTestLines[id] == "That code didn't match. Try again.")
        #expect(s.starts == 2)                                   // a fresh code on the TV
        #expect(!f.store.settings.tvs[0].remotePaired)
    }

    @Test func timedOutClosesTheSheetWithOneLine() async {
        let f = UIFixture(); defer { f.cleanup() }
        let s = RemoteSender(); s.result = .unsupported; let (m, id) = model(f, sender: s)
        _ = await m.startRemotePairing(id)
        #expect(await m.pairRemote(id, code: "ABCDEF") == .closed)
        #expect(m.tvTestLines[id] == "Pairing timed out. Press Pair remote again.")
        #expect(!f.store.settings.tvs[0].remotePaired)
    }

    @Test func aBadShapeNeverReachesTheTV() async {
        let f = UIFixture(); defer { f.cleanup() }
        let s = RemoteSender(); let (m, id) = model(f, sender: s)
        _ = await m.startRemotePairing(id)
        for bad in ["", "ABC", "ABCDEFG", "GHIJKL", "12 345"] { #expect(await m.pairRemote(id, code: bad) == .tryAgain) }
        #expect(s.codes.isEmpty && s.starts == 1)
        #expect(m.tvTestLines[id] == "That code didn't match. Try again.")
    }

    @Test func aSenderThatCannotPairSaysSo() async {
        let f = UIFixture(); defer { f.cleanup() }
        let (m, id) = model(f, sender: RecordingSender())
        #expect(await m.startRemotePairing(id) == false)
        #expect(m.tvTestLines[id] == "The TV did not answer")
    }

    @Test func onlyAGoogleTVPairsARemote() async {
        let f = UIFixture(); defer { f.cleanup() }
        try? f.store.mutate { $0.tvs = [TVDevice(name: "Den", kind: .samsung, host: "10.0.0.8")] }
        let s = RemoteSender()
        let m = SettingsViewModel(store: f.store, gate: f.gate, clock: f.clock, audio: f.audio, loginAgent: f.login, geocoder: f.geocoder, tv: s)
        #expect(await m.startRemotePairing(f.store.settings.tvs[0].id) == false)
        #expect(await m.pairRemote(f.store.settings.tvs[0].id, code: "ABCDEF") == .closed)
        #expect(s.codes.isEmpty && s.starts == 0)
    }

    @Test func tvOnlyIsAThirdModeAndSavesLikeTheOthers() {
        let f = UIFixture(); defer { f.cleanup() }
        let m = f.settingsModel()
        m.set(\.mode, to: .tvOnly)
        #expect(f.store.settings.mode == .tvOnly && BlockMode.tvOnly.displayName == "TV only")
    }

    // MARK: Snapshots

    @Test func snapshots() async {
        let f = UIFixture(); defer { f.cleanup() }
        let (m, id) = model(f, sender: RemoteSender())
        let snap = SnapshotTests(); let credits = AnyView(Text("Credits").padding())
        let size = CGSize(width: 560, height: 3200)
        await snap.shot("gtv-settings-unpaired", SettingsView(model: m, credits: credits), size: size)
        m.set(\.mode, to: .tvOnly)
        await snap.shot("gtv-settings-tv-only-mode", SettingsView(model: m, credits: credits), size: size)
        m.set(\.mode, to: .wholeScreen)
        _ = await m.startRemotePairing(id); _ = await m.pairRemote(id, code: "A1B2C3")
        await snap.shot("gtv-settings-paired", SettingsView(model: m, credits: credits), size: size)
        let sheet = RemoteCodeSheet(tv: m.tvs[0], model: m, isPresented: .constant(true))
        await snap.shot("gtv-code-sheet", sheet, size: CGSize(width: 340, height: 200))
    }
}
