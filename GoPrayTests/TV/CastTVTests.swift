// CastTVTests.swift — the Google TV driver (Google TV Plan §6): the CASTV2 codec against the shared vectors in
// tv/vectors/, the reply parser, the pure decisions, and the driver against a fake Chromecast on localhost
// (real sockets, real bytes). The seams (media, server, power) are the PM's fakes in CastFakes.swift.

import Foundation
import Testing
@testable import GoPray

private final class VectorAnchor {}

private func vectorFile(_ name: String) throws -> Any {
    // The bundle only: project.yml copies tv/vectors into Fixtures/tv-vectors (the source tree is under ~/Documents).
    guard let r = Bundle(for: VectorAnchor.self).resourceURL else { throw CocoaError(.fileReadNoSuchFile) }
    return try JSONSerialization.jsonObject(with: Data(contentsOf: r.appendingPathComponent("Fixtures/tv-vectors/\(name)")))
}

private func hexData(_ s: String) -> Data {
    var d = Data(), i = s.startIndex
    while i < s.endIndex { let j = s.index(i, offsetBy: 2); d.append(UInt8(s[i..<j], radix: 16)!); i = j }
    return d
}

private let castHostCheck: @Sendable (String) -> Bool = { $0 == "127.0.0.1" || TVHost.isAllowed($0) }

private func googleTV(_ host: String = "127.0.0.1") -> TVDevice { TVDevice(id: "tv-1", name: "Den", kind: .googleTV, host: host) }

private func fastTiming() -> CastTiming {
    var t = CastTiming()
    t.connect = 1; t.status = 1; t.stopWait = 0.5; t.launchWait = 1; t.finalStopWait = 0.3
    t.ping = 0.1; t.frozen = 0.8; t.cap = 20; t.probeGap = 0.05
    return t
}

private struct Rig {
    let server = FakeCastServer()
    let media = MemoryMediaSource()
    let serving = FakeServing()
    let power = FakePower()
    var timing = fastTiming()

    var driver: CastTV {
        CastTV(port: server.port, tls: false, hostCheck: castHostCheck, timing: timing, media: media, server: serving, power: power)
    }
    func launch(_ prayer: Prayer = .asr, test: Bool = false) async throws {
        try await driver.launch(googleTV(), prayer: prayer, voice: .sunni("Minshawi"), test: test)
    }
    func index(_ entry: String) -> Int? { server.log.firstIndex(of: entry) }
}

private func advancing(_ n: Int = 200) -> [FakeCastServer.Media] { (1...n).map { .playing(Double($0) * 2) } }

// MARK: - Codec

@Suite("Cast codec") struct CastCodecTests {
    @Test func connectEncodesToThePinnedVector() {
        let m = CastOut.handshake(to: "receiver-0")
        #expect(CastFrame.encode(m).map { String(format: "%02x", $0) }.joined() ==
                "00000058" + "0800120873656e6465722d301a0a72656365697665722d30222875726e3a782d636173743a636f6d2e676f6f676c652e636173742e74702e636f6e6e656374696f6e280032127b2274797065223a22434f4e4e454354227d")
    }

    @Test func everySharedVectorEncodesAndDecodes() throws {
        let file = try #require(try vectorFile("cast-frames.json") as? [String: Any])
        let cases = try #require(file["cases"] as? [[String: Any]])
        #expect(cases.count >= 10)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let hex = try #require(c["frameHex"] as? String)
            let m = try #require(c["message"] as? [String: Any])
            let want = CastMessage(source: m["source_id"] as! String, destination: m["destination_id"] as! String,
                                   namespace: m["namespace"] as! String, payload: m["payload_utf8"] as! String)
            #expect(CastFrame.encode(want) == hexData(hex), "encode \(name)")
            var buf = hexData(hex)
            let body = try #require(try CastFrame.take(from: &buf), "take \(name)")
            #expect(buf.isEmpty)
            #expect(CastMessage.decode(body) == want, "decode \(name)")
        }
    }

    @Test func decodeRoundTripsAndIgnoresUnknownFields() throws {
        let m = CastMessage(source: "a", destination: "b", namespace: "urn:x", payload: #"{"type":"PING"}"#)
        #expect(CastMessage.decode(m.encoded()) == m)
        // fields 15 (varint), 14 (bytes), 9 (fixed32) and 10 (fixed64) the schema does not know are skipped
        var extra = m.encoded()
        extra += Proto.encode([(15, .varint(300)), (14, .bytes(Data("zz".utf8)))])
        extra += Data([0x4d, 1, 2, 3, 4]) + Data([0x51, 1, 2, 3, 4, 5, 6, 7, 8])
        #expect(CastMessage.decode(extra) == m)
    }

    @Test func truncatedAndWrongTypedBytesAreNil() {
        #expect(Proto.decode(Data([0x08, 0x80]), schema: CastMessage.schema) == nil)             // varint cut off
        #expect(Proto.decode(Data([0x12, 0x05, 0x61]), schema: CastMessage.schema) == nil)       // 5 bytes declared, 1 there
        #expect(Proto.decode(Data([0x10, 0x01]), schema: CastMessage.schema) == nil)             // field 2 as a varint
        #expect(Proto.decode(Data(repeating: 0xff, count: 11), schema: CastMessage.schema) == nil)
        #expect(CastMessage.decode(Data()) == nil)                                               // no ids at all
        // a binary payload (payload_type 1) is refused
        let bin = Proto.encode([(1, .varint(0)), (2, .bytes(Data("s".utf8))), (3, .bytes(Data("d".utf8))), (4, .bytes(Data("n".utf8))), (5, .varint(1)), (7, .bytes(Data([1])))])
        #expect(CastMessage.decode(bin) == nil)
    }

    @Test func aDeclaredLengthOverTheCapClosesAndTheCapItselfIsFine() throws {
        var big = Data([0x00, 0x01, 0x00, 0x01, 0x08])                       // 65 537
        #expect(throws: TVError.unreachable) { _ = try CastFrame.take(from: &big) }
        var edge = Data([0x00, 0x01, 0x00, 0x00, 0x08])                      // 65 536: allowed, just not all here yet
        #expect(try CastFrame.take(from: &edge) == nil)
        var partial = Data([0x00, 0x00, 0x00])
        #expect(try CastFrame.take(from: &partial) == nil)
    }

    @Test func twoFramesInOneBufferComeOutOneAtATime() throws {
        let a = CastMessage(source: "a", destination: "b", namespace: "n", payload: "1")
        let b = CastMessage(source: "c", destination: "d", namespace: "n", payload: "2")
        var buf = CastFrame.encode(a) + CastFrame.encode(b).prefix(7)
        #expect(CastMessage.decode(try #require(try CastFrame.take(from: &buf))) == a)
        #expect(try CastFrame.take(from: &buf) == nil)
        buf += CastFrame.encode(b).dropFirst(7)
        #expect(CastMessage.decode(try #require(try CastFrame.take(from: &buf))) == b)
    }

    @Test func varintPrefixRoundTripsAThreeHundredByteMessage() throws {
        let body = Proto.encode([(1, .varint(2)), (2, .bytes(Data(repeating: 0x41, count: 295)))])
        #expect(body.count == 300)
        var framed = CastFrame.wrap(body, prefix: .varint)
        #expect(Array(framed.prefix(2)) == [0xac, 0x02])                     // 300 as a two-byte varint
        #expect(framed.count == 302)
        #expect(try CastFrame.take(from: &framed, prefix: .varint) == body)
        var cut = CastFrame.wrap(body, prefix: .varint).prefix(1)
        #expect(try CastFrame.take(from: &cut, prefix: .varint) == nil)      // half a prefix: wait
        var huge = Proto.varint(70_000) + Data([1])
        #expect(throws: TVError.unreachable) { _ = try CastFrame.take(from: &huge, prefix: .varint) }
    }
}

// MARK: - Replies

@Suite("Cast replies") struct CastReplyTests {
    private func parse(_ ns: String, _ payload: String, from: String = "receiver-0") -> CastReply {
        CastReply.parse(CastMessage(source: from, destination: "sender-0", namespace: ns, payload: payload))
    }

    @Test func receiverStatusReadsOnlyTheNamedFields() {
        let r = parse(CastNS.receiver, #"{"type":"RECEIVER_STATUS","requestId":7,"status":{"isStandBy":true,"applications":[{"appId":"CC1AD845","transportId":"web-7","sessionId":"abc-1","statusText":"Casting: Go Pray","evil":"x"}]}}"#)
        #expect(r == .receiverStatus(requestId: 7, isStandBy: true,
                                     apps: [CastApp(appId: "CC1AD845", transportId: "web-7", sessionId: "abc-1", statusText: "Casting: Go Pray")]))
        #expect(parse(CastNS.receiver, #"{"type":"RECEIVER_STATUS","status":{}}"#) == .receiverStatus(requestId: nil, isStandBy: nil, apps: []))
    }

    @Test func idsThatAreNotPlainAreDropped() {
        let r = parse(CastNS.receiver, #"{"type":"RECEIVER_STATUS","status":{"applications":[{"appId":"CC1AD845","transportId":"../x","sessionId":"a b"}]}}"#)
        #expect(r == .receiverStatus(requestId: nil, isStandBy: nil, apps: [CastApp(appId: "CC1AD845", transportId: nil, sessionId: nil, statusText: "")]))
        #expect(CastReply.isValidID("web-7") && CastReply.isValidID("a.B_c-9"))
        #expect(!CastReply.isValidID("") && !CastReply.isValidID("../x") && !CastReply.isValidID("a/b") && !CastReply.isValidID(String(repeating: "a", count: 65)))
    }

    @Test func mediaStatusAndTheOtherTypes() {
        #expect(parse(CastNS.media, #"{"type":"MEDIA_STATUS","requestId":0,"status":[{"playerState":"IDLE","idleReason":"CANCELLED","currentTime":3.5}]}"#, from: "web-7")
                == .mediaStatus(requestId: 0, entries: [CastMedia(playerState: "IDLE", idleReason: "CANCELLED", currentTime: 3.5)]))
        #expect(parse(CastNS.heartbeat, #"{"type":"PING"}"#) == .ping)
        #expect(parse(CastNS.heartbeat, #"{"type":"PONG"}"#) == .pong)
        #expect(parse(CastNS.connection, #"{"type":"CLOSE"}"#) == .close)
        #expect(parse(CastNS.receiver, #"{"type":"LAUNCH_ERROR","reason":"NOT_FOUND"}"#) == .launchError)
        #expect(parse(CastNS.media, #"{"type":"LOAD_FAILED"}"#) == .loadFailed)
    }

    @Test func junkIsOther() {
        #expect(parse(CastNS.receiver, "not json {") == .other)
        #expect(parse(CastNS.receiver, "[1,2]") == .other)
        #expect(parse(CastNS.receiver, #"{"type":42}"#) == .other)
        #expect(parse(CastNS.receiver, #"{"type":"SOMETHING_NEW"}"#) == .other)
        #expect(parse(CastNS.receiver, String(repeating: " ", count: 70_000) + "{}") == .other)
    }
}

// MARK: - The pure decisions (shared fixtures)

@Suite("Cast decisions") struct CastDecideTests {
    private func media(_ a: Any?) -> CastMedia? {
        guard let a = a as? [Any], a.count == 3 else { return nil }
        return CastMedia(playerState: a[0] as! String, idleReason: a[1] as? String, currentTime: (a[2] as! NSNumber).doubleValue)
    }

    @Test func liveRule() throws {
        let file = try #require(try vectorFile("cast-decide.json") as? [String: Any])
        for c in try #require(file["live"] as? [[String: Any]]) {
            #expect(CastDecide.isLivePlayback(media(c["first"]), media(c["second"])) == (c["expect"] as! Bool), "\(c["name"] ?? "?")")
        }
    }

    @Test func endRule() throws {
        let file = try #require(try vectorFile("cast-decide.json") as? [String: Any])
        for c in try #require(file["end"] as? [[String: Any]]) {
            let m = try #require(media(c["media"]))
            #expect(CastDecide.end(of: m)?.rawValue == c["expect"] as? String, "\(c["name"] ?? "?")")
        }
    }

    @Test func progressRule() throws {
        let file = try #require(try vectorFile("cast-decide.json") as? [String: Any])
        for c in try #require(file["progress"] as? [[String: Any]]) {
            var p = CastProgress(startedAt: (c["startedAt"] as! NSNumber).doubleValue)
            for o in c["observations"] as! [[Any]] {
                p.observe(CastMedia(playerState: o[1] as! String, idleReason: o[2] as? String, currentTime: (o[3] as! NSNumber).doubleValue),
                          at: (o[0] as! NSNumber).doubleValue)
            }
            #expect(p.isStalled(at: (c["at"] as! NSNumber).doubleValue, limit: (c["limit"] as! NSNumber).doubleValue) == (c["expectStalled"] as! Bool), "\(c["name"] ?? "?")")
        }
    }

    @Test func discoveryNamesTheTVLikeSettingsShowsIt() {
        #expect(CastDiscovery.displayName(fn: "Family Room TV", md: "BRAVIA 4K VH21") == "Family Room TV (BRAVIA 4K VH21)")
        #expect(CastDiscovery.displayName(fn: "Chromecast", md: "Chromecast") == "Chromecast")
        #expect(CastDiscovery.displayName(fn: nil, md: "Google TV Streamer") == "Google TV Streamer")
        #expect(CastDiscovery.displayName(fn: "Den\u{0007}", md: nil) == "Den")
        #expect(CastDiscovery.displayName(fn: nil, md: nil) == "Google TV")
        #expect(CastDiscovery.displayName(fn: String(repeating: "x", count: 200), md: "m").count == TVDevice.maxNameLength)
    }
}

// MARK: - The driver against a fake Chromecast

@Suite("Cast driver", .serialized) struct CastDriverTests {
    @Test func happyPathOrderAndWhatIsSent() async throws {
        let r = Rig()
        try await r.launch(.asr)
        let log = r.server.log
        #expect(Array(log.prefix(5)) == ["CONNECT>receiver-0", "GET_STATUS>receiver-0", "LAUNCH>receiver-0", "CONNECT>web-7", "LOAD>web-7"], "\(log)")
        let load = try #require(r.server.messages("LOAD").first)
        let media = try #require(load.json["media"] as? [String: Any])
        #expect(media["contentId"] as? String == r.serving.url.absoluteString)
        #expect(media["contentType"] as? String == "video/mp4")
        #expect(media["streamType"] as? String == "BUFFERED")
        #expect((media["metadata"] as? [String: Any])?["title"] as? String == "Go Pray · Asr")
        #expect(load.json["autoplay"] as? Bool == true)
        #expect(r.server.messages("PING").count >= 2)
        #expect(r.server.messages("GET_STATUS").filter { $0.destination == "web-7" }.count >= 2)
        let stop = try #require(r.server.messages("STOP").last)
        #expect(stop.destination == "receiver-0" && stop.json["sessionId"] as? String == "sess-new")
        #expect(r.serving.stops == 1)
        #expect(r.serving.calls.count == 1)
        #expect(r.serving.calls[0].peer == "127.0.0.1")
        #expect(r.serving.calls[0].localAddress == "127.0.0.1")         // the socket's own local address, not a guess
        #expect(r.media.calls.count == 1 && r.media.calls[0].prayer == .asr)
        #expect(r.power.turnOffs.isEmpty)                               // the TV was on
    }

    @Test func theTestButtonSaysTest() async throws {
        let r = Rig()
        try await r.launch(.fajr, test: true)
        let media = try #require(r.server.messages("LOAD").first?.json["media"] as? [String: Any])
        #expect((media["metadata"] as? [String: Any])?["title"] as? String == "Go Pray · Test")
    }

    // Standby: wake and play, and turn it back off only when the Athan finished.
    @Test func standbyWakesAndPlaysThenTurnsOffOnceWhenPaired() async throws {
        let r = Rig(); r.server.receiver = .standby
        try await r.launch()
        #expect(r.server.log.contains("LAUNCH>receiver-0") && r.server.log.contains("LOAD>web-7"))
        #expect(r.power.turnOffs.count == 1)
        #expect(r.power.turnOffs.first?.host == "127.0.0.1")
    }

    @Test func standbyButNotPairedLeavesItOn() async throws {
        let r = Rig(); r.server.receiver = .standby; r.power.paired = false
        try await r.launch()
        #expect(r.server.log.contains("LOAD>web-7"))
        #expect(r.power.turnOffs.isEmpty)
    }

    @Test func aTVThatWasOnIsNeverTurnedOff() async throws {
        let r = Rig(); r.server.receiver = .idle
        try await r.launch()
        #expect(r.power.turnOffs.isEmpty)
    }

    @Test func aFailedPowerOffDoesNotFailTheAthan() async throws {
        let r = Rig(); r.server.receiver = .standby; r.power.turnOffFailure = TVError.unreachable
        try await r.launch()
        #expect(r.power.turnOffs.count == 1)
    }

    // STOP first, always.
    @Test func aRunningReceiverIsStoppedBeforeTheLaunch() async throws {
        let r = Rig(); r.server.receiver = .running(statusText: "YouTube", sessionId: "sess-old", transport: "web-old")
        try await r.launch()
        let stop = try #require(r.server.messages("STOP").first)
        #expect(stop.json["sessionId"] as? String == "sess-old")
        let s = try #require(r.index("STOP>receiver-0")), l = try #require(r.index("LAUNCH>receiver-0"))
        #expect(s < l, "\(r.server.log)")
    }

    @Test func aLiveAthanFromAnotherLaptopIsLeftAlone() async throws {
        let r = Rig(); r.server.receiver = .running(statusText: "Casting: Go Pray · Asr", sessionId: "sess-old", transport: "web-old")
        r.server.existingPlan = [.playing(10), .playing(13)]
        try await r.launch()
        #expect(r.server.messages("STOP").isEmpty && r.server.messages("LAUNCH").isEmpty && r.server.messages("LOAD").isEmpty, "\(r.server.log)")
        #expect(r.media.calls.isEmpty && r.serving.calls.isEmpty)       // nothing rendered, nothing served
        #expect(r.power.turnOffs.isEmpty)                               // that sender owns it
    }

    @Test func theTestButtonStopsAndLaunchesEvenOverALiveAthan() async throws {
        let r = Rig(); r.server.receiver = .running(statusText: "Casting: Go Pray · Asr", sessionId: "sess-old", transport: "web-old")
        r.server.existingPlan = [.playing(10), .playing(13)]
        try await r.launch(test: true)
        #expect(r.server.messages("STOP").first?.json["sessionId"] as? String == "sess-old")
        #expect(r.server.log.contains("LAUNCH>receiver-0") && r.server.log.contains("LOAD>web-7"))
    }

    @Test func aFrozenCorpseThatLooksLikeOurAthanIsStoppedAndReplaced() async throws {
        let r = Rig(); r.server.receiver = .running(statusText: "Casting: Go Pray · Maghrib", sessionId: "sess-old", transport: "web-old")
        r.server.existingPlan = [.buffering(), .buffering()]
        try await r.launch()
        #expect(r.server.messages("STOP").first?.json["sessionId"] as? String == "sess-old")
        #expect(r.server.log.contains("LAUNCH>receiver-0") && r.server.log.contains("LOAD>web-7"))
    }

    @Test func aTransportIdThatIsNotPlainIsNeverUsedAsADestination() async throws {
        let r = Rig(); r.server.receiver = .running(statusText: "Casting: Go Pray", sessionId: "sess-old", transport: "../x")
        r.server.existingPlan = [.playing(10), .playing(13)]
        try await r.launch()
        #expect(!r.server.seen.contains { $0.destination.contains("..") }, "\(r.server.log)")
        #expect(r.server.log.contains("LOAD>web-7"))
    }

    // How it ends.
    @Test func backEndsItEarlyStopsTheReceiverAndLeavesTheTVOn() async throws {
        let r = Rig(); r.server.receiver = .standby
        r.server.mediaPlan = [.buffering(), .playing(2), .cancelled()]
        try await r.launch()
        #expect(r.server.messages("STOP").last?.json["sessionId"] as? String == "sess-new")
        #expect(r.serving.stops == 1)
        #expect(r.power.turnOffs.isEmpty, "a person is using the TV")
    }

    @Test func aFrozenClockEndsItEarlyWithNoPowerOff() async throws {
        let r = Rig(); r.server.receiver = .standby
        r.server.mediaPlan = [.buffering()]                              // BUFFERING forever: what Back leaves behind
        let t0 = Date()
        try await r.launch()
        #expect(Date().timeIntervalSince(t0) < 5)
        #expect(r.server.messages("STOP").last?.json["sessionId"] as? String == "sess-new")
        #expect(r.serving.stops == 1)
        #expect(r.power.turnOffs.isEmpty)
    }

    @Test func aPlayingClockThatStopsMovingIsFrozenToo() async throws {
        let r = Rig(); r.server.receiver = .standby
        r.server.mediaPlan = [.playing(1), .playing(4), .playing(4)]
        try await r.launch()
        #expect(r.server.messages("STOP").last?.json["sessionId"] as? String == "sess-new")
        #expect(r.power.turnOffs.isEmpty)
    }

    @Test func anotherSenderTakingOverIsLeftAlone() async throws {
        let r = Rig(); r.server.receiver = .standby
        r.server.mediaPlan = advancing()
        r.server.dropOurSessionAfterQueries = 2
        try await r.launch()
        #expect(r.server.messages("STOP").isEmpty, "not ours any more: \(r.server.log)")
        #expect(r.serving.stops == 1)
        #expect(r.power.turnOffs.isEmpty)
    }

    @Test func theTVsPingGetsAPong() async throws {
        let r = Rig(); r.server.sendPing = true
        try await r.launch()
        #expect(r.server.log.contains("PONG>receiver-0"))
    }

    @Test func aSocketDroppedMidPlayStillStopsTheServer() async throws {
        let r = Rig(); r.server.receiver = .standby
        r.server.mediaPlan = advancing()
        r.server.dropAfter = 5                                           // right after LOAD
        try await r.launch()
        #expect(r.serving.stops == 1)
        #expect(r.power.turnOffs.isEmpty)
    }

    @Test func theHardCapStopsAnAthanThatNeverEnds() async throws {
        var r = Rig(); r.server.receiver = .standby
        r.timing.cap = 1.0
        r.server.mediaPlan = advancing()
        let t0 = Date()
        try await r.launch()
        #expect(Date().timeIntervalSince(t0) < 4)
        #expect(r.server.messages("STOP").last?.json["sessionId"] as? String == "sess-new")
        #expect(r.serving.stops == 1)
        #expect(r.power.turnOffs.isEmpty, "a cap is not a finished Athan")
    }

    // Failures.
    @Test func launchErrorIsBadStatusAndNothingIsLoaded() async throws {
        let r = Rig(); r.server.launchReply = .error
        await #expect(throws: TVError.badStatus(0)) { try await r.launch() }
        #expect(!r.server.log.contains("LOAD>web-7"))
        #expect(r.serving.stops == 1)
    }

    @Test func aSilentLaunchTimesOutUnreachable() async throws {
        let r = Rig(); r.server.launchReply = .silence
        await #expect(throws: TVError.unreachable) { try await r.launch() }
        #expect(r.serving.stops == 1)
    }

    @Test func aHugeFrameIsUnreachable() async throws {
        let r = Rig(); r.server.sendHugeFrame = true
        await #expect(throws: TVError.unreachable) { try await r.launch() }
        #expect(!r.server.log.contains("LAUNCH>receiver-0"))
    }

    @Test func junkIsIgnoredAndTheAthanStillPlays() async throws {
        let r = Rig(); r.server.sendJunk = true
        try await r.launch()
        #expect(r.server.log.contains("LOAD>web-7"))
    }

    @Test func aClosedPortIsUnreachableFast() async throws {
        let r = Rig()
        let driver = CastTV(port: FakeCastServer.closedPort(), tls: false, hostCheck: castHostCheck, timing: fastTiming(), media: r.media, server: r.serving, power: r.power)
        let t0 = Date()
        await #expect(throws: TVError.unreachable) { try await driver.launch(googleTV(), prayer: .asr, voice: .sunni("Minshawi"), test: false) }
        #expect(Date().timeIntervalSince(t0) < 3)
        #expect(r.media.calls.isEmpty && r.serving.calls.isEmpty)
    }

    @Test func badHostsAreRefusedBeforeAnySocket() async throws {
        let r = Rig()
        let production = CastTV(port: r.server.port, tls: false, media: r.media, server: r.serving, power: r.power)    // the real host check
        for host in ["127.0.0.1", "8.8.8.8", "example.com", "010.0.0.1", "10.0.0", ""] {
            await #expect(throws: TVError.refusedHost, "\(host)") { try await production.launch(googleTV(host), prayer: .asr, voice: .sunni("Minshawi"), test: false) }
            await #expect(throws: TVError.refusedHost, "\(host)") { _ = try await production.findChannel(googleTV(host)) }
        }
        #expect(r.server.seen.isEmpty)
    }

    @Test func aChannelIdThatIsNotOursIsRefused() async throws {
        let r = Rig()
        var tv = googleTV(); tv.channelId = "ABCDEF01"
        await #expect(throws: TVError.badURL) { try await r.driver.launch(tv, prayer: .asr, voice: .sunni("Minshawi"), test: false) }
        #expect(r.server.seen.isEmpty)
    }

    @Test func aFailedRenderOrServerMeansNoLaunch() async throws {
        let a = Rig(); a.media.failure = URLError(.cannotCreateFile)
        await #expect(throws: (any Error).self) { try await a.launch() }
        #expect(!a.server.log.contains("LAUNCH>receiver-0"))

        let b = Rig(); b.serving.failure = TVError.unreachable
        await #expect(throws: TVError.unreachable) { try await b.launch() }
        #expect(!b.server.log.contains("LAUNCH>receiver-0"))
        #expect(b.serving.stops == 0)
    }

    @Test func findChannelAnswersWithTheStockReceiver() async throws {
        let r = Rig()
        #expect(try await r.driver.findChannel(googleTV()) == "CC1AD845")
        #expect(r.server.log == ["CONNECT>receiver-0", "GET_STATUS>receiver-0"])
    }

    @Test func forgetClearsTheRemoteAndProductionUsesTLS() {
        let r = Rig()
        r.driver.forget(googleTV())
        #expect(r.power.forgotten.count == 1)
        #expect(CastTV(media: r.media, server: r.serving, power: r.power).tls)
        #expect(CastTV(media: r.media, server: r.serving, power: r.power).port == 8009)
    }
}
