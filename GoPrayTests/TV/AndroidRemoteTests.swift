// AndroidRemoteTests.swift — the Android TV Remote driver (Google TV Plan §4/§6): the codec against the shared JSON vectors
// in tv/vectors/, the pairing-secret hash, the generated client certificate (parsed by Security and by openssl), the
// pairing handshake and the power-off against a fake TV on loopback (plain TCP, `tls: false`), and the opt-in live run.

import CryptoKit
import Foundation
import Security
import Testing
@testable import GoPray

/// Read from the test bundle only ("Copy test fixtures" phase): a path under ~/Documents makes macOS ask the test host for access.
private let fixtures = Bundle(for: TVFixtureToken.self).resourceURL!.appendingPathComponent("Fixtures", isDirectory: true)
private final class TVFixtureToken {}

private func vector(_ name: String) throws -> [String: Any] {
    let data = try Data(contentsOf: fixtures.appendingPathComponent("tv-vectors/\(name)"))
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func hex(_ s: String) -> Data {
    var out = Data(); var i = s.startIndex
    while i < s.endIndex { let j = s.index(i, offsetBy: 2); out.append(UInt8(s[i..<j], radix: 16)!); i = j }
    return out
}
private func hexString(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

private let loopback: @Sendable (String) -> Bool = { $0 == "127.0.0.1" }

private func tv(_ host: String = "127.0.0.1", paired: Bool = false) -> TVDevice {
    TVDevice(id: "gtv-1", name: "Den", kind: .googleTV, host: host, remotePaired: paired)
}

private func remote(pairing: FakeRemoteServer? = nil, control: FakeRemoteServer? = nil, store: IdentityStore = MemoryIdentityStore.withIdentity(),
                    step: TimeInterval = 2, serverCert: Data? = nil) -> AndroidRemote {
    AndroidRemote(store: store, tls: false, pairingPort: pairing?.port ?? 9, controlPort: control?.port ?? 9, stepTimeout: step,
                  hostAllowed: loopback, peerCertificateOverride: serverCert)
}

/// A JSON value (NSNumber / NSDictionary) turned into what `PB.decode` returns, so the two compare.
private func normalize(_ v: Any) -> Any {
    if let d = v as? [String: Any] {
        if let h = d["secret_hex"] as? String { return ["secret": hex(h)] }
        return d.mapValues(normalize)
    }
    if let a = v as? [Any] { return a.map(normalize) }
    if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.uint64Value }
    return v
}

private func same(_ a: Any, _ b: Any) -> Bool {
    switch (a, b) {
    case let (x as [String: Any], y as [String: Any]): return x.count == y.count && x.allSatisfy { k, v in y[k].map { same(v, $0) } ?? false }
    case let (x as [Any], y as [Any]): return x.count == y.count && zip(x, y).allSatisfy { same($0, $1) }
    case let (x as UInt64, y as UInt64): return x == y
    case let (x as Bool, y as Bool): return x == y
    case let (x as String, y as String): return x == y
    case let (x as Data, y as Data): return x == y
    default: return false
    }
}

// MARK: - Codec

@Suite("AndroidRemote codec") struct AndroidRemoteCodecTests {
    @Test func everySharedFrameDecodesAndTheSentOnesEncodeToTheSameBytes() throws {
        let frames = try #require(try vector("remote-frames.json")["frames"] as? [[String: Any]])
        #expect(frames.count >= 15)
        for f in frames {
            let name = f["name"] as! String
            let schema = (f["family"] as! String) == "polo" ? RemoteWire.polo : RemoteWire.remote
            let bytes = hex(f["frame_hex"] as! String)
            var buf = bytes
            let body = try #require(try RemoteFrame.take(&buf), Comment(rawValue: name))
            #expect(buf.isEmpty, Comment(rawValue: name))
            let fields = normalize(f["fields"]!)
            let decoded = try #require(PB.decode(body, schema: schema), Comment(rawValue: name))
            #expect(same(fields, decoded), Comment(rawValue: "decode \(name)"))
            if (f["direction"] as! String) == "send" {
                let encoded = try #require(PB.encode(fields as! [String: Any], schema: schema), Comment(rawValue: name))
                #expect(RemoteFrame.wrap(encoded) == bytes, Comment(rawValue: "encode \(name)"))
            }
        }
    }

    @Test func theBuildersMakeTheVectorBytes() throws {
        let frames = try #require(try vector("remote-frames.json")["frames"] as? [[String: Any]])
        func bytes(_ name: String) -> Data { hex(frames.first { ($0["name"] as! String) == name }!["frame_hex"] as! String) }
        #expect(RemoteWire.pairingRequest() == bytes("pairing_request"))
        #expect(RemoteWire.pairingOptions() == bytes("options"))
        #expect(RemoteWire.pairingConfiguration() == bytes("configuration"))
        #expect(RemoteWire.configureReply() == bytes("remote_configure_reply"))
        #expect(RemoteWire.setActiveReply() == bytes("remote_set_active_reply"))
        #expect(RemoteWire.pingResponse(7) == bytes("remote_ping_response"))
        #expect(RemoteWire.keyFrame(.power, .short) == bytes("power_key"))
        #expect(hexString(RemoteWire.keyFrame(.power, .short)) == "065204081a1003")
    }

    @Test func aTruncatedOrOversizeFrameIsRefusedAndAnUnknownFieldIsIgnored() throws {
        var half = Data([0x10, 0x08])                       // says 16 bytes, has 1
        #expect(try RemoteFrame.take(&half) == nil)
        var huge = Data([0x81, 0x80, 0x04])                 // 65 537
        #expect(throws: RemoteError.self) { _ = try RemoteFrame.take(&huge) }
        var longVarint = Data([0x80, 0x80, 0x80, 0x01])     // a 4-byte length
        #expect(throws: RemoteError.self) { _ = try RemoteFrame.take(&longVarint) }
        #expect(PB.decode(Data([0x08, 0x80]), schema: RemoteWire.remote) == nil)   // truncated varint
        // field 99 (varint) next to a known field: skipped
        let known = try #require(PB.encode(["remote_set_active": ["active": 35]], schema: RemoteWire.remote))
        let withUnknown = Data([0x98, 0x06, 0x01]) + known
        let d = try #require(PB.decode(withUnknown, schema: RemoteWire.remote))
        #expect(same(d, ["remote_set_active": ["active": UInt64(35)]]))
    }

    @Test func aThreeHundredByteMessageRoundTripsWithATwoByteLengthPrefix() throws {
        let text = String(repeating: "x", count: 297)
        let body = try #require(PB.encode(["remote_configure": ["device_info": ["model": text]]], schema: RemoteWire.remote))
        let framed = RemoteFrame.wrap(body)
        #expect(framed.count == body.count + 2)
        var buf = framed
        let back = try #require(try RemoteFrame.take(&buf))
        #expect(back == body && buf.isEmpty)
    }

    @Test func theEncoderRefusesAKeyTheTableDoesNotHave() {
        #expect(PB.encode(["remote_voice_begin": ["session_id": 1]], schema: RemoteWire.remote) == nil)
    }
}

// MARK: - Pairing secret

@Suite("RemotePairing") struct RemotePairingTests {
    private func numbers() throws -> (cn: Data, ce: Data, sn: Data, se: Data, v: [String: Any]) {
        let v = try vector("remote-pairing-secret.json")
        return (hex(v["client_modulus_hex"] as! String), hex(v["client_exponent_hex"] as! String),
                hex(v["server_modulus_hex"] as! String), hex(v["server_exponent_hex"] as! String), v)
    }

    @Test func theSecretEqualsTheValueTheAndroidtvremote2LibraryComputes() throws {
        let n = try numbers()
        let secret = try #require(RemotePairing.secret(clientN: n.cn, clientE: n.ce, serverN: n.sn, serverE: n.se, code: n.v["code"] as! String))
        #expect(hexString(secret) == n.v["secret_hex"] as! String)
        #expect(RemotePairing.secret(clientN: n.cn, clientE: n.ce, serverN: n.sn, serverE: n.se, code: (n.v["code"] as! String).lowercased()) == secret)
    }

    @Test func aWrongFirstByteOrABadCodeGivesNothingToSend() throws {
        let n = try numbers()
        func s(_ code: String) -> Data? { RemotePairing.secret(clientN: n.cn, clientE: n.ce, serverN: n.sn, serverE: n.se, code: code) }
        #expect(s(n.v["wrong_first_byte_code"] as! String) == nil)
        #expect(s("") == nil && s("3EA1B") == nil && s("3EA1B2C") == nil && s("3EA1BG") == nil && s("3EA1 2") == nil)
    }

    @Test func theModulusAndExponentFromTheVectorCertificatesMatchTheLibrary() throws {
        let n = try numbers()
        let c = try #require(RemoteIdentity.numbers(certificateDER: hex(n.v["client_cert_der_hex"] as! String)))
        let s = try #require(RemoteIdentity.numbers(certificateDER: hex(n.v["server_cert_der_hex"] as! String)))
        #expect(c.n == n.cn && c.e == Data([1, 0, 1]))
        #expect(s.n == n.sn)
        // and the full path: certificates in, the vector secret out
        let secret = try #require(RemotePairing.secret(clientN: c.n, clientE: c.e, serverN: s.n, serverE: s.e, code: n.v["code"] as! String))
        #expect(hexString(secret) == n.v["secret_hex"] as! String)
    }
}

// MARK: - Identity

@Suite("RemoteIdentity") struct RemoteIdentityTests {
    private func run(_ args: [String], stdin: Data) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = args
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = Pipe()
        try p.run()
        inPipe.fileHandleForWriting.write(stdin)
        try inPipe.fileHandleForWriting.close()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: out, as: UTF8.self)
    }

    @Test func theGeneratedCertificateParsesAsA2048BitRSAKeyAndOpensslReadsIt() throws {
        let id = MemoryIdentityStore.sharedIdentity
        let der = SecCertificateCopyData(id.certificate) as Data
        let key = try #require(SecCertificateCopyKey(id.certificate))
        let attrs = try #require(SecKeyCopyAttributes(key) as? [String: Any])
        #expect(attrs["bsiz"] as? Int == 2048)
        #expect((attrs["type"] as? String) == (kSecAttrKeyTypeRSA as String))

        let text = try run(["x509", "-inform", "der", "-noout", "-subject", "-dates", "-serial"], stdin: der)
        #expect(text.contains("CN=Go Pray") || text.contains("CN = Go Pray"), Comment(rawValue: text))
        let fmt = DateFormatter(); fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.timeZone = TimeZone(secondsFromGMT: 0); fmt.dateFormat = "MMM d HH:mm:ss yyyy 'GMT'"
        func date(_ label: String) -> Date? {
            guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix(label) }) else { return nil }
            let v = line.dropFirst(label.count).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            return fmt.date(from: v)
        }
        let from = try #require(date("notBefore="), Comment(rawValue: text)), to = try #require(date("notAfter="), Comment(rawValue: text))
        let years = to.timeIntervalSince(from) / (365.25 * 86_400)
        #expect(years > 9.99 && years < 10.02, Comment(rawValue: "\(years)"))
    }

    @Test func theModulusWeExtractEqualsOpensslsModulus() throws {
        let id = MemoryIdentityStore.sharedIdentity
        let der = SecCertificateCopyData(id.certificate) as Data
        let ours = try #require(RemoteIdentity.numbers(certificate: id.certificate))
        let theirs = try run(["x509", "-inform", "der", "-noout", "-modulus"], stdin: der).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(theirs.uppercased() == "MODULUS=" + hexString(ours.n).uppercased())
        #expect(ours.e == Data([1, 0, 1]))
    }

    @Test func theCertificateIsSignedByItsOwnKey() throws {
        let id = MemoryIdentityStore.sharedIdentity
        let pub = try #require(SecKeyCopyPublicKey(id.key))
        let msg = Data("x".utf8) as CFData
        var err: Unmanaged<CFError>?
        let sig = try #require(SecKeyCreateSignature(id.key, .rsaSignatureMessagePKCS1v15SHA256, msg, &err))
        #expect(SecKeyVerifySignature(pub, .rsaSignatureMessagePKCS1v15SHA256, msg, sig, &err))
        // the certificate's own signature, checked by openssl against its own key
        let der = SecCertificateCopyData(id.certificate) as Data
        let pem = "-----BEGIN CERTIFICATE-----\n" + der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed]) + "\n-----END CERTIFICATE-----\n"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gopray-id-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("c.pem")
        try Data(pem.utf8).write(to: f)
        let out = try run(["verify", "-CAfile", f.path, f.path], stdin: Data())
        #expect(out.contains(": OK"), Comment(rawValue: out))
    }

    @Test func derHelpersRoundTrip() {
        #expect(DER.length(5) == [5] && DER.length(200) == [0x81, 200] && DER.length(300) == [0x82, 1, 44])
        #expect(DER.unsignedInteger([0x80]) == [0x02, 0x02, 0x00, 0x80])
        #expect(DER.unsignedInteger([0, 0, 0x7f]) == [0x02, 0x01, 0x7f])
        var pos = 0
        let e = DER.sequence(DER.unsignedInteger([0x01, 0x00]))
        let r = DER.read(e, &pos)
        #expect(r?.tag == 0x30 && pos == e.count)
    }
}

// MARK: - Flood cap

@Suite("RemoteChannel cap", .serialized) struct RemoteChannelCapTests {
    @Test func aFloodStopsBeingReadAtTheCapAndTheCallThrowsMalformed() async throws {
        let fake = try FakeRemoteServer(.remote); defer { fake.stop() }
        fake.sendStart = false
        let ch = RemoteChannel(host: "127.0.0.1", port: fake.port, tls: false, identity: nil)
        try await ch.open(timeout: 3)
        defer { ch.close() }
        for _ in 0..<50 where fake.connectedAt.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        try await Task.sleep(nanoseconds: 100_000_000)
        fake.flood(2_000_000)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let held = ch.bufferedByteCount
        #expect(held > 100_000, Comment(rawValue: "flood never arrived: \(held)"))
        #expect(held <= RemoteChannel.bufferCap + 16_384, Comment(rawValue: "buffered \(held)"))
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(ch.bufferedByteCount == held)
        let reads = ch.receiveCount
        fake.flood(300_000)
        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(ch.receiveCount == reads, Comment(rawValue: "still reading after the cap: \(ch.receiveCount - reads) more"))
        #expect(ch.bufferedByteCount == held)
        var thrown: Error?
        for _ in 0..<20 where thrown == nil {
            do { _ = try await ch.next(timeout: 1) } catch { thrown = error }
        }
        #expect(thrown as? RemoteError == .malformed, Comment(rawValue: "thrown: \(String(describing: thrown))"))
    }
}

// MARK: - Pairing flow

@Suite("AndroidRemote pairing", .serialized) struct AndroidRemotePairingTests {
    private func serverCert() throws -> Data { hex(try vector("remote-pairing-secret.json")["server_cert_der_hex"] as! String) }

    /// A code that is right for this Mac's identity and the vector's server certificate.
    private func goodCode(_ store: MemoryIdentityStore) throws -> String {
        let mine = try #require(RemoteIdentity.numbers(certificate: store.load()!.certificate))
        let theirs = try #require(RemoteIdentity.numbers(certificateDER: try serverCert()))
        let nonce = Data([0xA1, 0xB2])
        let d = RemotePairing.digest(clientN: mine.n, clientE: mine.e, serverN: theirs.n, serverE: theirs.e, nonce: nonce)
        return String(format: "%02X", d[0]) + "A1B2"
    }

    @Test func theHandshakeOrderAndEveryFieldValue() async throws {
        let fake = try FakeRemoteServer(.polo); defer { fake.stop() }
        let store = MemoryIdentityStore.withIdentity()
        let r = remote(pairing: fake, store: store, serverCert: try serverCert())
        #expect(try await r.startPairing(tv()) == true)
        let code = try goodCode(store)
        #expect(try await r.pair(tv(), code: code) == .paired)

        let got = fake.received.map(\.fields)
        #expect(got.count == 4)
        #expect(same(got[0], ["protocol_version": UInt64(2), "status": UInt64(200), "pairing_request": ["service_name": "atvremote", "client_name": "Go Pray"]]))
        #expect(same(got[1], ["protocol_version": UInt64(2), "status": UInt64(200),
                              "options": ["input_encodings": [["type": UInt64(3), "symbol_length": UInt64(6)]], "preferred_role": UInt64(1)]]))
        #expect(same(got[2], ["protocol_version": UInt64(2), "status": UInt64(200),
                              "configuration": ["encoding": ["type": UInt64(3), "symbol_length": UInt64(6)], "client_role": UInt64(1)]]))
        let mine = try #require(RemoteIdentity.numbers(certificate: store.load()!.certificate))
        let theirs = try #require(RemoteIdentity.numbers(certificateDER: try serverCert()))
        let expected = try #require(RemotePairing.secret(clientN: mine.n, clientE: mine.e, serverN: theirs.n, serverE: theirs.e, code: code))
        #expect(same(got[3], ["protocol_version": UInt64(2), "status": UInt64(200), "secret": ["secret": expected]]))
    }

    @Test func aWrongCodeSendsNothingAfterTheConfigurationAckAndKeepsTheSessionForARetry() async throws {
        let fake = try FakeRemoteServer(.polo); defer { fake.stop() }
        let store = MemoryIdentityStore.withIdentity()
        let r = remote(pairing: fake, store: store, serverCert: try serverCert())
        #expect(try await r.startPairing(tv()) == true)
        let good = try goodCode(store)
        let bad = String(format: "%02X", UInt8(good.prefix(2), radix: 16)! ^ 1) + "A1B2"
        #expect(try await r.pair(tv(), code: bad) == .denied)
        #expect(try await r.pair(tv(), code: "zz") == .denied)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(fake.fields(named: "secret").isEmpty)
        #expect(fake.received.count == 3)
        // the person retypes within the TV's own window
        #expect(try await r.pair(tv(), code: good) == .paired)
    }

    @Test func theTVAnswering402IsDeniedAndTheSessionIsGone() async throws {
        let fake = try FakeRemoteServer(.polo); defer { fake.stop() }
        fake.secretReply = .badSecret
        let store = MemoryIdentityStore.withIdentity()
        let r = remote(pairing: fake, store: store, serverCert: try serverCert())
        #expect(try await r.startPairing(tv()) == true)
        #expect(try await r.pair(tv(), code: try goodCode(store)) == .denied)
        #expect(try await r.pair(tv(), code: try goodCode(store)) == .unsupported)   // no held session any more
    }

    @Test func silenceAtAnyStepIsUnsupportedWithoutHanging() async throws {
        let fake = try FakeRemoteServer(.polo); defer { fake.stop() }
        fake.poloStop = .afterRequest
        let r = remote(pairing: fake, step: 0.4, serverCert: try serverCert())
        let t0 = Date()
        #expect(try await r.startPairing(tv()) == false)
        #expect(Date().timeIntervalSince(t0) < 2)
        fake.poloStop = .afterOptions
        #expect(try await r.startPairing(tv()) == false)

        let quiet = try FakeRemoteServer(.polo); defer { quiet.stop() }
        quiet.secretReply = .silence
        let store = MemoryIdentityStore.withIdentity()
        let r2 = remote(pairing: quiet, store: store, step: 0.4, serverCert: try serverCert())
        #expect(try await r2.startPairing(tv()) == true)
        #expect(try await r2.pair(tv(), code: try goodCode(store)) == .unsupported)
    }

    @Test func pairWithoutAStartedSessionIsUnsupportedAndSendsNothing() async throws {
        let fake = try FakeRemoteServer(.polo); defer { fake.stop() }
        let r = remote(pairing: fake, serverCert: try serverCert())
        #expect(try await r.pair(tv(), code: "3EA1B2") == .unsupported)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(fake.received.isEmpty && fake.connectedAt.isEmpty)
    }

    @Test func startPairingMakesAndSavesTheIdentityOnce() async throws {
        let fake = try FakeRemoteServer(.polo); defer { fake.stop() }
        let store = MemoryIdentityStore()
        let r = remote(pairing: fake, store: store, serverCert: try serverCert())
        #expect(try await r.startPairing(tv()) == true)
        #expect(try await r.startPairing(tv()) == true)
        #expect(store.saves == 1 && store.load() != nil)
    }

    @Test func aClosedPortIsUnreachableAndABadHostIsRefusedBeforeAnySocket() async throws {
        let r = AndroidRemote(store: MemoryIdentityStore.withIdentity(), tls: false, pairingPort: 9, controlPort: 9, stepTimeout: 1, peerCertificateOverride: nil)
        await #expect(throws: TVError.refusedHost) { _ = try await r.startPairing(tv("8.8.8.8")) }
        await #expect(throws: TVError.refusedHost) { _ = try await r.turnOff(tv("example")) }
        let local = remote()
        await #expect(throws: TVError.self) { _ = try await local.startPairing(tv()) }
    }
}

// MARK: - Power-off

@Suite("AndroidRemote turnOff", .serialized) struct AndroidRemoteTurnOffTests {
    private func keys(_ f: FakeRemoteServer) -> [FakeRemoteServer.Received] { f.fields(named: "remote_key_inject") }

    @Test func onTVGetsExactlyOneShortPowerPressAndReturnsTrueWhenItReportsOff() async throws {
        let fake = try FakeRemoteServer(.remote); defer { fake.stop() }
        let r = remote(control: fake)
        #expect(try await r.turnOff(tv(paired: true)) == true)
        let pressed = keys(fake)
        #expect(pressed.count == 1)
        #expect(same(pressed[0].fields, ["remote_key_inject": ["key_code": UInt64(26), "direction": UInt64(3)]]))
    }

    @Test func theTVsSetupIsAnsweredWithTheRightFeatureBitsAndPingsAreEchoed() async throws {
        let fake = try FakeRemoteServer(.remote); defer { fake.stop() }
        _ = try await remote(control: fake).turnOff(tv())
        let f = fake.received.map(\.fields)
        let configure = try #require(f.first { $0["remote_configure"] != nil })
        #expect(same(configure, ["remote_configure": ["code1": UInt64(35), "device_info": ["unknown1": UInt64(1), "unknown2": "1", "package_name": "atvremote", "app_version": "1.0.0"]]]))
        #expect(f.contains { same($0, ["remote_set_active": ["active": UInt64(35)]]) })
        #expect(f.contains { same($0, ["remote_ping_response": ["val1": UInt64(7)]]) })
    }

    @Test func noKeyIsSentBeforeOneSecondAfterConnecting() async throws {
        let fake = try FakeRemoteServer(.remote); defer { fake.stop() }
        _ = try await remote(control: fake).turnOff(tv())
        let connected = try #require(fake.connectedAt.first)
        let pressed = try #require(keys(fake).first)
        let gap = pressed.at.timeIntervalSince(connected)
        #expect(gap >= 1.0, Comment(rawValue: "key arrived \(gap) s after the connection"))
        #expect(gap < 2.5)
    }

    @Test func aTVThatIsAlreadyOffGetsNoKeyAndReturnsFalse() async throws {
        let fake = try FakeRemoteServer(.remote); defer { fake.stop() }
        fake.isOn = false
        #expect(try await remote(control: fake).turnOff(tv()) == false)
        #expect(keys(fake).isEmpty)
    }

    @Test func aTVThatNeverSaysItsStateGetsNoKey() async throws {
        let fake = try FakeRemoteServer(.remote); defer { fake.stop() }
        fake.sendStart = false
        let t0 = Date()
        #expect(try await remote(control: fake).turnOff(tv()) == false)
        #expect(keys(fake).isEmpty)
        #expect(Date().timeIntervalSince(t0) < 7)
    }

    @Test func aTVThatDoesNotConfirmOffReturnsFalseAfterOneKeyOnly() async throws {
        let fake = try FakeRemoteServer(.remote); defer { fake.stop() }
        fake.offOnKey = false
        #expect(try await remote(control: fake).turnOff(tv()) == false)
        #expect(keys(fake).count == 1)
    }

    @Test func noIdentityThrowsAndNothingIsSent() async throws {
        let fake = try FakeRemoteServer(.remote); defer { fake.stop() }
        let r = remote(control: fake, store: MemoryIdentityStore())
        await #expect(throws: RemoteError.noIdentity) { _ = try await r.turnOff(tv()) }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(fake.connectedAt.isEmpty && fake.received.isEmpty)
    }

    @Test func aClosedPortThrowsUnreachableQuickly() async throws {
        let r = remote()
        let t0 = Date()
        await #expect(throws: TVError.self) { _ = try await r.turnOff(tv()) }
        #expect(Date().timeIntervalSince(t0) < 4)
    }

    @Test func isPairedIsTheFlagAndForgetIsHarmless() {
        let r = remote()
        #expect(r.isPaired(tv(paired: true)) && !r.isPaired(tv(paired: false)))
        r.forget(tv())
    }
}

// MARK: - Opt-in: the real TV (there is no live Keychain test, on purpose)

/// Always on. A first version of the identity store queried the identity class by label; the label is ignored there, so
/// its delete removed the person's own code-signing identities. The store now lives in a keychain file of its own.
/// These tests create real keychain FILES, only under a fresh temp directory, with an in-memory password source: they never
/// touch the login keychain or any search list.
@Suite("Identity store safety", .serialized) struct IdentityStoreSafetyTests {
    private static let scratch = URL(fileURLWithPath: "/private/tmp/claude-501/-Users-ahmedelgazar-Documents-The-Vault/828593e0-cfb9-4a8c-84b3-3da62d0c055e/scratchpad/kc-tests")

    private func tempFile() -> URL {
        let base = FileManager.default.fileExists(atPath: Self.scratch.path) ? Self.scratch : FileManager.default.temporaryDirectory
        return base.appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent("tv-remote.keychain-db")
    }

    private func code() throws -> String {
        let text = try String(contentsOf: fixtures.appendingPathComponent("source/TVToken.swift"), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line)
        }.joined(separator: "\n")
    }

    private func count(_ needle: String, in text: String) -> Int { text.components(separatedBy: needle).count - 1 }

    @Test func theKeychainStoreNeverNamesTheIdentityClass() throws {
        let code = try code()
        #expect(!code.contains("kSecClassIdentity"))
        #expect(count("SecItemDelete(", in: code) == 1, "the only item delete is the Samsung token's")
        #expect(!code.contains("SecKeychainSetSearchList") && !code.contains("SecKeychainSetDefault"), "our file is never put in a search list")
        let mark = try #require(code.range(of: "MARK: - The Android TV Remote client identity") ?? code.range(of: "protocol IdentityStore"))
        let section = String(code[mark.lowerBound...])
        #expect(count("SecItemCopyMatching(", in: section) == count("kSecMatchSearchList", in: section), "every query carries our file as its search list")
        #expect(!section.contains("SecItemDelete("))
        for line in section.split(separator: "\n") where line.contains("SecItemAdd(") { #expect(line.contains("kSecUseKeychain")) }
    }

    @Test func scopedStoreRoundTrip() throws {
        let file = tempFile(); let pw = MemoryTokenStore()
        let store = KeychainIdentityStore(fileURL: file, passwordStore: pw)
        defer { store.delete(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        #expect(store.load() == nil)
        let made = try #require(store.makeIdentity())
        let loaded = try #require(store.load())
        #expect(SecCertificateCopyData(loaded.certificate) as Data == SecCertificateCopyData(made.certificate) as Data)
        let identity = try #require(loaded.identity)
        #expect(sec_identity_create(identity) != nil)
        #expect(FileManager.default.fileExists(atPath: file.path))
        store.delete()
        #expect(store.load() == nil && !FileManager.default.fileExists(atPath: file.path))
    }

    @Test func twoFilesDoNotSeeEachOther() throws {
        let fa = tempFile(), fb = tempFile()
        let a = KeychainIdentityStore(fileURL: fa, passwordStore: MemoryTokenStore())
        let b = KeychainIdentityStore(fileURL: fb, passwordStore: MemoryTokenStore())
        defer { a.delete(); b.delete(); try? FileManager.default.removeItem(at: fa.deletingLastPathComponent()); try? FileManager.default.removeItem(at: fb.deletingLastPathComponent()) }
        let madeB = try #require({ _ = a.makeIdentity(); return b.makeIdentity() }())
        a.delete()
        #expect(a.load() == nil)
        let stillB = try #require(b.load())
        #expect(SecCertificateCopyData(stillB.certificate) as Data == SecCertificateCopyData(madeB.certificate) as Data)
    }

    /// Documents why the search list is the only filter: on the identity class a wrong label still matches. If Apple ever
    /// fixes that, this test says so. Scoped to our own temp file; the identity class is queried here, never in the app.
    @Test func theTrapIsReal() throws {
        let file = tempFile(); let pw = MemoryTokenStore()
        let store = KeychainIdentityStore(fileURL: file, passwordStore: pw)
        defer { store.delete(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        _ = try #require(store.makeIdentity())
        let password = try #require(pw.load(KeychainIdentityStore.passwordAccount)).token
        var kc: SecKeychain?
        #expect(SecKeychainOpen(file.path, &kc) == errSecSuccess)
        let k = try #require(kc)
        let bytes = Array(password.utf8)
        #expect(SecKeychainUnlock(k, UInt32(bytes.count), bytes, true) == errSecSuccess)
        let q: [String: Any] = [kSecClass as String: kSecClassIdentity, kSecAttrLabel as String: "zzz-no-such-label", kSecMatchSearchList as String: [k] as CFArray,
                                kSecReturnRef as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        #expect(status == errSecSuccess && ((out as? [Any])?.count ?? 0) == 1, "a wrong label still returns the identity; only the search list filters")
    }
}

/// `GOPRAY_LIVE_TESTS=1 GOPRAY_LIVE_GTV=<ip> GOPRAY_LIVE_GTV_CODE_FILE=<path>`: pairs with the real TV (the TV shows a code; the
/// person writes it into the file within two minutes), then, if `GOPRAY_LIVE_GTV_OFF=1`, turns the TV off. The code and the
/// identity are never printed.
@Suite("AndroidRemote live", .enabled(if: ProcessInfo.processInfo.environment["GOPRAY_LIVE_TESTS"] != nil
                                       && ProcessInfo.processInfo.environment["GOPRAY_LIVE_GTV"] != nil)) struct AndroidRemoteLiveTests {
    @Test func pairThenTurnOff() async throws {
        let env = ProcessInfo.processInfo.environment
        let device = TVDevice(name: "Live", kind: .googleTV, host: try #require(env["GOPRAY_LIVE_GTV"]))
        let r = AndroidRemote(store: KeychainIdentityStore())
        if env["GOPRAY_LIVE_GTV_CODE_FILE"] != nil {
            #expect(try await r.startPairing(device) == true)
            let path = try #require(env["GOPRAY_LIVE_GTV_CODE_FILE"])
            var code = ""
            for _ in 0..<120 {
                if let s = try? String(contentsOfFile: path, encoding: .utf8), s.trimmingCharacters(in: .whitespacesAndNewlines).count == 6 {
                    code = s.trimmingCharacters(in: .whitespacesAndNewlines); break
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            #expect(try await r.pair(device, code: code) == .paired)
        }
        if env["GOPRAY_LIVE_GTV_OFF"] == "1" {
            #expect(try await r.turnOff(device) == true)
        }
    }
}
