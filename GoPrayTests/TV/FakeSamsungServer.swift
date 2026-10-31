// FakeSamsungServer.swift — a fake Samsung TV on 127.0.0.1 for the driver tests: a REST listener (8001's stand-in) and a
// plain ws:// WebSocket listener (8002's stand-in; no TLS, so the driver is built with scheme "ws" in tests only).
// Both record what they get, so the tests see the real bytes over real sockets. Test target only.

import CryptoKit
import Darwin
import Foundation

final class FakeSamsungServer: @unchecked Sendable {
    struct Request: Equatable { var requestLine: String; var headers: [String: String]; var body: Data }

    /// What the WebSocket does after the upgrade.
    enum WSMode: Equatable {
        case connect(token: String?)        // sends ms.channel.connect (with data.token when given)
        case unauthorized
        case timeOut
        case silence
        case refuse                         // answers the upgrade with 403
        case bigFrame                       // sends a 100 KB text frame
        case raw(String)                    // sends this exact text frame
    }

    private let lock = NSLock()
    private var restFD: Int32 = -1
    private var wsFD: Int32 = -1
    private var wsConns: [Int32] = []
    private var _requests: [Request] = []
    private var _wsRequests: [String] = []
    private var _emits: [String] = []

    private(set) var restPort = 0
    private(set) var wsPort = 0

    // REST knobs
    private var _deviceJSON = #"{"device":{"name":"Den","PowerState":"on"}}"#
    private var _deviceStatus = 200
    private var _appJSON = #"{"id":"GoPrayAth1.GoPray","name":"Go Pray","running":false,"visible":false,"version":"1.0.0"}"#
    private var _appStatus = 200
    private var _postStatus = 200
    private var _stream: Int?
    private var _written = 0
    private var _wsMode: WSMode = .connect(token: nil)

    var deviceJSON: String { get { lock.withLock { _deviceJSON } } set { lock.withLock { _deviceJSON = newValue } } }
    var deviceStatus: Int { get { lock.withLock { _deviceStatus } } set { lock.withLock { _deviceStatus = newValue } } }
    var appJSON: String { get { lock.withLock { _appJSON } } set { lock.withLock { _appJSON = newValue } } }
    var appStatus: Int { get { lock.withLock { _appStatus } } set { lock.withLock { _appStatus = newValue } } }
    var postStatus: Int { get { lock.withLock { _postStatus } } set { lock.withLock { _postStatus = newValue } } }
    var streamBytes: Int? { get { lock.withLock { _stream } } set { lock.withLock { _stream = newValue } } }
    var bytesWritten: Int { lock.withLock { _written } }
    var wsMode: WSMode { get { lock.withLock { _wsMode } } set { lock.withLock { _wsMode = newValue } } }

    var requests: [Request] { lock.withLock { _requests } }
    var posts: [Request] { requests.filter { $0.requestLine.hasPrefix("POST") } }
    /// Request lines of every WebSocket upgrade, e.g. `GET /api/v2/channels/samsung.remote.control?name=…&token=… HTTP/1.1`.
    var wsRequests: [String] { lock.withLock { _wsRequests } }
    /// Text of every frame the client sent.
    var emits: [String] { lock.withLock { _emits } }

    init() {
        (restFD, restPort) = Self.listen()
        (wsFD, wsPort) = Self.listen()
        let r = restFD, w = wsFD
        Thread.detachNewThread { [weak self] in
            while true { let c = accept(r, nil, nil); if c < 0 { return }; self?.serveREST(c) }
        }
        Thread.detachNewThread { [weak self] in
            while true {
                let c = accept(w, nil, nil); if c < 0 { return }
                Thread.detachNewThread { [weak self] in self?.serveWS(c) }
            }
        }
    }

    deinit { stop() }

    /// After this both ports refuse connections ("TV off").
    func stop() { stopREST(); stopWS() }
    func stopREST() { let f = lock.withLock { () -> Int32 in let f = restFD; restFD = -1; return f }; if f >= 0 { shutdown(f, SHUT_RDWR); close(f) } }
    func stopWS() {
        let (f, conns) = lock.withLock { () -> (Int32, [Int32]) in let f = wsFD; wsFD = -1; return (f, wsConns) }
        if f >= 0 { shutdown(f, SHUT_RDWR); close(f) }
        for c in conns { shutdown(c, SHUT_RDWR) }
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

    // MARK: HTTP

    private static func readHead(_ c: Int32) -> (head: String, rest: Data)? {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            if let r = data.range(of: Data("\r\n\r\n".utf8)) {
                return (String(decoding: data[..<r.lowerBound], as: UTF8.self), Data(data[r.upperBound...]))
            }
            let n = read(c, &buf, buf.count)
            if n <= 0 { return nil }
            data.append(contentsOf: buf[0..<n])
        }
    }

    private static func parseHead(_ head: String) -> (line: String, headers: [String: String]) {
        let lines = head.components(separatedBy: "\r\n")
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            if let i = l.firstIndex(of: ":") { headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) }
        }
        return (lines[0], headers)
    }

    private func serveREST(_ c: Int32) {
        defer { close(c) }
        var nosigpipe: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
        guard let (head, rest) = Self.readHead(c) else { return }
        let (line, headers) = Self.parseHead(head)
        let want = Int(headers["content-length"] ?? "0") ?? 0
        var body = rest
        var buf = [UInt8](repeating: 0, count: 4096)
        while body.count < want { let n = read(c, &buf, buf.count); if n <= 0 { break }; body.append(contentsOf: buf[0..<n]) }
        let (code, payload) = lock.withLock { () -> (Int, String) in
            _requests.append(.init(requestLine: line, headers: headers, body: body))
            if line.hasPrefix("POST") { return (_postStatus, "") }
            if line.hasPrefix("GET /api/v2/applications/") { return (_appStatus, _appJSON) }
            return (_deviceStatus, _deviceJSON)
        }
        if let total = streamBytes {
            let h = "HTTP/1.1 \(code) X\r\nContent-Length: \(total)\r\nConnection: close\r\n\r\n"
            guard h.withCString({ write(c, $0, strlen($0)) }) > 0 else { return }
            let chunk = [UInt8](repeating: 0x20, count: 65_536)
            var sent = 0
            while sent < total {
                let n = write(c, chunk, min(chunk.count, total - sent))
                if n <= 0 { break }
                sent += n
                lock.withLock { _written += n }
                usleep(1000)
            }
            return
        }
        let reply = "HTTP/1.1 \(code) X\r\nContent-Length: \(payload.utf8.count)\r\nConnection: close\r\n\r\n\(payload)"
        _ = reply.withCString { write(c, $0, strlen($0)) }
    }

    // MARK: WebSocket (RFC 6455, text frames only)

    private func serveWS(_ c: Int32) {
        defer { close(c) }
        var nosigpipe: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
        lock.withLock { wsConns.append(c) }
        guard let (head, rest) = Self.readHead(c) else { return }
        let (line, headers) = Self.parseHead(head)
        lock.withLock { _wsRequests.append(line) }
        let mode = wsMode
        if mode == .refuse { _ = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".withCString { write(c, $0, strlen($0)) }; return }
        guard let key = headers["sec-websocket-key"] else { return }
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        let up = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        guard up.withCString({ write(c, $0, strlen($0)) }) > 0 else { return }

        switch mode {
        case .connect(let token):
            let data = token.map { #","data":{"token":"\#($0)"}"# } ?? #","data":{}"#
            send(c, #"{"event":"ms.channel.connect"\#(data)}"#)
        case .unauthorized: send(c, #"{"event":"ms.channel.unauthorized","data":{}}"#)
        case .timeOut: send(c, #"{"event":"ms.channel.timeOut","data":{}}"#)
        case .bigFrame: send(c, #"{"event":"ms.channel.connect","pad":""# + String(repeating: "a", count: 100_000) + #""}"#)
        case .raw(let text): send(c, text)
        case .silence, .refuse: break
        }

        var buf = Data(rest)
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            while let (op, payload, used) = Self.parseFrame(buf) {
                buf.removeFirst(used)
                if op == 8 { return }
                if op == 1, payload.count <= 64 * 1024 { lock.withLock { _emits.append(String(decoding: payload, as: UTF8.self)) } }
            }
            let n = read(c, &chunk, chunk.count)
            if n <= 0 { return }
            buf.append(contentsOf: chunk[0..<n])
        }
    }

    /// One client frame (masked): (opcode, payload, bytes used), or nil when more bytes are needed.
    private static func parseFrame(_ b: Data) -> (UInt8, Data, Int)? {
        let b = [UInt8](b)
        guard b.count >= 2 else { return nil }
        let op = b[0] & 0x0F
        var len = Int(b[1] & 0x7F), i = 2
        if len == 126 { guard b.count >= 4 else { return nil }; len = Int(b[2]) << 8 | Int(b[3]); i = 4 }
        else if len == 127 { guard b.count >= 10 else { return nil }; len = (2..<10).reduce(0) { $0 << 8 | Int(b[$1]) }; i = 10 }
        let masked = b[1] & 0x80 != 0
        let key: [UInt8] = masked ? { guard b.count >= i + 4 else { return [] }; return Array(b[i..<i + 4]) }() : []
        if masked { guard key.count == 4 else { return nil }; i += 4 }
        guard b.count >= i + len else { return nil }
        var p = Array(b[i..<i + len])
        if masked { for j in 0..<p.count { p[j] ^= key[j % 4] } }
        return (op, Data(p), i + len)
    }

    private func send(_ c: Int32, _ text: String) {
        let p = Array(text.utf8)
        var f: [UInt8] = [0x81]
        if p.count < 126 { f.append(UInt8(p.count)) }
        else if p.count < 65_536 { f += [126, UInt8(p.count >> 8), UInt8(p.count & 0xFF)] }
        else { f.append(127); f += (0..<8).map { UInt8((p.count >> (8 * (7 - $0))) & 0xFF) } }
        f += p
        var sent = 0
        while sent < f.count { let n = f[sent...].withUnsafeBufferPointer { write(c, $0.baseAddress, $0.count) }; if n <= 0 { break }; sent += n }
    }
}
