// ShieldTestSupport.swift — helpers for the lane B tests. Owner: lane B.
// Nothing here puts a window on screen: panels are never ordered front (orderFront = false).

import AppKit
import WebKit
import Network
import Foundation
@testable import GoPray

@MainActor func until(_ seconds: Double = 5, _ cond: @MainActor () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if await cond() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return await cond()
}

/// True once bridge.js has built the `.block` UI in this web view.
@MainActor func blockBuilt(_ web: SceneWebView) async -> Bool {
    await web.js("String(!!document.querySelector('.block .ring-time'))") == "true"
}

extension WKWebView {
    /// Runs JS and returns the result as a string ("ERR: ..." when it throws).
    @MainActor func js(_ script: String) async -> String {
        await withCheckedContinuation { cont in
            evaluateJavaScript(script) { result, error in
                if let error { cont.resume(returning: "ERR: \(error.localizedDescription)") }
                else { cont.resume(returning: result.map { String(describing: $0) } ?? "nil") }
            }
        }
    }
}

@MainActor final class SpyDelegate: ShieldDelegate {
    var confirms = 0
    var silences = 0
    var onConfirm: (() -> Void)?
    func shieldDidRequestConfirm() { confirms += 1; onConfirm?() }
    func shieldDidRequestSilence() { silences += 1 }
}

@MainActor enum Fixture {
    static func ctx(_ prayer: Prayer = .dhuhr, mode: BlockMode = .wholeScreen, remainingMs: Int = 600_000,
                    athanMs: Int = 0, reduce: Bool = false, app: String? = nil) -> ShieldContext {
        ShieldContext(prayer: prayer, mode: mode, remainingMs: remainingMs, athanRemainingMs: athanMs,
                      reduceMotion: reduce, hiddenAppName: app)
    }

    static func display(_ id: UInt32, x: CGFloat = 0, w: CGFloat = 1440, h: CGFloat = 900) -> ShieldController.Display {
        .init(id: id, frame: NSRect(x: x, y: 0, width: w, height: h))
    }

    /// A controller that shows nothing on screen, activates nothing, touches no presentation options.
    static func controller(displays: [ShieldController.Display] = [display(1)],
                                      scenesRoot: URL = SceneWebView.bundledScenesRoot) -> ShieldController {
        var o = ShieldController.Options()
        o.activate = false
        o.presentationOptions = nil
        o.orderFront = false
        o.fadeSeconds = 0
        o.scenesRoot = scenesRoot
        o.displays = { displays }
        return ShieldController(options: o)
    }

    /// Fixtures copied into the test bundle at build time ("Copy test fixtures" phase):
    /// `check-manifest.sh`, and `design-scenes/` when the design folder exists. Tests never
    /// read the source tree at run time (it lives under ~/Documents).
    static var fixtures: URL {
        Bundle(for: FixtureBundleToken.self).resourceURL!.appendingPathComponent("Fixtures", isDirectory: true)
    }

    /// A scratch scenes folder with the given files, for pages that must not ship.
    static func scratchScenes(_ files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gopray-scenes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, body) in files { try body.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        return dir
    }

    /// The CSP string exactly as shipped in shield.html.
    static func shippedCSP() throws -> String {
        let html = try String(contentsOf: SceneWebView.bundledScenesRoot.appendingPathComponent("shield.html"), encoding: .utf8)
        let r = try #require(html.range(of: #"Content-Security-Policy" content=""#))
        let rest = html[r.upperBound...]
        return String(rest[..<rest.firstIndex(of: "\"")!])
    }
}

import Testing

private final class FixtureBundleToken {}

/// A local HTTP listener that counts connections. Proof that a blocked request never left the page.
final class HitCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _paths: [String] = []
    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    var hits: Int { lock.lock(); defer { lock.unlock() }; return _paths.count }
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return _paths }

    func start() async throws {
        let l = try NWListener(using: .tcp, on: .any)
        l.newConnectionHandler = { [weak self] conn in
            guard let me = self else { return }
            conn.start(queue: .global())
            conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                let line = data.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: "\r\n").first.map(String.init) ?? "?"
                me.lock.lock(); me._paths.append(line); me.lock.unlock()
                conn.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                          completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        let ready = AsyncStream<Void> { cont in
            l.stateUpdateHandler = { if case .ready = $0 { cont.yield(); cont.finish() } }
        }
        l.start(queue: .global())
        for await _ in ready { break }
        port = l.port?.rawValue ?? 0
        listener = l
    }

    func stop() { listener?.cancel() }
}
