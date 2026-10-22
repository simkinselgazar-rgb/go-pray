// BridgeMessageTests.swift — lane B: the JS <-> Swift bridge (Architecture Plan C.6, §E lane B).
// Real shield.html in a real WKWebView; the gate is a spy.

import Testing
import AppKit
import WebKit
@testable import GoPray

@MainActor @Suite("Bridge messages", .serialized)
struct BridgeMessageTests {

    // MARK: validation (pure)

    @Test func parsesTheFourNames() {
        for m in BridgeMessage.allCases {
            #expect(BridgeMessage.parse(["type": m.rawValue]) == m)
        }
    }

    @Test func dropsEverythingElse() {
        #expect(BridgeMessage.parse(["type": "end"]) == nil)
        #expect(BridgeMessage.parse(["type": "PRAYED"]) == nil)
        #expect(BridgeMessage.parse(["type": "prayed", "force": true]) == nil)   // extra key
        #expect(BridgeMessage.parse(["kind": "prayed"]) == nil)
        #expect(BridgeMessage.parse(["type": 1]) == nil)
        #expect(BridgeMessage.parse(["type": ["prayed"]]) == nil)
        #expect(BridgeMessage.parse("prayed") == nil)
        #expect(BridgeMessage.parse(["prayed"]) == nil)
        #expect(BridgeMessage.parse(42) == nil)
        #expect(BridgeMessage.parse(NSNull()) == nil)
        #expect(BridgeMessage.parse([String: Any]()) == nil)
    }

    @Test func payloadCarriesReduceMotionAndClampsNumbers() throws {
        let p = BridgePayload(Fixture.ctx(remainingMs: 99_999_999, athanMs: -5, reduce: true), layout: .full)
        #expect(p.reduceMotion)
        #expect(p.remainingMs == 1_800_000)
        #expect(p.athanRemainingMs == 0)
        let script = p.showScript()
        #expect(script.hasPrefix("GoPrayBridge.show({"))
        #expect(script.contains("\"reduceMotion\":true"))
        #expect(script.contains("\"layout\":\"full\""))
    }

    @Test func appNameIsEscapedByTheEncoderAndCapped() {
        let evil = "\"});alert(1);//</script>\n\u{2028}" + String(repeating: "x", count: 200)
        let p = BridgePayload(Fixture.ctx(mode: .codingApps, app: evil), layout: .notice)
        #expect((p.hiddenAppName ?? "").count == BridgePayload.maxAppNameLength)
        let script = p.showScript()
        #expect(!script.contains("\n"))                       // control characters are escaped
        #expect(script.contains(#"\"});alert(1)"#))          // the quote is escaped, it cannot close the string
    }

    // MARK: the real page

    @Test(arguments: [(1440.0, 900.0), (5120.0, 2880.0)])
    func pageSaysReadyWithinTwoSeconds(w: Double, h: Double) async {
        let spy = SpyDelegate()
        let c = Fixture.controller(displays: [Fixture.display(1, w: w, h: h)])
        c.delegate = spy
        defer { c.tearDown() }
        let t0 = ContinuousClock.now
        c.show(Fixture.ctx())
        let ok = await until(2.0) { c.slots.first?.ready == true }
        let ms = (ContinuousClock.now - t0) / .milliseconds(1)
        print("READY \(Int(w))x\(Int(h)) in \(Int(ms)) ms")
        #expect(ok)
        #expect(c.fallbackReasons.isEmpty)
        // and the page built the block from the context
        let slot = try! #require(c.slots.first)
        #expect(await until(2) { await blockBuilt(slot.web!) })
        let name = await slot.web!.js("document.querySelector('.name-latin')?.textContent ?? 'none'")
        #expect(name == "Dhuhr")
        let time = await slot.web!.js("document.querySelector('.ring-time')?.textContent ?? 'none'")
        // a cold load can let a second tick before this read: accept up to 2 s elapsed
        #expect(["10:00", "9:59", "9:58"].contains(time), "ring time was \(time)")
    }

    @Test func prayedBeforeUnlockDoesNotEndTheBlockAndTheGateResyncsThePage() async throws {
        let spy = SpyDelegate()
        let c = Fixture.controller()
        c.delegate = spy
        defer { c.tearDown() }
        // a gate that refuses and answers like BlockGate does: update(ctx) with the true remaining time
        spy.onConfirm = { c.update(Fixture.ctx(remainingMs: 300_000)) }
        c.show(Fixture.ctx(remainingMs: 300_000))
        let slot = try #require(c.slots.first)
        #expect(await until { slot.ready })
        let web = try #require(slot.web)
        #expect(await until { await blockBuilt(web) })

        let shownBefore = slot.shownAt
        // A lying page: unlock the button by hand, click it. ui.js ignores the click (its clock says locked)
        // but the bridge still reports a click on an enabled "I prayed", which is all the page can do.
        _ = await web.js("(function(){ const b=document.querySelector('.prayed'); b.disabled=false; b.click(); return 'clicked'; })()")
        #expect(await until { spy.confirms == 1 })
        #expect(c.isPresenting)          // the shield did not end itself
        #expect(!c.isDismissing)
        // the gate's update made the shield re-show the page with the true remaining time
        #expect(await until { slot.shownAt > shownBefore })
        let disabled = await web.js("String(document.querySelector('.prayed').disabled)")
        #expect(disabled == "true")
        let time = await web.js("document.querySelector('.ring-time').textContent")
        #expect(["5:00", "4:59", "4:58"].contains(time))
    }

    @Test func unknownMessagesAreDroppedAndNeverReachTheGate() async throws {
        let spy = SpyDelegate()
        let c = Fixture.controller()
        c.delegate = spy
        defer { c.tearDown() }
        c.show(Fixture.ctx())
        let slot = try #require(c.slots.first)
        #expect(await until { slot.ready })
        let web = try #require(slot.web)
        _ = await web.js("""
          const h = window.webkit.messageHandlers.gopray;
          h.postMessage({type:'end'}); h.postMessage('prayed'); h.postMessage({type:'prayed', force:true});
          h.postMessage({type:'quit'}); h.postMessage(7); h.postMessage(null); 'sent'
        """)
        #expect(await until { web.droppedMessages.count == 6 })
        #expect(spy.confirms == 0)
        #expect(spy.silences == 0)
        // any other handler name does not exist
        let other = await web.js("typeof window.webkit.messageHandlers.system + '/' + typeof window.webkit.messageHandlers.gopray2")
        #expect(other == "undefined/undefined")
    }

    @Test func reduceMotionReachesThePage() async throws {
        let c = Fixture.controller()
        defer { c.tearDown() }
        c.show(Fixture.ctx(reduce: true))
        let slot = try #require(c.slots.first)
        #expect(await until { slot.ready })
        let web = try #require(slot.web)
        #expect(await until { await blockBuilt(web) })
        let reduce = await web.js("String(document.documentElement.classList.contains('reduce'))")
        #expect(reduce == "true")
    }

    @Test func threeDisplaysGiveThreePanelsAndUIOnlyOnTheMainOne() async throws {
        let c = Fixture.controller(displays: [Fixture.display(1, x: 0, w: 1512, h: 982),
                                              Fixture.display(2, x: 1512, w: 1920, h: 1080),
                                              Fixture.display(3, x: -2560, w: 2560, h: 1440)])
        defer { c.tearDown() }
        c.show(Fixture.ctx(.fajr))
        #expect(c.slots.count == 3)
        #expect(await until { c.slots.allSatisfy { $0.ready } })
        // spike bug 1: each panel sits exactly on its own display's global frame
        for s in c.slots { #expect(s.panel.frame == s.display.frame) }
        #expect(await until { await blockBuilt(c.slots[0].web!) })
        try? await Task.sleep(for: .milliseconds(300))
        let counts = await [c.slots[0].web!.js("String(document.querySelectorAll('.block').length)"),
                            c.slots[1].web!.js("String(document.querySelectorAll('.block').length)"),
                            c.slots[2].web!.js("String(document.querySelectorAll('.block').length)")]
        #expect(counts == ["1", "0", "0"])
        let layouts = c.slots.map(\.layout)
        #expect(layouts == [.full, .art, .art])
    }

    @Test func athanStoppedFadesTheSilenceButtonWithoutEchoingToTheGate() async throws {
        let spy = SpyDelegate()
        let c = Fixture.controller()
        c.delegate = spy
        defer { c.tearDown() }
        c.show(Fixture.ctx(remainingMs: 600_000, athanMs: 180_000))
        let slot = try #require(c.slots.first)
        let web = try #require(slot.web)
        #expect(await until { slot.ready })
        #expect(await until { await blockBuilt(web) })
        #expect(await web.js("String(document.querySelector('.silence').classList.contains('is-quiet'))") == "false")
        c.update(Fixture.ctx(remainingMs: 600_000, athanMs: 0))        // audio finished, gate says so
        #expect(await until { await web.js("String(document.querySelector('.silence').classList.contains('is-quiet'))") == "true" })
        try? await Task.sleep(for: .milliseconds(200))
        #expect(spy.silences == 0)
    }

    @Test func gateConfirmDismissesThroughThePageAndCallsIdleOnce() async throws {
        let c = Fixture.controller()
        defer { c.tearDown() }
        c.show(Fixture.ctx(remainingMs: 0))
        let slot = try #require(c.slots.first)
        #expect(await until { slot.ready })
        var idleCount = 0
        let t0 = ContinuousClock.now
        c.dismiss { idleCount += 1 }
        #expect(await until(4) { idleCount == 1 })
        let ms = (ContinuousClock.now - t0) / .milliseconds(1)
        print("DISMISS idle after \(Int(ms)) ms")
        #expect(ms < 2600)
        #expect(!c.isPresenting)
        #expect(c.slots.isEmpty)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(idleCount == 1)
    }

    @Test func tearDownDuringDismissNeverCallsIdleAndLeavesNothingBehind() async throws {
        let c = Fixture.controller()
        c.show(Fixture.ctx(remainingMs: 0))
        let slot = try #require(c.slots.first)
        #expect(await until { slot.ready })
        var idle = 0
        c.dismiss { idle += 1 }
        #expect(c.isDismissing)
        c.tearDown()                        // fail-open while the accept fade runs
        #expect(!c.isPresenting && c.slots.isEmpty)
        try? await Task.sleep(for: .milliseconds(1800))
        #expect(idle == 0)
    }

    @Test func tearDownWorksFromEveryState() async {
        let c = Fixture.controller()
        c.tearDown()                                    // idle
        c.show(Fixture.ctx()); c.tearDown()             // right after show, page not even loaded
        c.show(Fixture.ctx()); c.show(Fixture.ctx(.asr))    // overlap: new prayer replaces
        #expect(c.slots.count == 1)
        c.tearDown(); c.tearDown()
        #expect(!c.isPresenting)
    }
}

