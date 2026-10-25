// TVTests.swift — TV control (CONTRACT-NOTES #56): the exact wire call against a fake TV on localhost,
// the address rule, the tolerant Settings decode, and the gate calling the controller once per Athan.

import Foundation
import Testing
@testable import GoPray

/// Tests only: 127.0.0.1 is let through here, never in `TVHost`.
private let testHostCheck: @Sendable (String) -> Bool = { $0 == "127.0.0.1" || TVHost.isAllowed($0) }

private func roku(_ server: FakeTVServer) -> RokuTV { RokuTV(port: server.port, hostCheck: testHostCheck) }
private func tv(_ host: String = "127.0.0.1", channel: String = "dev", enabled: Bool = true) -> TVDevice {
    TVDevice(id: UUID().uuidString, name: "Lounge", host: host, channelId: channel, enabled: enabled)
}

private func waitFor(_ ok: @escaping () -> Bool, seconds: Double = 5) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { if ok() { return true }; try? await Task.sleep(for: .milliseconds(20)) }
    return ok()
}

@Suite("TV wire call") struct TVWireTests {
    @Test func exactURLAndQuery() throws {
        let r = RokuTV(port: 8060, hostCheck: TVHost.isAllowed)
        let url = r.launchURL(tv("192.168.1.160"), prayer: .asr, voice: .sunni("Minshawi"))
        #expect(url?.absoluteString == "http://192.168.1.160:8060/launch/dev?prayer=asr&voice=sunni.Minshawi")
    }

    @Test func testURLHasTestFlagAndAthanURLDoesNot() {
        let r = RokuTV(port: 8060, hostCheck: TVHost.isAllowed)
        let t = r.launchURL(tv("10.0.0.5"), prayer: .asr, voice: .sunni("Saber"), test: true)?.absoluteString
        #expect(t == "http://10.0.0.5:8060/launch/dev?prayer=asr&voice=sunni.Saber&test=1")
        let a = r.launchURL(tv("10.0.0.5"), prayer: .asr, voice: .sunni("Saber"))?.absoluteString
        #expect(a == "http://10.0.0.5:8060/launch/dev?prayer=asr&voice=sunni.Saber")
        #expect(a?.contains("test") == false)
    }

    @Test func overTheWireTestButtonSendsTestAndAthanDoesNot() async throws {
        let server = FakeTVServer()
        let c = TVController(drivers: [.roku: roku(server)])
        try await c.test(tv(), prayer: .dhuhr, voice: .sunni("Saber"))
        c.athanStarted(prayer: .dhuhr, voice: .sunni("Saber"), tvs: [tv()])
        #expect(await waitFor { server.posts.count == 2 })
        let lines = server.posts.map(\.requestLine)
        #expect(lines.filter { $0.contains("test=1") }.count == 1)
        #expect(lines.contains("POST /launch/dev?prayer=dhuhr&voice=sunni.Saber&test=1 HTTP/1.1"))
        #expect(lines.contains("POST /launch/dev?prayer=dhuhr&voice=sunni.Saber HTTP/1.1"))
    }

    @Test func shiaVoiceAndEveryPrayer() throws {
        let r = RokuTV(port: 8060, hostCheck: TVHost.isAllowed)
        let want = ["fajr", "dhuhr", "asr", "maghrib", "isha"]
        for (p, name) in zip(Prayer.allCases, want) {
            let u = r.launchURL(tv("10.0.0.5"), prayer: p, voice: .shia("Kazem-Zadeh"))?.absoluteString
            #expect(u == "http://10.0.0.5:8060/launch/dev?prayer=\(name)&voice=shia.Kazem-Zadeh")
        }
    }

    @Test func everyShippedVoiceTokenIsTheFileStem() {
        for e in VoiceCatalog.sunni { #expect(RokuTV.voiceToken(e.voice) == "sunni.\(e.stem)") }
        for e in VoiceCatalog.shia { #expect(RokuTV.voiceToken(e.voice) == "shia.\(e.stem)") }
    }

    @Test func valuesAreURLEncoded() {
        let r = RokuTV(port: 8060, hostCheck: TVHost.isAllowed)
        let u = r.launchURL(tv("10.0.0.5", channel: "12345"), prayer: .fajr, voice: .sunni("a b&c=d+e/é"))?.absoluteString
        #expect(u == "http://10.0.0.5:8060/launch/12345?prayer=fajr&voice=sunni.a%20b%26c%3Dd%2Be%2F%C3%A9")
    }

    @Test func badChannelIdIsRefused() {
        let r = RokuTV(port: 8060, hostCheck: TVHost.isAllowed)
        #expect(r.launchURL(tv("10.0.0.5", channel: "../keypress/Home"), prayer: .asr, voice: .sunni("x")) == nil)
        #expect(r.launchURL(tv("10.0.0.5", channel: ""), prayer: .asr, voice: .sunni("x")) == nil)
    }

    @Test func realRequestOverTheWire() async throws {
        let server = FakeTVServer()
        try await roku(server).launch(tv(), prayer: .maghrib, voice: .shia("Sobhdel"))
        let r = try #require(server.posts.first)
        #expect(r.requestLine == "POST /launch/dev?prayer=maghrib&voice=shia.Sobhdel HTTP/1.1")
        #expect(r.body.isEmpty)
        #expect(r.headers["content-length"] == "0")
    }

    @Test func fajrOverTheWireUsesSettingsVoice() async throws {
        let server = FakeTVServer()
        try await roku(server).launch(tv(channel: "123456"), prayer: .fajr, voice: .sunni("Minshawi"))
        #expect(server.posts.first?.requestLine == "POST /launch/123456?prayer=fajr&voice=sunni.Minshawi HTTP/1.1")
    }

    @Test func tvOffLogsAndThrowsOnlyTVError() async {
        let server = FakeTVServer(); let r = roku(server); server.stop()
        do { try await r.launch(tv(), prayer: .asr, voice: .sunni("x")); Issue.record("should have thrown") }
        catch { #expect(error as? TVError == .unreachable) }
    }

    @Test func tvAnswering500IsAnError() async {
        let server = FakeTVServer(); server.status = 500
        do { try await roku(server).launch(tv(), prayer: .asr, voice: .sunni("x")); Issue.record("should have thrown") }
        catch { #expect(error as? TVError == .badStatus(500)) }
    }

    @Test func redirectIsNotFollowed() async {
        let server = FakeTVServer(); server.status = 302
        do { try await roku(server).launch(tv(), prayer: .asr, voice: .sunni("x")); Issue.record("should have thrown") }
        catch { #expect(server.posts.count == 1) }
    }
}

@Suite("TV controller") struct TVControllerTests {
    @Test func callsEveryEnabledTVAndSkipsDisabled() async {
        let a = FakeTVServer(), b = FakeTVServer(), off = FakeTVServer()
        let c = TVController(drivers: [.roku: RokuTV(port: a.port, hostCheck: { $0 == "127.0.0.1" })])
        _ = (b, off)
        c.athanStarted(prayer: .isha, voice: .sunni("Hafez"), tvs: [tv(), tv(enabled: false)])
        #expect(await waitFor { a.posts.count == 1 })
        try? await Task.sleep(for: .milliseconds(200))
        #expect(a.posts.count == 1)      // the disabled TV (same fake port) was not called: still 1
        #expect(a.posts.first?.requestLine == "POST /launch/dev?prayer=isha&voice=sunni.Hafez HTTP/1.1")
        #expect(off.requests.isEmpty && b.requests.isEmpty)
    }

    @Test func athanStartedReturnsAtOnceEvenWhenTVIsOff() {
        let server = FakeTVServer(); let port = server.port; server.stop()
        let c = TVController(drivers: [.roku: RokuTV(port: port, hostCheck: testHostCheck)])
        let t0 = Date()
        c.athanStarted(prayer: .asr, voice: .sunni("x"), tvs: [tv(), tv("10.255.255.1")])
        #expect(Date().timeIntervalSince(t0) < 0.5)
    }

    @Test func nonPrivateHostsAreRefusedByTheProductionCheck() async {
        let server = FakeTVServer()
        // Production RokuTV (default hostCheck) with the fake's port: loopback, public and names never connect.
        let r = RokuTV(port: server.port)
        for host in ["127.0.0.1", "8.8.8.8", "172.32.0.1", "192.169.1.1", "tv.local", "localhost", "example.com", "::1", "10.0.0.1:80", " 10.0.0.1"] {
            do { try await r.launch(tv(host), prayer: .asr, voice: .sunni("x")); Issue.record("\(host) should be refused") }
            catch { #expect(error as? TVError == .refusedHost, "\(host)") }
        }
        #expect(server.requests.isEmpty)
    }

    @Test func testButtonReportsFailureAndWorksOnADisabledTV() async throws {
        let server = FakeTVServer()
        let c = TVController(drivers: [.roku: roku(server)])
        try await c.test(tv(enabled: false), prayer: .dhuhr, voice: .sunni("Saber"))
        #expect(server.requests.count == 1)
        server.stop()
        await #expect(throws: TVError.self) { try await c.test(tv(), prayer: .dhuhr, voice: .sunni("Saber")) }
    }
}

private func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }

private func appsXML(_ apps: (String, String)...) -> String {
    "<?xml version=\"1.0\" encoding=\"UTF-8\" ?><apps>" + apps.map { "<app id=\"\($0.0)\" type=\"appl\" version=\"1.0.0\">\(esc($0.1))</app>" }.joined() + "</apps>"
}

@Suite("TV finds the Go Pray app") struct TVChannelTests {
    private func find(_ xml: String) async throws -> (String?, FakeTVServer) {
        let server = FakeTVServer(); server.appsXML = xml
        return (try await roku(server).findChannel(tv()), server)
    }

    @Test func devOnly() async throws {
        let (id, server) = try await find(appsXML(("12", "Netflix"), ("dev", "Go Pray")))
        #expect(id == "dev")
        #expect(server.requests.first?.requestLine == "GET /query/apps HTTP/1.1")
    }

    @Test func publishedBeatsDev() async throws {
        let (a, _) = try await find(appsXML(("dev", "Go Pray"), ("987654", "Go Pray: Athan & Adhan")))
        #expect(a == "987654")
        let (b, _) = try await find(appsXML(("987654", "Go Pray: Athan & Adhan"), ("dev", "Go Pray")))
        #expect(b == "987654")
    }

    @Test func noneInstalled() async throws {
        let (id, _) = try await find(appsXML(("12", "Netflix"), ("dev", "Some Other Dev App"), ("34", "My Go Pray")))
        #expect(id == nil)
        let (empty, _) = try await find("<apps/>")
        #expect(empty == nil)
    }

    @Test func junkIdsAreRejected() async throws {
        for bad in ["../keypress/Home", "12345678901", "dev2", "1 2", "-5", "", "dev/../x", "1e5", "٣٤"] {
            let (id, _) = try await find(appsXML((bad, "Go Pray")))
            #expect(id == nil, "\(bad)")
        }
        // a junk entry next to a good one: only the good one counts
        let (id, _) = try await find(appsXML(("../x", "Go Pray"), ("dev", "Go Pray")))
        #expect(id == "dev")
    }

    @Test func channelIdShape() {
        for ok in ["dev", "0", "1234567890"] { #expect(TVDevice.isValidChannelId(ok)) }
        for bad in ["dev\n", "12\n", "DEV", " dev", "dev ", "11111111111"] { #expect(!TVDevice.isValidChannelId(bad), "\(bad)") }
    }

    @Test func notXMLOrHugeOrHostileIsNothing() async throws {
        let (a, _) = try await find("not xml at all")
        #expect(a == nil)
        let (b, _) = try await find(String(repeating: "<app id=\"dev\">Go Pray</app>", count: 40_000))
        #expect(b == nil)
        let (c, _) = try await find("<!DOCTYPE x [<!ENTITY e SYSTEM \"file:///etc/passwd\">]><apps><app id=\"&e;\">Go Pray</app></apps>")
        #expect(c == nil)
    }

    @Test func tvOffThrowsAndWrongAddressIsRefused() async {
        let server = FakeTVServer(); let r = roku(server); server.stop()
        await #expect(throws: TVError.unreachable) { _ = try await r.findChannel(tv()) }
        await #expect(throws: TVError.refusedHost) { _ = try await RokuTV(port: server.port).findChannel(tv("8.8.8.8")) }
    }

    @Test func controllerMapsItAndAthanUsesTheStoredIdWithoutAskingAgain() async throws {
        let server = FakeTVServer(); server.appsXML = appsXML(("555", "Go Pray"))
        let c = TVController(drivers: [.roku: roku(server)])
        #expect(await c.resolve(tv()) == .found("555"))
        server.appsXML = "<apps/>"
        #expect(await c.resolve(tv()) == .notInstalled)
        server.stop()
        #expect(await c.resolve(tv()) == .unreachable)
        // at Athan time: the stored id is used, no /query/apps call
        let live = FakeTVServer()
        let c2 = TVController(drivers: [.roku: roku(live)])
        c2.athanStarted(prayer: .asr, voice: .sunni("Saber"), tvs: [tv(channel: "555")])
        #expect(await waitFor { live.posts.count == 1 })
        #expect(live.posts.map(\.requestLine) == ["POST /launch/555?prayer=asr&voice=sunni.Saber HTTP/1.1"])
    }

    @Test func notInstalledTVIsSkippedAtAthan() async {
        let live = FakeTVServer()
        let c = TVController(drivers: [.roku: roku(live)])
        var t = tv(); t.installed = false
        c.athanStarted(prayer: .asr, voice: .sunni("Saber"), tvs: [t])
        try? await Task.sleep(for: .milliseconds(300))
        #expect(live.requests.isEmpty)
    }
}

@MainActor @Suite("TV settings model: channel") struct TVModelChannelTests {
    private func model(_ r: UIFixture, _ s: RecordingSender) -> SettingsViewModel {
        SettingsViewModel(store: r.store, gate: r.gate, clock: r.clock, audio: r.audio, loginAgent: r.login, geocoder: r.geocoder, tv: s)
    }

    @Test func addStoresTheFoundChannel() async {
        let r = UIFixture(); defer { r.cleanup() }
        let s = RecordingSender(); s.resolution = .found("424242")
        let m = model(r, s)
        #expect(await m.addTVAndCheck(host: "10.0.0.7", name: "Den"))
        #expect(m.tvs[0].channelId == "424242" && m.tvs[0].installed)
    }

    @Test func notInstalledIsStoredAndTheTestSaysSo() async {
        let r = UIFixture(); defer { r.cleanup() }
        let s = RecordingSender(); s.resolution = .notInstalled
        let m = model(r, s)
        _ = await m.addTVAndCheck(host: "10.0.0.7", name: "Den")
        #expect(m.tvs[0].installed == false)
        await m.testTV(m.tvs[0].id)
        #expect(m.tvTestLines[m.tvs[0].id] == SettingsViewModel.notInstalledLine && s.tests.isEmpty)
        s.resolution = .found("dev")                   // installed later: the Test button picks it up
        await m.testTV(m.tvs[0].id)
        #expect(m.tvs[0].installed && s.tests.count == 1)
    }

    @Test func localNetworkDeniedShowsTheAllowLine() async {
        let r = UIFixture(); defer { r.cleanup() }
        let s = RecordingSender(); s.resolution = .localNetworkDenied
        let m = model(r, s)
        #expect(await m.addTVAndCheck(host: "10.0.0.7", name: "Den"))
        let id = m.tvs[0].id
        #expect(m.tvsNeedingNetworkAccess == [id] && m.tvs[0].installed && m.tvs[0].channelId == "dev")
        await m.testTV(id)
        #expect(m.tvTestLines[id] == SettingsViewModel.allowLocalNetworkLine && s.tests.isEmpty)
        s.resolution = .found("dev"); s.failWith = .localNetworkDenied      // allowed for the check, refused for the launch
        await m.testTV(id)
        #expect(m.tvTestLines[id] == SettingsViewModel.allowLocalNetworkLine && m.tvsNeedingNetworkAccess.isEmpty)
    }

    @Test func scanRefusedByMacOSShowsTheAllowLine() async {
        let r = UIFixture(); defer { r.cleanup() }
        let m = SettingsViewModel(store: r.store, gate: r.gate, clock: r.clock, audio: r.audio, loginAgent: r.login,
                                  geocoder: r.geocoder, discovery: FixedDiscovery(found: [], denied: true))
        await m.scanForTVs()
        #expect(m.scanNeedsNetworkAccess && m.foundTVs.isEmpty)
    }

    @Test func unreachableKeepsWhatWeHad() async {
        let r = UIFixture(); defer { r.cleanup() }
        let s = RecordingSender(); s.resolution = .unreachable
        let m = model(r, s)
        #expect(await m.addTVAndCheck(host: "10.0.0.7", name: "Den"))
        #expect(m.tvs[0].channelId == "dev" && m.tvs[0].installed)
    }
}

@Suite("TV skips a launch when Go Pray is already on screen") struct TVAlreadyPlayingTests {
    private func active(_ id: String) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\" ?><active-app><app id=\"\(id)\" type=\"appl\" version=\"1.0.0\">Go Pray</app></active-app>"
    }

    @Test func ours_noPost() async throws {
        let server = FakeTVServer(); server.activeXML = active("dev")
        try await roku(server).launch(tv(channel: "dev"), prayer: .asr, voice: .sunni("x"))
        #expect(server.requests.map(\.requestLine) == ["GET /query/active-app HTTP/1.1"])
        let pub = FakeTVServer(); pub.activeXML = active("987654")
        try await roku(pub).launch(tv(channel: "987654"), prayer: .asr, voice: .sunni("x"))
        #expect(pub.posts.isEmpty)
    }

    @Test func other_post() async throws {
        let server = FakeTVServer(); server.activeXML = active("12")
        try await roku(server).launch(tv(channel: "dev"), prayer: .asr, voice: .sunni("x"))
        #expect(server.posts.count == 1)
        // dev on screen but the stored id is the published one: not ours, launch
        let s2 = FakeTVServer(); s2.activeXML = active("dev")
        try await roku(s2).launch(tv(channel: "987654"), prayer: .asr, voice: .sunni("x"))
        #expect(s2.posts.count == 1)
    }

    @Test func checkFails_post() async throws {
        let bad = FakeTVServer(); bad.activeStatus = 500
        try await roku(bad).launch(tv(), prayer: .asr, voice: .sunni("x"))
        #expect(bad.posts.count == 1)
        let junk = FakeTVServer(); junk.activeXML = "not xml"
        try await roku(junk).launch(tv(), prayer: .asr, voice: .sunni("x"))
        #expect(junk.posts.count == 1)
        let huge = FakeTVServer(); huge.streamBytes = 200 * 1024 * 1024
        try await roku(huge).launch(tv(), prayer: .asr, voice: .sunni("x"))
        #expect(huge.posts.count == 1)
    }

    @Test func test_noCheck_alwaysLaunches() async throws {
        let server = FakeTVServer(); server.activeXML = active("dev")
        try await roku(server).launch(tv(channel: "dev"), prayer: .asr, voice: .sunni("x"), test: true)
        #expect(server.requests.map(\.requestLine) == ["POST /launch/dev?prayer=asr&voice=sunni.x&test=1 HTTP/1.1"])
    }

    @Test func controllerAthanSkipsWhenOurs() async {
        let server = FakeTVServer(); server.activeXML = active("dev")
        let c = TVController(drivers: [.roku: roku(server)])
        c.athanStarted(prayer: .asr, voice: .sunni("x"), tvs: [tv()])
        #expect(await waitFor { server.requests.count == 1 })
        try? await Task.sleep(for: .milliseconds(300))
        #expect(server.posts.isEmpty)
    }
}

@Suite("TV bounded reads") struct TVBoundedReadTests {
    private let wayTooBig = 200 * 1024 * 1024

    @Test func oversizeAppsListStopsEarlyAndIsJunk() async throws {
        let server = FakeTVServer(); server.streamBytes = wayTooBig
        let id = try await roku(server).findChannel(tv())
        #expect(id == nil)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(server.bytesWritten < 20 * 1024 * 1024, "server wrote \(server.bytesWritten)")
    }

    @Test func oversizeDeviceInfoStopsEarlyAndHasNoName() async {
        let server = FakeTVServer(); server.streamBytes = wayTooBig
        let name = await RokuDiscovery(session: RokuTV.makeSession(), port: server.port).friendlyName("127.0.0.1")
        #expect(name == nil)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(server.bytesWritten < 20 * 1024 * 1024)
    }

    @Test func launchNeverReadsTheBody() async throws {
        let server = FakeTVServer(); server.streamBytes = wayTooBig
        let t0 = Date()
        try await roku(server).launch(tv(), prayer: .asr, voice: .sunni("x"))
        #expect(Date().timeIntervalSince(t0) < 2)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(server.bytesWritten < 20 * 1024 * 1024)
    }
}

@Suite("TV local network error") struct TVLocalNetworkTests {
    private func err(_ code: Int, path: String) -> NSError {
        let under = NSError(domain: "kCFErrorDomainCFNetwork", code: -1009, userInfo: ["_NSURLErrorNWPathKey": path])
        return NSError(domain: NSURLErrorDomain, code: code, userInfo: ["NSUnderlyingError": under])
    }
    @Test func onlyTheProhibitedPathCounts() {
        #expect(tvIsLocalNetworkDenial(err(-1009, path: "unsatisfied (Local network prohibited), interface: en0")))
        #expect(!tvIsLocalNetworkDenial(err(-1009, path: "unsatisfied (No network route)")))
        #expect(!tvIsLocalNetworkDenial(err(-1001, path: "unsatisfied (Local network prohibited)")))
        #expect(!tvIsLocalNetworkDenial(TVError.unreachable))
    }
}

@Suite("TV address rule") struct TVHostTests {
    @Test func privateRangesOnly() {
        for ok in ["10.0.0.1", "10.255.255.255", "172.16.0.1", "172.31.255.254", "192.168.1.160", "169.254.10.10"] { #expect(TVHost.isAllowed(ok), "\(ok)") }
        for bad in ["127.0.0.1", "0.0.0.0", "8.8.8.8", "172.15.0.1", "172.32.0.1", "192.167.1.1", "169.253.1.1", "11.0.0.1",
                    "224.0.0.251", "255.255.255.255", "10.0.0", "10.0.0.256", "010.0.0.1", "10.0.0.01", "10.0.0.1 ", " 10.0.0.1",
                    "tv.local", "localhost", "example.com", "", "::1", "10.0.0.1/8", "10.0.0.1:8060", "0xA.0.0.1", "-10.0.0.1", "1e1.0.0.1"] {
            #expect(!TVHost.isAllowed(bad), "\(bad)")
        }
    }
}

@Suite("TVs in Settings") struct TVSettingsTests {
    private func settingsJSON(tvs: String?) -> Data {
        var s = #"{"city":"X","latitude":43.6,"longitude":-79.3,"method":"northAmerica","madhab":1,"mode":"wholeScreen","voice":{"sunni":{"_0":"Minshawi"}},"athanVolume":0.5,"launchAtLogin":false,"setupComplete":true,"lockMinutes":10"#
        if let tvs { s += #","tvs":\#(tvs)"# }
        return Data((s + "}").utf8)
    }

    @Test func absentKeyIsEmpty() throws {
        let s = try JSONDecoder().decode(Settings.self, from: settingsJSON(tvs: nil))
        #expect(s.tvs.isEmpty)
    }

    @Test func presentKeyDecodes() throws {
        let s = try JSONDecoder().decode(Settings.self, from: settingsJSON(tvs: #"[{"id":"a","name":"Lounge","kind":"roku","host":"192.168.1.160","channelId":"dev","enabled":false}]"#))
        #expect(s.tvs == [TVDevice(id: "a", name: "Lounge", host: "192.168.1.160", channelId: "dev", enabled: false)])
    }

    @Test func missingOptionalFieldsTakeDefaults() throws {
        let s = try JSONDecoder().decode(Settings.self, from: settingsJSON(tvs: #"[{"id":"a","kind":"roku","host":"10.0.0.2"}]"#))
        #expect(s.tvs.first?.enabled == true && s.tvs.first?.channelId == "dev" && s.tvs.first?.name == "")
    }

    @Test func oneBadEntryOrBadKeyNeverBreaksTheFile() throws {
        let mixed = try JSONDecoder().decode(Settings.self, from: settingsJSON(tvs: #"[{"id":"a","kind":"samsung","host":"10.0.0.2"},{"id":"b","kind":"roku","host":"10.0.0.3"},42]"#))
        #expect(mixed.tvs.map(\.id) == ["b"])
        let junk = try JSONDecoder().decode(Settings.self, from: settingsJSON(tvs: #""nope""#))
        #expect(junk.tvs.isEmpty)
        #expect(junk.city == "X")
    }

    @Test func roundTrips() throws {
        var s = Settings.test(); s.tvs = [TVDevice(id: "a", name: "Lounge", host: "10.0.0.2")]
        let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }

    @Test func badAddressIsRefusedAtSave() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gopray-tv-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ok = Settings.defaults.sanitized()
        var s = ok
        s.tvs = [TVDevice(id: "1", name: "Good", host: "192.168.1.5"), TVDevice(id: "2", name: "Public", host: "8.8.8.8"),
                 TVDevice(id: "3", name: "Name", host: "tv.local"), TVDevice(id: "4", name: "Loop", host: "127.0.0.1"),
                 TVDevice(id: "1", name: "Same id", host: "192.168.1.6"), TVDevice(id: "5", name: "Same host", host: "192.168.1.5"),
                 TVDevice(id: "6", name: "  ", host: " 10.0.0.9 ", channelId: "a/b")]
        let clean = s.sanitized().tvs
        #expect(clean.map(\.id) == ["1", "6"])
        #expect(clean[1].host == "10.0.0.9" && clean[1].name == "Roku TV" && clean[1].channelId == "dev")
    }
}

@MainActor @Suite("TV and the gate") struct TVGateTests {
    private let asr = FakeSchedule.at(.asr)
    private let lounge = TVDevice(id: "a", name: "Lounge", host: "192.168.1.160")

    private func harness(tvs: [TVDevice]? = nil, at: Date? = nil) -> Harness {
        var s = Settings.test(); s.tvs = tvs ?? [lounge]
        return Harness(at: at ?? asr.addingTimeInterval(-60), settings: s)
    }

    @Test func oncePerPresent() {
        let h = harness(); defer { h.cleanup() }
        h.clock.now = asr
        h.gate.athanFired(.asr, at: asr)
        #expect(h.audio.plays.count == 1)
        #expect(h.tv.calls == [.init(prayer: .asr, voice: .sunni("test-voice"), tvs: [lounge])])
        h.gate.athanFired(.asr, at: asr)                       // the scheduler firing again: no second block, no second call
        #expect(h.tv.calls.count == 1)
    }

    @Test func wakeWithinThreeMinutesCalls() {
        for secs: TimeInterval in [0, 60, 120, 180] {
            let h = harness(); defer { h.cleanup() }
            h.clock.now = asr.addingTimeInterval(secs)
            h.gate.reevaluate(.wake)
            #expect(h.gate.isBlocked)
            #expect(h.tv.calls.count == 1 && h.tv.calls.first?.prayer == .asr, "+\(secs)s")
        }
    }

    @Test func lateWakeBlocksTheMacButLeavesTheTVAlone() {
        for secs: TimeInterval in [181, 600, 20 * 60] {
            let h = harness(); defer { h.cleanup() }
            h.clock.now = asr.addingTimeInterval(secs)
            h.gate.reevaluate(.wake)
            #expect(h.gate.isBlocked && h.audio.plays.count == 1, "the Mac block starts as today")
            #expect(h.tv.calls.isEmpty, "+\(secs)s")
        }
    }

    @Test func liveAthanAlwaysCallsEvenIfTheScheduleTickIsLate() {
        let h = harness(); defer { h.cleanup() }
        h.clock.now = asr.addingTimeInterval(5)              // the scheduler's timer fired a few seconds late
        h.gate.athanFired(.asr, at: asr)
        #expect(h.tv.calls.count == 1)
    }

    @Test func relaunchMidBlockNeverCalls() {
        let h = harness(); defer { h.cleanup() }
        h.clock.now = asr
        h.gate.athanFired(.asr, at: asr)
        h.clock.now = asr.addingTimeInterval(120)
        h.relaunch()
        #expect(h.gate.isBlocked && h.shield.shows.count >= 1)
        #expect(h.tv.calls.isEmpty && h.audio.plays.isEmpty)
    }

    @Test func silenceDoesNotTouchTheTV() {
        let h = harness(); defer { h.cleanup() }
        h.clock.now = asr
        h.gate.athanFired(.asr, at: asr)
        h.gate.requestSilence()
        #expect(h.tv.calls.count == 1)
    }

    @Test func pausedMeansNoTVCall() {
        var s = Settings.test(pausedUntil: .distantFuture); s.tvs = [lounge]
        let h = Harness(at: asr.addingTimeInterval(-60), settings: s); defer { h.cleanup() }
        h.clock.now = asr
        h.gate.athanFired(.asr, at: asr)
        #expect(!h.gate.isBlocked)
        #expect(h.tv.calls.isEmpty && h.audio.plays.isEmpty)
    }

    @Test func noTVsStillCallsWithAnEmptyListAndTheBlockPresents() {
        let h = harness(tvs: []); defer { h.cleanup() }
        h.clock.now = asr
        h.gate.athanFired(.asr, at: asr)
        #expect(h.gate.isBlocked && h.tv.calls.first?.tvs.isEmpty == true)
    }

    @Test func blockStillPresentsWhenTheMacAudioFails() {
        let h = harness(); defer { h.cleanup() }
        h.audio.throwOnPlay = true
        h.clock.now = asr
        h.gate.athanFired(.asr, at: asr)
        #expect(h.gate.isBlocked && !h.shield.shows.isEmpty)
        #expect(h.tv.calls.count == 1)          // the TV is the household's Athan: it does not depend on the Mac's speaker
    }

    @Test func tvOffDoesNotStopTheBlockFromPresenting() async {
        let server = FakeTVServer(); let port = server.port; server.stop()
        var s = Settings.test(); s.tvs = [TVDevice(id: "a", name: "Lounge", host: "10.255.255.1")]
        let h = Harness(at: asr.addingTimeInterval(-60), settings: s); defer { h.cleanup() }
        let real = TVController(drivers: [.roku: RokuTV(port: port, hostCheck: testHostCheck)])
        h.gate = BlockGate(clock: h.clock, store: StateStore(directory: h.dir), schedule: h.schedule, shield: h.shield, audio: h.audio,
                           hider: h.hider, ledger: h.ledger, defaultApps: h.defaultApps, tv: real,
                           settings: { [unowned h] in h.settings }, systemReduceMotion: { false })
        h.clock.now = asr
        let t0 = Date()
        h.gate.athanFired(.asr, at: asr)
        #expect(Date().timeIntervalSince(t0) < 0.5)
        #expect(h.gate.isBlocked && !h.shield.shows.isEmpty)
    }
}

@MainActor @Suite("TV settings model") struct TVModelTests {

    @Test func addByAddressAndRefuseBadOnes() {
        let r = UIFixture(); defer { r.cleanup() }
        let m = r.settingsModel()
        #expect(m.addTV(host: " 192.168.1.20 ", name: "Lounge"))
        #expect(m.tvs.map(\.host) == ["192.168.1.20"] && m.tvs.first?.name == "Lounge" && m.tvs.first?.channelId == "dev")
        #expect(!m.addTV(host: "192.168.1.20", name: ""))
        #expect(m.notice == SettingsViewModel.duplicateTVLine)
        for bad in ["8.8.8.8", "127.0.0.1", "tv.local", "http://10.0.0.2", ""] {
            #expect(!m.addTV(host: bad, name: "x"))
            #expect(m.notice == SettingsViewModel.badAddressLine)
        }
        #expect(m.tvs.count == 1)
    }

    @Test func toggleRenameRemove() {
        let r = UIFixture(); defer { r.cleanup() }
        let m = r.settingsModel()
        m.addTV(host: "10.0.0.7", name: "Den")
        let id = m.tvs[0].id
        m.setTV(id, enabled: false); #expect(m.tvs[0].enabled == false)
        m.renameTV(id, to: "  Bedroom  "); #expect(m.tvs[0].name == "Bedroom")
        m.removeTV(id); #expect(m.tvs.isEmpty)
    }

    @Test func readOnlyDuringABlock() {
        let r = UIFixture(); defer { r.cleanup() }
        let m = r.settingsModel()
        m.addTV(host: "10.0.0.7", name: "Den")
        r.startBlock()
        #expect(!m.addTV(host: "10.0.0.8", name: "Other"))
        m.setTV(m.tvs[0].id, enabled: false)
        m.removeTV(m.tvs[0].id)
        #expect(m.tvs.count == 1 && m.tvs[0].enabled)
    }

    @Test func testButtonSendsTheNextPrayerWithTheCurrentVoice() async {
        let r = UIFixture(); defer { r.cleanup() }
        let sender = RecordingSender()
        let m = SettingsViewModel(store: r.store, gate: r.gate, clock: r.clock, audio: r.audio, loginAgent: r.login,
                                  geocoder: r.geocoder, schedule: r.schedule, tv: sender)
        m.addTV(host: "10.0.0.7", name: "Den")
        let id = m.tvs[0].id
        await m.testTV(id)
        let next = r.schedule.nextAthan(after: r.clock.now)?.prayer
        #expect(sender.tests.count == 1 && sender.tests.first?.1 == next && sender.tests.first?.2 == m.settings.voice)
        #expect(m.tvTestLines[id] == SettingsViewModel.testSentLine)
        sender.fail = true
        await m.testTV(id)
        #expect(m.tvTestLines[id] == SettingsViewModel.testFailedLine)
    }

    @Test func scanListsOnlyNewTVs() async {
        let r = UIFixture(); defer { r.cleanup() }
        let m = SettingsViewModel(store: r.store, gate: r.gate, clock: r.clock, audio: r.audio, loginAgent: r.login,
                                  geocoder: r.geocoder, discovery: FixedDiscovery(found: [FoundTV(host: "10.0.0.7", name: "Den"), FoundTV(host: "10.0.0.8", name: "Lounge")]))
        m.addTV(host: "10.0.0.7", name: "Den")
        await m.scanForTVs()
        #expect(m.scanState == .done && m.foundTVs.map(\.host) == ["10.0.0.8"])
        await m.addFound(m.foundTVs[0])
        #expect(m.tvs.count == 2 && m.foundTVs.isEmpty)
    }
}

final class RecordingSender: TVSending, @unchecked Sendable {
    var tests: [(TVDevice, Prayer, Voice)] = []
    var fail = false
    var failWith: TVError?
    var resolution: TVResolution = .found("dev")
    func athanStarted(prayer: Prayer, voice: Voice, tvs: [TVDevice]) {}
    func resolve(_ tv: TVDevice) async -> TVResolution { resolution }
    func test(_ tv: TVDevice, prayer: Prayer, voice: Voice) async throws {
        tests.append((tv, prayer, voice))
        if let failWith { throw failWith }
        if fail { throw TVError.unreachable }
    }
}

struct FixedDiscovery: TVDiscovering { var found: [FoundTV]; var denied = false; func scan() async -> TVScan { TVScan(found: found, denied: denied) } }

@Suite("Roku discovery parsing") struct RokuParseTests {
    @Test func friendlyNameElement() {
        let xml = "<device-info><user-device-name> Lounge TV </user-device-name><friendly-device-name>Hisense</friendly-device-name></device-info>"
        #expect(RokuDiscovery.element("user-device-name", in: xml) == "Lounge TV")
        #expect(RokuDiscovery.element("friendly-device-name", in: xml) == "Hisense")
        #expect(RokuDiscovery.element("model-name", in: xml) == nil)
    }
}

/// Opt-in (GOPRAY_LIVE_TESTS=1, GOPRAY_LIVE_TV=<ip>): launches the Go Pray channel on a real Roku.
@Suite("TV live", .enabled(if: ProcessInfo.processInfo.environment["GOPRAY_LIVE_TESTS"] != nil)) struct TVLiveTests {
    @Test func launchesOnARealRoku() async throws {
        let host = try #require(ProcessInfo.processInfo.environment["GOPRAY_LIVE_TV"])
        let device = TVDevice(id: "live", name: "Live", host: host)
        try await TVController().test(device, prayer: .asr, voice: .sunni("Minshawi"))
    }
}
