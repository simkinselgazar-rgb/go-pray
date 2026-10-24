// EmergencyShieldTests.swift — v2 shield side of the emergency exit: bridge message, payload, the page's
// hold + card flow, the plain-fade dismiss, the controller's routing and the native fallback.
// Nothing here puts a window on screen (alpha 0 / orderFront off).

import Testing
import AppKit
import WebKit
@testable import GoPray

@MainActor @Suite("Emergency exit (shield)", .serialized)
struct EmergencyShieldTests {
    // MARK: Bridge vocabulary

    @Test func emergencyIsTheFifthAndLastMessageName() {
        #expect(BridgeMessage.parse(["type": "emergency"]) == .emergency)
        #expect(BridgeMessage.parse(["type": "emergency", "x": 1]) == nil)
        #expect(BridgeMessage.parse(["type": "Emergency"]) == nil)
        #expect(Set(BridgeMessage.allCases.map(\.rawValue)) == ["ready", "prayed", "silence", "emergency", "gone"])
    }

    @Test func payloadClampsTheCountAndCarriesItInTheShowScript() {
        var c = Fixture.ctx(); c.emergencyExitsLeft = 99
        #expect(BridgePayload(c, layout: .full).emergencyExitsLeft == 5)
        c.emergencyExitsLeft = -4
        #expect(BridgePayload(c, layout: .full).emergencyExitsLeft == 0)
        c.emergencyExitsLeft = 3
        #expect(BridgePayload(c, layout: .full).showScript().contains("\"emergencyExitsLeft\":3"))
    }

    // MARK: The page

    private func page(left: Int, layout: ShieldLayout = .full, msgs: @escaping (BridgeMessage) -> Void)
        async throws -> (SceneWebView, NSWindow) {
        let web = SceneWebView(scenesRoot: SceneWebView.bundledScenesRoot)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: layout == .full ? 1440 : 420, height: layout == .full ? 900 : 520),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.alphaValue = 0; win.ignoresMouseEvents = true
        win.contentView = web
        win.orderFront(nil)
        var ready = false
        web.onMessage = { if $0 == .ready { ready = true } else { msgs($0) } }
        web.load()
        #expect(await until(5) { ready })
        var c = Fixture.ctx(.asr, mode: layout == .full ? .wholeScreen : .codingApps, remainingMs: 600_000)
        c.emergencyExitsLeft = left; c.lockSeconds = 600
        web.show(BridgePayload(c, layout: layout))
        #expect(await until(5) { await blockBuilt(web) })
        return (web, win)
    }

    private func fire(_ web: SceneWebView, _ selector: String, _ type: String) async {
        _ = await web.js("document.querySelector('\(selector)').dispatchEvent(new PointerEvent('\(type)', {button: 0, bubbles: true})); 'ok'")
    }

    @Test func noButtonWhenNoneAreLeft() async throws {
        let (web, win) = try await page(left: 0) { _ in }
        defer { web.shutDown(); win.contentView = nil; win.close() }
        #expect(await web.js("String(document.querySelectorAll('.exit-btn').length)") == "0")
        #expect(await web.js("String(GoPrayBridge.violations())") == "0")
    }

    @Test func holdForThreeSecondsThenCardThenOneMessage() async throws {
        var got: [BridgeMessage] = []
        let (web, win) = try await page(left: 5) { got.append($0) }
        defer { web.shutDown(); win.contentView = nil; win.close() }
        #expect(await web.js("document.querySelector('.exit-label').textContent") == "Emergency exit · 5 of 5 left this year")

        // Release at 2.9 s: nothing happens.
        await fire(web, ".exit-btn", "pointerdown")
        #expect(await web.js("document.querySelector('.exit-label').textContent") == "Keep holding…")
        try? await Task.sleep(for: .milliseconds(2900))
        await fire(web, ".exit-btn", "pointerup")
        try? await Task.sleep(for: .milliseconds(500))
        #expect(await web.js("String(document.querySelectorAll('.exit-card').length)") == "0")
        #expect(await web.js("document.querySelector('.exit-label').textContent") == "Emergency exit · 5 of 5 left this year")
        #expect(got.isEmpty)

        // Hold to 3 s: the card shows, and it says what it costs.
        await fire(web, ".exit-btn", "pointerdown")
        #expect(await until(5) { await web.js("String(document.querySelectorAll('.exit-card').length)") == "1" })
        let body = await web.js("document.querySelector('.exit-body').textContent")
        #expect(body == "This ends the block now. Asr will count as missed, not prayed. You'll have 4 of 5 left this year.")
        #expect(await web.js("document.querySelector('h2').textContent") == "Use an emergency exit?")
        #expect(got.isEmpty)

        // "Not now" sends nothing.
        _ = await web.js("document.querySelector('.exit-no').click(); 'ok'")
        #expect(await web.js("String(document.querySelectorAll('.exit-card').length)") == "0")
        try? await Task.sleep(for: .milliseconds(200))
        #expect(got.isEmpty)

        // Hold again, "Use it" sends exactly one `emergency`, even if clicked twice.
        await fire(web, ".exit-btn", "pointerdown")
        #expect(await until(5) { await web.js("String(document.querySelectorAll('.exit-card').length)") == "1" })
        _ = await web.js("(function(){ const y=document.querySelector('.exit-yes'); y.click(); y.click(); return 'ok'; })()")
        try? await Task.sleep(for: .milliseconds(300))
        #expect(got == [.emergency])
        #expect(await web.js("String(GoPrayBridge.violations())") == "0")
    }

    @Test func lastExitSaysSoOnTheCard() async throws {
        let (web, win) = try await page(left: 1) { _ in }
        defer { web.shutDown(); win.contentView = nil; win.close() }
        #expect(await web.js("document.querySelector('.exit-label').textContent") == "Emergency exit · 1 of 5 left this year")
        await fire(web, ".exit-btn", "pointerdown")
        #expect(await until(5) { await web.js("String(document.querySelectorAll('.exit-card').length)") == "1" })
        #expect(await web.js("document.querySelector('.exit-body').textContent").hasSuffix("This is your last one this year."))
    }

    @Test func aRefusedExitShowsTheRetryLineWhenTheGateResyncs() async throws {
        let (web, win) = try await page(left: 5) { _ in }
        defer { web.shutDown(); win.contentView = nil; win.close() }
        await fire(web, ".exit-btn", "pointerdown")
        #expect(await until(5) { await web.js("String(document.querySelectorAll('.exit-card').length)") == "1" })
        _ = await web.js("document.querySelector('.exit-yes').click(); 'ok'")
        var c = Fixture.ctx(.asr, remainingMs: 590_000); c.emergencyExitsLeft = 5; c.lockSeconds = 600
        web.show(BridgePayload(c, layout: .full))          // what the gate's update does on a refusal
        #expect(await until(5) { await web.js("document.querySelector('.exit-note').textContent") == "Couldn't use the exit. Try again in a moment." })
    }

    @Test func emergencyDismissIsAPlainFadeWithNoAcceptLine() async throws {
        var got: [BridgeMessage] = []
        let (web, win) = try await page(left: 5) { got.append($0) }
        defer { web.shutDown(); win.contentView = nil; win.close() }
        web.dismissPage(kind: .emergency)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(await web.js("String(document.querySelector('.accept')?.classList.contains('is-on') ?? false)") == "false")
        #expect(await web.js("String(document.querySelector('.shield').classList.contains('is-gone'))") == "true")
        #expect(await until(3) { got.contains(.gone) })
    }

    @Test func confirmedDismissStillShowsTheAcceptLine() async throws {
        let (web, win) = try await page(left: 5) { _ in }
        defer { web.shutDown(); win.contentView = nil; win.close() }
        web.dismissPage(kind: .confirmed)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(await web.js("String(document.querySelector('.accept').classList.contains('is-on'))") == "true")
    }

    @Test func noticeLayoutHasTheSameFooter() async throws {
        let (web, win) = try await page(left: 3, layout: .notice) { _ in }
        defer { web.shutDown(); win.contentView = nil; win.close() }
        #expect(await web.js("document.querySelector('.exit-label').textContent") == "Emergency exit · 3 of 5 left this year")
    }

    // MARK: Controller + fallback

    @Test func controllerRoutesAPageEmergencyToTheDelegateOnlyWhilePresenting() async throws {
        let spy = SpyDelegate()
        let c = Fixture.controller()
        c.delegate = spy
        defer { c.tearDown() }
        var ctx = Fixture.ctx(remainingMs: 600_000); ctx.emergencyExitsLeft = 5
        c.show(ctx)
        let slot = try #require(c.slots.first)
        let web = try #require(slot.web)
        #expect(await until { slot.ready })
        #expect(await until { await blockBuilt(web) })
        await fire(web, ".exit-btn", "pointerdown")
        #expect(await until(5) { await web.js("String(document.querySelectorAll('.exit-card').length)") == "1" })
        _ = await web.js("document.querySelector('.exit-yes').click(); 'ok'")
        #expect(await until { spy.emergencies == 1 })
    }

    @Test func fallbackCarriesTheCountAndAsksTheGate() async throws {
        let spy = SpyDelegate()
        let empty = try Fixture.scratchScenes([:])
        let c = Fixture.controller(scenesRoot: empty)
        c.delegate = spy
        defer { c.tearDown() }
        var ctx = Fixture.ctx(remainingMs: 600_000); ctx.emergencyExitsLeft = 4
        c.show(ctx)
        let slot = try #require(c.slots.first)
        #expect(await until(5) { slot.fallback != nil })
        let model = try #require(slot.fallback)
        #expect(model.exitsLeft == 4)
        model.requestEmergency()
        #expect(spy.emergencies == 1)
        // The gate said no and re-synced: the page-equivalent line appears.
        ctx.emergencyExitsLeft = 4
        c.update(ctx)
        #expect(model.exitNote == "Couldn't use the exit. Try again in a moment.")
        var out = 0
        c.dismiss(kind: .emergency) { out += 1 }
        #expect(model.exiting && !model.accepting)
        #expect(await until(4) { out == 1 })
    }
}
