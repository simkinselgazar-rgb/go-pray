// SamsungTV.swift — the Samsung (Tizen) TV driver (Samsung TV Plan §3, §5, §7). The ONE Samsung network file.
//
// LAN only, same posture as RokuTV: hosts come only from Settings (an IPv4 literal in a private range, checked on every
// entry), 3 s, ephemeral sessions, no redirects, bodies read with a cap. This file has no hostname or URL literal.
//
// The wire contract (the Tizen app is built against exactly this):
//   Athan, TV paired:   wss://<ip>:8002/api/v2/channels/samsung.remote.control?name=<base64 "Go Pray">&token=<t>
//                       -> wait for ms.channel.connect -> send ms.channel.emit / ed.apps.launch / DEEP_LINK
//                          metaTag = prayer=<p>&voice=<v>[&test=1]            (the same query string the Roku gets)
//   Athan, not paired (or the socket failed before the send):  POST :8001/api/v2/applications/<appId>, empty body.
//   Never both when the socket send succeeded. A TV in standby is left alone. Only Settings (`pair`) ever opens a
//   socket without a token, so the TV's Allow box never appears at prayer time.
//
// TLS on 8002 is Samsung's self-signed certificate. The exception is as narrow as `SamsungTrust.decide` makes it:
// server-trust challenges only, the one IPv4 the person typed, port 8002, trust-on-first-use while pairing, then the
// leaf's SHA-256 is pinned and a different one cancels the connection.

import CryptoKit
import Foundation
import os

private let log = Logger(subsystem: "com.ahmedelgazar.gopray", category: "tv")

// MARK: - TLS trust (the whole exception)

enum SamsungTrust {
    enum Decision: Equatable {
        /// Trust this connection. `firstUse`: nothing was pinned yet, so the caller records the fingerprint.
        case use(firstUse: Bool)
        /// Not ours to excuse: the system's default check runs (and fails for a self-signed certificate).
        case defaultHandling
        /// A pinned TV showed a different certificate.
        case cancel
    }

    static func decide(method: String, host: String, port: Int, leafFingerprint: String?, stored: String?, allowedHost: String) -> Decision {
        guard method == NSURLAuthenticationMethodServerTrust,
              TVHost.isAllowed(allowedHost), host == allowedHost,
              port == SamsungTV.wssPort,
              let leaf = leafFingerprint else { return .defaultHandling }
        guard let stored else { return .use(firstUse: true) }
        return leaf == stored ? .use(firstUse: false) : .cancel
    }

    /// Lowercase hex SHA-256 of the leaf certificate's DER bytes.
    static func leafFingerprint(_ trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        return SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
    }
}

/// One per socket. Holds the one host it may excuse; never trusts a second host, a name, another port or a redirect.
final class SamsungTLSDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    enum Outcome: Equatable { case trust, defaultHandling, cancel }

    let allowedHost: String
    private let stored: String?
    private let allowFirstUse: Bool
    private let lock = NSLock()
    private var _observed: String?
    private var _mismatch = false

    /// `stored`: the pinned fingerprint (launch). nil + `allowFirstUse`: pairing, trust on first use.
    init(allowedHost: String, stored: String?, allowFirstUse: Bool) {
        self.allowedHost = allowedHost; self.stored = stored; self.allowFirstUse = allowFirstUse
    }

    /// The fingerprint recorded on first use.
    var observed: String? { lock.withLock { _observed } }
    /// A pinned TV showed a different certificate.
    var mismatch: Bool { lock.withLock { _mismatch } }

    func evaluate(method: String, host: String, port: Int, trust: SecTrust?) -> Outcome {
        let leaf = trust.flatMap(SamsungTrust.leafFingerprint)
        switch SamsungTrust.decide(method: method, host: host, port: port, leafFingerprint: leaf, stored: stored, allowedHost: allowedHost) {
        case .use(let firstUse):
            if firstUse {
                guard allowFirstUse else { return .defaultHandling }      // a launch never pins a new certificate
                lock.withLock { _observed = leaf }
            }
            return .trust
        case .defaultHandling: return .defaultHandling
        case .cancel:
            lock.withLock { _mismatch = true }
            log.error("tv: samsung cert changed, pair again")
            return .cancel
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        switch evaluate(method: space.authenticationMethod, host: space.host, port: space.port, trust: space.serverTrust) {
        case .trust:
            guard let trust = space.serverTrust else { completionHandler(.performDefaultHandling, nil); return }
            completionHandler(.useCredential, URLCredential(trust: trust))
        case .defaultHandling: completionHandler(.performDefaultHandling, nil)
        case .cancel: completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class SamsungNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// MARK: - What the TV says (untrusted bytes: caps, a few named fields, nothing else)

enum SamsungReply {
    static let maxFrameBytes = 64 * 1024
    static let maxStateLength = 20

    /// `device.PowerState` of `GET :8001/api/v2/`. nil when absent or unreadable.
    static func powerState(in data: Data) -> String? {
        guard data.count <= RokuApps.maxBytes, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let device = obj["device"] as? [String: Any], let s = device["PowerState"] as? String else { return nil }
        return String(s.prefix(maxStateLength))
    }

    /// `name` of `GET :8001/api/v2/applications/<id>`, at most `TVDevice.maxNameLength` characters. nil when the body is
    /// not a JSON object (or is over the cap); "" when it has no name.
    static func appName(in data: Data) -> String? {
        guard data.count <= RokuApps.maxBytes, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return String(((obj["name"] as? String) ?? "").prefix(TVDevice.maxNameLength))
    }

    /// One WebSocket text frame: the `event` and `data.token`, nothing else is read.
    static func frame(_ message: URLSessionWebSocketTask.Message) -> (event: String, token: String?)? {
        guard case .string(let text) = message, text.utf8.count <= maxFrameBytes,
              let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let event = obj["event"] as? String, event.count <= 64 else { return nil }
        return (event, (obj["data"] as? [String: Any])?["token"] as? String)
    }
}

// MARK: - The driver

struct SamsungTV: TVControlling {
    static let restPort = 8001
    static let wssPort = 8002

    let restPort: Int
    let wsPort: Int
    /// Production: `wss`. Tests inject `ws` to talk to a plain fake on localhost; the production check never takes one.
    let wsScheme: String
    /// Production: `TVHost.isAllowed`. Tests inject one that also lets 127.0.0.1 through.
    let hostCheck: @Sendable (String) -> Bool
    let session: URLSession
    let tokens: TokenStore
    /// Seconds to wait for `ms.channel.connect` when launching, and for the person to press Allow when pairing.
    let connectWait: Double
    let pairWait: Double
    /// Tests only (no TLS, so no certificate to pin): the fingerprint to store when pairing over `ws`.
    let pinOverride: String?

    init(restPort: Int = SamsungTV.restPort, wsPort: Int = SamsungTV.wssPort, wsScheme: String = "wss",
         hostCheck: @escaping @Sendable (String) -> Bool = TVHost.isAllowed, session: URLSession = SamsungTV.makeSession(),
         tokens: TokenStore = KeychainTokenStore(), connectWait: Double = 3, pairWait: Double = 30, pinOverride: String? = nil) {
        self.restPort = restPort; self.wsPort = wsPort; self.wsScheme = wsScheme; self.hostCheck = hostCheck
        self.session = session; self.tokens = tokens; self.connectWait = connectWait; self.pairWait = pairWait
        self.pinOverride = pinOverride
    }

    /// Ephemeral (no cookies, no cache), 3 s, no redirects.
    static func makeSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 3
        c.timeoutIntervalForResource = 3
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c, delegate: SamsungNoRedirects(), delegateQueue: nil)
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    private static func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }

    static func metaTag(prayer: Prayer, voice: Voice, test: Bool) -> String {
        "prayer=\(enc(prayer.rawValue))&voice=\(enc(RokuTV.voiceToken(voice)))" + (test ? "&test=1" : "")
    }

    // MARK: URLs

    private func restURL(_ tv: TVDevice, _ path: String) -> URL? {
        guard hostCheck(tv.host) else { return nil }
        var u = URLComponents()
        u.scheme = "http"; u.host = tv.host; u.port = restPort; u.percentEncodedPath = path
        return u.url
    }

    private func appURL(_ tv: TVDevice) -> URL? {
        guard TVDevice.isValidChannelId(tv.channelId, kind: .samsung) else { return nil }
        return restURL(tv, "/api/v2/applications/" + Self.enc(tv.channelId))
    }

    private func socketURL(_ tv: TVDevice, token: String?) -> URL? {
        guard hostCheck(tv.host) else { return nil }
        var u = URLComponents()
        u.scheme = wsScheme; u.host = tv.host; u.port = wsPort
        u.percentEncodedPath = "/api/v2/channels/samsung.remote.control"
        u.percentEncodedQuery = "name=" + Data("Go Pray".utf8).base64EncodedString() + (token.map { "&token=" + $0 } ?? "")
        return u.url
    }

    // MARK: Find the app

    /// `GET :8001/api/v2/applications/<id>`: 200 + a JSON object means installed, 404 means not.
    func findChannel(_ tv: TVDevice) async throws -> String? {
        guard hostCheck(tv.host) else { throw TVError.refusedHost }
        guard let url = appURL(tv) else { throw TVError.badURL }
        do {
            let (data, http) = try await RokuTV.readCapped(session, URLRequest(url: url, timeoutInterval: 3))
            if http.statusCode == 404 { return nil }
            guard http.statusCode == 200 else { throw TVError.badStatus(http.statusCode) }
            guard let data, SamsungReply.appName(in: data) != nil else { return nil }
            return tv.channelId
        } catch let e as TVError {
            throw e
        } catch {
            throw RokuTV.classify(error)
        }
    }

    // MARK: Launch

    func launch(_ tv: TVDevice, prayer: Prayer, voice: Voice, test: Bool = false) async throws {
        guard hostCheck(tv.host) else { throw TVError.refusedHost }
        guard let appURL = appURL(tv) else { throw TVError.badURL }

        // 1. Standby: leave the TV off. Absent or unreadable = proceed. A TV that does not answer at all throws.
        if try await powerState(tv) == "standby" {
            if test { throw TVError.standby }
            log.notice("tv: samsung standby, skipped")
            return
        }

        // 2. Paired: one launch over the socket.
        if let saved = tokens.load(tv.id) {
            do {
                try await launchOverSocket(tv, saved: saved, prayer: prayer, voice: voice, test: test)
                return
            } catch {
                log.error("tv: samsung socket launch failed, trying the basic launch: \(TVLog.describe(error), privacy: .public)")
            }
        }

        // 3. Not paired, or the socket failed before the send: the basic launch (no prayer or voice travels with it).
        var req = URLRequest(url: appURL, timeoutInterval: 3)
        req.httpMethod = "POST"
        req.setValue("0", forHTTPHeaderField: "Content-Length")
        do {
            let (_, resp) = try await session.bytes(for: req)            // headers only: the body is never read
            guard let http = resp as? HTTPURLResponse else { throw TVError.unreachable }
            guard (200..<300).contains(http.statusCode) else { throw TVError.badStatus(http.statusCode) }
        } catch let e as TVError {
            throw e
        } catch {
            throw RokuTV.classify(error)
        }
    }

    /// `GET :8001/api/v2/` → `device.PowerState`.
    private func powerState(_ tv: TVDevice) async throws -> String? {
        guard let url = restURL(tv, "/api/v2/") else { throw TVError.refusedHost }
        do {
            let (data, http) = try await RokuTV.readCapped(session, URLRequest(url: url, timeoutInterval: 3))
            guard http.statusCode == 200, let data else { return nil }
            return SamsungReply.powerState(in: data)
        } catch {
            throw RokuTV.classify(error)
        }
    }

    private func launchOverSocket(_ tv: TVDevice, saved: StoredTVToken, prayer: Prayer, voice: Voice, test: Bool) async throws {
        guard let url = socketURL(tv, token: saved.token) else { throw TVError.badURL }
        let delegate = SamsungTLSDelegate(allowedHost: tv.host, stored: saved.fingerprint, allowFirstUse: false)
        let (task, sess) = openSocket(url, delegate: delegate, seconds: connectWait * 2 + 2)
        defer { task.cancel(with: .normalClosure, reason: nil); sess.finishTasksAndInvalidate() }

        let emit: [String: Any] = [
            "method": "ms.channel.emit",
            "params": ["event": "ed.apps.launch", "to": "host",
                       "data": ["appId": tv.channelId, "action_type": "DEEP_LINK",
                                "metaTag": Self.metaTag(prayer: prayer, voice: voice, test: test)]],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: emit), let text = String(data: body, encoding: .utf8) else { throw TVError.badURL }
        do {
            try await Self.withDeadline(connectWait, onTimeout: { task.cancel(with: .goingAway, reason: nil) }) {
                while true {
                    let event = SamsungReply.frame(try await task.receive())?.event
                    if event == "ms.channel.connect" { return }
                    if event == "ms.channel.unauthorized" || event == "ms.channel.timeOut" { throw TVError.unreachable }
                }
            }
            try await Self.withDeadline(connectWait, onTimeout: { task.cancel(with: .goingAway, reason: nil) }) {
                try await task.send(.string(text))
            }
            try? await Task.sleep(for: .milliseconds(250))                // let the frame leave before the close
        } catch {
            throw delegate.mismatch ? TVError.certChanged : ((error as? TVError) ?? RokuTV.classify(error))
        }
    }

    // MARK: Pair (Settings only)

    /// Opens the socket WITHOUT a token: the TV shows Allow, and answers `ms.channel.connect` with a token.
    /// Trust on first use happens here and only here; the person is in the room pressing a remote.
    func pair(_ tv: TVDevice) async throws -> TVPairResult {
        guard hostCheck(tv.host) else { throw TVError.refusedHost }
        guard TVDevice.isValidChannelId(tv.channelId, kind: .samsung), let url = socketURL(tv, token: nil) else { throw TVError.badURL }
        let delegate = SamsungTLSDelegate(allowedHost: tv.host, stored: nil, allowFirstUse: true)
        let (task, sess) = openSocket(url, delegate: delegate, seconds: pairWait + 5)
        defer { task.cancel(with: .normalClosure, reason: nil); sess.finishTasksAndInvalidate() }

        let answer: (event: String, token: String?)
        do {
            answer = try await Self.withDeadline(pairWait, onTimeout: { task.cancel(with: .goingAway, reason: nil) }) { () -> (event: String, token: String?) in
                while true {
                    guard let f = SamsungReply.frame(try await task.receive()) else { continue }
                    if ["ms.channel.connect", "ms.channel.unauthorized", "ms.channel.timeOut"].contains(f.event) { return f }
                }
            }
        } catch TVError.unreachable where !delegate.mismatch {
            return .unsupported                                            // silence: nobody pressed Allow, or this TV never asks
        } catch {
            throw delegate.mismatch ? TVError.certChanged : ((error as? TVError) ?? RokuTV.classify(error))
        }
        switch answer.event {
        case "ms.channel.unauthorized": return .denied
        case "ms.channel.timeOut": return .unsupported
        default: break
        }
        guard let token = answer.token, TVTokenRules.isValidToken(token) else {
            log.error("tv: samsung gave no usable token")                  // never log the token itself
            return .unsupported
        }
        guard let fingerprint = delegate.observed ?? pinOverride else {
            log.error("tv: samsung certificate not seen, not saving a token")
            return .unsupported
        }
        guard tokens.save(tv.id, token: token, fingerprint: fingerprint) else {
            log.error("tv: samsung token could not be stored")
            return .unsupported
        }
        return .paired
    }

    func forget(_ tv: TVDevice) { tokens.delete(tv.id) }
    func isPaired(_ tv: TVDevice) -> Bool { tokens.load(tv.id) != nil }

    // MARK: Socket plumbing

    private func openSocket(_ url: URL, delegate: SamsungTLSDelegate, seconds: Double) -> (URLSessionWebSocketTask, URLSession) {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 3
        c.timeoutIntervalForResource = seconds
        c.waitsForConnectivity = false
        let sess = URLSession(configuration: c, delegate: delegate, delegateQueue: nil)
        let task = sess.webSocketTask(with: url)
        task.maximumMessageSize = SamsungReply.maxFrameBytes
        task.resume()
        return (task, sess)
    }

    /// Runs `op`; if it has not finished in `seconds`, calls `onTimeout` (which closes the socket so `op` ends) and throws.
    private static func withDeadline<T: Sendable>(_ seconds: Double, onTimeout: @escaping @Sendable () -> Void,
                                                  _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await op() }
            group.addTask { try await Task.sleep(for: .seconds(seconds)); return nil }
            defer { group.cancelAll() }
            if let first = try await group.next(), let value = first { return value }
            onTimeout()
            throw TVError.unreachable
        }
    }
}
