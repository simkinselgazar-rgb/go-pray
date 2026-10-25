// Windows.swift — the Setup and Settings windows. Owner: PM (wiring).
// AppKit-hosted on purpose: a menu bar (.accessory) app has no main menu, and SwiftUI's
// Settings scene does not come forward reliably from a MenuBarExtra. One window of each,
// reused; closing it only orders it out.

import AppKit
import SwiftUI

@MainActor final class Windows: NSObject, NSWindowDelegate {
    private var setup: NSWindow?
    private var settings: NSWindow?
    /// Called when a window closes (the single-instance hand-over waits for this).
    var onClose: (() -> Void)?

    var hasOpenWindow: Bool { [setup, settings].contains { $0?.isVisible == true } }

    func showSetup(_ env: AppEnvironment) {
        if setup == nil {
            let model = SetupViewModel(store: env.settingsStore, schedule: env.schedule, clock: env.clock,
                                       audio: env.audio, loginAgent: env.loginAgent, geocoder: env.geocoder,
                                       gate: env.gate)
            let view = SetupView(model: model, headerStill: AnyView(SetupHeaderStill(model: model)),
                                 onFinished: { [weak self] in self?.setup?.close() })
            setup = makeWindow(title: "Set up Go Pray", view: view)
        }
        present(setup)
    }

    func showSettings(_ env: AppEnvironment) {
        if settings == nil {
            let model = SettingsViewModel(store: env.settingsStore, gate: env.gate, clock: env.clock,
                                          audio: env.audio, loginAgent: env.loginAgent, geocoder: env.geocoder,
                                          schedule: env.schedule, tv: env.tv, discovery: env.tvDiscovery)
            // The Form scrolls; size the window to its ideal height (720), never taller than the screen.
            let visible = NSScreen.main?.visibleFrame.height ?? 800
            let w = makeWindow(title: "Go Pray Settings", view: SettingsView(model: model), fitToContent: false)
            w.setContentSize(NSSize(width: 480, height: min(720, visible - 60)))
            w.center()
            settings = w
        }
        present(settings)
    }

    private func makeWindow<V: View>(title: String, view: V, fitToContent: Bool = true) -> NSWindow {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = fitToContent ? [.preferredContentSize] : []
        let w = NSWindow(contentViewController: host)
        w.title = title
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        return w
    }

    private func present(_ w: NSWindow?) {
        guard let w else { return }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // After the window is gone, so `hasOpenWindow` is already false.
        DispatchQueue.main.async { [weak self] in self?.onClose?() }
    }
}

/// The setup header follows the model: Dhuhr before a city is picked, the next prayer after.
private struct SetupHeaderStill: View {
    let model: SetupViewModel

    var body: some View {
        let _ = model.step   // re-read the next prayer when the step changes
        SceneStill(prayer: model.headerPrayer, size: CGSize(width: 520, height: 96))
    }
}
