// SamsungTVTests.swift — the Samsung driver (Samsung TV Plan §6): the exact wire bytes against a fake TV on localhost,
// pairing, the trust decision (a pure function, plus the delegate with a real certificate), the token store, and the
// Settings model. The gate cases (late wake, once per Athan) are in TVTests.swift with a Samsung device in the fixtures.

import CryptoKit
import Foundation
import Security
import Testing
@testable import GoPray

private let samsungHostCheck: @Sendable (String) -> Bool = { $0 == "127.0.0.1" || TVHost.isAllowed($0) }
private let pin = String(repeating: "ab", count: 32)        // a stand-in fingerprint: the fake has no TLS to pin

/// Tests only. Records what the driver asked of the store.
final class MemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: StoredTVToken] = [:]
    private var _deleted: [String] = []
    private var _saves = 0
    var deleted: [String] { lock.withLock { _deleted } }
    var saves: Int { lock.withLock { _saves } }
    func load(_ tvID: String) -> StoredTVToken? { lock.withLock { items[tvID] } }
    @discardableResult func save(_ tvID: String, token: String, fingerprint: String) -> Bool {
        guard TVTokenRules.encode(StoredTVToken(token: token, fingerprint: fingerprint)) != nil else { return false }
        lock.withLock { items[tvID] = StoredTVToken(token: token, fingerprint: fingerprint); _saves += 1 }
        return true
    }
    func delete(_ tvID: String) { lock.withLock { items[tvID] = nil; _deleted.append(tvID) } }
}

private func samsungTV(_ host: String = "127.0.0.1", id: String = "tv-1", app: String = "GoPrayAth1.GoPray") -> TVDevice {
    TVDevice(id: id, name: "Den", kind: .samsung, host: host, channelId: app)
}

private func samsung(_ s: FakeSamsungServer, tokens: MemoryTokenStore = MemoryTokenStore(), connectWait: Double = 1.5,
                     pairWait: Double = 1.5, hostCheck: @escaping @Sendable (String) -> Bool = samsungHostCheck) -> SamsungTV {
    SamsungTV(restPort: s.restPort, wsPort: s.wsPort, wsScheme: "ws", hostCheck: hostCheck, tokens: tokens,
              connectWait: connectWait, pairWait: pairWait, pinOverride: pin)
}

private func waitUntil(_ ok: @escaping () -> Bool, seconds: Double = 5) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { if ok() { return true }; try? await Task.sleep(for: .milliseconds(20)) }
    return ok()
}

private func emitJSON(_ text: String) -> [String: Any]? { try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] }

@Suite("Samsung wire call") struct SamsungWireTests {
    @Test func pairedTVGetsOneSocketLaunchWithTheRightMetaTag() async throws {
        let s = FakeSamsungServer(); s.wsMode = .connect(token: "t0k3n")
        let tokens = MemoryTokenStore(); tokens.save("tv-1", token: "Abc123", fingerprint: pin)
        try await samsung(s, tokens: tokens).launch(samsungTV(), prayer: .asr, voice: .sunni("Minshawi"), test: false)
        #expect(await waitUntil { s.emits.count == 1 })
        #expect(s.wsRequests.count == 1)
        let line = try #require(s.wsRequests.first)
        #expect(line.hasPrefix("GET /api/v2/channels/samsung.remote.control?name=R28gUHJheQ==&token=Abc123 HTTP/1.1"), "\(line)")
        let obj = try #require(emitJSON(s.emits[0]))
        #expect(obj["method"] as? String == "ms.channel.emit")
        let params = try #require(obj["params"] as? [String: Any])
        #expect(params["event"] as? String == "ed.apps.launch" && params["to"] as? String == "host")
        let data = try #require(params["data"] as? [String: Any])
        #expect(data["appId"] as? String == "GoPrayAth1.GoPray" && data["action_type"] as? String == "DEEP_LINK")
        #expect(data["metaTag"] as? String == "prayer=asr&voice=sunni.Minshawi")
        #expect(s.posts.isEmpty, "the socket worked, so no second launch")
    }

    @Test func testButtonAddsTheTestFlagAndAnAthanNeverDoes() async throws {
        let s = FakeSamsungServer(); s.wsMode = .connect(token: "x")
        let tokens = MemoryTokenStore(); tokens.save("tv-1", token: "Abc123", fingerprint: pin)
        let d = samsung(s, tokens: tokens)
        try await d.launch(samsungTV(), prayer: .fajr, voice: .shia("Sobhdel"), test: true)
        try await d.launch(samsungTV(), prayer: .fajr, voice: .shia("Sobhdel"), test: false)
        #expect(await waitUntil { s.emits.count == 2 })
        let tags = s.emits.compactMap { emitJSON($0) }.compactMap { (($0["params"] as? [String: Any])?["data"] as? [String: Any])?["metaTag"] as? String }
        #expect(tags.sorted() == ["prayer=fajr&voice=shia.Sobhdel", "prayer=fajr&voice=shia.Sobhdel&test=1"])
    }

    @Test func notPairedMeansNoSocketAndOneEmptyPost() async throws {
        let s = FakeSamsungServer()
        try await samsung(s).launch(samsungTV(), prayer: .asr, voice: .sunni("x"), test: false)
        #expect(s.wsRequests.isEmpty, "the Athan path never opens a socket without a token")
        let p = try #require(s.posts.first)
        #expect(s.posts.count == 1 && p.requestLine == "POST /api/v2/applications/GoPrayAth1.GoPray HTTP/1.1")
        #expect(p.body.isEmpty && p.headers["content-length"] == "0")
    }

    @Test func socketFailuresFallBackToTheBasicLaunch() async throws {
        let modes: [FakeSamsungServer.WSMode] = [.refuse, .timeOut, .unauthorized, .silence]
        for mode in modes {
            let s = FakeSamsungServer(); s.wsMode = mode
            let tokens = MemoryTokenStore(); tokens.save("tv-1", token: "Abc123", fingerprint: pin)
            try await samsung(s, tokens: tokens, connectWait: 0.6).launch(samsungTV(), prayer: .asr, voice: .sunni("x"), test: false)
            #expect(s.posts.count == 1, "\(mode)")
            #expect(s.emits.isEmpty, "\(mode): nothing was sent over the socket")
        }
    }

    @Test func socketClosedPortFallsBackToo() async throws {
        let s = FakeSamsungServer(); s.stopWS()
        let tokens = MemoryTokenStore(); tokens.save("tv-1", token: "Abc123", fingerprint: pin)
        try await samsung(s, tokens: tokens).launch(samsungTV(), prayer: .asr, voice: .sunni("x"), test: false)
        #expect(s.posts.count == 1)
    }

    @Test func standbyMeansNothingIsSentAtAll() async throws {
        let s = FakeSamsungServer(); s.deviceJSON = #"{"device":{"PowerState":"standby"}}"#; s.wsMode = .connect(token: "x")
        let tokens = MemoryTokenStore(); tokens.save("tv-1", token: "Abc123", fingerprint: pin)
        try await samsung(s, tokens: tokens).launch(samsungTV(), prayer: .asr, voice: .sunni("x"), test: false)
        #expect(s.posts.isEmpty && s.wsRequests.isEmpty && s.emits.isEmpty)
        #expect(s.requests.map(\.requestLine) == ["GET /api/v2/ HTTP/1.1"])
    }

    @Test func standbyOnTheTestButtonSaysSoInsteadOfPretending() async {
        let s = FakeSamsungServer(); s.deviceJSON = #"{"device":{"PowerState":"standby"}}"#
        await #expect(throws: TVError.standby) { try await samsung(s).launch(samsungTV(), prayer: .asr, voice: .sunni("x"), test: true) }
        #expect(s.posts.isEmpty)
    }

    @Test func absentOrJunkPowerStateProceeds() async throws {
        for body in [#"{"device":{}}"#, "not json", "{}"] {
            let s = FakeSamsungServer(); s.deviceJSON = body
            try await samsung(s).launch(samsungTV(), prayer: .asr, voice: .sunni("x"), test: false)
            #expect(s.posts.count == 1, "\(body)")
        }
    }

    @Test func tvOffThrowsUnreachableWithinThreeSeconds() async {
        let s = FakeSamsungServer(); let d = samsung(s); s.stop()
        let t0 = Date()
        await #expect(throws: TVError.unreachable) { try await d.launch(samsungTV(), prayer: .asr, voice: .sunni("x"), test: false) }
        #expect(Date().timeIntervalSince(t0) < 3.5)
    }

    @Test func tvAnswering500IsBadStatus() async {
        let s = FakeSamsungServer(); s.postStatus = 500
        await #expect(throws: TVError.badStatus(500)) { try await samsung(s).launch(samsungTV(), prayer: .asr, voice: .sunni("x"), test: false) }
    }

    @Test func redirectIsNotFollowed() async {
        let s = FakeSamsungServer(); s.postStatus = 302
        await #expect(throws: TVError.badStatus(302)) { try await samsung(s).launch(samsungTV(), prayer: .asr, voice: .sunni("x"), test: false) }
        #expect(s.posts.count == 1)
    }

    @Test func badHostsAreRefusedBeforeAnySocket() async {
        let s = FakeSamsungServer()
        let d = SamsungTV(restPort: s.restPort, wsPort: s.wsPort, wsScheme: "ws", tokens: { let t = MemoryTokenStore(); t.save("tv-1", token: "Abc123", fingerprint: pin); return t }())
        for host in ["8.8.8.8", "localhost", "tv.local", "127.0.0.1", "::1", " 10.0.0.1"] {
            await #expect(throws: TVError.refusedHost, "\(host)") { try await d.launch(samsungTV(host), prayer: .asr, voice: .sunni("x"), test: false) }
            await #expect(throws: TVError.refusedHost, "\(host)") { _ = try await d.pair(samsungTV(host)) }
            await #expect(throws: TVError.refusedHost, "\(host)") { _ = try await d.findChannel(samsungTV(host)) }
        }
        #expect(s.requests.isEmpty && s.wsRequests.isEmpty)
    }

    @Test func badAppIdIsRefusedBeforeAnySocket() async {
        let s = FakeSamsungServer()
        for bad in ["dev", "../x", "GoPrayAth1/GoPray", "", "short.GoPray", "GoPrayAth1.Go Pray"] {
            await #expect(throws: TVError.badURL, "\(bad)") { try await samsung(s).launch(samsungTV(app: bad), prayer: .asr, voice: .sunni("x"), test: false) }
        }
        #expect(s.requests.isEmpty && s.wsRequests.isEmpty)
    }

    @Test func controllerUsesTheSamsungDriverAndSkipsDisabledTVs() async {
        let s = FakeSamsungServer()
        let c = TVController(drivers: [.samsung: samsung(s)])
        c.athanStarted(prayer: .isha, voice: .sunni("Hafez"), tvs: [samsungTV(), { var t = samsungTV(id: "off"); t.enabled = false; return t }()])
        #expect(await waitUntil { s.posts.count == 1 })
        try? await Task.sleep(for: .milliseconds(200))
        #expect(s.posts.count == 1)
    }
}

@Suite("Samsung finds the app") struct SamsungFindTests {
    @Test func installedIs200WithJSON() async throws {
        let s = FakeSamsungServer()
        #expect(try await samsung(s).findChannel(samsungTV()) == "GoPrayAth1.GoPray")
        #expect(s.requests.first?.requestLine == "GET /api/v2/applications/GoPrayAth1.GoPray HTTP/1.1")
    }

    @Test func notInstalledIs404() async throws {
        let s = FakeSamsungServer(); s.appStatus = 404
        #expect(try await samsung(s).findChannel(samsungTV()) == nil)
    }

    @Test func otherStatusThrowsAndJunkIsNothing() async throws {
        let s = FakeSamsungServer(); s.appStatus = 500
        await #expect(throws: TVError.badStatus(500)) { _ = try await samsung(s).findChannel(samsungTV()) }
        s.appStatus = 200; s.appJSON = "<html>not json</html>"
        #expect(try await samsung(s).findChannel(samsungTV()) == nil)
    }

    @Test func tvOffThrows() async {
        let s = FakeSamsungServer(); let d = samsung(s); s.stop()
        await #expect(throws: TVError.unreachable) { _ = try await d.findChannel(samsungTV()) }
    }

    @Test func a200MBBodyIsAbandonedAtTheCap() async throws {
        let s = FakeSamsungServer(); s.streamBytes = 200 * 1024 * 1024
        #expect(try await samsung(s).findChannel(samsungTV()) == nil)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(s.bytesWritten < 20 * 1024 * 1024, "server wrote \(s.bytesWritten)")
    }

    @Test func onlyTheNamedFieldsAreReadAndCapped() {
        let long = String(repeating: "x", count: 500)
        #expect(SamsungReply.appName(in: Data(#"{"name":"\#(long)"}"#.utf8))?.count == TVDevice.maxNameLength)
        #expect(SamsungReply.appName(in: Data(#"{"id":"1"}"#.utf8)) == "")
        #expect(SamsungReply.appName(in: Data("[1,2]".utf8)) == nil)
        #expect(SamsungReply.appName(in: Data(repeating: 0x20, count: RokuApps.maxBytes + 1)) == nil)
        #expect(SamsungReply.powerState(in: Data(#"{"device":{"PowerState":"standby","name":"Den"}}"#.utf8)) == "standby")
        #expect(SamsungReply.powerState(in: Data(#"{"device":{"PowerState":7}}"#.utf8)) == nil)
        #expect(SamsungReply.powerState(in: Data(#"{"device":{"PowerState":"\#(long)"}}"#.utf8))?.count == SamsungReply.maxStateLength)
    }

    @Test func frameParsingReadsOnlyEventAndTokenAndCapsSize() {
        let ok = SamsungReply.frame(.string(#"{"event":"ms.channel.connect","data":{"token":"abc","clients":[1,2,3]},"x":1}"#))
        #expect(ok?.event == "ms.channel.connect" && ok?.token == "abc")
        #expect(SamsungReply.frame(.string(#"{"data":{}}"#)) == nil)
        #expect(SamsungReply.frame(.data(Data("{}".utf8))) == nil)
        let big = #"{"event":"e","pad":""# + String(repeating: "a", count: SamsungReply.maxFrameBytes) + #""}"#
        #expect(SamsungReply.frame(.string(big)) == nil)
    }
}

@Suite("Samsung pairing") struct SamsungPairTests {
    @Test func tokenAndFingerprintAreSavedAndNoTokenIsSentWhilePairing() async throws {
        let s = FakeSamsungServer(); s.wsMode = .connect(token: "12345678")
        let tokens = MemoryTokenStore()
        let r = try await samsung(s, tokens: tokens).pair(samsungTV())
        #expect(r == .paired)
        #expect(tokens.load("tv-1") == StoredTVToken(token: "12345678", fingerprint: pin))
        let line = try #require(s.wsRequests.first)
        #expect(line.hasPrefix("GET /api/v2/channels/samsung.remote.control?name=R28gUHJheQ== HTTP/1.1"), "pairing opens the token-less socket: \(line)")
    }

    @Test func deniedSavesNothing() async throws {
        let s = FakeSamsungServer(); s.wsMode = .unauthorized
        let tokens = MemoryTokenStore()
        #expect(try await samsung(s, tokens: tokens).pair(samsungTV()) == .denied)
        #expect(tokens.saves == 0 && tokens.load("tv-1") == nil)
    }

    @Test func silenceTimeOutAndNoTokenAreUnsupported() async throws {
        let cases: [FakeSamsungServer.WSMode] = [.silence, .timeOut, .connect(token: nil)]
        for mode in cases {
            let s = FakeSamsungServer(); s.wsMode = mode
            let tokens = MemoryTokenStore()
            #expect(try await samsung(s, tokens: tokens, pairWait: 0.5).pair(samsungTV()) == .unsupported, "\(mode)")
            #expect(tokens.saves == 0, "\(mode)")
        }
    }

    @Test func aBadTokenIsRefusedAndNothingIsSaved() async throws {
        for bad in ["ab/cd", String(repeating: "a", count: 200), "", "a b", "../x"] {
            let s = FakeSamsungServer(); s.wsMode = .connect(token: bad)
            let tokens = MemoryTokenStore()
            #expect(try await samsung(s, tokens: tokens).pair(samsungTV()) == .unsupported, "\(bad.prefix(10))")
            #expect(tokens.saves == 0)
        }
    }

    @Test func anOversizeFrameIsNotReadAsAnAnswer() async {
        let s = FakeSamsungServer(); s.wsMode = .bigFrame
        let tokens = MemoryTokenStore()
        let r = try? await samsung(s, tokens: tokens, pairWait: 1).pair(samsungTV())
        #expect(r != .paired && tokens.saves == 0)
    }

    @Test func tvOffThrows() async {
        let s = FakeSamsungServer(); let d = samsung(s); s.stop()
        await #expect(throws: TVError.unreachable) { _ = try await d.pair(samsungTV()) }
    }

    @Test func aRokuNeedsNoPairing() async throws {
        let s = FakeTVServer()
        let r = RokuTV(port: s.port, hostCheck: samsungHostCheck)
        #expect(try await r.pair(TVDevice(name: "x", host: "127.0.0.1")) == .notNeeded)
        #expect(!r.isPaired(TVDevice(name: "x", host: "127.0.0.1")))
    }

    @Test func removingTheTVDeletesItsToken() async throws {
        let s = FakeSamsungServer()
        let tokens = MemoryTokenStore(); tokens.save("tv-1", token: "Abc123", fingerprint: pin)
        let c = TVController(drivers: [.samsung: samsung(s, tokens: tokens)])
        #expect(c.isPaired(samsungTV()))
        c.forget(samsungTV())
        #expect(tokens.deleted == ["tv-1"] && !c.isPaired(samsungTV()))
    }
}

// MARK: - Trust

/// A real self-signed certificate (EC P-256, CN=samsung-test), so the delegate runs on a genuine `SecTrust`.
private let fixtureCertDER = Data(base64Encoded: "MIIBYTCCAQigAwIBAgIUKosxZSjSXu0y0rfjvscn7NWRYwswCgYIKoZIzj0EAwIwFzEVMBMGA1UEAwwMc2Ftc3VuZy10ZXN0MB4XDTI2MTAyOTA0MzczNVoXDTM2MTAyNjA0MzczNVowFzEVMBMGA1UEAwwMc2Ftc3VuZy10ZXN0MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE/sm/VyLsT7V/UWZyHf9kGzJMDVoir0R2lX5lZDeMDB1c7RrP1m9YXKua2SdzdPnAfB4THlMHhjAWFBUSoHiox6MyMDAwHQYDVR0OBBYEFN9D+HEXOhHMvLEIGlK3U6ybM3NYMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDRwAwRAIgQ70KyrQkdEn52LQehRbz7w9+E1LyBqvklUdB8PqWgIsCIDQ3bjjKI9/FOT5DisvgnvQwDdSNFLMY54st6hRPLH7I")!
private let fixtureFingerprint = "5e315a30f482438b2ceba1077e9ea7b0d33bf7e113e6b05e4e643214e8020730"

private func fixtureTrust() -> SecTrust {
    let cert = SecCertificateCreateWithData(nil, fixtureCertDER as CFData)!
    var trust: SecTrust?
    SecTrustCreateWithCertificates(cert, SecPolicyCreateBasicX509(), &trust)
    return trust!
}

@Suite("Samsung TLS trust") struct SamsungTrustTests {
    private let method = NSURLAuthenticationMethodServerTrust
    private let lan = "192.168.1.50"

    private func decide(method: String? = nil, host: String? = nil, port: Int = 8002, leaf: String? = "aa", stored: String? = nil,
                        allowed: String? = nil) -> SamsungTrust.Decision {
        SamsungTrust.decide(method: method ?? self.method, host: host ?? lan, port: port, leafFingerprint: leaf, stored: stored, allowedHost: allowed ?? lan)
    }

    @Test func rightHostPortAndServerTrustIsUsedAndFirstUseIsFlagged() {
        #expect(decide() == .use(firstUse: true))
        #expect(decide(stored: "aa") == .use(firstUse: false))
    }

    @Test func otherHostIsNotExcused() {
        #expect(decide(host: "192.168.1.51") == .defaultHandling)
        #expect(decide(host: "127.0.0.2", allowed: "127.0.0.1") == .defaultHandling)
        #expect(decide(host: "tv.local") == .defaultHandling)
    }

    @Test func otherPortIsNotExcused() {
        #expect(decide(port: 443) == .defaultHandling)
        #expect(decide(port: 8001) == .defaultHandling)
    }

    @Test func otherAuthenticationMethodsAreNotExcused() {
        for m in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodClientCertificate, NSURLAuthenticationMethodNTLM, NSURLAuthenticationMethodDefault] {
            #expect(decide(method: m) == .defaultHandling, "\(m)")
        }
    }

    @Test func aPublicOrLoopbackAllowedHostIsNeverExcused() {
        #expect(decide(host: "8.8.8.8", allowed: "8.8.8.8") == .defaultHandling)
        #expect(decide(host: "127.0.0.1", allowed: "127.0.0.1") == .defaultHandling)
    }

    @Test func noLeafMeansNoTrust() {
        #expect(decide(leaf: nil) == .defaultHandling)
    }

    @Test func aDifferentFingerprintCancels() {
        #expect(decide(leaf: "bb", stored: "aa") == .cancel)
    }

    // The delegate, on a real certificate.

    @Test func delegatePinsOnFirstUseWhilePairing() {
        let d = SamsungTLSDelegate(allowedHost: lan, stored: nil, allowFirstUse: true)
        #expect(d.evaluate(method: method, host: lan, port: 8002, trust: fixtureTrust()) == .trust)
        #expect(d.observed == fixtureFingerprint && !d.mismatch)
    }

    @Test func delegateNeverPinsANewCertificateOnALaunch() {
        let d = SamsungTLSDelegate(allowedHost: lan, stored: nil, allowFirstUse: false)
        #expect(d.evaluate(method: method, host: lan, port: 8002, trust: fixtureTrust()) == .defaultHandling)
        #expect(d.observed == nil)
    }

    @Test func delegateTrustsThePinnedCertificateAndCancelsAnyOther() {
        let same = SamsungTLSDelegate(allowedHost: lan, stored: fixtureFingerprint, allowFirstUse: false)
        #expect(same.evaluate(method: method, host: lan, port: 8002, trust: fixtureTrust()) == .trust)
        let other = SamsungTLSDelegate(allowedHost: lan, stored: String(repeating: "0", count: 64), allowFirstUse: false)
        #expect(other.evaluate(method: method, host: lan, port: 8002, trust: fixtureTrust()) == .cancel)
        #expect(other.mismatch)
    }

    /// Negative control (c): a connection to any host other than the one in Settings is refused, even with a pinned-looking certificate.
    @Test func delegateRefusesAnotherHostWhateverTheCertificate() {
        for first in [true, false] {
            let d = SamsungTLSDelegate(allowedHost: lan, stored: first ? nil : fixtureFingerprint, allowFirstUse: first)
            #expect(d.evaluate(method: method, host: "192.168.1.51", port: 8002, trust: fixtureTrust()) == .defaultHandling)
            #expect(d.evaluate(method: method, host: "example.org", port: 8002, trust: fixtureTrust()) == .defaultHandling)
            #expect(d.evaluate(method: method, host: lan, port: 443, trust: fixtureTrust()) == .defaultHandling)
            #expect(d.observed == nil)
        }
    }

    @Test func delegateRefusesRedirects() async {
        let d = SamsungTLSDelegate(allowedHost: lan, stored: nil, allowFirstUse: true)
        let resp = HTTPURLResponse(url: URL(string: "http://192.168.1.50/")!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "http://192.168.1.50/")!)
        let next: URLRequest?? = await withCheckedContinuation { k in
            d.urlSession(session, task: task, willPerformHTTPRedirection: resp, newRequest: URLRequest(url: URL(string: "http://192.168.1.99/")!)) { k.resume(returning: .some($0)) }
        }
        #expect(next == .some(nil))
        session.invalidateAndCancel()
    }
}

// MARK: - Token store + model

@Suite("Samsung token store") struct SamsungTokenTests {
    @Test func rulesRoundTripAndRefuseJunk() {
        let t = StoredTVToken(token: "Abc123", fingerprint: pin)
        #expect(TVTokenRules.decode(TVTokenRules.encode(t)!) == t)
        #expect(TVTokenRules.encode(StoredTVToken(token: "a/b", fingerprint: pin)) == nil)
        #expect(TVTokenRules.encode(StoredTVToken(token: "ok", fingerprint: "XYZ")) == nil)
        #expect(TVTokenRules.encode(StoredTVToken(token: String(repeating: "a", count: 65), fingerprint: pin)) == nil)
        #expect(TVTokenRules.decode(Data("tok\nmd5:abc".utf8)) == nil)
        #expect(TVTokenRules.decode(Data("a\nb\nc".utf8)) == nil)
    }

    /// Opt-in (GOPRAY_LIVE_KEYCHAIN=1): the real Keychain, one throwaway item.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GOPRAY_LIVE_KEYCHAIN"] != nil))
    func liveKeychainRoundTrip() {
        let store = KeychainTokenStore(); let id = "gopray-test-\(UUID().uuidString)"
        defer { store.delete(id) }
        #expect(store.save(id, token: "Abc123", fingerprint: pin))
        #expect(store.load(id) == StoredTVToken(token: "Abc123", fingerprint: pin))
        #expect(store.save(id, token: "Zzz9", fingerprint: pin))
        #expect(store.load(id)?.token == "Zzz9")
        store.delete(id)
        #expect(store.load(id) == nil)
    }
}

@Suite("Samsung in Settings") struct SamsungSettingsTests {
    @Test func channelIdShapePerKind() {
        #expect(TVDevice.isValidChannelId("GoPrayAth1.GoPray", kind: .samsung))
        for bad in ["dev", "12345", "GoPrayAth1", "GoPrayAth2.GoPray", "AAAAAAAAAA.GoPray", "GoPrayAth1.Other", "GoPrayAth1.", "GoPrayAth.GoPray", "GoPrayAth1.Go/Pray", "../GoPrayAth1.GoPray", "GoPrayAth1.GoPray\n"] {
            #expect(!TVDevice.isValidChannelId(bad, kind: .samsung), "\(bad)")
        }
        #expect(!TVDevice.isValidChannelId("GoPrayAth1.GoPray", kind: .roku))
        #expect(TVDevice(name: "x", kind: .samsung, host: "10.0.0.2").channelId == "GoPrayAth1.GoPray")
        #expect(TVDevice(name: "x", host: "10.0.0.2").channelId == "dev")
    }

    @Test func aSamsungSurvivesSaveWithItsAppIdAndName() {
        var s = Settings.defaults.sanitized()
        s.tvs = [TVDevice(id: "a", name: "  ", kind: .samsung, host: "10.0.0.2"),
                 TVDevice(id: "b", name: "Bad", kind: .samsung, host: "10.0.0.3", channelId: "dev"),
                 TVDevice(id: "c", name: "Roku", host: "10.0.0.4", channelId: "GoPrayAth1.GoPray")]
        let clean = s.sanitized().tvs
        #expect(clean[0].name == "Samsung TV" && clean[0].channelId == "GoPrayAth1.GoPray" && clean[0].kind == .samsung)
        #expect(clean[1].channelId == "GoPrayAth1.GoPray")
        #expect(clean[2].channelId == "dev")
    }

    /// A settings.json saved before Samsung existed: Roku TVs only. Must decode and sanitize exactly as before.
    @Test func savedRokuOnlyFileIsUnchangedBySanitizing() throws {
        let json = #"{"city":"X","latitude":43.6,"longitude":-79.3,"method":"northAmerica","madhab":1,"mode":"wholeScreen","voice":{"sunni":{"_0":"Minshawi"}},"athanVolume":0.5,"launchAtLogin":false,"setupComplete":true,"lockMinutes":10,"tvs":[{"id":"a","name":"Lounge","kind":"roku","host":"192.168.1.160","channelId":"dev","enabled":false,"installed":true},{"id":"b","name":"","kind":"roku","host":"10.0.0.3","channelId":"12345"},{"id":"c","name":"Bad","kind":"roku","host":"10.0.0.4","channelId":"a/b"},{"id":"d","name":"Pub","kind":"roku","host":"8.8.8.8"}]}"#
        let tvs = try JSONDecoder().decode(Settings.self, from: Data(json.utf8)).sanitized().tvs
        #expect(tvs.map(\.id) == ["a", "b", "c"])
        #expect(tvs.allSatisfy { $0.kind == .roku })
        #expect(tvs[0] == TVDevice(id: "a", name: "Lounge", host: "192.168.1.160", channelId: "dev", enabled: false))
        #expect(tvs[1].name == "Roku TV" && tvs[1].channelId == "12345")
        #expect(tvs[2].channelId == "dev")
    }

    @Test func roundTripsAndOldFilesStillDecode() throws {
        let t = TVDevice(id: "a", name: "Den", kind: .samsung, host: "10.0.0.2")
        let back = try JSONDecoder().decode(TVDevice.self, from: JSONEncoder().encode(t))
        #expect(back == t)
        let old = try JSONDecoder().decode(TVDevice.self, from: Data(#"{"id":"1","host":"10.0.0.2","kind":"roku"}"#.utf8))
        #expect(old.kind == .roku && old.channelId == "dev")
        let sam = try JSONDecoder().decode(TVDevice.self, from: Data(#"{"id":"1","host":"10.0.0.2","kind":"samsung"}"#.utf8))
        #expect(sam.channelId == "GoPrayAth1.GoPray")
    }
}

@MainActor @Suite("Samsung settings model") struct SamsungModelTests {
    private func model(_ r: UIFixture, _ s: RecordingSender) -> SettingsViewModel {
        SettingsViewModel(store: r.store, gate: r.gate, clock: r.clock, audio: r.audio, loginAgent: r.login, geocoder: r.geocoder, tv: s)
    }

    @Test func addBySamsungKind() {
        let r = UIFixture(); defer { r.cleanup() }
        let m = model(r, RecordingSender())
        #expect(m.addTV(host: "10.0.0.9", name: "", kind: .samsung))
        #expect(m.tvs[0].kind == .samsung && m.tvs[0].name == "Samsung TV" && m.tvs[0].channelId == "GoPrayAth1.GoPray")
        #expect(m.addTV(host: "10.0.0.10", name: ""))
        #expect(m.tvs[1].kind == .roku && m.tvs[1].name == "Roku TV" && m.tvs[1].channelId == "dev")
    }

    @Test func pairOutcomesBecomeOneLineEach() async {
        let r = UIFixture(); defer { r.cleanup() }
        let s = RecordingSender(); let m = model(r, s)
        m.addTV(host: "10.0.0.9", name: "", kind: .samsung)
        let id = m.tvs[0].id
        #expect(m.tokenState(of: id) == .notPaired)
        s.pairResult = .denied; await m.pairTV(id)
        #expect(m.tvTestLines[id] == TVListModel.pairDeniedLine && m.tokenState(of: id) == .notPaired)
        s.pairResult = .unsupported; await m.pairTV(id)
        #expect(m.tvTestLines[id] == TVListModel.basicLaunchLine && m.tokenState(of: id) == .basicLaunchOnly)
        s.pairResult = .paired; s.paired = true; await m.pairTV(id)
        #expect(m.tvTestLines[id] == TVListModel.pairedLine && m.tokenState(of: id) == .paired)
        s.pairError = .certChanged; await m.pairTV(id)
        #expect(m.tokenState(of: id) == .pairAgain && m.tvTestLines[id] == TVListModel.pairAgainLine)
        #expect(s.pairs == 4)
    }

    @Test func pairIsSamsungOnlyAndNeverDuringABlock() async {
        let r = UIFixture(); defer { r.cleanup() }
        let s = RecordingSender(); let m = model(r, s)
        m.addTV(host: "10.0.0.9", name: "Den")
        await m.pairTV(m.tvs[0].id)
        #expect(s.pairs == 0, "a Roku never pairs")
        m.addTV(host: "10.0.0.10", name: "", kind: .samsung)
        r.startBlock()
        await m.pairTV(m.tvs[1].id)
        #expect(s.pairs == 0, "read-only during a block")
    }

    @Test func testButtonOnAStandbyTVSaysItIsOff() async {
        let r = UIFixture(); defer { r.cleanup() }
        let s = RecordingSender(); s.failWith = .standby; let m = model(r, s)
        m.addTV(host: "10.0.0.9", name: "", kind: .samsung)
        await m.testTV(m.tvs[0].id)
        #expect(m.tvTestLines[m.tvs[0].id] == TVListModel.tvOffLine)
    }

    @Test func removingATVForgetsItsCredential() {
        let r = UIFixture(); defer { r.cleanup() }
        let s = RecordingSender(); let m = model(r, s)
        m.addTV(host: "10.0.0.9", name: "", kind: .samsung)
        let tv = m.tvs[0]
        m.removeTV(tv.id)
        #expect(s.forgotten == [tv.id] && m.tvs.isEmpty)
    }

    @Test func removingDuringABlockForgetsNothing() {
        let r = UIFixture(); defer { r.cleanup() }
        let s = RecordingSender(); let m = model(r, s)
        m.addTV(host: "10.0.0.9", name: "", kind: .samsung)
        r.startBlock()
        m.removeTV(m.tvs[0].id)
        #expect(s.forgotten.isEmpty && m.tvs.count == 1)
    }
}

private struct OddError: Error { var secret: String }

@Suite("TV error logging") struct TVLogTests {
    @Test func neverCarriesTheURLOrTheToken() {
        let url = "wss://192.168.1.50:8002/api/v2/channels/samsung.remote.control?name=R28gUHJheQ==&token=SECRET123"
        let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost,
                          userInfo: [NSURLErrorFailingURLStringErrorKey: url, NSURLErrorFailingURLErrorKey: URL(string: url)!,
                                     NSLocalizedDescriptionKey: "could not connect to \(url)"])
        let out = TVLog.describe(URLError(_nsError: err))
        for bad in ["SECRET", "token", "wss", "192.168", "http"] { #expect(!out.contains(bad), "\(bad) in \(out)") }
        #expect(out == "URLError(\(NSURLErrorCannotConnectToHost))")
        #expect(!TVLog.describe(err).contains("SECRET"))
    }

    @Test func fixedNamesForOurErrors() {
        #expect(TVLog.describe(TVError.certChanged) == "certChanged")
        #expect(TVLog.describe(TVError.badStatus(500)) == "badStatus(500)")
        #expect(TVLog.describe(OddError(secret: "token=SECRET123")) == "OddError")
    }
}
