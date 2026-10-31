// FakeCastServer.swift — a fake Chromecast on 127.0.0.1 for the CastTV driver tests: plain TCP (the driver is built with
// tls: false in tests only), 4-byte framing, the real CastMessage codec. It plays a TV by script and records every
// message it decodes, in order, so the tests see the real bytes over a real socket. Test target only.

import Darwin
import Foundation
@testable import GoPray

final class FakeCastServer: @unchecked Sendable {
    /// One decoded message from the driver.
    struct Seen {
        var destination: String
        var namespace: String
        var type: String
        var json: [String: Any]
        var at: Date
    }

    /// What GET_STATUS reports before the driver touches anything.
    enum Receiver {
        case standby                                                              // isStandBy true, no apps
        case idle                                                                 // on, no apps
        case running(statusText: String, sessionId: String, transport: String)    // a CC1AD845 already up
    }
    enum LaunchReply { case ok, error, silence }

    /// One media status the fake can report.
    struct Media {
        var state: String
        var idleReason: String? = nil
        var currentTime: Double
        static func playing(_ t: Double) -> Media { Media(state: "PLAYING", currentTime: t) }
        static func buffering(_ t: Double = 0) -> Media { Media(state: "BUFFERING", currentTime: t) }
        static func finished() -> Media { Media(state: "IDLE", idleReason: "FINISHED", currentTime: 0) }
        static func cancelled() -> Media { Media(state: "IDLE", idleReason: "CANCELLED", currentTime: 0) }
    }

    static let ourTransport = "web-7"
    static let ourSession = "sess-new"
    static let oldTransport = "web-old"
    static let appId = TVDevice.defaultCastAppId

    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var conns: [Int32] = []
    private(set) var port = 0

    private var _seen: [Seen] = []
    private var _apps: [[String: Any]] = []
    private var _standby = false
    private var _receiver: Receiver = .idle
    private var _launch: LaunchReply = .ok
    private var _ourPlan: [Media] = [.buffering(), .playing(1), .playing(6), .finished()]
    private var _oldPlan: [Media] = []
    private var _ourIndex = 0
    private var _oldIndex = 0
    private var _sendPing = false
    private var _huge = false
    private var _junk = false
    private var _dropAfter: Int?
    private var _dropSessionAfterQueries: Int?
    private var _ignoreStop = false
    private var _count = 0
    private var _ourQueries = 0

    var receiver: Receiver { get { lock.withLock { _receiver } } set { lock.withLock { _receiver = newValue; applyReceiver(newValue) } } }
    var launchReply: LaunchReply { get { lock.withLock { _launch } } set { lock.withLock { _launch = newValue } } }
    /// Statuses for the driver's own session: LOAD gets the first, then one per media GET_STATUS (the last repeats).
    var mediaPlan: [Media] { get { lock.withLock { _ourPlan } } set { lock.withLock { _ourPlan = newValue } } }
    /// Statuses for the receiver that was already running (transport `oldTransport`), one per media GET_STATUS.
    var existingPlan: [Media] { get { lock.withLock { _oldPlan } } set { lock.withLock { _oldPlan = newValue } } }
    var sendPing: Bool { get { lock.withLock { _sendPing } } set { lock.withLock { _sendPing = newValue } } }
    var sendHugeFrame: Bool { get { lock.withLock { _huge } } set { lock.withLock { _huge = newValue } } }
    var sendJunk: Bool { get { lock.withLock { _junk } } set { lock.withLock { _junk = newValue } } }
    /// Close the socket right after the n-th message has been handled.
    var dropAfter: Int? { get { lock.withLock { _dropAfter } } set { lock.withLock { _dropAfter = newValue } } }
    /// After this many media GET_STATUS on our transport, report a RECEIVER_STATUS without our session (another sender took over).
    var dropOurSessionAfterQueries: Int? { get { lock.withLock { _dropSessionAfterQueries } } set { lock.withLock { _dropSessionAfterQueries = newValue } } }
    /// STOP is recorded but changes nothing and gets no answer.
    var ignoreStop: Bool { get { lock.withLock { _ignoreStop } } set { lock.withLock { _ignoreStop = newValue } } }

    var seen: [Seen] { lock.withLock { _seen } }
    /// `TYPE>destination`, in order: `["CONNECT>receiver-0", "GET_STATUS>receiver-0", …]`.
    var log: [String] { seen.map { "\($0.type)>\($0.destination)" } }
    func messages(_ type: String) -> [Seen] { seen.filter { $0.type == type } }

    init() {
        (listenFD, port) = Self.listen()
        let fd = listenFD
        Thread.detachNewThread { [weak self] in
            while true {
                let c = accept(fd, nil, nil); if c < 0 { return }
                self?.lock.withLock { self?.conns.append(c) }
                Thread.detachNewThread { [weak self] in self?.serve(c) }
            }
        }
    }

    deinit { stop() }

    func stop() {
        let (l, cs) = lock.withLock { () -> (Int32, [Int32]) in let r = (listenFD, conns); listenFD = -1; conns = []; return r }
        if l >= 0 { shutdown(l, SHUT_RDWR); close(l) }
        for c in cs { shutdown(c, SHUT_RDWR); close(c) }
    }

    /// A port nothing listens on.
    static func closedPort() -> Int { let (fd, p) = listen(); close(fd); return p }

    // MARK: Script

    private func applyReceiver(_ r: Receiver) {      // called with the lock held
        switch r {
        case .standby: _standby = true; _apps = []
        case .idle: _standby = false; _apps = []
        case .running(let text, let session, let transport):
            _standby = false
            _apps = [["appId": Self.appId, "transportId": transport, "sessionId": session, "statusText": text]]
        }
    }

    private func statusPayload(_ id: Int) -> String {   // lock held
        CastOut.json(["type": "RECEIVER_STATUS", "requestId": id,
                      "status": ["applications": _apps, "isActiveInput": !_standby, "isStandBy": _standby]])
    }

    private func mediaPayload(_ id: Int, _ m: Media) -> String {
        var e: [String: Any] = ["mediaSessionId": 1, "playerState": m.state, "currentTime": m.currentTime]
        if let r = m.idleReason { e["idleReason"] = r }
        return CastOut.json(["type": "MEDIA_STATUS", "requestId": id, "status": [e]])
    }

    private func serve(_ fd: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])
            while let body = try? CastFrame.take(from: &buffer) {
                if let m = CastMessage.decode(body), !handle(m, fd) { shutdown(fd, SHUT_RDWR); close(fd); return }
            }
        }
    }

    /// false = close the connection now.
    private func handle(_ m: CastMessage, _ fd: Int32) -> Bool {
        let obj = (try? JSONSerialization.jsonObject(with: Data(m.payload.utf8))) as? [String: Any] ?? [:]
        let type = obj["type"] as? String ?? "?"
        let id = obj["requestId"] as? Int ?? 0
        var out: [CastMessage] = []
        var raw: [Data] = []
        var drop = false

        lock.lock()
        _seen.append(Seen(destination: m.destination, namespace: m.namespace, type: type, json: obj, at: Date()))
        _count += 1
        func reply(_ ns: String, _ payload: String, from: String = CastOut.platform) {
            out.append(CastMessage(source: from, destination: CastOut.sender, namespace: ns, payload: payload))
        }
        switch (m.namespace, type) {
        case (CastNS.connection, "CONNECT"):
            if _huge { raw.append(Data([0x00, 0x01, 0x00, 0x01, 0x08, 0x00])) }       // declares 65 537 bytes
            if _junk {
                raw.append(CastFrame.wrap(Data([0xff, 0xff, 0xff, 0xff])))             // not a protobuf message
                raw.append(CastFrame.encode(CastMessage(source: CastOut.platform, destination: CastOut.sender, namespace: CastNS.receiver, payload: "not json {")))
            }
        case (CastNS.receiver, "GET_STATUS"):
            reply(CastNS.receiver, statusPayload(id))
            if _sendPing { _sendPing = false; reply(CastNS.heartbeat, CastOut.json(["type": "PING"])) }
        case (CastNS.receiver, "STOP"):
            if !_ignoreStop {
                let session = obj["sessionId"] as? String
                _apps.removeAll { ($0["sessionId"] as? String) == session }
                reply(CastNS.receiver, statusPayload(id))
            }
        case (CastNS.receiver, "LAUNCH"):
            switch _launch {
            case .ok:
                _standby = false
                _apps = [["appId": Self.appId, "transportId": Self.ourTransport, "sessionId": Self.ourSession, "statusText": "Default Media Receiver"]]
                reply(CastNS.receiver, statusPayload(id))
            case .error: reply(CastNS.receiver, CastOut.json(["type": "LAUNCH_ERROR", "requestId": id, "reason": "NOT_FOUND"]))
            case .silence: break
            }
        case (CastNS.media, "LOAD"):
            _ourIndex = 0; _ourQueries = 0
            if let first = _ourPlan.first { reply(CastNS.media, mediaPayload(id, first), from: Self.ourTransport); _ourIndex = 1 }
        case (CastNS.media, "GET_STATUS"):
            if m.destination == Self.oldTransport {
                if !_oldPlan.isEmpty { reply(CastNS.media, mediaPayload(id, _oldPlan[min(_oldIndex, _oldPlan.count - 1)]), from: Self.oldTransport); _oldIndex += 1 }
            } else {
                _ourQueries += 1
                if let limit = _dropSessionAfterQueries, _ourQueries > limit {
                    _apps = []
                    reply(CastNS.receiver, statusPayload(0))
                } else if !_ourPlan.isEmpty {
                    reply(CastNS.media, mediaPayload(id, _ourPlan[min(_ourIndex, _ourPlan.count - 1)]), from: Self.ourTransport)
                    _ourIndex += 1
                }
            }
        case (CastNS.heartbeat, "PING"):
            reply(CastNS.heartbeat, CastOut.json(["type": "PONG"]))
        default: break
        }
        if let n = _dropAfter, _count >= n { drop = true }
        lock.unlock()

        for r in raw { Self.write(fd, r) }
        for r in out { Self.write(fd, CastFrame.encode(r)) }
        return !drop
    }

    private static func write(_ fd: Int32, _ data: Data) {
        var off = 0
        while off < data.count {
            let n = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + off, data.count - off) }
            if n <= 0 { return }
            off += n
        }
    }

    private static func listen() -> (Int32, Int) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        Darwin.listen(fd, 8)
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return (fd, Int(UInt16(bigEndian: bound.sin_port)))
    }
}
