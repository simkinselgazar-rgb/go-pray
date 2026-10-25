// SnapshotTests.swift — lane A. Renders the three screens (and their states) to PNG so a
// person can look at them. It writes only when GOPRAY_SHOTS_DIR is set (pass it to
// xcodebuild as TEST_RUNNER_GOPRAY_SHOTS_DIR=<dir>); otherwise it only checks that each
// screen lays out to a non-empty image. Not a pixel-diff test: no golden images.

import AppKit
import SwiftUI
import Testing
@testable import GoPray

@MainActor @Suite("Screen snapshots", .serialized)
struct SnapshotTests {
    static let outDir: URL? = ProcessInfo.processInfo.environment["GOPRAY_SHOTS_DIR"].map { URL(fileURLWithPath: $0) }

    /// Render `view` in an off-screen window and return the bitmap.
    func render<V: View>(_ view: V, size: CGSize, dark: Bool = false) async -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))   // cacheDisplay skips the window's own fill
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        window.setFrameOrigin(CGPoint(x: -12_000, y: 200))      // off every screen
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(120))
        }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    func shot<V: View>(_ name: String, _ view: V, size: CGSize, dark: Bool = false) async {
        guard let rep = await render(view, size: size, dark: dark) else { Issue.record("no bitmap for \(name)"); return }
        #expect(rep.pixelsWide > 0 && rep.pixelsHigh > 0)
        guard let dir = Self.outDir, let png = rep.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? png.write(to: dir.appendingPathComponent("\(name).png"))
    }

    // MARK: Setup

    @Test func setupScreens() async throws {
        let f = UIFixture(configured: false); defer { f.cleanup() }
        f.geocoder.results = [.toronto, .torontoOhio]
        let m = f.setupModel()
        let size = CGSize(width: 520, height: 600)
        let view = SetupView(model: m, onFinished: {})

        await shot("setup-1-city-empty", view, size: size)
        m.search.queryChanged("Toronto")                         // skeleton rows
        f.geocoder.hang = true
        await shot("setup-1-city-searching", view, size: size)
        m.search.queryChanged("")
        f.geocoder.hang = false
        m.search.queryChanged("Toronto")
        await m.search.settle()
        await shot("setup-1-city-results", view, size: size)
        m.pickedCity = .toronto
        await shot("setup-1-city-picked", view, size: size)
        m.next()
        await shot("setup-2-method", view, size: size)
        m.next()
        await shot("setup-3-mode", view, size: size)
        m.next()
        await shot("setup-4-tv-scanning", view, size: size)
        m.next()
        await shot("setup-5-done", view, size: size)
        await shot("setup-5-done-dark", view, size: size, dark: true)
    }

    @Test func setupTVStepSkeleton() async throws {
        let f = UIFixture(configured: false); defer { f.cleanup() }
        let d = CountingDiscovery(); d.hang = true               // the scan never answers: skeleton row stays
        let m = f.setupModel(discovery: d)
        m.pickedCity = .toronto
        m.next(); m.next(); m.next()
        let size = CGSize(width: 520, height: 600)
        let view = SetupView(model: m, onFinished: {})
        await shot("setup-tv-1-scanning", view, size: size)
        await shot("setup-tv-1-scanning-dark", view, size: size, dark: true)
    }

    @Test func setupTVStep() async throws {
        let f = UIFixture(configured: false); defer { f.cleanup() }
        let s = RecordingSender(); s.resolution = .found("dev")
        let d = CountingDiscovery()
        d.result = TVScan(found: [FoundTV(host: "192.168.1.20", name: "Living room"), FoundTV(host: "192.168.1.31", name: "Bedroom TV")])
        let m = f.setupModel(tv: s, discovery: d)
        m.pickedCity = .toronto
        m.next(); m.next(); m.next()
        let size = CGSize(width: 520, height: 600)
        let view = SetupView(model: m, onFinished: {})
        await m.tvs.scanForTVs()
        await shot("setup-tv-2-found", view, size: size)
        await shot("setup-tv-2-found-dark", view, size: size, dark: true)
        await m.tvs.addFound(m.tvs.foundTVs[0])
        await shot("setup-tv-3-added-ready", view, size: size)
        await shot("setup-tv-3-added-ready-dark", view, size: size, dark: true)
    }

    // MARK: Settings

    @Test func settingsScreens() async throws {
        let f = UIFixture(); defer { f.cleanup() }
        let m = f.settingsModel()
        let credits = AnyView(Text("Credits").padding())
        let size = CGSize(width: 480, height: 1020)
        await shot("settings-idle", SettingsView(model: m, credits: credits), size: size)
        await shot("settings-idle-dark", SettingsView(model: m, credits: credits), size: size, dark: true)
        try f.store.pause(.oneWeek, now: f.clock.now)
        await shot("settings-paused", SettingsView(model: m, credits: credits), size: size)
        try f.store.resume(now: f.clock.now)
        f.startBlock()
        await shot("settings-blocked", SettingsView(model: m, credits: credits), size: size)
    }

    // MARK: Popover

    @Test func popoverScreens() async throws {
        let f = UIFixture(); defer { f.cleanup() }
        let model = f.menuModel()
        let size = CGSize(width: 320, height: 440)
        func menu() -> MenuView { MenuView(model: model, openSettings: {}, openSetup: {}, quit: {}) }
        await shot("popover-normal", menu(), size: size)
        await shot("popover-normal-dark", menu(), size: size, dark: true)
        try f.store.pause(.oneDay, now: f.clock.now)
        await shot("popover-paused", menu(), size: size)
        try f.store.resume(now: f.clock.now)
        f.startBlock()
        f.clock.advance(372)
        await shot("popover-blocked", menu(), size: size)

        let fresh = UIFixture(configured: false); defer { fresh.cleanup() }
        await shot("popover-needs-setup", MenuView(model: fresh.menuModel(), openSettings: {}, openSetup: {}, quit: {}),
                   size: CGSize(width: 320, height: 160))
    }
}
