// ReopenDuringBlockTests.swift — a reopen or `show` request must not open a window under the shield.

import AppKit
import Foundation
import Testing
@testable import GoPray

@MainActor @Suite("Reopen during a block")
struct ReopenDuringBlockTests {
    private func environment(_ h: Harness) -> AppEnvironment {
        AppEnvironment(clock: h.clock, store: StateStore(directory: h.dir), settingsStore: SettingsStore(directory: h.dir),
                       schedule: h.schedule, shield: h.shield, audio: h.audio, hider: h.hider,
                       loginAgent: FakeLoginAgent(), geocoder: FakeGeocoder())
    }

    @Test func reopenWhileBlockedOpensNoWindow() throws {
        let at = FakeSchedule.at(.asr)
        let h = Harness(at: at.addingTimeInterval(-3600)); defer { h.cleanup() }
        let env = environment(h)
        try env.settingsStore.mutate { $0 = .test() }
        h.clock.now = at         // setup finishing never blocks the window already open, so the Athan comes after
        env.gate.athanFired(.asr, at: at)
        #expect(env.gate.isBlocked)
        let delegate = AppDelegate()
        delegate.env = env
        _ = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        #expect(!delegate.windows.hasOpenWindow)
    }
}
