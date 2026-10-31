// AndroidRemote.swift — the TV's own remote protocol (Android TV Remote v2), used for one thing: turning a TV back off
// that was off before the Athan (Google TV Plan §4). Owner: lane D.
//
// What lives here, top to bottom: a tiny table-driven protobuf codec and the two message tables (the same field numbers
// the Windows port reads from tv/vectors/*.json); the pairing-secret hash; the Mac's client identity (a self-signed RSA
// certificate built as DER); one NWConnection channel; `AndroidRemote` (pairing on 6467, power-off on 6466).
//
// Safety, all enforced by scripts/guard.sh (4c/4d/4e/4f): this is the only file with the TV-remote TLS exception, the
// only one that builds keys and certificates, and the only one that names a remote key. `RemoteKey` has one case
// (power) and `RemoteDirection` one (short). There is no "send key" function. Nothing here logs anything, and the
// pairing code is only ever a function argument: not stored, not interpolated, not written.

import CryptoKit
import Foundation
import Network
import Security

// MARK: - The one key, the one direction

/// The only key this app can press. Do not add a case: guard 4f fails, on purpose.
enum RemoteKey: Int {
    case power = 26
}

/// The only way to press it. A long press toggles the TV off and straight back on, so it is not here.
enum RemoteDirection: Int {
    case short = 3
}

enum RemoteError: Error, Equatable {
    /// No client identity is stored: the Mac was never paired.
    case noIdentity
    /// The identity could not be made or saved.
    case identity
    /// The TV spoke something we could not read, or too much of it.
    case malformed
}

// MARK: - Protobuf: a table, not a class per message

indirect enum PBKind: Sendable {
    case uint, bool, string, bytes
    case message([String: PBField])
}

struct PBField: Sendable {
    var number: Int
    var kind: PBKind
    var repeated = false
}

typealias PBSchema = [String: PBField]

enum PB {
    /// Encodes `value` by `schema`, fields in number order. Nil for a key the schema does not know or a wrong type.
    static func encode(_ value: [String: Any], schema: PBSchema, depth: Int = 0) -> Data? {
        guard depth <= 4 else { return nil }
        for key in value.keys where schema[key] == nil { return nil }
        var out = [UInt8]()
        for (name, field) in schema.sorted(by: { $0.value.number < $1.value.number }) {
            guard let v = value[name] else { continue }
            let items: [Any]
            if field.repeated { guard let arr = v as? [Any] else { return nil }; items = arr } else { items = [v] }
            for item in items {
                guard let bytes = encodeOne(item, field: field, depth: depth) else { return nil }
                out += bytes
            }
        }
        return Data(out)
    }

    private static func encodeOne(_ item: Any, field: PBField, depth: Int) -> [UInt8]? {
        func tag(_ wire: UInt64) -> [UInt8] { varint(UInt64(field.number) << 3 | wire) }
        switch field.kind {
        case .uint:
            guard let n = asUInt(item) else { return nil }
            return tag(0) + varint(n)
        case .bool:
            guard let b = item as? Bool else { return nil }
            return tag(0) + varint(b ? 1 : 0)
        case .string:
            guard let s = item as? String else { return nil }
            let d = Array(s.utf8)
            return tag(2) + varint(UInt64(d.count)) + d
        case .bytes:
            guard let d = item as? Data else { return nil }
            return tag(2) + varint(UInt64(d.count)) + Array(d)
        case .message(let sub):
            guard let m = item as? [String: Any], let d = encode(m, schema: sub, depth: depth + 1) else { return nil }
            return tag(2) + varint(UInt64(d.count)) + Array(d)
        }
    }

    private static func asUInt(_ v: Any) -> UInt64? {
        if v is Bool { return nil }
        if let n = v as? UInt64 { return n }
        if let n = v as? Int, n >= 0 { return UInt64(n) }
        return nil
    }

    /// Decodes by `schema`. Unknown fields are skipped; nil for anything truncated, mistyped or nested too deep.
    /// A repeated field is always an array; an absent field is absent (a proto3 default is not on the wire).
    static func decode(_ data: Data, schema: PBSchema, depth: Int = 0) -> [String: Any]? {
        guard depth <= 4 else { return nil }
        let b = [UInt8](data)
        var byNumber: [Int: (String, PBField)] = [:]
        for (name, f) in schema { byNumber[f.number] = (name, f) }
        var pos = 0
        var out: [String: Any] = [:]
        while pos < b.count {
            guard let key = readVarint(b, &pos) else { return nil }
            let number = Int(truncatingIfNeeded: key >> 3), wire = key & 7
            var value: Any?
            switch wire {
            case 0:
                guard let n = readVarint(b, &pos) else { return nil }
                if let (_, f) = byNumber[number] {
                    switch f.kind {
                    case .uint: value = n
                    case .bool: value = n != 0
                    default: return nil
                    }
                }
            case 2:
                guard let len = readVarint(b, &pos), len <= UInt64(b.count - pos) else { return nil }
                let body = Array(b[pos..<(pos + Int(len))]); pos += Int(len)
                if let (_, f) = byNumber[number] {
                    switch f.kind {
                    case .string: guard let s = String(bytes: body, encoding: .utf8) else { return nil }; value = s
                    case .bytes: value = Data(body)
                    case .message(let sub): guard let m = decode(Data(body), schema: sub, depth: depth + 1) else { return nil }; value = m
                    default: return nil
                    }
                }
            case 1:
                guard pos + 8 <= b.count else { return nil }
                pos += 8
                if byNumber[number] != nil { return nil }
            case 5:
                guard pos + 4 <= b.count else { return nil }
                pos += 4
                if byNumber[number] != nil { return nil }
            default:
                return nil
            }
            if let value, let (name, f) = byNumber[number] {
                if f.repeated { out[name] = ((out[name] as? [Any]) ?? []) + [value] } else { out[name] = value }
            }
        }
        return out
    }

    static func varint(_ value: UInt64) -> [UInt8] {
        var v = value
        var out = [UInt8]()
        while v >= 0x80 { out.append(UInt8(v & 0x7f) | 0x80); v >>= 7 }
        out.append(UInt8(v))
        return out
    }

    static func readVarint(_ b: [UInt8], _ pos: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var i = pos
        while i < b.count, shift < 64 {
            let byte = b[i]; i += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { pos = i; return result }
            shift += 7
        }
        return nil
    }
}

/// One message on the wire = varint length + protobuf (the Python lib's base.py). A frame over 64 KiB is refused.
enum RemoteFrame {
    static let maxLength = 65_536

    static func wrap(_ message: Data) -> Data { Data(PB.varint(UInt64(message.count))) + message }

    /// Removes and returns one whole message from the front of `buffer`; nil = not all there yet.
    static func take(_ buffer: inout Data) throws -> Data? {
        let b = [UInt8](buffer)
        var pos = 0
        var length: UInt64 = 0
        var shift: UInt64 = 0
        var done = false
        while pos < b.count, pos < 3 {
            let byte = b[pos]; pos += 1
            length |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { done = true; break }
            shift += 7
        }
        if !done {
            if b.count >= 3 { throw RemoteError.malformed }   // a length longer than 3 bytes is over any allowed size
            return nil
        }
        guard length <= UInt64(maxLength) else { throw RemoteError.malformed }
        guard b.count - pos >= Int(length) else { return nil }
        let body = Data(b[pos..<(pos + Int(length))])
        buffer = Data(b[(pos + Int(length))...])
        return body
    }
}

// MARK: - The two message tables (polo.proto for pairing, remotemessage.proto for control)

enum RemoteWire {
    private static func f(_ n: Int, _ k: PBKind, repeated: Bool = false) -> PBField { PBField(number: n, kind: k, repeated: repeated) }
    private static let encoding: PBSchema = ["type": f(1, .uint), "symbol_length": f(2, .uint)]

    /// OuterMessage. Encoding type HEXADECIMAL = 3, role INPUT = 1, status 200 OK, 402 bad secret.
    static let polo: PBSchema = [
        "protocol_version": f(1, .uint),
        "status": f(2, .uint),
        "pairing_request": f(10, .message(["service_name": f(1, .string), "client_name": f(2, .string)])),
        "pairing_request_ack": f(11, .message(["server_name": f(1, .string)])),
        "options": f(20, .message(["input_encodings": f(1, .message(encoding), repeated: true),
                                   "output_encodings": f(2, .message(encoding), repeated: true),
                                   "preferred_role": f(3, .uint)])),
        "configuration": f(30, .message(["encoding": f(1, .message(encoding)), "client_role": f(2, .uint)])),
        "configuration_ack": f(31, .message([:])),
        "secret": f(40, .message(["secret": f(1, .bytes)])),
        "secret_ack": f(41, .message(["secret": f(1, .bytes)])),
    ]

    /// RemoteMessage.
    static let remote: PBSchema = [
        "remote_configure": f(1, .message(["code1": f(1, .uint),
                                           "device_info": f(2, .message(["model": f(1, .string), "vendor": f(2, .string),
                                                                         "unknown1": f(3, .uint), "unknown2": f(4, .string),
                                                                         "package_name": f(5, .string), "app_version": f(6, .string)]))])),
        "remote_set_active": f(2, .message(["active": f(1, .uint)])),
        "remote_ping_request": f(8, .message(["val1": f(1, .uint), "val2": f(2, .uint)])),
        "remote_ping_response": f(9, .message(["val1": f(1, .uint)])),
        "remote_key_inject": f(10, .message(["key_code": f(1, .uint), "direction": f(2, .uint)])),
        "remote_start": f(40, .message(["started": f(1, .bool)])),
    ]

    private static var ok: [String: Any] { ["protocol_version": 2, "status": 200] }

    private static func polo(_ extra: [String: Any]) -> Data {
        RemoteFrame.wrap(PB.encode(ok.merging(extra) { a, _ in a }, schema: polo) ?? Data())
    }

    static func pairingRequest() -> Data {
        polo(["pairing_request": ["service_name": "atvremote", "client_name": "Go Pray"]])
    }
    static func pairingOptions() -> Data {
        polo(["options": ["input_encodings": [["type": 3, "symbol_length": 6]], "preferred_role": 1]])
    }
    static func pairingConfiguration() -> Data {
        polo(["configuration": ["encoding": ["type": 3, "symbol_length": 6], "client_role": 1]])
    }
    static func pairingSecret(_ secret: Data) -> Data { polo(["secret": ["secret": secret]]) }

    static func configureReply() -> Data {
        RemoteFrame.wrap(PB.encode(["remote_configure": ["code1": 35,
            "device_info": ["unknown1": 1, "unknown2": "1", "package_name": "atvremote", "app_version": "1.0.0"]]], schema: remote) ?? Data())
    }
    static func setActiveReply() -> Data { RemoteFrame.wrap(PB.encode(["remote_set_active": ["active": 35]], schema: remote) ?? Data()) }
    static func pingResponse(_ val1: UInt64) -> Data { RemoteFrame.wrap(PB.encode(["remote_ping_response": ["val1": val1]], schema: remote) ?? Data()) }

    /// The one key frame. The only place a `remote_key_inject` is built.
    static func keyFrame(_ key: RemoteKey, _ direction: RemoteDirection) -> Data {
        RemoteFrame.wrap(PB.encode(["remote_key_inject": ["key_code": key.rawValue, "direction": direction.rawValue]], schema: remote) ?? Data())
    }
}

// MARK: - The pairing secret

enum RemotePairing {
    /// SHA256( clientN ‖ clientE ‖ serverN ‖ serverE ‖ nonce ), each number big-endian with no leading zero and an even
    /// number of hex digits (65537 is 01 00 01), `nonce` = the last 4 hex characters of the code as 2 bytes.
    static func digest(clientN: Data, clientE: Data, serverN: Data, serverE: Data, nonce: Data) -> Data {
        func norm(_ d: Data) -> [UInt8] { Array([UInt8](d).drop(while: { $0 == 0 })) }
        var h = SHA256()
        for part in [norm(clientN), norm(clientE), norm(serverN), norm(serverE), [UInt8](nonce)] { h.update(data: part) }
        return Data(h.finalize())
    }

    /// The 32 bytes to send, or nil when `code` is not 6 hex characters or its first 2 do not equal the digest's first
    /// byte (a wrong code: nothing is sent).
    static func secret(clientN: Data, clientE: Data, serverN: Data, serverE: Data, code: String) -> Data? {
        guard code.utf8.count == 6, code.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102) }),
              let first = UInt8(code.prefix(2), radix: 16),
              let n1 = UInt8(code.dropFirst(2).prefix(2), radix: 16), let n2 = UInt8(code.dropFirst(4), radix: 16) else { return nil }
        let d = digest(clientN: clientN, clientE: clientE, serverN: serverN, serverE: serverE, nonce: Data([n1, n2]))
        return d.first == first ? d : nil
    }
}

// MARK: - The client identity: RSA-2048, self-signed X.509 built by hand

enum DER {
    static func length(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        var bytes = [UInt8](); var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xff), at: 0); v >>= 8 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }
    static func tlv(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] { [tag] + length(body.count) + body }
    static func sequence(_ parts: [UInt8]...) -> [UInt8] { tlv(0x30, parts.flatMap { $0 }) }
    static func unsignedInteger(_ bytes: [UInt8]) -> [UInt8] {
        var b = Array(bytes.drop(while: { $0 == 0 }))
        if b.isEmpty { b = [0] }
        if b[0] & 0x80 != 0 { b.insert(0, at: 0) }
        return tlv(0x02, b)
    }

    /// One element at `pos`: its tag and body. Nil for anything that does not fit.
    static func read(_ b: [UInt8], _ pos: inout Int) -> (tag: UInt8, body: [UInt8])? {
        guard pos + 2 <= b.count else { return nil }
        let tag = b[pos]; var len = Int(b[pos + 1]); pos += 2
        if len & 0x80 != 0 {
            let n = len & 0x7f
            guard n >= 1, n <= 3, pos + n <= b.count else { return nil }
            len = 0
            for _ in 0..<n { len = len << 8 | Int(b[pos]); pos += 1 }
        }
        guard pos + len <= b.count else { return nil }
        let body = Array(b[pos..<(pos + len)]); pos += len
        return (tag, body)
    }
}

enum RemoteIdentity {
    private static let oidSha256WithRSA: [UInt8] = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0b]
    private static let oidRSA: [UInt8] = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01]
    private static let oidCommonName: [UInt8] = [0x55, 0x04, 0x03]
    private static let oidBasicConstraints: [UInt8] = [0x55, 0x1d, 0x13]
    private static let oidSubjectAltName: [UInt8] = [0x55, 0x1d, 0x11]
    static let commonName = "Go Pray"

    private static func algorithm(_ oid: [UInt8]) -> [UInt8] { DER.sequence(DER.tlv(0x06, oid), [0x05, 0x00]) }

    private static func time(_ date: Date) -> [UInt8] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func two(_ n: Int?) -> String { String(format: "%02d", n ?? 0) }
        let y = c.year ?? 1970
        let body = (y < 2050 ? two(y % 100) : String(format: "%04d", y)) + two(c.month) + two(c.day) + two(c.hour) + two(c.minute) + two(c.second) + "Z"
        return DER.tlv(y < 2050 ? 0x17 : 0x18, Array(body.utf8))
    }

    /// The certificate: v3, the given serial, sha256WithRSA, issuer = subject = CN "Go Pray", BasicConstraints CA (like the
    /// Python library's certificate, which TVs are known to accept) and a SAN. `sign` signs the TBS with the private key.
    static func certificateDER(publicKeyPKCS1: Data, serial: [UInt8], notBefore: Date, notAfter: Date,
                               sign: ([UInt8]) -> [UInt8]?) -> Data? {
        let name = DER.sequence(DER.tlv(0x31, DER.sequence(DER.tlv(0x06, oidCommonName), DER.tlv(0x0c, Array(commonName.utf8)))))
        let spki = DER.sequence(algorithm(oidRSA), DER.tlv(0x03, [0x00] + [UInt8](publicKeyPKCS1)))
        let basic = DER.sequence(DER.tlv(0x06, oidBasicConstraints),
                                 DER.tlv(0x04, DER.sequence([0x01, 0x01, 0xff], DER.unsignedInteger([0]))))
        let san = DER.sequence(DER.tlv(0x06, oidSubjectAltName), DER.tlv(0x04, DER.sequence(DER.tlv(0x82, Array("gopray".utf8)))))
        let tbs = DER.sequence(
            DER.tlv(0xa0, DER.unsignedInteger([2])),
            DER.unsignedInteger(serial),
            algorithm(oidSha256WithRSA),
            name,
            DER.sequence(time(notBefore), time(notAfter)),
            name,
            spki,
            DER.tlv(0xa3, DER.sequence(basic, san)))
        guard let sig = sign(tbs) else { return nil }
        return Data(DER.sequence(tbs, algorithm(oidSha256WithRSA), DER.tlv(0x03, [0x00] + sig)))
    }

    /// A fresh key and certificate (valid from yesterday, for 10 years).
    static func generate(now: Date = Date(), keyAttributes: CFDictionary = IdentityStoreRules.keyAttributes) -> (key: SecKey, certificate: SecCertificate)? {
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(keyAttributes, &error),
              let pub = SecKeyCopyPublicKey(key),
              let pkcs1 = SecKeyCopyExternalRepresentation(pub, &error) as Data? else { return nil }
        var serial = (0..<8).map { _ in UInt8.random(in: 0...255) }
        serial[0] = serial[0] & 0x7f | 0x01
        let cal = Calendar(identifier: .gregorian)
        guard let from = cal.date(byAdding: .day, value: -1, to: now), let to = cal.date(byAdding: .year, value: 10, to: now),
              let der = certificateDER(publicKeyPKCS1: pkcs1, serial: serial, notBefore: from, notAfter: to, sign: { tbs in
                  var e: Unmanaged<CFError>?
                  guard let sig = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(tbs) as CFData, &e) else { return nil }
                  return [UInt8](sig as Data)
              }),
              let cert = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        return (key, cert)
    }

    /// (modulus, exponent) from a PKCS#1 RSAPublicKey (SEQUENCE of two INTEGERs), no leading zeros.
    static func numbers(pkcs1: Data) -> (n: Data, e: Data)? {
        let b = [UInt8](pkcs1)
        var pos = 0
        guard let outer = DER.read(b, &pos), outer.tag == 0x30, pos == b.count else { return nil }
        var inner = 0
        guard let n = DER.read(outer.body, &inner), n.tag == 0x02, let e = DER.read(outer.body, &inner), e.tag == 0x02,
              inner == outer.body.count else { return nil }
        return (Data(n.body.drop(while: { $0 == 0 })), Data(e.body.drop(while: { $0 == 0 })))
    }

    /// (modulus, exponent) of the RSA public key inside a certificate (DER).
    static func numbers(certificateDER der: Data) -> (n: Data, e: Data)? {
        guard let cert = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        return numbers(certificate: cert)
    }

    static func numbers(certificate: SecCertificate) -> (n: Data, e: Data)? {
        var error: Unmanaged<CFError>?
        guard let key = SecCertificateCopyKey(certificate),
              let pkcs1 = SecKeyCopyExternalRepresentation(key, &error) as Data? else { return nil }
        return numbers(pkcs1: pkcs1)
    }
}

// MARK: - One TLS (or, in tests, plain TCP) connection speaking length-prefixed protobuf

final class RemoteChannel: @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "gopray.remote.channel")
    private let lock = NSLock()
    private var buffer = Data()
    private var generation = 0
    private var ended: Error?
    private var waiter: CheckedContinuation<Void, Never>?
    private var serverCertificate: Data?

    /// `tls == false` is for tests only (a plain-TCP fake). With TLS the server certificate is accepted for this one
    /// host and port and handed back through `peerCertificateDER` (the pairing hash needs its public key).
    init(host: String, port: UInt16, tls: Bool, identity: SecIdentity?) {
        self.host = host
        self.port = port
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any)
        var parameters = NWParameters.tcp
        let me = WeakChannel()
        if tls {
            let options = NWProtocolTLS.Options()
            if let identity, let sid = sec_identity_create(identity) {
                sec_protocol_options_set_local_identity(options.securityProtocolOptions, sid)
            }
            sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
            sec_protocol_options_set_verify_block(options.securityProtocolOptions, { metadata, _, complete in
                // The TV's certificate is self-signed per device, so there is nothing to chain to. What scopes this
                // exception: the block is built for one connection, to the one Settings address and the one port.
                guard let channel = me.channel, channel.pathMatchesTarget() else { complete(false); return }
                var leaf: Data?
                sec_protocol_metadata_access_peer_certificate_chain(metadata) { sc in
                    if leaf == nil { leaf = SecCertificateCopyData(sec_certificate_copy_ref(sc).takeRetainedValue()) as Data }
                }
                channel.lock.withLock { channel.serverCertificate = leaf }
                complete(true)
            }, queue)
            parameters = NWParameters(tls: options, tcp: NWProtocolTCP.Options())
        }
        connection = NWConnection(to: endpoint, using: parameters)
        me.channel = self
    }

    private final class WeakChannel: @unchecked Sendable { weak var channel: RemoteChannel? }

    /// Whether the connection is going where it was told to. An unknown path is not another host: the endpoint is a fixed
    /// IPv4 literal, so there is no name to be redirected to.
    private func pathMatchesTarget() -> Bool {
        guard let ep = connection.currentPath?.remoteEndpoint, case .hostPort(let h, let p) = ep else { return true }
        let shown = "\(h)"
        return p.rawValue == port && (shown.split(separator: "%").first.map(String.init) ?? shown) == host
    }

    var peerCertificateDER: Data? { lock.withLock { serverCertificate } }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<Void, Error>?
        init(_ c: CheckedContinuation<Void, Error>) { cont = c }
        func finish(_ r: Result<Void, Error>) {
            let c = lock.withLock { () -> CheckedContinuation<Void, Error>? in let c = cont; cont = nil; return c }
            c?.resume(with: r)
        }
    }

    static func map(_ error: NWError) -> Error {
        switch error {
        case .dns(let code) where code == -65570: return TVError.localNetworkDenied
        case .posix(let code) where code.rawValue == 65: return TVError.localNetworkDenied
        default: return TVError.unreachable
        }
    }

    func open(timeout: TimeInterval) async throws {
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let once = Once(cont)
                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready: once.finish(.success(()))
                    case .waiting(let e), .failed(let e): once.finish(.failure(Self.map(e)))
                    case .cancelled: once.finish(.failure(TVError.unreachable)); self?.end(TVError.unreachable)
                    default: break
                    }
                    if case .failed = state { self?.end(TVError.unreachable) }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) { once.finish(.failure(TVError.unreachable)) }
            }
        } catch {
            close()
            throw error
        }
        receiveLoop()
    }

    /// Bytes waiting to be read (tests: proves a flood stops being read once the cap is hit).
    var bufferedByteCount: Int { lock.withLock { buffer.count } }
    /// How many receive callbacks have run (tests: none after the cap).
    var receiveCount: Int { lock.withLock { receives } }
    private var receives = 0
    static let bufferCap = 4 * RemoteFrame.maxLength

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            let overCap = self.lock.withLock { () -> Bool in
                self.receives += 1
                if self.ended != nil { return true }
                if let data, !data.isEmpty { self.buffer.append(data); self.generation += 1 }
                return self.buffer.count > Self.bufferCap
            }
            if overCap {
                // The peer is sending faster than anything is read: stop reading, drop the connection, schedule no more.
                self.end(RemoteError.malformed)
                self.connection.cancel()
                return
            }
            if let error { self.end(Self.map(error)); return }
            if isComplete { self.end(TVError.unreachable); return }
            self.wake()
            self.receiveLoop()
        }
    }

    private func end(_ error: Error) {
        lock.withLock { if ended == nil { ended = error } }
        wake()
    }

    private func wake() {
        let w = lock.withLock { () -> CheckedContinuation<Void, Never>? in let w = waiter; waiter = nil; return w }
        w?.resume()
    }

    func send(_ frame: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: Self.map(error)) } else { cont.resume() }
            })
        }
    }

    /// The next whole message, nil if none arrived within `timeout`. Throws when the connection is gone and nothing is left.
    func next(timeout: TimeInterval) async throws -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let (frame, err, seen): (Data?, Error?, Int) = try lock.withLock {
                if let frame = try RemoteFrame.take(&buffer) { return (frame, nil, generation) }
                return (nil, ended, generation)
            }
            if let frame { return frame }
            if let err { throw err }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock { () -> Bool in
                    if generation != seen || ended != nil { return true }
                    waiter = cont
                    return false
                }
                if resumeNow { cont.resume(); return }
                queue.asyncAfter(deadline: .now() + remaining) { [weak self] in self?.wake() }
            }
        }
    }

    func close() {
        connection.stateUpdateHandler = nil
        connection.cancel()
        end(TVError.unreachable)
    }
}

// MARK: - AndroidRemote

final class AndroidRemote: TVPowering, @unchecked Sendable {
    /// A short power press sent at once after connecting is ignored (proved on the Sony); one second after it works.
    static let keyDelay: TimeInterval = 1.0

    private let store: IdentityStore
    private let tls: Bool
    private let pairingPort: UInt16, controlPort: UInt16
    private let stepTimeout: TimeInterval
    private let hostAllowed: @Sendable (String) -> Bool
    private let peerOverride: Data?

    private struct Held { var channel: RemoteChannel; var serverCertificate: Data; var token: Int }
    private let lock = NSLock()
    private var held: [String: Held] = [:]
    private var heldCounter = 0

    /// Everything but `store` is for tests (a plain-TCP fake on loopback, short timeouts).
    init(store: IdentityStore = KeychainIdentityStore(), tls: Bool = true, pairingPort: UInt16 = 6467, controlPort: UInt16 = 6466,
         stepTimeout: TimeInterval = 10, hostAllowed: @escaping @Sendable (String) -> Bool = TVHost.isAllowed,
         peerCertificateOverride: Data? = nil) {
        self.store = store; self.tls = tls; self.pairingPort = pairingPort; self.controlPort = controlPort
        self.stepTimeout = stepTimeout; self.hostAllowed = hostAllowed; self.peerOverride = peerCertificateOverride
    }

    func isPaired(_ tv: TVDevice) -> Bool { tv.remotePaired }

    /// The Mac forgets any half-done pairing for this TV. The identity is per Mac, not per TV, so it stays.
    func forget(_ tv: TVDevice) { drop(tv.id) }

    // MARK: pairing (Settings only, port 6467)

    /// Steps 1-3: the TV is asked to show its 6-character code. True = the code is on the TV's screen and the session is
    /// held (up to 120 s) for `pair(_:code:)`. False = the TV did not follow the protocol.
    func startPairing(_ tv: TVDevice) async throws -> Bool {
        guard hostAllowed(tv.host) else { throw TVError.refusedHost }
        let ident = try loadOrCreateIdentity()
        drop(tv.id)
        let ch = RemoteChannel(host: tv.host, port: pairingPort, tls: tls, identity: ident.identity)
        try await ch.open(timeout: 5)
        do {
            try await ch.send(RemoteWire.pairingRequest())
            guard try await expectPolo(ch, "pairing_request_ack") != nil else { ch.close(); return false }
            try await ch.send(RemoteWire.pairingOptions())
            guard try await expectPolo(ch, "options") != nil else { ch.close(); return false }
            try await ch.send(RemoteWire.pairingConfiguration())
            guard try await expectPolo(ch, "configuration_ack") != nil else { ch.close(); return false }
        } catch {
            ch.close()
            if error is TVError { throw error }
            return false
        }
        guard let cert = peerOverride ?? ch.peerCertificateDER else { ch.close(); return false }
        let token = lock.withLock { () -> Int in heldCounter += 1; held[tv.id] = Held(channel: ch, serverCertificate: cert, token: heldCounter); return heldCounter }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            self?.expire(tv.id, token: token)
        }
        return true
    }

    /// Steps 4-5: hash the code with both certificates, send it once, read the TV's answer. `.denied` = a wrong code (the
    /// first two characters did not match, and nothing was sent) or the TV said 402. `.unsupported` = no held session, silence
    /// or anything unexpected. The code is used here and nowhere else.
    func pair(_ tv: TVDevice, code: String) async throws -> TVPairResult {
        guard hostAllowed(tv.host) else { throw TVError.refusedHost }
        guard let session = lock.withLock({ held.removeValue(forKey: tv.id) }) else { return .unsupported }
        guard let ours = store.load(), let mine = RemoteIdentity.numbers(certificate: ours.certificate),
              let theirs = RemoteIdentity.numbers(certificateDER: session.serverCertificate) else {
            session.channel.close()
            return .unsupported
        }
        guard let secret = RemotePairing.secret(clientN: mine.n, clientE: mine.e, serverN: theirs.n, serverE: theirs.e, code: code) else {
            // A typo: nothing is sent, and the session stays so the person can retype within the TV's own window.
            lock.withLock { held[tv.id] = session }
            return .denied
        }
        defer { session.channel.close() }
        do {
            try await session.channel.send(RemoteWire.pairingSecret(secret))
            guard let reply = try await nextPolo(session.channel) else { return .unsupported }
            if reply["secret_ack"] != nil, (reply["status"] as? UInt64 ?? 200) == 200 { return .paired }
            if (reply["status"] as? UInt64) == 402 { return .denied }
            return .unsupported
        } catch let e as TVError where e == .localNetworkDenied {
            throw e
        } catch {
            return .unsupported
        }
    }

    private func drop(_ id: String) {
        lock.withLock { held.removeValue(forKey: id) }?.channel.close()
    }

    private func expire(_ id: String, token: Int) {
        let h = lock.withLock { () -> Held? in
            guard let h = held[id], h.token == token else { return nil }
            return held.removeValue(forKey: id)
        }
        h?.channel.close()
    }

    /// The next pairing message, nil on silence. A status other than 200 comes back as the message (the caller reads it).
    private func nextPolo(_ ch: RemoteChannel) async throws -> [String: Any]? {
        guard let frame = try await ch.next(timeout: stepTimeout) else { return nil }
        guard let msg = PB.decode(frame, schema: RemoteWire.polo) else { throw RemoteError.malformed }
        return msg
    }

    /// The next pairing message must be `field` with status 200. Nil on silence or anything else.
    private func expectPolo(_ ch: RemoteChannel, _ field: String) async throws -> [String: Any]? {
        guard let msg = try await nextPolo(ch), msg[field] != nil, (msg["status"] as? UInt64 ?? 200) == 200 else { return nil }
        return msg
    }

    private func loadOrCreateIdentity() throws -> StoredIdentity {
        if let s = store.load() { return s }
        guard let s = store.makeIdentity() else { throw RemoteError.identity }
        return s
    }

    // MARK: power-off (port 6466)

    private final class Control: @unchecked Sendable {
        private let lock = NSLock()
        private var _isOn: Bool?
        var isOn: Bool? { get { lock.withLock { _isOn } } set { lock.withLock { _isOn = newValue } } }
    }

    /// Connect, answer the TV's setup, wait `keyDelay`, and if the TV says it is on press power once. True = the TV then
    /// reported itself off. Never a second press, never another key. Throws (nothing sent) when the Mac has no identity.
    func turnOff(_ tv: TVDevice) async throws -> Bool {
        guard hostAllowed(tv.host) else { throw TVError.refusedHost }
        guard let ident = store.load() else { throw RemoteError.noIdentity }
        if tls, ident.identity == nil { throw RemoteError.noIdentity }
        let ch = RemoteChannel(host: tv.host, port: controlPort, tls: tls, identity: ident.identity)
        try await ch.open(timeout: 5)
        defer { ch.close() }
        let state = Control()
        let opened = Date()

        // The TV sends its setup at once; we answer it, and wait out the delay before any key.
        try await pump(ch, until: opened.addingTimeInterval(Self.keyDelay), state: state, stop: { false })
        if state.isOn == nil {
            try await pump(ch, until: opened.addingTimeInterval(Self.keyDelay + 4), state: state, stop: { state.isOn != nil })
        }
        guard state.isOn == true else { return false }

        try await ch.send(RemoteWire.keyFrame(.power, .short))
        do {
            try await pump(ch, until: Date().addingTimeInterval(3), state: state, stop: { state.isOn == false })
        } catch {
            return false   // the TV closed on us: it may well be off, but it did not say so
        }
        return state.isOn == false
    }

    private func pump(_ ch: RemoteChannel, until deadline: Date, state: Control, stop: () -> Bool) async throws {
        while !stop() {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { return }
            guard let frame = try await ch.next(timeout: left) else { return }
            guard let msg = PB.decode(frame, schema: RemoteWire.remote) else { continue }
            if msg["remote_configure"] != nil {
                try await ch.send(RemoteWire.configureReply())
            } else if msg["remote_set_active"] != nil {
                try await ch.send(RemoteWire.setActiveReply())
            } else if let ping = msg["remote_ping_request"] as? [String: Any] {
                try await ch.send(RemoteWire.pingResponse(ping["val1"] as? UInt64 ?? 0))
            } else if let start = msg["remote_start"] as? [String: Any] {
                state.isOn = start["started"] as? Bool ?? false
            }
        }
    }
}
