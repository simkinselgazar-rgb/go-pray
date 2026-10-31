// FakeRemoteServer.swift — a fake Android TV on 127.0.0.1 for the AndroidRemote tests. Plain TCP (the driver is built with
// `tls: false` in tests only), varint-framed protobuf, scripted by knobs. It records every message it decodes, with the
// time it arrived, so the tests see the real bytes in order. Test target only.

import Foundation
import Network
import Security
@testable import GoPray

final class MemoryIdentityStore: IdentityStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: StoredIdentity?
    private(set) var saves = 0
    init(_ initial: StoredIdentity? = nil) { stored = initial }
    func load() -> StoredIdentity? { lock.withLock { stored } }
    func makeIdentity() -> StoredIdentity? {
        guard let made = RemoteIdentity.generate() else { return nil }
        let s = StoredIdentity(key: made.key, certificate: made.certificate, identity: nil)
        lock.withLock { stored = s; saves += 1 }
        return s
    }
    func delete() { lock.withLock { stored = nil } }

    /// One real key + certificate for the whole test run (making an RSA-2048 key takes a moment).
    static let sharedIdentity: StoredIdentity = {
        let made = RemoteIdentity.generate()!
        return StoredIdentity(key: made.key, certificate: made.certificate, identity: nil)
    }()
    static func withIdentity() -> MemoryIdentityStore { MemoryIdentityStore(sharedIdentity) }
}

final class FakeRemoteServer: @unchecked Sendable {
    enum Family { case polo, remote }
    struct Received { var at: Date; var fields: [String: Any] }

    /// What the pairing side answers to the secret.
    enum SecretReply { case ack, badSecret, silence }
    /// How far through the pairing handshake the TV gets before going quiet.
    enum PoloStop { case never, afterRequest, afterOptions }

    private let family: Family
    private let queue = DispatchQueue(label: "fake.remote")
    private let lock = NSLock()
    private var listener: NWListener?
    private var conns: [NWConnection] = []
    private var buffers: [ObjectIdentifier: Data] = [:]
    private var _received: [Received] = []
    private var _connectedAt: [Date] = []
    private(set) var port: UInt16 = 0

    // knobs
    private var _secretReply: SecretReply = .ack
    private var _poloStop: PoloStop = .never
    private var _isOn = true
    private var _sendStart = true
    private var _offOnKey = true
    var secretReply: SecretReply { get { lock.withLock { _secretReply } } set { lock.withLock { _secretReply = newValue } } }
    var poloStop: PoloStop { get { lock.withLock { _poloStop } } set { lock.withLock { _poloStop = newValue } } }
    /// Remote side: what `remote_start` says right after the setup messages.
    var isOn: Bool { get { lock.withLock { _isOn } } set { lock.withLock { _isOn = newValue } } }
    /// Remote side: false = never send `remote_start` at all.
    var sendStart: Bool { get { lock.withLock { _sendStart } } set { lock.withLock { _sendStart = newValue } } }
    /// Remote side: answer a power key with `remote_start{false}`.
    var offOnKey: Bool { get { lock.withLock { _offOnKey } } set { lock.withLock { _offOnKey = newValue } } }

    var received: [Received] { lock.withLock { _received } }
    var connectedAt: [Date] { lock.withLock { _connectedAt } }
    func fields(named name: String) -> [Received] { received.filter { $0.fields[name] != nil } }

    init(_ family: Family) throws {
        self.family = family
        let l = try NWListener(using: .tcp, on: .any)
        listener = l
        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success, let p = l.port?.rawValue else { throw NSError(domain: "FakeRemoteServer", code: 1) }
        port = p
    }

    /// Sends `count` junk bytes to every connection, in chunks.
    func flood(_ count: Int) {
        let chunk = Data(repeating: 0xFF, count: 16_384)
        for c in lock.withLock({ conns }) {
            var left = count
            while left > 0 { let n = min(left, chunk.count); c.send(content: chunk.prefix(n), completion: .contentProcessed { _ in }); left -= n }
        }
    }

    func stop() {
        listener?.cancel()
        lock.withLock { conns }.forEach { $0.cancel() }
    }

    private var schema: PBSchema { family == .polo ? RemoteWire.polo : RemoteWire.remote }

    private func accept(_ c: NWConnection) {
        lock.withLock { conns.append(c); _connectedAt.append(Date()) }
        c.start(queue: queue)
        if family == .remote { sendSetup(on: c) }
        read(c)
    }

    private func sendSetup(on c: NWConnection) {
        send(["remote_configure": ["code1": 611, "device_info": ["model": "BRAVIA", "vendor": "Sony"]]], on: c)
        send(["remote_set_active": ["active": 611]], on: c)
        send(["remote_ping_request": ["val1": 7]], on: c)
        if sendStart { send(["remote_start": ["started": isOn]], on: c) }
    }

    func send(_ fields: [String: Any], on c: NWConnection) {
        var f = fields
        if family == .polo, f["protocol_version"] == nil { f["protocol_version"] = 2; if f["status"] == nil { f["status"] = 200 } }
        guard let body = PB.encode(f, schema: schema) else { return }
        c.send(content: RemoteFrame.wrap(body), completion: .contentProcessed { _ in })
    }

    private func read(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.ingest(data, from: c) }
            if error == nil, !done { self.read(c) }
        }
    }

    private func ingest(_ data: Data, from c: NWConnection) {
        let id = ObjectIdentifier(c)
        var msgs: [Data] = []
        lock.withLock {
            var b = (buffers[id] ?? Data()) + data
            while let m = try? RemoteFrame.take(&b) { msgs.append(m) }
            buffers[id] = b
        }
        for m in msgs {
            guard let f = PB.decode(m, schema: schema) else { continue }
            lock.withLock { _received.append(Received(at: Date(), fields: f)) }
            react(to: f, on: c)
        }
    }

    private func react(to f: [String: Any], on c: NWConnection) {
        switch family {
        case .polo:
            if f["pairing_request"] != nil {
                if poloStop != .afterRequest { send(["pairing_request_ack": ["server_name": "Fake TV"]], on: c) }
            } else if f["options"] != nil {
                if poloStop != .afterOptions { send(["options": ["input_encodings": [["type": 3, "symbol_length": 6]], "preferred_role": 1]], on: c) }
            } else if f["configuration"] != nil {
                send(["configuration_ack": [String: Any]()], on: c)
            } else if f["secret"] != nil {
                switch secretReply {
                case .ack: send(["secret_ack": ["secret": Data([1, 2])]], on: c)
                case .badSecret: send(["status": 402], on: c)
                case .silence: break
                }
            }
        case .remote:
            if f["remote_key_inject"] != nil, offOnKey { send(["remote_start": [String: Any]()], on: c) }
        }
    }
}
