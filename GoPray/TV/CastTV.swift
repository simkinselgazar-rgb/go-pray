// CastTV.swift — the Google TV (Chromecast built-in) driver: CASTV2 from Swift, no SDK (Google TV Plan §3, §5).
// The ONE Cast network file, with AndroidRemote.swift (the TV's own remote protocol, lane D).
//
// LAN only. The host comes only from Settings (an IPv4 literal in a private range, checked on every entry). This file
// has no hostname, URL or IP literal; guard.sh checks that. Nothing secret crosses this channel (a LAN URL to a public
// painting), which is what makes its TLS exception acceptable: see `CastLink.parameters`.
//
// The wire, in the order that was proved on a real TV:
//   CONNECT receiver-0 -> GET_STATUS (isStandBy => wasOff) -> STOP any running CC1AD845 -> LAUNCH CC1AD845 (wakes a TV in
//   standby) -> CONNECT <transportId> -> LOAD <url of the mp4 on this Mac> -> hold (PING + media GET_STATUS every 5 s) ->
//   STOP our session (the TV goes to its home screen) -> and, only if the TV was off and the Athan finished, power it off.

import Foundation
import Network
import os

private let log = Logger(subsystem: "com.ahmedelgazar.gopray", category: "tv")

// MARK: - Protobuf, table-driven (two wire types; no SwiftProtobuf)

enum ProtoWire: Equatable, Sendable { case varint, bytes }
enum ProtoValue: Equatable, Sendable { case varint(UInt64), bytes(Data) }

/// Just enough protobuf for CastMessage and the Android TV Remote messages: varint (wire 0) and length-delimited (wire 2).
/// A message is a schema (`field number -> wire type`) plus values; unknown fields are skipped, a known field with the
/// wrong wire type or any truncation makes the whole message nil.
enum Proto {
    static func varint(_ value: UInt64) -> Data {
        var v = value, out = Data()
        while v >= 0x80 { out.append(UInt8(v & 0x7f) | 0x80); v >>= 7 }
        out.append(UInt8(v))
        return out
    }

    static func encode(_ fields: [(field: Int, value: ProtoValue)]) -> Data {
        var out = Data()
        for f in fields {
            switch f.value {
            case .varint(let v): out += varint(UInt64(f.field) << 3); out += varint(v)
            case .bytes(let d): out += varint(UInt64(f.field) << 3 | 2); out += varint(UInt64(d.count)); out += d
            }
        }
        return out
    }

    /// Reads one varint from `bytes` at `i` (advanced past it). nil: truncated, or more than 10 bytes.
    static func readVarint(_ bytes: [UInt8], _ i: inout Int) -> UInt64? {
        var result: UInt64 = 0, shift: UInt64 = 0
        while i < bytes.count, shift < 70 {
            let b = bytes[i]; i += 1
            if shift == 63, b > 1 { return nil }
            result |= UInt64(b & 0x7f) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    static func decode(_ data: Data, schema: [Int: ProtoWire]) -> [Int: [ProtoValue]]? {
        let bytes = [UInt8](data)
        var i = 0
        var out: [Int: [ProtoValue]] = [:]
        while i < bytes.count {
            guard let tag = readVarint(bytes, &i), tag >> 3 > 0, tag >> 3 < 1 << 29 else { return nil }
            let field = Int(tag >> 3), wire = tag & 7
            switch wire {
            case 0:
                guard let v = readVarint(bytes, &i) else { return nil }
                if let want = schema[field] { guard want == .varint else { return nil }; out[field, default: []].append(.varint(v)) }
            case 2:
                guard let n = readVarint(bytes, &i), n <= UInt64(bytes.count - i) else { return nil }
                let end = i + Int(n)
                if let want = schema[field] { guard want == .bytes else { return nil }; out[field, default: []].append(.bytes(Data(bytes[i..<end]))) }
                i = end
            case 1: guard bytes.count - i >= 8 else { return nil }; i += 8
            case 5: guard bytes.count - i >= 4 else { return nil }; i += 4
            default: return nil
            }
        }
        return out
    }
}

// MARK: - CastMessage and framing

/// `cast_channel.proto` CastMessage, STRING payloads only. `protocol_version` is always CASTV2_1_0 (0) and
/// `payload_type` STRING (0) on the way out; a binary payload is refused on the way in.
struct CastMessage: Equatable, Sendable {
    var source: String
    var destination: String
    var namespace: String
    var payload: String

    static let schema: [Int: ProtoWire] = [1: .varint, 2: .bytes, 3: .bytes, 4: .bytes, 5: .varint, 6: .bytes, 7: .bytes]

    func encoded() -> Data {
        Proto.encode([(1, .varint(0)), (2, .bytes(Data(source.utf8))), (3, .bytes(Data(destination.utf8))),
                      (4, .bytes(Data(namespace.utf8))), (5, .varint(0)), (6, .bytes(Data(payload.utf8)))])
    }

    static func decode(_ body: Data) -> CastMessage? {
        guard let f = Proto.decode(body, schema: schema) else { return nil }
        func text(_ n: Int) -> String? {
            guard case .bytes(let d)? = f[n]?.last else { return nil }
            return String(data: d, encoding: .utf8)
        }
        if case .varint(let t)? = f[5]?.last, t != 0 { return nil }
        guard let s = text(2), let d = text(3), let ns = text(4) else { return nil }
        return CastMessage(source: s, destination: d, namespace: ns, payload: text(6) ?? "")
    }
}

/// Length-prefixed frames. Cast: 4-byte big-endian. The Android TV Remote (lane D) uses the same bodies with a varint prefix.
enum CastFrame {
    /// Anything declared bigger than this closes the connection.
    static let maxBody = 64 * 1024
    enum Prefix: Sendable { case fixed32, varint }

    static func wrap(_ body: Data, prefix: Prefix = .fixed32) -> Data {
        switch prefix {
        case .fixed32:
            let n = UInt32(body.count)
            return Data([UInt8(n >> 24), UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)]) + body
        case .varint: return Proto.varint(UInt64(body.count)) + body
        }
    }

    static func encode(_ m: CastMessage) -> Data { wrap(m.encoded()) }

    /// Removes and returns the first complete body from `buffer`; nil when more bytes are needed.
    /// Throws `.unreachable` for a declared length over `maxBody` or a prefix that is not a varint.
    static func take(from buffer: inout Data, prefix: Prefix = .fixed32) throws -> Data? {
        let bytes = [UInt8](buffer)
        var start = 0, length = 0
        switch prefix {
        case .fixed32:
            guard bytes.count >= 4 else { return nil }
            length = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3]); start = 4
        case .varint:
            guard let end = bytes.prefix(10).firstIndex(where: { $0 & 0x80 == 0 }) else {
                if bytes.count < 10 { return nil }       // the prefix itself is not all here yet
                throw TVError.unreachable                // ten bytes and still no end: not a length
            }
            var i = 0
            guard let n = Proto.readVarint(bytes, &i), i == end + 1, n <= UInt64(maxBody) else { throw TVError.unreachable }
            length = Int(n); start = i
        }
        guard length <= maxBody else { throw TVError.unreachable }
        guard bytes.count - start >= length else { return nil }
        buffer = Data(bytes[(start + length)...])
        return Data(bytes[start..<(start + length)])
    }
}

// MARK: - What the TV says (untrusted bytes: a cap, a few named fields, nothing else)

struct CastApp: Equatable, Sendable {
    var appId: String
    var transportId: String?
    var sessionId: String?
    var statusText: String
}

struct CastMedia: Equatable, Sendable {
    var playerState: String
    var idleReason: String?
    var currentTime: Double
}

enum CastReply: Equatable, Sendable {
    case receiverStatus(requestId: Int?, isStandBy: Bool?, apps: [CastApp])
    case mediaStatus(requestId: Int?, entries: [CastMedia])
    case ping, pong, close
    case launchError
    case loadFailed
    case other

    static let maxIDLength = 64

    /// `^[A-Za-z0-9._-]{1,64}$`: the only shape a transportId or sessionId may have before it is reused as a
    /// destination or inside a STOP. Never a URL, a path, or anything shown in the UI.
    static func isValidID(_ s: String) -> Bool {
        (1...maxIDLength).contains(s.utf8.count) && s.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 46 || $0 == 95 || $0 == 45 }
    }

    static func parse(_ m: CastMessage) -> CastReply {
        guard m.payload.utf8.count <= CastFrame.maxBody,
              let obj = try? JSONSerialization.jsonObject(with: Data(m.payload.utf8)) as? [String: Any],
              let type = obj["type"] as? String, type.utf8.count <= 32 else { return .other }
        let requestId = obj["requestId"] as? Int
        switch type {
        case "PING": return .ping
        case "PONG": return .pong
        case "CLOSE": return .close
        case "LAUNCH_ERROR": return .launchError
        case "LOAD_FAILED", "LOAD_CANCELLED", "INVALID_REQUEST": return .loadFailed
        case "RECEIVER_STATUS":
            let status = obj["status"] as? [String: Any] ?? [:]
            let apps = (status["applications"] as? [[String: Any]] ?? []).prefix(16).compactMap { a -> CastApp? in
                guard let id = a["appId"] as? String, id.utf8.count <= maxIDLength else { return nil }
                return CastApp(appId: id,
                               transportId: (a["transportId"] as? String).flatMap { isValidID($0) ? $0 : nil },
                               sessionId: (a["sessionId"] as? String).flatMap { isValidID($0) ? $0 : nil },
                               statusText: String(((a["statusText"] as? String) ?? "").prefix(100)))
            }
            return .receiverStatus(requestId: requestId, isStandBy: status["isStandBy"] as? Bool, apps: Array(apps))
        case "MEDIA_STATUS":
            let entries = (obj["status"] as? [[String: Any]] ?? []).prefix(8).compactMap { e -> CastMedia? in
                guard let state = e["playerState"] as? String, state.utf8.count <= 16 else { return nil }
                let t = (e["currentTime"] as? Double) ?? 0
                return CastMedia(playerState: state, idleReason: (e["idleReason"] as? String).map { String($0.prefix(24)) },
                                 currentTime: t.isFinite ? t : 0)
            }
            return .mediaStatus(requestId: requestId, entries: Array(entries))
        default: return .other
        }
    }
}

// MARK: - What we say

enum CastNS {
    static let connection = "urn:x-cast:com.google.cast.tp.connection"
    static let heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
    static let receiver = "urn:x-cast:com.google.cast.receiver"
    static let media = "urn:x-cast:com.google.cast.media"
}

enum CastOut {
    static let sender = "sender-0"
    static let platform = "receiver-0"

    static func json(_ object: [String: Any]) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: d, as: UTF8.self)
    }

    private static func msg(_ to: String, _ ns: String, _ object: [String: Any]) -> CastMessage {
        CastMessage(source: sender, destination: to, namespace: ns, payload: json(object))
    }

    static func handshake(to dest: String) -> CastMessage { msg(dest, CastNS.connection, ["type": "CONNECT"]) }
    static func getStatus(id: Int) -> CastMessage { msg(platform, CastNS.receiver, ["type": "GET_STATUS", "requestId": id]) }
    static func launch(appId: String, id: Int) -> CastMessage { msg(platform, CastNS.receiver, ["type": "LAUNCH", "appId": appId, "requestId": id]) }
    static func stop(sessionId: String, id: Int) -> CastMessage { msg(platform, CastNS.receiver, ["type": "STOP", "sessionId": sessionId, "requestId": id]) }
    static func mediaGetStatus(transport: String, id: Int) -> CastMessage { msg(transport, CastNS.media, ["type": "GET_STATUS", "requestId": id]) }
    static func ping() -> CastMessage { msg(platform, CastNS.heartbeat, ["type": "PING"]) }
    static func pong(to dest: String) -> CastMessage { msg(dest, CastNS.heartbeat, ["type": "PONG"]) }
    static func load(transport: String, contentId: String, title: String, id: Int) -> CastMessage {
        msg(transport, CastNS.media, ["type": "LOAD", "requestId": id, "autoplay": true,
                                      "media": ["contentId": contentId, "contentType": "video/mp4", "streamType": "BUFFERED",
                                                "metadata": ["metadataType": 0, "title": title]]])
    }
}

// MARK: - The decisions (pure functions over parsed status: the same fixtures run on Windows)

enum CastEnd: String, Equatable, Sendable { case finished, early, taken, cap }

enum CastDecide {
    /// The progress rule for the de-dupe: a receiver that is really playing right now is PLAYING in both samples and its
    /// clock moved at least a second between them. Anything else (BUFFERING, PAUSED, IDLE, frozen, no media) is a corpse.
    static func isLivePlayback(_ first: CastMedia?, _ second: CastMedia?) -> Bool {
        guard let a = first, let b = second, a.playerState == "PLAYING", b.playerState == "PLAYING" else { return false }
        return b.currentTime - a.currentTime >= 1
    }

    /// IDLE/FINISHED is the Athan ending on its own; IDLE with any other reason (CANCELLED, INTERRUPTED, ERROR) is a
    /// person (Back) or a failure; IDLE with no reason is the receiver's blank state and says nothing.
    static func end(of m: CastMedia) -> CastEnd? {
        guard m.playerState == "IDLE", let reason = m.idleReason else { return nil }
        return reason == "FINISHED" ? .finished : .early
    }
}

/// Watches `currentTime` while PLAYING. BUFFERING, PAUSED and a frozen clock all look the same here: no progress.
struct CastProgress: Equatable, Sendable {
    private(set) var lastTime = -1.0
    private(set) var lastProgressAt: Double

    init(startedAt: Double) { lastProgressAt = startedAt }

    mutating func observe(_ m: CastMedia, at seconds: Double) {
        guard m.playerState == "PLAYING" else { return }
        if m.currentTime > lastTime + 0.01 { lastProgressAt = seconds }
        lastTime = max(lastTime, m.currentTime)
    }

    func isStalled(at seconds: Double, limit: Double) -> Bool { seconds - lastProgressAt >= limit }
}

// MARK: - The socket

/// One CASTV2 connection: frames in, frames out, a queue of what arrived, and a deadline on every wait.
final class CastLink: @unchecked Sendable {
    enum Event: Sendable { case message(CastMessage), closed }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "gopray.cast.link")
    private let lock = NSLock()
    private var events: [Event] = []
    private var waiter: CheckedContinuation<Event?, Never>?
    private var waiterToken = 0
    private var closedFlag = false
    private var buffer = Data()      // touched only on `queue`

    private init(_ connection: NWConnection) { self.connection = connection }

    /// TLS to a Cast device uses a self-signed per-device certificate (every open client skips the check). The exception
    /// is built only here, only when asked for TLS, only for the one host the caller already checked and port 8009.
    private static func parameters(tls: Bool, host: String, port: Int, timeout: Double) throws -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = max(1, Int(timeout.rounded(.up)))
        tcp.noDelay = true
        guard tls else { return NWParameters(tls: nil, tcp: tcp) }
        guard TVHost.isAllowed(host), port == CastTV.castPort else { throw TVError.refusedHost }
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, _, done in done(true) }, DispatchQueue(label: "gopray.cast.tls"))
        return NWParameters(tls: options, tcp: tcp)
    }

    static func open(host: String, port: Int, tls: Bool, timeout: Double) async throws -> CastLink {
        guard let p = NWEndpoint.Port(rawValue: UInt16(truncatingIfNeeded: port)), port > 0, port < 65536 else { throw TVError.unreachable }
        let params = try parameters(tls: tls, host: host, port: port, timeout: timeout)
        return try await open(NWConnection(host: NWEndpoint.Host(host), port: p, using: params), timeout: timeout)
    }

    static func open(_ connection: NWConnection, timeout: Double) async throws -> CastLink {
        let link = CastLink(connection)
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.take() { k.resume() }
                case .failed, .waiting, .cancelled: if once.take() { connection.cancel(); k.resume(throwing: TVError.unreachable) }
                default: break
                }
            }
            link.queue.asyncAfter(deadline: .now() + timeout) { if once.take() { connection.cancel(); k.resume(throwing: TVError.unreachable) } }
            connection.start(queue: link.queue)
        }
        connection.stateUpdateHandler = { [weak link] state in
            switch state {
            case .failed, .cancelled: link?.push(.closed)
            default: break
            }
        }
        link.pump()
        return link
    }

    /// The Mac's own address on the path to this TV: what the TV will be told to fetch from.
    var localHost: String? { Self.address(connection.currentPath?.localEndpoint) }
    var remoteHost: String? { Self.address(connection.currentPath?.remoteEndpoint) }

    private static func address(_ endpoint: NWEndpoint?) -> String? {
        guard case .hostPort(let host, _)? = endpoint, case .ipv4(let a) = host else { return nil }
        let text = "\(a)"
        return String(text.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)[0])
    }

    func send(_ m: CastMessage) async throws {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            connection.send(content: CastFrame.encode(m), completion: .contentProcessed { error in
                if error != nil { k.resume(throwing: TVError.unreachable) } else { k.resume() }
            })
        }
    }

    /// The next thing that arrived, `.closed` once the socket is gone, or nil if nothing came within `seconds`.
    func next(within seconds: Double) async -> Event? {
        await withCheckedContinuation { (k: CheckedContinuation<Event?, Never>) in
            lock.lock()
            if !events.isEmpty { let e = events.removeFirst(); lock.unlock(); k.resume(returning: e); return }
            if closedFlag { lock.unlock(); k.resume(returning: .closed); return }
            waiterToken += 1
            let token = waiterToken
            waiter = k
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + max(0, seconds)) { [weak self] in self?.expire(token) }
        }
    }

    func close() { connection.cancel() }

    private func expire(_ token: Int) {
        lock.lock()
        guard let k = waiter, waiterToken == token else { lock.unlock(); return }
        waiter = nil
        lock.unlock()
        k.resume(returning: nil)
    }

    private func push(_ e: Event) {
        lock.lock()
        if case .closed = e { closedFlag = true }
        if let k = waiter { waiter = nil; lock.unlock(); k.resume(returning: e); return }
        if case .closed = e, !events.isEmpty { lock.unlock(); return }
        events.append(e)
        lock.unlock()
    }

    private func pump() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty, !self.ingest(data) { self.push(.closed); self.connection.cancel(); return }
            if error != nil || complete { self.push(.closed); return }
            self.pump()
        }
    }

    /// false = the TV sent a frame over the cap: drop the connection. A frame that is not a CastMessage is ignored.
    private func ingest(_ data: Data) -> Bool {
        buffer.append(data)
        while true {
            do {
                guard let body = try CastFrame.take(from: &buffer) else { return true }
                if let m = CastMessage.decode(body) { push(.message(m)) }
            } catch { return false }
        }
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}

// MARK: - Timing (tests shrink it)

struct CastTiming: Sendable {
    var connect = 3.0, status = 3.0, stopWait = 3.0, launchWait = 8.0, finalStopWait = 1.0
    /// PING + media GET_STATUS every `ping`; no progress for `frozen` ends the Athan early; `cap` is the hard stop.
    var ping = 5.0, frozen = 15.0, cap = 8.0 * 60
    /// The gap between the two samples of the de-dupe.
    var probeGap = 1.5
    init() {}
}

// MARK: - The driver

struct CastTV: TVControlling {
    static let castPort = 8009

    let port: Int
    /// Production: TLS. Tests pass false to talk to a plain fake on localhost; production never does.
    let tls: Bool
    /// Production: `TVHost.isAllowed`. Tests inject one that also lets 127.0.0.1 through.
    let hostCheck: @Sendable (String) -> Bool
    let timing: CastTiming
    let media: CastMediaSource
    let server: CastServing
    let power: TVPowering

    init(port: Int = CastTV.castPort, tls: Bool = true, hostCheck: @escaping @Sendable (String) -> Bool = TVHost.isAllowed,
         timing: CastTiming = CastTiming(), media: CastMediaSource, server: CastServing, power: TVPowering) {
        self.port = port; self.tls = tls; self.hostCheck = hostCheck; self.timing = timing
        self.media = media; self.server = server; self.power = power
    }

    // MARK: Find the app

    /// Cast needs no install: a TV that answers CONNECT + GET_STATUS has the stock receiver.
    func findChannel(_ tv: TVDevice) async throws -> String? {
        guard hostCheck(tv.host) else { throw TVError.refusedHost }
        let run = Run(link: try await CastLink.open(host: tv.host, port: port, tls: tls, timeout: timing.connect), timing: timing)
        defer { run.link.close() }
        try await run.send(CastOut.handshake(to: CastOut.platform))
        _ = try await run.receiverStatus()
        return TVDevice.defaultCastAppId
    }

    func forget(_ tv: TVDevice) { power.forget(tv) }

    // MARK: Launch

    func launch(_ tv: TVDevice, prayer: Prayer, voice: Voice, test: Bool = false) async throws {
        guard hostCheck(tv.host) else { throw TVError.refusedHost }
        guard TVDevice.isValidChannelId(tv.channelId, kind: .googleTV) else { throw TVError.badURL }
        let appId = TVDevice.defaultCastAppId

        let run = Run(link: try await CastLink.open(host: tv.host, port: port, tls: tls, timeout: timing.connect), timing: timing)
        var served: CastServed?
        defer { run.link.close(); served?.stop() }

        // 1. Who are we talking to, and was it off?
        try await run.send(CastOut.handshake(to: CastOut.platform))
        let status = try await run.receiverStatus()
        let wasOff = status.isStandBy == true
        if wasOff { log.notice("tv: cast was off") }
        let running = status.apps.filter { $0.appId == appId }

        // 2. De-dupe, Athan path only (many senders, one Athan): leave a receiver that is really playing our Athan alone.
        if !test, let theirs = running.first(where: { $0.statusText.hasPrefix("Casting: Go Pray") }), let transport = theirs.transportId {
            try await run.send(CastOut.handshake(to: transport))
            let first = try await run.mediaState(transport)
            try await Task.sleep(for: .seconds(timing.probeGap))
            let second = try await run.mediaState(transport)
            if CastDecide.isLivePlayback(first, second) {
                log.notice("tv: cast already playing")
                return
            }
        }

        // 3. STOP first, always: a hidden receiver takes a LOAD and never comes forward.
        if !running.isEmpty {
            for app in running { if let session = app.sessionId { try await run.send(CastOut.stop(sessionId: session, id: run.nextId())) } }
            do { _ = try await run.status(within: timing.stopWait) { !$0.apps.contains { $0.appId == appId } } }
            catch { log.error("tv: cast old receiver did not quit, launching anyway") }
        }

        // 4. The video, the server for it, then the receiver.
        let file = try await media.prepare(prayer: prayer, voice: voice)
        guard let mac = run.link.localHost else { throw TVError.unreachable }
        let handle = try server.serve(file: file, on: mac, forPeer: tv.host)
        served = handle

        try await run.send(CastOut.launch(appId: appId, id: run.nextId()))
        let (transport, session): (String, String) = try await run.wait(within: timing.launchWait) { reply in
            switch reply {
            case .launchError: throw TVError.badStatus(0)
            case .receiverStatus(_, _, let apps):
                guard let a = apps.first(where: { $0.appId == appId }), let t = a.transportId, let s = a.sessionId else { return nil }
                return (t, s)
            default: return nil
            }
        }
        try await run.send(CastOut.handshake(to: transport))
        let title = "Go Pray · " + (test ? "Test" : prayer.rawValue.capitalized)
        try await run.send(CastOut.load(transport: transport, contentId: handle.url.absoluteString, title: title, id: run.nextId()))

        // 5. Hold until it ends, one way or another.
        let end = await run.hold(transport: transport, session: session)
        log.notice("tv: cast stopped (\(end.rawValue, privacy: .public))")

        // 6. Put the TV back: finished, early and cap quit our session (home screen); taken is not ours any more.
        if end != .taken {
            try? await run.send(CastOut.stop(sessionId: session, id: run.nextId()))
            _ = try? await run.status(within: timing.finalStopWait) { !$0.apps.contains { $0.sessionId == session } }
        }
        run.link.close(); served?.stop(); served = nil

        // 7. Power-off, the one call site: the TV was off, the Athan finished (not Back, not a cap), and the remote is paired.
        if wasOff && end == .finished && power.isPaired(tv) { do { let off = try await power.turnOff(tv); log.notice("\(off ? "tv: power off" : "tv: power off not confirmed", privacy: .public)") } catch { log.error("tv: power off failed: \(TVLog.describe(error), privacy: .public)") } }
        else if wasOff && end == .finished { log.notice("tv: cast was off, remote not paired, left on") }
    }

    // MARK: One connection's conversation

    final class Run: @unchecked Sendable {
        let link: CastLink
        let timing: CastTiming
        private let lock = NSLock()
        private var id = 0
        private let started = ContinuousClock.now

        init(link: CastLink, timing: CastTiming) { self.link = link; self.timing = timing }

        func nextId() -> Int { lock.withLock { id += 1; return id } }
        func send(_ m: CastMessage) async throws { try await link.send(m) }
        var elapsed: Double { Self.seconds(started.duration(to: .now)) }
        static func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }

        /// Reads until `match` returns a value. A TV PING is answered, junk is ignored, the clock is the only way out.
        func wait<T>(within seconds: Double, _ match: (CastReply) throws -> T?) async throws -> T {
            let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
            while true {
                let left = Self.seconds(ContinuousClock.now.duration(to: deadline))
                guard left > 0, let event = await link.next(within: left) else { throw TVError.unreachable }
                guard case .message(let m) = event else { throw TVError.unreachable }
                let reply = CastReply.parse(m)
                if reply == .ping { try? await link.send(CastOut.pong(to: m.source)); continue }
                if let value = try match(reply) { return value }
            }
        }

        struct Status { var isStandBy: Bool?; var apps: [CastApp] }

        /// GET_STATUS, then the first RECEIVER_STATUS.
        func receiverStatus() async throws -> Status {
            try await send(CastOut.getStatus(id: nextId()))
            return try await status(within: timing.status) { _ in true }
        }

        /// The first RECEIVER_STATUS (a reply or a broadcast) that `accept`s.
        func status(within seconds: Double, accept: (Status) -> Bool) async throws -> Status {
            try await wait(within: seconds) { reply in
                guard case .receiverStatus(_, let standby, let apps) = reply else { return nil }
                let s = Status(isStandBy: standby, apps: apps)
                return accept(s) ? s : nil
            }
        }

        /// The media status of an existing receiver: nil when it answers nothing in time (or has no media).
        func mediaState(_ transport: String) async throws -> CastMedia? {
            try await send(CastOut.mediaGetStatus(transport: transport, id: nextId()))
            return try? await wait(within: timing.status) { reply -> CastMedia?? in
                guard case .mediaStatus(_, let entries) = reply else { return nil }
                return .some(entries.first)
            }
        }

        /// Hold: PING + media GET_STATUS every `ping`, answer the TV's PING, and decide how it ends.
        func hold(transport: String, session: String) async -> CastEnd {
            var progress = CastProgress(startedAt: elapsed)
            var nextTick = elapsed + timing.ping
            while true {
                let now = elapsed
                if now >= timing.cap { return .cap }
                if progress.isStalled(at: now, limit: timing.frozen) { return .early }
                if now >= nextTick {
                    nextTick += timing.ping
                    do { try await send(CastOut.ping()); try await send(CastOut.mediaGetStatus(transport: transport, id: nextId())) }
                    catch { return .taken }
                    continue
                }
                guard let event = await link.next(within: min(nextTick, timing.cap) - now) else { continue }
                guard case .message(let m) = event else { return .taken }
                switch CastReply.parse(m) {
                case .ping: try? await link.send(CastOut.pong(to: m.source))
                case .receiverStatus(_, _, let apps): if !apps.contains(where: { $0.sessionId == session }) { return .taken }
                case .close: if m.source == transport || m.source == CastOut.platform { return .taken }
                case .loadFailed: return .early
                case .mediaStatus(_, let entries):
                    guard let media = entries.first else { continue }
                    if let end = CastDecide.end(of: media) { return end }
                    progress.observe(media, at: elapsed)
                default: break
                }
            }
        }
    }
}

// MARK: - Finding Google TVs (Bonjour _googlecast._tcp)

struct CastDiscovery: TVDiscovering {
    static let searchSeconds = 3.0
    static let resolveSeconds = 2.0
    static let serviceType = "_googlecast._tcp"
    /// kDNSServiceErr_PolicyDenied: what Local Network privacy gives a Bonjour browse.
    private static let policyDenied: Int32 = -65570

    func scan() async -> TVScan {
        let (results, denied) = await Self.browse()
        let found = await withTaskGroup(of: FoundTV?.self) { group in
            for r in results {
                group.addTask {
                    guard let host = await Self.address(of: r.endpoint), TVHost.isAllowed(host) else { return nil }
                    var fn: String?, md: String?
                    if case .bonjour(let txt) = r.metadata { fn = txt["fn"]; md = txt["md"] }
                    return FoundTV(host: host, name: Self.displayName(fn: fn, md: md), kind: .googleTV)
                }
            }
            var seen = Set<String>(), out: [FoundTV] = []
            for await tv in group { if let tv, seen.insert(tv.host).inserted { out.append(tv) } }
            return out.sorted { $0.host < $1.host }
        }
        return TVScan(found: found, denied: denied)
    }

    /// "Family Room TV (BRAVIA 4K VH21)": TXT `fn` (the name the person gave it) and `md` (the model).
    static func displayName(fn: String?, md: String?) -> String {
        func clean(_ s: String?) -> String {
            String((s ?? "").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let name = clean(fn), model = clean(md)
        let full = name.isEmpty ? (model.isEmpty ? TVKind.googleTV.defaultName : model) : (model.isEmpty || model == name ? name : "\(name) (\(model))")
        return String(full.prefix(TVDevice.maxNameLength))
    }

    private static func browse() async -> ([NWBrowser.Result], Bool) {
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
        let denied = Flag()
        browser.stateUpdateHandler = { state in
            switch state {
            case .failed(let e), .waiting(let e): if case .dns(let code) = e, code == policyDenied { denied.set() }
            default: break
            }
        }
        browser.start(queue: DispatchQueue(label: "gopray.cast.browse"))
        try? await Task.sleep(for: .seconds(searchSeconds))
        let results = Array(browser.browseResults)
        browser.cancel()
        return (results, denied.value)
    }

    /// Connect to the service on its own port (plain TCP, nothing is sent) and read the IPv4 the path settled on.
    private static func address(of endpoint: NWEndpoint) async -> String? {
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        guard let link = try? await CastLink.open(NWConnection(to: endpoint, using: params), timeout: resolveSeconds) else { return nil }
        defer { link.close() }
        return link.remoteHost
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    func set() { lock.withLock { on = true } }
    var value: Bool { lock.withLock { on } }
}
