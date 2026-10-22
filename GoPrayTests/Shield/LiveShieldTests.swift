// LiveShieldTests.swift — lane B: raises a REAL shield (level .screenSaver, every display, activation,
// presentation options) for a few seconds and screenshots it. Off by default: it takes over the screen.
//
//   TEST_RUNNER_GOPRAY_LIVE_SHIELD=<dir> xcodebuild … test -only-testing:GoPrayTests/LiveShieldTests
//
// The test writes `<name>.up` into <dir> once the shield is up and holds it for `hold` seconds; a
// caller with Screen Recording permission (the test process has none) runs `screencapture` then.
//
// Safety: every run dismisses itself after `hold` seconds (never more than 15), and a watchdog on a
// background queue kills the test process at 14 s if the main actor is ever stuck.

import Testing
import AppKit
@testable import GoPray

@MainActor @Suite("Live shield (manual)", .serialized)
struct LiveShieldTests {
    nonisolated static var outDir: URL? {
        ProcessInfo.processInfo.environment["GOPRAY_LIVE_SHIELD"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Our windows as CoreGraphics sees them (layer 1000 = .screenSaver).
    private func ourWindows() -> [String] {
        let pid = ProcessInfo.processInfo.processIdentifier
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        return list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }.map {
            let b = $0[kCGWindowBounds as String] as? [String: Any] ?? [:]
            return "layer=\($0[kCGWindowLayer as String] ?? "?") bounds=\(b["X"] ?? "?"),\(b["Y"] ?? "?") \(b["Width"] ?? "?")x\(b["Height"] ?? "?")"
        }
    }

    private func live(_ ctx: ShieldContext, name: String, hold: Double, scenesRoot: URL = SceneWebView.bundledScenesRoot,
                      dir: URL) async throws {
        let watchdog = DispatchWorkItem { kill(getpid(), SIGKILL) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 14, execute: watchdog)
        defer { watchdog.cancel() }

        var o = ShieldController.Options()
        o.scenesRoot = scenesRoot
        let c = ShieldController(options: o)
        let spy = SpyDelegate()
        c.delegate = spy
        c.show(ctx)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("\(name).up").path, contents: Data())
        try? await Task.sleep(for: .seconds(hold))
        let wins = ourWindows()
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        print("INFO live \(name): displays=\(NSScreen.screens.count) panels=\(c.slots.count) ourWindows=\(wins) frontmost=\(front) presentationOptions=\(NSApp.presentationOptions.rawValue) fallbackReasons=\(c.fallbackReasons)")
        c.tearDown()
        try? await Task.sleep(for: .milliseconds(500))
        print("INFO live \(name): after tearDown presentationOptions=\(NSApp.presentationOptions.rawValue) ourWindows=\(ourWindows().count)")
    }

    @Test(.enabled(if: LiveShieldTests.outDir != nil)) func wholeScreenShield() async throws {
        let dir = try #require(Self.outDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await live(Fixture.ctx(.fajr, remainingMs: 540_000, athanMs: 120_000), name: "shield-fajr", hold: 7, dir: dir)
    }

    @Test(.enabled(if: LiveShieldTests.outDir != nil)) func wholeScreenShieldIsha() async throws {
        let dir = try #require(Self.outDir)
        try await live(Fixture.ctx(.isha, remainingMs: 0), name: "shield-isha-open", hold: 7, dir: dir)
    }

    @Test(.enabled(if: LiveShieldTests.outDir != nil)) func noticeDhuhr() async throws {
        let dir = try #require(Self.outDir)
        var c = Fixture.ctx(.dhuhr, mode: .codingApps, remainingMs: 420_000, athanMs: 60_000, app: "Cursor")
        c.lockSeconds = 600
        try await live(c, name: "notice-dhuhr", hold: 7, dir: dir)
    }

    @Test(.enabled(if: LiveShieldTests.outDir != nil)) func noticeIsha() async throws {
        let dir = try #require(Self.outDir)
        var c = Fixture.ctx(.isha, mode: .codingApps, remainingMs: 0, app: "Visual Studio Code")
        c.lockSeconds = 600
        try await live(c, name: "notice-isha", hold: 7, dir: dir)
    }

    @Test(.enabled(if: LiveShieldTests.outDir != nil)) func nativeFallbackShield() async throws {
        let dir = try #require(Self.outDir)
        let empty = try Fixture.scratchScenes([:])
        try await live(Fixture.ctx(.asr, remainingMs: 300_000, athanMs: 60_000), name: "fallback-asr", hold: 6, scenesRoot: empty, dir: dir)
    }
}
