// TVController.swift — "start the TV at each Athan" (TV Plan §3, CONTRACT-NOTES #56). The ONE TV network file.
//
// LAN only. The block never waits on the TV: the gate calls `athanStarted`, which returns at once and sends on
// a background task with a 3 s timeout. Every failure is one log line and nothing else.
// Hosts come ONLY from Settings (`TVDevice.host`, an IPv4 literal in a private range). This file has no
// hostname or URL literal; guard.sh checks that. Roku's ECP has no auth, so we add nothing to it.
//
// The wire contract (the Roku channel is built against exactly this):
//   POST http://<roku-ip>:8060/launch/<channelId>?prayer=<p>&voice=<v>     (empty body)
//   p = fajr|dhuhr|asr|maghrib|isha     v = sunni.<stem> | shia.<stem>     values URL-encoded
//
// Seam for another make later: add a `TVKind` case and one more `TVControlling` in `TVController.drivers`.

import Darwin
import Foundation
import os

private let log = Logger(subsystem: "com.ahmedelgazar.gopray", category: "tv")

// MARK: - Seams

enum TVError: Error, Equatable { case refusedHost, badURL, badStatus(Int), unreachable, localNetworkDenied }

/// macOS Local Network privacy refuses the app until the person allows it. It shows up as -1009 whose underlying
/// network path says "Local network prohibited" (checked live on macOS 26), or as errno 65 on a raw socket.
func tvIsLocalNetworkDenial(_ error: Error) -> Bool {
    let e = error as NSError
    return e.domain == NSURLErrorDomain && e.code == NSURLErrorNotConnectedToInternet && "\(e)".contains("Local network prohibited")
}

/// One make of TV. `launch` throws on any failure; the caller turns that into a log line.
/// Every driver MUST refuse a `tv.host` that `TVHost.isAllowed` does not accept (RokuTV does it in `launchURL`).
protocol TVControlling: Sendable {
    /// The id of the Go Pray app installed on this TV (a published numeric id beats `dev`), nil if none. Throws if unreachable.
    func findChannel(_ tv: TVDevice) async throws -> String?
    /// `test` = the Settings Test button: adds `&test=1` so the channel knows it is not an Athan. Athans never send it.
    func launch(_ tv: TVDevice, prayer: Prayer, voice: Voice, test: Bool) async throws
}

/// What the gate and the Settings Test button talk to.
enum TVResolution: Equatable, Sendable { case found(String), notInstalled, unreachable, localNetworkDenied }

/// A scan: the Rokus found, and whether macOS refused the network (Local Network not allowed yet).
struct TVScan: Equatable, Sendable { var found: [FoundTV] = []; var denied = false }

protocol TVSending: Sendable {
    /// Asks the TV which Go Pray app it has. Used when a TV is added and on the Test button, never on the Athan path.
    func resolve(_ tv: TVDevice) async -> TVResolution
    /// Fire and forget: every enabled TV, background, never throws, never waits. The gate calls this.
    func athanStarted(prayer: Prayer, voice: Voice, tvs: [TVDevice])
    /// The Test button: one TV (even if switched off), and the caller sees whether it worked.
    func test(_ tv: TVDevice, prayer: Prayer, voice: Voice) async throws
}

protocol TVDiscovering: Sendable {
    func scan() async -> TVScan
}

struct NoTV: TVSending, TVDiscovering {
    func athanStarted(prayer: Prayer, voice: Voice, tvs: [TVDevice]) {}
    func resolve(_ tv: TVDevice) async -> TVResolution { .unreachable }
    func test(_ tv: TVDevice, prayer: Prayer, voice: Voice) async throws { throw TVError.unreachable }
    func scan() async -> TVScan { TVScan() }
}

// MARK: - Roku

struct RokuTV: TVControlling {
    static let ecpPort = 8060

    let port: Int
    /// Production: `TVHost.isAllowed`. Tests inject one that also lets 127.0.0.1 through; the production check never does.
    let hostCheck: @Sendable (String) -> Bool
    let session: URLSession

    init(port: Int = RokuTV.ecpPort, hostCheck: @escaping @Sendable (String) -> Bool = TVHost.isAllowed,
         session: URLSession = RokuTV.makeSession()) {
        self.port = port; self.hostCheck = hostCheck; self.session = session
    }

    /// Ephemeral (no cookies, no cache), 3 s, no redirects.
    static func makeSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 3
        c.timeoutIntervalForResource = 3
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c, delegate: NoRedirects(), delegateQueue: nil)
    }

    /// `sunni.<stem>` / `shia.<stem>`: the same stem as the Mac's `Resources/athan/{sunni,shia}/<stem>.mp3`.
    static func voiceToken(_ voice: Voice) -> String {
        switch voice {
        case .sunni(let stem): return "sunni.\(stem)"
        case .shia(let stem): return "shia.\(stem)"
        }
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    private static func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }

    /// nil when the host is refused or the channel id is not a plain word/number.
    func launchURL(_ tv: TVDevice, prayer: Prayer, voice: Voice, test: Bool = false) -> URL? {
        guard hostCheck(tv.host), TVDevice.isValidChannelId(tv.channelId) else { return nil }
        var u = URLComponents()
        u.scheme = "http"
        u.host = tv.host
        u.port = port
        u.percentEncodedPath = "/launch/" + Self.enc(tv.channelId)
        u.percentEncodedQuery = "prayer=\(Self.enc(prayer.rawValue))&voice=\(Self.enc(Self.voiceToken(voice)))" + (test ? "&test=1" : "")
        return u.url
    }

    /// The body, read as it arrives and abandoned (nil) the moment it passes `RokuApps.maxBytes`: a TV on the LAN
    /// cannot make us buffer more than the cap, whatever it sends in the 3 s timeout.
    static func readCapped(_ session: URLSession, _ req: URLRequest) async throws -> (Data?, HTTPURLResponse) {
        let (bytes, resp) = try await session.bytes(for: req)
        guard let http = resp as? HTTPURLResponse else { throw TVError.unreachable }
        var data = Data()
        for try await b in bytes {
            data.append(b)
            if data.count > RokuApps.maxBytes { return (nil, http) }
        }
        return (data, http)
    }

    static func classify(_ error: Error) -> TVError {
        if tvIsLocalNetworkDenial(error) { log.error("tv request refused: local network not allowed"); return .localNetworkDenied }
        log.error("tv request failed: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
        return .unreachable
    }

    /// `GET :8060/query/apps`. The XML is untrusted LAN input: XMLParser (no external entities), a size cap, only
    /// apps whose name starts with "Go Pray", only ids matching `TVDevice.isValidChannelId`.
    func findChannel(_ tv: TVDevice) async throws -> String? {
        guard hostCheck(tv.host) else { throw TVError.refusedHost }
        var u = URLComponents()
        u.scheme = "http"; u.host = tv.host; u.port = port; u.path = "/query/apps"
        guard let url = u.url else { throw TVError.badURL }
        var req = URLRequest(url: url, timeoutInterval: 3)
        req.httpMethod = "GET"
        do {
            let (data, http) = try await Self.readCapped(session, req)
            guard http.statusCode == 200 else { throw TVError.badStatus(http.statusCode) }
            guard let data else { return nil }          // over the cap: junk, same as an unreadable list
            return RokuApps.goPrayChannel(in: data)
        } catch let e as TVError {
            throw e
        } catch {
            throw Self.classify(error)
        }
    }

    /// The id of the app on screen, from `GET :8060/query/active-app` (bounded read, XMLParser). nil on any error.
    func activeAppID(_ tv: TVDevice) async -> String? {
        var u = URLComponents()
        u.scheme = "http"; u.host = tv.host; u.port = port; u.path = "/query/active-app"
        guard hostCheck(tv.host), let url = u.url,
              let (data, http) = try? await Self.readCapped(session, URLRequest(url: url, timeoutInterval: 3)),
              http.statusCode == 200, let data else { return nil }
        return RokuApps.activeAppID(in: data)
    }

    func launch(_ tv: TVDevice, prayer: Prayer, voice: Voice, test: Bool = false) async throws {
        guard hostCheck(tv.host) else { throw TVError.refusedHost }
        guard let url = launchURL(tv, prayer: prayer, voice: voice, test: test) else { throw TVError.badURL }
        // A repeat /launch restarts the channel (a short audio gap), so an Athan launch first looks at what is on
        // screen. Any error here means: send the launch anyway (the TV de-dupes as the backstop). Test always sends.
        if !test, await activeAppID(tv) == tv.channelId { log.notice("tv: already playing"); return }
        var req = URLRequest(url: url, timeoutInterval: 3)
        req.httpMethod = "POST"
        req.setValue("0", forHTTPHeaderField: "Content-Length")
        do {
            let (_, resp) = try await session.bytes(for: req)       // headers only: the body is never read
            guard let http = resp as? HTTPURLResponse else { throw TVError.unreachable }
            guard (200..<300).contains(http.statusCode) else { throw TVError.badStatus(http.statusCode) }
        } catch let e as TVError {
            throw e
        } catch {
            throw Self.classify(error)
        }
    }
}

/// Reads `<apps><app id="…">Name</app>…</apps>`.
enum RokuApps {
    static let maxBytes = 512 * 1024
    static let namePrefix = "Go Pray"

    /// The first `<app id="…">` of an `active-app` reply.
    static func activeAppID(in data: Data) -> String? { parse(data).first?.id }

    private static func parse(_ data: Data) -> [(id: String, name: String)] {
        guard data.count <= maxBytes else { return [] }
        let reader = Reader()
        let p = XMLParser(data: data)
        p.shouldResolveExternalEntities = false
        p.delegate = reader
        p.parse()                       // a parse error keeps what was read so far; ids are validated by the callers
        return reader.apps
    }

    static func goPrayChannel(in data: Data) -> String? {
        let ids = parse(data).filter { $0.name.hasPrefix(namePrefix) && TVDevice.isValidChannelId($0.id) }.map(\.id)
        return ids.first { $0 != TVDevice.defaultChannelId } ?? ids.first
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var apps: [(id: String, name: String)] = []
        private var id: String?
        private var text = ""
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            guard name == "app" else { return }
            id = attributes["id"]; text = ""
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if id != nil { text += string } }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard name == "app", let id else { return }
            apps.append((id, text.trimmingCharacters(in: .whitespacesAndNewlines)))
            self.id = nil
        }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// MARK: - The controller

struct TVController: TVSending {
    let drivers: [TVKind: any TVControlling]

    init(drivers: [TVKind: any TVControlling] = [.roku: RokuTV()]) { self.drivers = drivers }

    func athanStarted(prayer: Prayer, voice: Voice, tvs: [TVDevice]) {
        for tv in tvs where tv.enabled {
            guard tv.installed else { log.error("tv skipped: Go Pray is not installed on it"); continue }
            guard let driver = drivers[tv.kind] else { log.error("tv skipped: no driver"); continue }
            Task.detached(priority: .utility) {
                do { try await driver.launch(tv, prayer: prayer, voice: voice, test: false) }
                catch { log.error("tv launch failed: \(String(describing: error), privacy: .public)") }
            }
        }
    }

    func resolve(_ tv: TVDevice) async -> TVResolution {
        guard let driver = drivers[tv.kind] else { return .unreachable }
        do {
            if let id = try await driver.findChannel(tv) { return .found(id) }
            return .notInstalled
        } catch {
            return (error as? TVError) == .localNetworkDenied ? .localNetworkDenied : .unreachable
        }
    }

    func test(_ tv: TVDevice, prayer: Prayer, voice: Voice) async throws {
        guard let driver = drivers[tv.kind] else { throw TVError.badURL }
        try await driver.launch(tv, prayer: prayer, voice: voice, test: true)
    }
}

// MARK: - Finding Rokus (SSDP, then device-info for the name)

struct RokuDiscovery: TVDiscovering {
    static let searchSeconds = 3
    private static let ssdpGroup = "239.255.255.250"
    private static let ssdpPort: UInt16 = 1900

    let session: URLSession
    let port: Int
    init(session: URLSession = RokuTV.makeSession(), port: Int = RokuTV.ecpPort) { self.session = session; self.port = port }

    func scan() async -> TVScan {
        let (hosts, denied) = await withCheckedContinuation { (k: CheckedContinuation<([String], Bool), Never>) in
            DispatchQueue.global(qos: .userInitiated).async { k.resume(returning: Self.search()) }
        }
        let found = await withTaskGroup(of: FoundTV.self) { group in
            for h in hosts { group.addTask { FoundTV(host: h, name: await self.friendlyName(h) ?? "Roku TV") } }
            var out: [FoundTV] = []
            for await tv in group { out.append(tv) }
            return out.sorted { $0.host < $1.host }
        }
        return TVScan(found: found, denied: denied)
    }

    /// M-SEARCH for `roku:ecp`. The address comes from the datagram's sender, never from the LOCATION header.
    static func search() -> (hosts: [String], denied: Bool) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { log.error("scan: no socket"); return ([], false) }
        defer { close(fd) }

        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = ssdpPort.bigEndian
        guard inet_pton(AF_INET, ssdpGroup, &dest.sin_addr) == 1 else { return ([], false) }

        let msg = "M-SEARCH * HTTP/1.1\r\nHOST: \(ssdpGroup):\(ssdpPort)\r\nMAN: \"ssdp:discover\"\r\nST: roku:ecp\r\nMX: 2\r\n\r\n"
        let sent = msg.withCString { p in
            withUnsafePointer(to: &dest) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, p, strlen(p), 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent > 0 else {
            let denied = errno == EHOSTUNREACH         // 65: what Local Network privacy gives a raw socket (checked live)
            log.error("scan: send failed errno \(errno)")
            return ([], denied)
        }

        var found: [String] = []
        let deadline = Date().addingTimeInterval(TimeInterval(searchSeconds))
        var buf = [UInt8](repeating: 0, count: 2048)
        while true {
            let left = Int(deadline.timeIntervalSinceNow * 1000)
            if left <= 0 { break }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, Int32(left)) > 0 else { break }
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &fromLen) }
            }
            guard n > 0 else { continue }
            let text = String(decoding: buf[0..<n], as: UTF8.self).lowercased()
            guard text.contains("roku:ecp") else { continue }
            var addr = from.sin_addr
            var out = [CChar](repeating: 0, count: 16)
            guard inet_ntop(AF_INET, &addr, &out, 16) != nil else { continue }
            let host = String(cString: out)
            if TVHost.isAllowed(host), !found.contains(host) { found.append(host) }
        }
        return (found, false)
    }

    func friendlyName(_ host: String) async -> String? {
        var u = URLComponents()
        u.scheme = "http"; u.host = host; u.port = port; u.path = "/query/device-info"
        guard let url = u.url, let (data, http) = try? await RokuTV.readCapped(session, URLRequest(url: url, timeoutInterval: 3)),
              http.statusCode == 200, let data else { return nil }
        let xml = String(decoding: data, as: UTF8.self)
        for tag in ["user-device-name", "friendly-device-name", "model-name"] {
            if let v = Self.element(tag, in: xml) { return String(v.prefix(TVDevice.maxNameLength)) }
        }
        return nil
    }

    static func element(_ tag: String, in xml: String) -> String? {
        guard let a = xml.range(of: "<\(tag)>"), let b = xml.range(of: "</\(tag)>", range: a.upperBound..<xml.endIndex) else { return nil }
        let v = xml[a.upperBound..<b.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }
}
