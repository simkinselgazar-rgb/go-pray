// WebLockdownTests.swift — lane B: the WKWebView lockdown and its negative controls
// (Architecture Plan §G, §E lane B). Every attack is aimed at a local listener that counts
// connections, so "blocked" means "no connection was ever made", not "the page said so".

import Testing
import AppKit
import WebKit
@testable import GoPray

private let hostileJS = """
(function () {
  var base = new URLSearchParams(location.search).get('t');
  var port = base.split(':').pop();
  var out = {};
  function attempt(name, fn) {
    try { var r = fn(); out[name] = 'ran'; if (r && r.catch) r.catch(function () { out[name] = 'rejected'; }); }
    catch (e) { out[name] = 'threw:' + e.name; }
  }
  window.__out = out;
  attempt('fetch', function () { return fetch(base + '/fetch'); });
  attempt('xhr', function () { var x = new XMLHttpRequest(); x.open('GET', base + '/xhr'); x.send(); });
  attempt('beacon', function () { return navigator.sendBeacon(base + '/beacon', 'x'); });
  attempt('websocket', function () { return new WebSocket('ws://127.0.0.1:' + port + '/ws'); });
  attempt('script', function () { var s = document.createElement('script'); s.src = base + '/remote.js'; document.head.appendChild(s); });
  attempt('img', function () { var i = new Image(); i.src = base + '/img'; document.body.appendChild(i); });
  attempt('css', function () { var l = document.createElement('link'); l.rel = 'stylesheet'; l.href = base + '/css'; document.head.appendChild(l); });
  attempt('font', function () { var st = document.createElement('style'); st.textContent = "@font-face{font-family:x;src:url(" + base + "/font)} body{font-family:x}"; document.head.appendChild(st); });
  attempt('iframe', function () { var f = document.createElement('iframe'); f.src = base + '/iframe'; document.body.appendChild(f); });
  attempt('form', function () { var f = document.createElement('form'); f.action = base + '/form'; f.method = 'post'; document.body.appendChild(f); f.submit(); });
  attempt('anchor_blank', function () { var a = document.createElement('a'); a.href = base + '/anchor'; a.target = '_blank'; document.body.appendChild(a); a.click(); });
  attempt('window_open', function () { return window.open(base + '/open'); });
  attempt('outside_file_script', function () { var s = document.createElement('script'); s.src = new URLSearchParams(location.search).get('outside'); document.head.appendChild(s); });
  attempt('location', function () { location = base + '/location'; });
})();
"""

@MainActor @Suite("Web lockdown", .serialized)
struct WebLockdownTests {
    /// A scratch scenes folder: hostile.html (shipped CSP), nocsp.html (no CSP), hostile.js, plus a canary
    /// script OUTSIDE the folder that must never run.
    struct Rig {
        let root: URL; let outsideScript: URL
        func cleanup() { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outsideScript.deletingLastPathComponent()) }
    }

    static func rig() throws -> Rig {
        let csp = try Fixture.shippedCSP()
        let page = { (meta: String) in "<!doctype html><html><head><meta charset=utf-8>\(meta)</head><body><script src=\"hostile.js\"></script></body></html>" }
        let root = try Fixture.scratchScenes([
            "hostile.html": page("<meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\">"),
            "nocsp.html": page(""),
            "hostile.js": hostileJS,
        ])
        let outsideDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/gopray-lockdown-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        let canary = outsideDir.appendingPathComponent("canary.js")
        try "window.__canary = 'RAN';".write(to: canary, atomically: true, encoding: .utf8)
        return Rig(root: root, outsideScript: canary)
    }

    func attackQuery(_ hits: HitCounter, _ rig: Rig) -> String {
        let t = "http://127.0.0.1:\(hits.port)"
        let outside = rig.outsideScript.absoluteString
        return "t=\(t.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)&outside=\(outside.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)"
    }

    /// Loads a page in a locked SceneWebView, waits, returns it.
    func runLocked(page: String, hits: HitCounter, rig: Rig) async throws -> SceneWebView {
        let web = SceneWebView(scenesRoot: rig.root)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = web
        var finished = false
        web.onNavigationFinished = { finished = true }
        // `t` is percent-encoded once for the query; the page reads it back with URLSearchParams
        web.load(query: attackQuery(hits, rig), page: page)
        #expect(await until(5) { finished })
        try? await Task.sleep(for: .milliseconds(1500))     // let every attempt (and any request) happen
        return web
    }

    // MARK: the lockdown holds

    @Test func everyAttackIsBlockedAndNothingLeavesTheMachine() async throws {
        let hits = HitCounter(); try await hits.start(); defer { hits.stop() }
        let rig = try Self.rig(); defer { rig.cleanup() }
        let web = try await runLocked(page: "hostile.html", hits: hits, rig: rig)
        defer { web.shutDown() }

        let out = await web.js("JSON.stringify(window.__out)")
        print("INFO attempts: \(out)")
        print("INFO listener hits: \(hits.hits) \(hits.paths)")
        print("INFO blocked navigations: \(web.blockedNavigations)")
        #expect(hits.hits == 0, "the listener saw: \(hits.paths)")
        // the page is still our page
        let href = await web.js("location.pathname")
        #expect(href.hasSuffix("/hostile.html"))
        // `location = https://…` reached the navigation policy and was cancelled
        #expect(web.blockedNavigations.contains { $0.hasSuffix("/location") })
        // the canary outside the scenes folder did not run (read access = scenes only)
        #expect(await web.js("String(window.__canary)") == "undefined")
        // no popup was created
        #expect(web.blockedPopups >= 0)
        #expect(await web.js("String(window.open('http://127.0.0.1/x'))") == "null")
    }

    @Test func lockdownCSPIsWhatStopsSubresourcesNavigationPolicyIsWhatStopsNavigation() async throws {
        // Negative control 1: the same attacks on a page WITHOUT the CSP, in the locked web view.
        // Subresources get through (so the listener works and the attacks are real) ...
        let hits = HitCounter(); try await hits.start(); defer { hits.stop() }
        let rig = try Self.rig(); defer { rig.cleanup() }
        let web = try await runLocked(page: "nocsp.html", hits: hits, rig: rig)
        defer { web.shutDown() }
        print("INFO no-CSP page, locked view: hits=\(hits.hits) \(hits.paths.map { String($0.prefix(40)) })")
        #expect(hits.hits > 0, "without the CSP the attacks must reach the listener, or this suite proves nothing")
        // ... but top-level navigation, popups and forms are still cancelled by the policy.
        #expect(!hits.paths.contains { $0.contains("/location") })
        #expect(!hits.paths.contains { $0.contains("/form") })
        #expect(web.blockedNavigations.contains { $0.hasSuffix("/location") })
    }

    @Test func aPlainWebViewLeaksEverything() async throws {
        // Negative control 2: no lockdown at all.
        let hits = HitCounter(); try await hits.start(); defer { hits.stop() }
        let rig = try Self.rig(); defer { rig.cleanup() }
        let plain = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let page = rig.root.appendingPathComponent("nocsp.html").absoluteString + "?" + attackQuery(hits, rig)
        plain.loadFileURL(URL(string: page)!, allowingReadAccessTo: rig.root.deletingLastPathComponent())
        try? await Task.sleep(for: .milliseconds(2500))
        print("INFO plain web view: hits=\(hits.hits)")
        #expect(hits.hits > 0)
    }

    // MARK: drag and drop, context menu

    @Test func fileDropAndContextMenuAreRefused() throws {
        let web = SceneWebView()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = web
        web.registerForDraggedTypes([.fileURL, .URL, .string])
        #expect(web.registeredDraggedTypes.isEmpty)

        let drop = FakeDrag(file: URL(fileURLWithPath: "/etc/hosts"), window: win)
        #expect(web.draggingEntered(drop).isEmpty)
        #expect(web.draggingUpdated(drop).isEmpty)
        #expect(!web.prepareForDragOperation(drop))
        #expect(!web.performDragOperation(drop))

        let ev = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(web.menu(for: ev) == nil)
        let menu = NSMenu(); menu.addItem(withTitle: "Reload", action: nil, keyEquivalent: ""); menu.addItem(withTitle: "Inspect Element", action: nil, keyEquivalent: "")
        web.willOpenMenu(menu, with: ev)
        #expect(menu.items.isEmpty)
        web.shutDown()
    }

    @Test func lockdownConfigurationIsTight() {
        let web = SceneWebView()
        defer { web.shutDown() }
        #expect(!web.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        #expect(!web.configuration.websiteDataStore.isPersistent)
        #expect(!web.allowsBackForwardNavigationGestures)
        #expect(!web.allowsLinkPreview)
    }

    @Test func isInsideScenesResolvesDotDotAndSymlinks() throws {
        let web = SceneWebView()
        defer { web.shutDown() }
        let root = web.scenesRoot
        #expect(web.isInsideScenes(root.appendingPathComponent("shield.html")))
        #expect(!web.isInsideScenes(root.appendingPathComponent("../Info.plist")))
        #expect(!web.isInsideScenes(URL(string: "https://example.com/shield.html")))
        #expect(!web.isInsideScenes(URL(string: "about:blank")))
        #expect(!web.isInsideScenes(URL(fileURLWithPath: "/etc/hosts")))
        #expect(!web.isInsideScenes(nil))
    }

    // MARK: failures fall open to the native shield

    @Test func killingTheWebContentProcessShowsTheFallbackWithinOneSecond() async throws {
        let spy = SpyDelegate()
        let c = Fixture.controller()
        c.delegate = spy
        defer { c.tearDown() }
        c.show(Fixture.ctx(remainingMs: 300_000))
        let slot = try #require(c.slots.first)
        #expect(await until { slot.ready })
        let web = try #require(slot.web)
        #expect(await until { await blockBuilt(web) })      // page idle: no script call in flight when the process dies
        let sel = Selector(("_webProcessIdentifier"))
        try #require(web.responds(to: sel), "WKWebView no longer exposes its process id")
        let pid = (web.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value ?? 0
        try #require(pid > 1 && pid != ProcessInfo.processInfo.processIdentifier)
        let t0 = ContinuousClock.now
        kill(pid, SIGKILL)                  // OUR web view's own WebContent process, by its id
        #expect(await until(1.0) { slot.fallback != nil })
        let ms = (ContinuousClock.now - t0) / .milliseconds(1)
        print("FALLBACK after kill: \(Int(ms)) ms; reasons=\(c.fallbackReasons)")
        let model = try #require(slot.fallback)
        let left = model.canConfirmAt.timeIntervalSinceNow
        #expect(c.fallbackReasons == ["processTerminated"])
        #expect(left > 296 && left < 300.5, "remaining was \(left) s")
        #expect(slot.web == nil)
        // the fallback button asks the gate, nothing else
        model.onPrayed()
        #expect(spy.confirms == 1)
        #expect(c.isPresenting)
    }

    @Test func aBlankPageGetsTheFallbackWithinFourSeconds() async throws {
        let blank = try Fixture.scratchScenes(["shield.html": "<!doctype html><html><body></body></html>"])
        let c = Fixture.controller(scenesRoot: blank)
        defer { c.tearDown() }
        let t0 = ContinuousClock.now
        c.show(Fixture.ctx(remainingMs: 120_000))
        let slot = try #require(c.slots.first)
        #expect(await until(5) { slot.fallback != nil })
        let ms = (ContinuousClock.now - t0) / .milliseconds(1)
        print("FALLBACK blank page: \(Int(ms)) ms")
        #expect(ms >= 3900 && ms <= 4600)
        #expect(c.fallbackReasons == ["ready timeout"])
        #expect(slot.fallback!.canConfirmAt.timeIntervalSinceNow > 115)
    }

    @Test func aMissingPageFallsBackWithoutWaitingForTheTimeout() async throws {
        let empty = try Fixture.scratchScenes([:])
        let c = Fixture.controller(scenesRoot: empty)
        defer { c.tearDown() }
        c.show(Fixture.ctx())
        let slot = try #require(c.slots.first)
        #expect(await until(2) { slot.fallback != nil })
        #expect(c.isPresenting)
    }

    @Test func fallbackFollowsTheGatesUpdatesAndDismisses() async throws {
        let blank = try Fixture.scratchScenes([:])
        let c = Fixture.controller(scenesRoot: blank)
        defer { c.tearDown() }
        c.show(Fixture.ctx(remainingMs: 100_000, athanMs: 60_000))
        let slot = try #require(c.slots.first)
        #expect(await until(2) { slot.fallback != nil })
        let model = try #require(slot.fallback)
        c.update(Fixture.ctx(remainingMs: 30_000, athanMs: 0))
        #expect(model.canConfirmAt.timeIntervalSinceNow < 31)
        #expect(model.athanEndsAt == nil)
        var idle = 0
        c.dismiss { idle += 1 }
        #expect(model.accepting)
        #expect(await until(3) { idle == 1 })
    }

    // MARK: the scenes still render under the CSP

    @Test(arguments: Prayer.allCases)
    func sceneRendersUnderTheCSP(prayer: Prayer) async throws {
        let web = SceneWebView(scenesRoot: SceneWebView.bundledScenesRoot)
        defer { web.shutDown() }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.alphaValue = 0; win.ignoresMouseEvents = true      // an unseen window still counts as visible to WebKit
        win.contentView = web
        win.orderFront(nil)
        defer { win.contentView = nil; win.close() }
        var ready = false
        web.onMessage = { if $0 == .ready { ready = true } }
        web.load(query: "prayer=\(prayer.rawValue)&layout=full&reduce=0&ms=600000")
        #expect(await until(5) { ready })
        #expect(await until(8) { await web.js("document.getElementById('scene').dataset.state ?? ''") == "lived" })
        let canvases = await web.js("String(document.querySelectorAll('#scene canvas, #scene svg').length)")
        let violations = await web.js("String(GoPrayBridge.violations())")
        let paths = await web.js("String(document.querySelectorAll('.scene-ink path').length)")
        let d = await web.js("(function(){ const p=document.querySelector('.scene-ink path'); return p ? getComputedStyle(p).getPropertyValue('--d').trim() : 'none'; })()")
        print("INFO \(prayer.rawValue): layers=\(canvases) inkPaths=\(paths) --d=\(d) cspViolations=\(violations)")
        #expect(Int(canvases)! > 0)
        #expect(violations == "0")
        #expect(web.droppedMessages.isEmpty && web.blockedNavigations.isEmpty)
    }
}

/// A file drag with just enough of NSDraggingInfo to poke the overrides.
private final class FakeDrag: NSObject, NSDraggingInfo {
    let board: NSPasteboard
    let win: NSWindow?
    init(file: URL, window: NSWindow) {
        board = NSPasteboard(name: NSPasteboard.Name("gopray-test-\(UUID().uuidString)"))
        board.clearContents(); board.writeObjects([file as NSURL])
        win = window
    }
    var draggingDestinationWindow: NSWindow? { win }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { board }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation { get { .default } set {} }
    var animatesToDestination: Bool { get { false } set {} }
    var numberOfValidItemsForDrop: Int { get { 1 } set {} }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}
