// AppPicker.swift — "Add an app…" (v2). A picker, not a text field: NSOpenPanel limited to .app
// bundles, starting in /Applications. The id comes from the bundle, never from typing.

import AppKit
import UniformTypeIdentifiers

enum AppPicker {
    enum Result { case cancelled, unreadable, picked(SettingsViewModel.PickedApp) }

    @MainActor static func pick() -> Result {
        let panel = NSOpenPanel()
        panel.title = "Choose an app to rest"
        panel.prompt = "Add"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }
        return read(url)
    }

    static func read(_ url: URL) -> Result {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !id.isEmpty else { return .unreadable }
        let info = bundle.infoDictionary ?? [:]
        let name = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return .picked(.init(id: id, name: name))
    }
}
