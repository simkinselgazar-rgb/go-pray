// WebPrewarm.swift — warm WebKit at launch so the first shield is not a cold start.
// Owner: PM (wiring). Lane B measured ~2.3 s from a cold WKWebView to `ready`, and the
// shield falls back to native after 4 s, so a cold first Athan sits close to that line.
//
// One SceneWebView loads the bundled shield page (file:// only, the same lockdown as the
// shield) in no window, so nothing is shown. When the page says `ready` (or after 10 s)
// it is shut down and released. WebKit keeps its helper processes and caches warm.

import AppKit
import os

private let log = Logger(subsystem: "com.ahmedelgazar.gopray", category: "wire")

@MainActor enum WebPrewarm {
    private static var view: SceneWebView?

    static func start() {
        guard view == nil else { return }
        let started = ContinuousClock.now
        let web = SceneWebView()
        view = web
        web.onMessage = { msg in
            guard msg == .ready else { return }
            let ms = (ContinuousClock.now - started) / .milliseconds(1)
            log.notice("prewarm ready in \(Int(ms), privacy: .public) ms")
            finish()
        }
        web.onFailure = { _ in log.error("prewarm failed; the shield still has its native fallback"); finish() }
        web.load(query: "prayer=dhuhr&layout=art&reduce=1&ms=0")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            if view != nil { log.notice("prewarm: no ready in 10 s, released"); finish() }
        }
    }

    private static func finish() {
        view?.shutDown()
        view = nil
    }
}
