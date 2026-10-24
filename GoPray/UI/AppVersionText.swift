// AppVersionText.swift — "Go Pray 0.2.1", read from the bundle (never hand-typed). Shown in the
// menu popup footer and at the bottom of Settings → General (Ahmed, 2026-10-24).

import Foundation

enum AppVersionText {
    static func label(bundle: Bundle = .main) -> String {
        let v = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return "Go Pray \(v)"
    }
}
