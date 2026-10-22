// ManifestTests.swift — lane B: the scene manifest catches drift, and the shipped page keeps its lockdown.

import Testing
import Foundation
@testable import GoPray

@MainActor @Suite("Scene manifest and shield.html", .serialized)
struct ManifestTests {
    private func run(_ script: String, _ args: [String]) throws -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [Fixture.fixtures.appendingPathComponent(script).path] + args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        try p.run(); p.waitUntilExit()
        return (p.terminationStatus, String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }

    private func copyOfScenes() throws -> URL {
        let src = SceneWebView.bundledScenesRoot
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("gopray-manifest-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: src, to: dst)
        return dst
    }

    @Test func shippedScenesMatchTheirManifest() throws {
        let r = try run("check-manifest.sh", [SceneWebView.bundledScenesRoot.path])
        #expect(r.status == 0, "\(r.out)")
    }

    @Test func oneChangedByteInUIJsFailsTheCheck() throws {
        let dir = try copyOfScenes(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try run("check-manifest.sh", [dir.path]).status == 0)            // control: the copy is clean
        let ui = dir.appendingPathComponent("ui.js")
        var data = try Data(contentsOf: ui)
        data[data.count / 2] ^= 0x01                                             // flip one bit
        try data.write(to: ui)
        let r = try run("check-manifest.sh", [dir.path])
        #expect(r.status != 0)
        #expect(r.out.contains("ui.js differs"), "\(r.out)")
    }

    @Test func aMissingOrExtraFileFailsTheCheck() throws {
        let dir = try copyOfScenes(); defer { try? FileManager.default.removeItem(at: dir) }
        try "x".write(to: dir.appendingPathComponent("extra.js"), atomically: true, encoding: .utf8)
        let extra = try run("check-manifest.sh", [dir.path])
        #expect(extra.status != 0 && extra.out.contains("extra.js"))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("extra.js"))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("fonts/Amiri-Regular.woff"))
        let missing = try run("check-manifest.sh", [dir.path])
        #expect(missing.status != 0 && missing.out.contains("missing fonts/Amiri-Regular.woff"))
    }

    @Test func aTamperedShieldHtmlOrBridgeFailsTheCheck() throws {
        // the CSP lives in shield.html, so it is in the manifest too
        let dir = try copyOfScenes(); defer { try? FileManager.default.removeItem(at: dir) }
        let html = dir.appendingPathComponent("shield.html")
        try (String(contentsOf: html, encoding: .utf8).replacingOccurrences(of: "connect-src 'none'", with: "connect-src *")).write(to: html, atomically: true, encoding: .utf8)
        let r = try run("check-manifest.sh", [dir.path])
        #expect(r.status != 0 && r.out.contains("shield.html differs"))
    }

    @Test func approvedFilesAreByteIdenticalToTheDesignFolder() throws {
        let design = Fixture.fixtures.appendingPathComponent("design-scenes")
        guard FileManager.default.fileExists(atPath: design.path) else { return }   // not in a design checkout
        let app = SceneWebView.bundledScenesRoot
        for f in ["asr.js", "dhuhr.js", "fajr.js", "isha.js", "maghrib.js", "styles.css", "ui.js", "watercolor.js",
                  "fonts/Amiri-Regular.woff", "fonts/CormorantGaramond-VF.woff"] {
            #expect(FileManager.default.contentsEqual(atPath: design.appendingPathComponent(f).path, andPath: app.appendingPathComponent(f).path), "\(f) differs")
        }
    }

    @Test func shieldHtmlCarriesTheLockdownAndNoKeyHandlers() throws {
        let root = SceneWebView.bundledScenesRoot
        let html = try String(contentsOf: root.appendingPathComponent("shield.html"), encoding: .utf8)
        for d in ["default-src 'none'", "script-src 'self'", "connect-src 'none'", "object-src 'none'", "base-uri 'none'", "form-action 'none'", "font-src 'self'", "img-src 'self' data:"] {
            #expect(html.contains(d), "CSP lacks \(d)")
        }
        #expect(!html.contains("<script>"))                       // no inline script: script-src 'self' holds
        #expect(!html.contains("preview"))                        // no preview chrome
        let bridge = try String(contentsOf: root.appendingPathComponent("bridge.js"), encoding: .utf8)
        #expect(!bridge.contains("keydown") && !bridge.contains("keyup") && !bridge.contains("keypress"))
        #expect(!bridge.contains("innerHTML"))
    }
}
