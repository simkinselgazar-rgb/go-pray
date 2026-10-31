// CastServerTests.swift — the in-app video server (Google TV Plan §5/§6). Plain POSIX client on loopback, no TV.

import Testing
import Foundation
import Darwin
@testable import GoPray

@Suite(.serialized) struct CastServerTests {
    static let loopback = "127.0.0.1"
    private func allowLoopback(_ s: String) -> Bool { s == Self.loopback || TVHost.isAllowed(s) }

    private func makeFile(_ size: Int = 300_000) throws -> (URL, Data) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cast-test-\(UUID().uuidString).mp4")
        let data = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        try data.write(to: url)
        return (url, data)
    }

    private func server(maxLife: TimeInterval = 60, headTimeout: TimeInterval = 3) -> CastServer {
        CastServer(maxLife: maxLife, headTimeout: headTimeout, hostCheck: { [self] in allowLoopback($0) })
    }

    /// Opens a socket to loopback:port; nil if refused.
    private func connect(_ port: Int) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian; addr.sin_addr.s_addr = inet_addr(Self.loopback)
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if r != 0 { close(fd); return nil }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    /// Sends `request` and reads until the server closes. Empty when refused or closed without an answer.
    private func exchange(_ port: Int, _ request: String) -> Data {
        guard let fd = connect(port) else { return Data() }
        defer { close(fd) }
        _ = request.withCString { send(fd, $0, strlen($0), 0) }
        var out = Data(); var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        return out
    }

    private func split(_ raw: Data) -> (head: String, body: Data)? {
        guard let r = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        return (String(decoding: raw[..<r.lowerBound], as: UTF8.self), raw[r.upperBound...])
    }
    private func get(_ path: String, extra: String = "") -> String { "GET \(path) HTTP/1.1\r\nHost: x\r\n\(extra)\r\n" }

    @Test func rightPeerRightPathGetsTheFile() throws {
        let (file, data) = try makeFile(); defer { try? FileManager.default.removeItem(at: file) }
        let served = try server().serve(file: file, on: Self.loopback, forPeer: Self.loopback); defer { served.stop() }
        let u = served.url
        #expect(u.scheme == "http" && u.host == Self.loopback && u.path.hasPrefix("/a/") && u.path.hasSuffix(".mp4"))
        #expect(u.path.count == 3 + 32 + 4)
        let r = try #require(split(exchange(u.port!, get(u.path))))
        #expect(r.head.hasPrefix("HTTP/1.1 200"))
        #expect(r.head.contains("Content-Type: video/mp4") && r.head.contains("Content-Length: \(data.count)"))
        #expect(r.body == data)
    }

    @Test func wrongPathIs404() throws {
        let (file, _) = try makeFile(); defer { try? FileManager.default.removeItem(at: file) }
        let served = try server().serve(file: file, on: Self.loopback, forPeer: Self.loopback); defer { served.stop() }
        for p in ["/", "/a/00000000000000000000000000000000.mp4", served.url.path + "x", "/a/../etc/passwd", file.path] {
            let r = try #require(split(exchange(served.url.port!, get(p))))
            #expect(r.head.hasPrefix("HTTP/1.1 404"), "path \(p)")
            #expect(r.body.isEmpty)
        }
        // A method other than GET/HEAD on the right path is 404 too.
        let post = try #require(split(exchange(served.url.port!, "POST \(served.url.path) HTTP/1.1\r\n\r\n")))
        #expect(post.head.hasPrefix("HTTP/1.1 404"))
    }

    @Test func wrongPeerIsClosedWithoutAnAnswer() throws {
        let (file, _) = try makeFile(); defer { try? FileManager.default.removeItem(at: file) }
        // The TV is 10.9.9.9; we connect from 127.0.0.1.
        let served = try server().serve(file: file, on: Self.loopback, forPeer: "10.9.9.9"); defer { served.stop() }
        let raw = exchange(served.url.port!, get(served.url.path))
        #expect(raw.isEmpty)
    }

    @Test func rangeGetsThePlainFullBody() throws {
        let (file, data) = try makeFile(); defer { try? FileManager.default.removeItem(at: file) }
        let served = try server().serve(file: file, on: Self.loopback, forPeer: Self.loopback); defer { served.stop() }
        for range in ["bytes=0-", "bytes=100-200", "bytes=-5", "bytes=999999999-"] {
            let r = try #require(split(exchange(served.url.port!, get(served.url.path, extra: "Range: \(range)\r\n"))))
            #expect(r.head.hasPrefix("HTTP/1.1 200"), "range \(range)")
            #expect(r.head.contains("Accept-Ranges: none"))
            #expect(!r.head.contains("Content-Range"))
            #expect(r.body == data)
        }
    }

    @Test func headSendsHeadersOnly() throws {
        let (file, data) = try makeFile(); defer { try? FileManager.default.removeItem(at: file) }
        let served = try server().serve(file: file, on: Self.loopback, forPeer: Self.loopback); defer { served.stop() }
        let r = try #require(split(exchange(served.url.port!, "HEAD \(served.url.path) HTTP/1.1\r\n\r\n")))
        #expect(r.head.hasPrefix("HTTP/1.1 200") && r.head.contains("Content-Length: \(data.count)"))
        #expect(r.body.isEmpty)
    }

    @Test func afterStopTheConnectionIsRefused() throws {
        let (file, _) = try makeFile(); defer { try? FileManager.default.removeItem(at: file) }
        let served = try server().serve(file: file, on: Self.loopback, forPeer: Self.loopback)
        let port = served.url.port!
        #expect(connect(port).map { close($0) } != nil)          // up before stop
        served.stop(); served.stop()                               // safe to call twice
        #expect(refusedSoon(port))
    }

    @Test func theCapStopsItWithoutAnyoneAskingTo() throws {
        let (file, _) = try makeFile(); defer { try? FileManager.default.removeItem(at: file) }
        let served = try server(maxLife: 0.5).serve(file: file, on: Self.loopback, forPeer: Self.loopback); defer { served.stop() }
        let port = served.url.port!
        #expect(connect(port).map { close($0) } != nil)
        #expect(refusedSoon(port, within: 3))
    }

    @Test func aStalledHeadIsDropped() throws {
        let (file, _) = try makeFile(); defer { try? FileManager.default.removeItem(at: file) }
        let served = try server(headTimeout: 0.4).serve(file: file, on: Self.loopback, forPeer: Self.loopback); defer { served.stop() }
        let fd = try #require(connect(served.url.port!)); defer { close(fd) }
        var b = [UInt8](repeating: 0, count: 8)
        #expect(recv(fd, &b, 8, 0) == 0)                           // the server closed; we sent nothing
    }

    @Test func anOversizedHeadIsDropped() throws {
        let (file, _) = try makeFile(); defer { try? FileManager.default.removeItem(at: file) }
        let served = try server().serve(file: file, on: Self.loopback, forPeer: Self.loopback); defer { served.stop() }
        let raw = exchange(served.url.port!, "GET /" + String(repeating: "a", count: 5000))
        #expect(raw.isEmpty)
    }

    @Test func badAddressesAreRefusedBeforeAnySocket() throws {
        let (file, _) = try makeFile(); defer { try? FileManager.default.removeItem(at: file) }
        let strict = CastServer()                                  // production rule: no loopback, no public
        #expect(throws: CastServerError.refusedHost) { try strict.serve(file: file, on: Self.loopback, forPeer: "192.168.1.5") }
        #expect(throws: CastServerError.refusedHost) { try strict.serve(file: file, on: "192.168.1.5", forPeer: "8.8.8.8") }
        #expect(throws: CastServerError.noFile) { try self.server().serve(file: file.appendingPathExtension("x"), on: Self.loopback, forPeer: Self.loopback) }
    }

    @Test func eachServeGetsItsOwnPortAndPath() throws {
        let (file, _) = try makeFile(); defer { try? FileManager.default.removeItem(at: file) }
        let a = try server().serve(file: file, on: Self.loopback, forPeer: Self.loopback); defer { a.stop() }
        let b = try server().serve(file: file, on: Self.loopback, forPeer: Self.loopback); defer { b.stop() }
        #expect(a.url != b.url && a.url.path != b.url.path && a.url.port != b.url.port)
    }

    private func refusedSoon(_ port: Int, within seconds: Double = 1.5) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let fd = connect(port) { close(fd); Thread.sleep(forTimeInterval: 0.05) } else { return true }
        }
        return false
    }
}
