// ShieldContextTests.swift — lane B: the ring shows true progress after a relaunch (CONTRACT-NOTES #31),
// and every colour pair the notice layout uses passes WCAG AA.

import Testing
import AppKit
@testable import GoPray

@MainActor @Suite("Shield context + notice colours", .serialized)
struct ShieldContextTests {
    @Test func gateFillsStartAndLockLengthAndKeepsThemAcrossARelaunch() throws {
        let asr = FakeSchedule.at(.asr)
        let h = Harness(at: asr, settings: .test(lockMinutes: 15)); defer { h.cleanup() }
        h.gate.athanFired(.asr, at: asr)
        let first = try #require(h.shield.shows.first)
        #expect(first.lockSeconds == 900)
        #expect(first.blockStartedAt == asr)
        #expect(first.remainingMs == 900_000)

        h.clock.now = asr.addingTimeInterval(300)
        h.relaunch()
        let again = try #require(h.shield.shows.first)
        #expect(again.lockSeconds == 900)
        #expect(again.blockStartedAt == asr)
        #expect(again.remainingMs == 600_000)
    }

    @Test func payloadCarriesTheLockLength() {
        var c = Fixture.ctx(remainingMs: 300_000)
        c.lockSeconds = 600
        #expect(BridgePayload(c, layout: .full).lockMs == 600_000)
        c.lockSeconds = 99_999
        #expect(BridgePayload(c, layout: .full).lockMs == 1_800_000)
        #expect(BridgePayload(Fixture.ctx(), layout: .full).lockMs == 0)      // unknown
    }

    @Test func theRingStartsAtItsTrueProgressAfterARelaunch() async throws {
        let c = Fixture.controller()
        defer { c.tearDown() }
        var ctx = Fixture.ctx(remainingMs: 300_000)       // halfway through a 10-minute lock
        ctx.lockSeconds = 600
        c.show(ctx)
        let slot = try #require(c.slots.first)
        #expect(await until { slot.ready })
        let web = try #require(slot.web)
        #expect(await until { await blockBuilt(web) })
        try? await Task.sleep(for: .milliseconds(300))
        let off = Double(await web.js("document.querySelector('.ring-fill').getAttribute('stroke-dashoffset')")) ?? -1
        let circumference = 2 * Double.pi * 47
        print("INFO ring offset \(Int(off)) of \(Int(circumference)) (half = \(Int(circumference / 2)))")
        #expect(abs(off - circumference / 2) < circumference * 0.03, "ring offset \(off)")
        // and it keeps that after ui.js writes it again (one tick later)
        try? await Task.sleep(for: .milliseconds(1300))
        let later = Double(await web.js("document.querySelector('.ring-fill').getAttribute('stroke-dashoffset')")) ?? -1
        #expect(later < off && abs(later - circumference / 2) < circumference * 0.04, "after a tick: \(later)")
        // control: without a lock length the ring spans only what is left, so it starts empty
        c.tearDown()
        c.show(Fixture.ctx(remainingMs: 300_000))
        let s2 = try #require(c.slots.first)
        #expect(await until { s2.ready })
        #expect(await until { await blockBuilt(s2.web!) })
        let off2 = Double(await s2.web!.js("document.querySelector('.ring-fill').getAttribute('stroke-dashoffset')")) ?? -1
        #expect(off2 > circumference * 0.9)
    }

    // MARK: AA on the ground colour, from the shipped tokens

    private func luminance(_ c: NSColor) -> Double {
        let s = c.usingColorSpace(.sRGB)!
        func lin(_ v: CGFloat) -> Double { let x = Double(v); return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(s.redComponent) + 0.7152 * lin(s.greenComponent) + 0.0722 * lin(s.blueComponent)
    }
    private func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let (x, y) = (luminance(a), luminance(b)); return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
    private func blend(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        let (p, q) = (a.usingColorSpace(.sRGB)!, b.usingColorSpace(.sRGB)!)
        return NSColor(srgbRed: p.redComponent * t + q.redComponent * (1 - t), green: p.greenComponent * t + q.greenComponent * (1 - t),
                       blue: p.blueComponent * t + q.blueComponent * (1 - t), alpha: 1)
    }

    @Test(arguments: Prayer.allCases)
    func noticeTextPassesAAOnTheGroundColour(prayer: Prayer) throws {
        let css = try String(contentsOf: SceneWebView.bundledScenesRoot.appendingPathComponent("styles.css"), encoding: .utf8)
        let block = try #require(css.range(of: "[data-prayer='\(prayer.rawValue)'] {").map { css[$0.upperBound...] })
        let body = String(block[..<block.firstIndex(of: "}")!])
        func token(_ name: String) throws -> NSColor {
            let r = try #require(body.range(of: "--\(name):"))
            let hex = body[r.upperBound...].drop(while: { $0 == " " }).prefix(7)
            return ShieldPalette.hex(Int(hex.dropFirst(), radix: 16)!)
        }
        let ground = try token("ground"), text = try token("text"), soft = try token("text-soft")
        let disabledButton = blend(text, ground, 0.07)
        let nabawi = ShieldPalette.nabawi, onNabawi = ShieldPalette.hex(0xf4eee2)
        print("INFO AA \(prayer.rawValue): text \(String(format: "%.1f", contrast(text, ground))) soft \(String(format: "%.1f", contrast(soft, ground))) disabled-button \(String(format: "%.1f", contrast(soft, disabledButton))) on-nabawi \(String(format: "%.1f", contrast(onNabawi, nabawi)))")
        #expect(contrast(text, ground) >= 4.5)
        #expect(contrast(soft, ground) >= 4.5)
        #expect(contrast(soft, disabledButton) >= 4.5)
        #expect(contrast(onNabawi, nabawi) >= 4.5)
    }
}
