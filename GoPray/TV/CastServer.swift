// CastServer.swift — the tiny LAN web server that hands the one TV its one video (Google TV Plan §5).
// Up only during a cast. Bound to the one local address, an OS-picked port, one random path, one file, one peer IP.
// A `Range` header is ignored on purpose: the TV sends `Range: bytes=0-`, a plain 200 with the full body plays.

import Foundation
import Network
import os

private let log = Logger(subsystem: "com.ahmedelgazar.gopray", category: "tv")

enum CastServerError: Error, Equatable { case refusedHost, noFile, notReady }

final class CastServer: CastServing, @unchecked Sendable {
    static let maxConnections = 4
    static let maxHead = 2048
    static let chunk = 64 * 1024

    private let maxLife: TimeInterval
    private let headTimeout: TimeInterval
    private let hostCheck: @Sendable (String) -> Bool

    /// `hostCheck` is the address rule (`TVHost.isAllowed`); tests pass one that also accepts loopback.
    init(maxLife: TimeInterval = 8 * 60, headTimeout: TimeInterval = 3,
         hostCheck: @escaping @Sendable (String) -> Bool = TVHost.isAllowed) {
        self.maxLife = maxLife; self.headTimeout = headTimeout; self.hostCheck = hostCheck
    }

    func serve(file: URL, on localAddress: String, forPeer peer: String) throws -> CastServed {
        guard hostCheck(localAddress), hostCheck(peer) else { throw CastServerError.refusedHost }
        guard FileManager.default.isReadableFile(atPath: file.path) else { throw CastServerError.noFile }

        let token = Self.randomToken()
        let path = "/a/\(token).mp4"
        let queue = DispatchQueue(label: "gopray.cast-server")
        let params = NWParameters(tls: nil)
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(localAddress), port: .any)
        let listener = try NWListener(using: params)
        let session = Session(cancelListener: { listener.cancel() }, queue: queue, file: file, path: path, peer: peer, headTimeout: headTimeout)

        let ready = DispatchSemaphore(value: 0)
        let state = OSAllocatedUnfairLock(initialState: false)   // true once ready
        listener.stateUpdateHandler = { s in
            switch s {
            case .ready: state.withLock { $0 = true }; ready.signal()
            case .failed, .cancelled: ready.signal(); session.stop()
            default: break
            }
        }
        listener.newConnectionHandler = { session.accept($0) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3)
        guard state.withLock({ $0 }), let port = listener.port?.rawValue else {
            session.stop()
            throw CastServerError.notReady
        }
        queue.asyncAfter(deadline: .now() + maxLife) { session.stop() }   // the safety cap, whatever the cast does

        var c = URLComponents()
        c.scheme = "http"; c.host = localAddress; c.port = Int(port); c.path = path
        guard let url = c.url else { session.stop(); throw CastServerError.notReady }
        return CastServed(url: url) { session.stop() }
    }

    private static func randomToken() -> String {
        var g = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &g)) }.joined()
    }

    /// One serve() call's state. Everything runs on `queue`.
    private final class Session: @unchecked Sendable {
        let cancelListener: @Sendable () -> Void, queue: DispatchQueue, file: URL, path: String, peer: String, headTimeout: TimeInterval
        private var connections: [ObjectIdentifier: NWConnection] = [:]
        private var stopped = false
        private let stoppedFlag = OSAllocatedUnfairLock(initialState: false)

        init(cancelListener: @escaping @Sendable () -> Void, queue: DispatchQueue, file: URL, path: String, peer: String, headTimeout: TimeInterval) {
            self.cancelListener = cancelListener; self.queue = queue; self.file = file; self.path = path; self.peer = peer
            self.headTimeout = headTimeout
        }

        /// Safe from any thread, more than once.
        func stop() {
            guard stoppedFlag.withLock({ let was = $0; $0 = true; return !was }) else { return }
            queue.async { [self] in
                stopped = true
                cancelListener()
                for c in connections.values { c.cancel() }
                connections.removeAll()
            }
        }

        func accept(_ conn: NWConnection) {
            let id = ObjectIdentifier(conn)
            guard !stopped, connections.count < CastServer.maxConnections, remoteIPv4(conn) == peer else {
                conn.cancel(); return                                   // wrong peer or too many: closed before reading
            }
            connections[id] = conn
            conn.stateUpdateHandler = { [weak self] s in
                if case .cancelled = s { self?.queue.async { self?.connections[id] = nil } }
            }
            conn.start(queue: queue)
            let timeout = DispatchWorkItem { conn.cancel() }
            queue.asyncAfter(deadline: .now() + headTimeout, execute: timeout)
            readHead(conn, into: Data(), timeout: timeout)
        }

        private func remoteIPv4(_ conn: NWConnection) -> String? {
            guard case let .hostPort(host, _) = conn.endpoint, case let .ipv4(addr) = host else { return nil }
            return "\(addr)".split(separator: "%").first.map(String.init)
        }

        private func readHead(_ conn: NWConnection, into head: Data, timeout: DispatchWorkItem) {
            conn.receive(minimumIncompleteLength: 1, maximumLength: CastServer.maxHead) { [weak self] data, _, done, err in
                guard let self else { return }
                var buf = head
                if let data { buf.append(data) }
                if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                    timeout.cancel()
                    self.respond(conn, head: buf[..<end.lowerBound])
                } else if buf.count >= CastServer.maxHead || done || err != nil {
                    timeout.cancel(); conn.cancel()                      // too big, or gone, before a full head
                } else {
                    self.readHead(conn, into: buf, timeout: timeout)
                }
            }
        }

        private func respond(_ conn: NWConnection, head: Data) {
            let line = String(decoding: head, as: UTF8.self).split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
            let bits = line.split(separator: " ")
            guard bits.count == 3, bits[0] == "GET" || bits[0] == "HEAD", String(bits[1]) == path,
                  let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? Int else {
                send404(conn); return
            }
            let header = "HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: \(size)\r\nAccept-Ranges: none\r\nConnection: close\r\n\r\n"
            if bits[0] == "HEAD" {
                conn.send(content: Data(header.utf8), contentContext: .finalMessage, isComplete: true,
                          completion: .contentProcessed { _ in conn.cancel() })
                return
            }
            guard let fh = try? FileHandle(forReadingFrom: file) else { send404(conn); return }
            conn.send(content: Data(header.utf8), isComplete: false, completion: .contentProcessed { [weak self] err in
                guard err == nil else { try? fh.close(); conn.cancel(); return }
                self?.sendBody(conn, fh, total: size, sent: 0)
            })
        }

        private func sendBody(_ conn: NWConnection, _ fh: FileHandle, total: Int, sent: Int) {
            let piece = (try? fh.read(upToCount: CastServer.chunk)) ?? nil
            guard let piece, !piece.isEmpty else {
                try? fh.close()
                log.notice("tv: cast served \(sent, privacy: .public) of \(total, privacy: .public) bytes")
                conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
                return
            }
            conn.send(content: piece, isComplete: false, completion: .contentProcessed { [weak self] err in
                if err != nil { try? fh.close(); conn.cancel(); return }
                self?.sendBody(conn, fh, total: total, sent: sent + piece.count)
            })
        }

        private func send404(_ conn: NWConnection) {
            let body = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            conn.send(content: Data(body.utf8), contentContext: .finalMessage, isComplete: true,
                      completion: .contentProcessed { _ in conn.cancel() })
        }
    }
}
