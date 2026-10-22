// SceneStill.swift — a painted still of a prayer's scene for the popover and setup headers
// (spec: 320 x 96 popover, one frame, no motion). Owner: lane B.
//
// The still is one snapshot of the real scene page (reduce-motion path, art layout, no UI), cached
// as a PNG under Application Support/GoPray/stills so it is painted once per app version.
// Loading follows the vault rule: the prayer's ground colour is the skeleton and the still fades
// in over it, so nothing shifts when it lands.

import SwiftUI
import AppKit
import WebKit
import os

private let log = Logger(subsystem: "com.ahmedelgazar.gopray", category: "scenestill")

@MainActor final class SceneStillRenderer {
    static let shared = SceneStillRenderer()

    let cacheDirectory: URL
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private let scenesRoot: URL

    init(cacheDirectory: URL? = nil, scenesRoot: URL = SceneWebView.bundledScenesRoot) {
        self.cacheDirectory = cacheDirectory
            ?? StateStore.defaultDirectory().appendingPathComponent("stills", isDirectory: true)
        self.scenesRoot = scenesRoot
    }

    private static var versionTag: String {
        let i = Bundle.main.infoDictionary
        return "\(i?["CFBundleShortVersionString"] ?? "0")-\(i?["CFBundleVersion"] ?? "0")"
    }

    func cacheURL(_ prayer: Prayer, size: CGSize, scale: CGFloat) -> URL {
        cacheDirectory.appendingPathComponent("\(prayer.rawValue)-\(Int(size.width))x\(Int(size.height))@\(Int(scale))x-frame2-v\(Self.versionTag).png")
    }

    /// The still, from the cache or painted now. Never throws; nil means "keep showing the ground colour".
    func image(for prayer: Prayer, size: CGSize, scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2) async -> NSImage? {
        let url = cacheURL(prayer, size: size, scale: scale)
        if let img = NSImage(contentsOf: url) { return img }
        if let t = inFlight[url.path] { return await t.value }
        let task = Task { @MainActor [weak self] () -> NSImage? in
            guard let self else { return nil }
            let img = await self.paint(prayer, size: size, scale: scale)
            if let img { self.store(img, at: url) }
            return img
        }
        inFlight[url.path] = task
        let img = await task.value
        inFlight[url.path] = nil
        return img
    }

    private func store(_ image: NSImage, at url: URL) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
        } catch { log.error("still not cached: \(String(describing: error), privacy: .public)") }
    }

    /// Where each scene's art sits in its 1600 x 1000 virtual space: the band is cut around this point
    /// (the scene's `focal`, nudged where the focal point is not the subject) and `width` virtual
    /// units wide at a 320 pt band. The page centre is never used: it is where the text-lift sits.
    struct Frame { let x: Double, y: Double, width: Double }
    static let frames: [Prayer: Frame] = [
        .fajr: Frame(x: 1150, y: 400, width: 700),      // the window light
        .dhuhr: Frame(x: 1180, y: 640, width: 680),     // dome + minaret
        .asr: Frame(x: 862, y: 560, width: 640),        // dome through the arches + lanterns
        .maghrib: Frame(x: 1250, y: 480, width: 900),   // dome + minaret + sun
        .isha: Frame(x: 1080, y: 566, width: 700),      // Kaaba + mataf lights
    ]

    /// The crop of the full 1600 x 1000 page for a band, in page points when the page is `scale` points per unit.
    static func crop(_ prayer: Prayer, band: CGSize) -> (page: CGSize, rect: CGRect) {
        let f = frames[prayer] ?? Frame(x: 800, y: 500, width: 800)
        let cw = f.width * (band.width > 400 ? 1.35 : 1)
        let s = Double(band.width) / cw
        let page = CGSize(width: 1600 * s, height: 1000 * s)
        let ch = Double(band.height) / s
        let cx = min(max(f.x, cw / 2), 1600 - cw / 2)
        let cy = min(max(f.y, ch / 2), 1000 - ch / 2)
        return (page, CGRect(x: (cx - cw / 2) * s, y: (cy - ch / 2) * s, width: band.width, height: band.height))
    }

    private func paint(_ prayer: Prayer, size: CGSize, scale: CGFloat) async -> NSImage? {
        let framing = Self.crop(prayer, band: size)
        let web = SceneWebView(scenesRoot: scenesRoot, underPage: ShieldPalette.of(prayer).ground)
        web.frame = NSRect(origin: .zero, size: framing.page)
        // WebKit pauses a page that is not visible (CSS animations stay at frame 0, so the scene stays
        // transparent). An alpha-0 borderless window ordered in on a display counts as visible and
        // shows the person nothing.
        let win = NSWindow(contentRect: NSRect(x: 100, y: 100, width: framing.page.width, height: framing.page.height),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.alphaValue = 0
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        win.contentView = web
        win.level = .screenSaver
        win.orderFrontRegardless()
        defer { web.shutDown(); win.contentView = nil; win.close() }

        var ready = false
        web.onMessage = { if $0 == .ready { ready = true } }
        web.load(query: "prayer=\(prayer.rawValue)&layout=art&reduce=1&ms=600000")
        guard await wait(5, { ready }) else { return nil }
        var painted = false
        let deadline = ContinuousClock.now + .seconds(5)
        while !painted, ContinuousClock.now < deadline {
            var answered: Bool?
            web.scenePainted { answered = $0 }
            _ = await wait(0.5, { answered != nil })
            painted = answered ?? false
            if !painted { try? await Task.sleep(for: .milliseconds(100)) }
        }
        guard painted else { return nil }
        try? await Task.sleep(for: .milliseconds(400))          // the 200 ms crossfade of the still path
        let cfg = WKSnapshotConfiguration()
        cfg.rect = framing.rect
        cfg.snapshotWidth = NSNumber(value: Double(size.width))
        return await withCheckedContinuation { cont in
            web.takeSnapshot(with: cfg) { image, _ in cont.resume(returning: image) }
        }
    }

    private func wait(_ seconds: Double, _ cond: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return cond()
    }
}

/// The still of `prayer`'s scene at `size` (points). The ground colour is up first.
struct SceneStill: View {
    let prayer: Prayer
    var size = CGSize(width: 320, height: 96)
    var renderer: SceneStillRenderer = .shared
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color(nsColor: ShieldPalette.of(prayer).ground)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .animation(.easeOut(duration: 0.2), value: image == nil)
        .accessibilityHidden(true)
        .task(id: prayer) {
            image = nil
            image = await renderer.image(for: prayer, size: size)
        }
    }
}
