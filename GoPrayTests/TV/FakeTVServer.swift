// FakeTVServer.swift — a tiny HTTP server on 127.0.0.1 that records requests, so the TV tests send real
// bytes over a real socket. Test target only: the production address check never lets 127.0.0.1 through.

import Darwin
import Foundation

final class FakeTVServer: @unchecked Sendable {
    struct Request: Equatable { var requestLine: String; var headers: [String: String]; var body: Data }

    private let lock = NSLock()
    private var fd: Int32 = -1
    private var _requests: [Request] = []
    /// Status line code the server answers with.
    var status: Int { get { lock.withLock { _status } } set { lock.withLock { _status = newValue } } }
    private var _status = 200
    /// What `GET /query/apps` answers with.
    var appsXML: String { get { lock.withLock { _apps } } set { lock.withLock { _apps = newValue } } }
    private var _apps = "<apps/>"
    /// When set, every reply claims this many body bytes and streams them in 64 KB chunks until the client goes away.
    var streamBytes: Int? { get { lock.withLock { _stream } } set { lock.withLock { _stream = newValue } } }
    private var _stream: Int?
    private var _written = 0
    /// Body bytes the server managed to write before the client hung up.
    var bytesWritten: Int { lock.withLock { _written } }
    /// What `GET /query/active-app` answers with, and its status (default: nothing useful, 200).
    var activeXML: String { get { lock.withLock { _active } } set { lock.withLock { _active = newValue } } }
    private var _active = ""
    var activeStatus: Int? { get { lock.withLock { _activeStatus } } set { lock.withLock { _activeStatus = newValue } } }
    private var _activeStatus: Int?
    var posts: [Request] { requests.filter { $0.requestLine.hasPrefix("POST") } }
    private(set) var port: Int = 0
    var requests: [Request] { lock.withLock { _requests } }

    init() {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(fd, 8)
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        port = Int(UInt16(bigEndian: bound.sin_port))
        let listener = fd
        Thread.detachNewThread { [weak self] in
            while true {
                let c = accept(listener, nil, nil)
                if c < 0 { return }
                self?.serve(c)
            }
        }
    }

    deinit { stop() }

    /// After this the port refuses connections ("TV off").
    func stop() {
        let f = lock.withLock { () -> Int32 in let f = fd; fd = -1; return f }
        if f >= 0 { shutdown(f, SHUT_RDWR); close(f) }
    }

    private func serve(_ c: Int32) {
        defer { close(c) }
        var nosigpipe: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        var headEnd: Range<Data.Index>?
        while headEnd == nil {
            let n = read(c, &buf, buf.count)
            if n <= 0 { return }
            data.append(contentsOf: buf[0..<n])
            headEnd = data.range(of: Data("\r\n\r\n".utf8))
        }
        let head = String(decoding: data[..<headEnd!.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            if let i = l.firstIndex(of: ":") { headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) }
        }
        let want = Int(headers["content-length"] ?? "0") ?? 0
        var body = Data(data[headEnd!.upperBound...])
        while body.count < want {
            let n = read(c, &buf, buf.count)
            if n <= 0 { break }
            body.append(contentsOf: buf[0..<n])
        }
        let (code, payload) = lock.withLock { () -> (Int, String) in
            _requests.append(.init(requestLine: lines[0], headers: headers, body: body))
            if lines[0].hasPrefix("GET /query/active-app") { return (_activeStatus ?? _status, _active) }
            return (_status, lines[0].hasPrefix("GET /query/apps") ? _apps : "")
        }
        if let total = streamBytes {
            let head = "HTTP/1.1 \(code) X\r\nContent-Length: \(total)\r\nConnection: close\r\n\r\n"
            guard head.withCString({ write(c, $0, strlen($0)) }) > 0 else { return }
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
}
