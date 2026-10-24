// BlockedAppsSettingsTests.swift — v2 settings: the app lists and the two new switches.

import Foundation
import Testing
@testable import GoPray

@MainActor @Suite("Blocked apps settings")
struct BlockedAppsSettingsTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("gopray-ba-\(UUID().uuidString)", isDirectory: true)
    }

    /// A settings.json exactly as 0.1.1 wrote it (none of the v2 keys).
    static let v011 = """
    {"athanVolume":0.8,"city":"Toronto","highLatitudeRule":null,"latitude":43.6,"launchAtLogin":true,"lockMinutes":10,
     "longitude":-79.3,"madhab":1,"method":"northAmerica","mode":{"wholeScreen":{}},"setupComplete":true,
     "voice":{"sunni":{"_0":"x"}}}
    """

    @Test func aZeroPointOneSettingsFileDecodesWithTheDefaults() throws {
        var s = Settings.test(); s.city = "Toronto"
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        var json = try #require(JSONSerialization.jsonObject(with: enc.encode(s)) as? [String: Any])
        for k in ["disabledDefaultApps", "customApps", "emergencyExitsEnabled", "checkForUpdates"] { json[k] = nil }
        let old = try JSONSerialization.data(withJSONObject: json)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(Settings.self, from: old)
        #expect(back.disabledDefaultApps == [] && back.customApps == [])
        #expect(back.emergencyExitsEnabled && back.checkForUpdates)
    }

    @Test func settingsJsonKeysAreStableAndSorted() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        let gate = Harness(at: FakeSchedule.at(.asr)); defer { gate.cleanup() }
        store.attach(gate.gate)
        try store.mutate {
            $0.customApps = [.init(id: "com.figma.Desktop", name: "Figma", platform: .mac),
                             .init(id: "figma", name: "Figma", platform: .windows)]
            $0.disabledDefaultApps = ["com.apple.Safari", "msedge"]
            $0.emergencyExitsEnabled = false
        }
        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        for key in ["\"emergencyExitsEnabled\" : false", "\"checkForUpdates\" : true", "\"customApps\"", "\"disabledDefaultApps\"",
                    "\"platform\" : \"windows\"", "\"platform\" : \"mac\""] { #expect(text.contains(key), "missing \(key)") }
        // Reload: the Windows entry survives a save/load round trip untouched.
        let again = SettingsStore(directory: dir)
        #expect(again.settings.customApps.count == 2)
        #expect(again.settings.customApps.contains(.init(id: "figma", name: "Figma", platform: .windows)))
        #expect(again.settings.disabledDefaultApps == ["com.apple.Safari", "msedge"])
        #expect(again.settings.emergencyExitsEnabled == false)
    }

    @Test func disablingADefaultRemovesItAndACustomMacAppIsAdded() {
        var s = Settings.test()
        s.disabledDefaultApps = ["com.apple.Safari"]
        s.customApps = [.init(id: "x.mac", name: "X", platform: .mac), .init(id: "x.exe", name: "X", platform: .windows)]
        let eff = BlockedApps.effective(s, defaults: CodingApps.bundleIDs)
        #expect(!eff.contains("com.apple.Safari") && eff.contains("com.google.Chrome"))
        #expect(eff.contains("x.mac") && !eff.contains("x.exe"))
    }

    @Test func sanitizedDropsTheDenylistDedupesCapsAndTrims() {
        var s = Settings.test()
        s.disabledDefaultApps = Array(BlockedApps.neverBlock) + ["a", "a", "  b  "] + (0..<300).map { "d.\($0)" }
        s.customApps = Array(BlockedApps.neverBlock).map { .init(id: $0, name: "n", platform: .mac) }
            + [.init(id: " c ", name: String(repeating: "n", count: 90), platform: .mac), .init(id: "c", name: "dup", platform: .mac)]
            + (0..<80).map { .init(id: "u.\($0)", name: "u", platform: .mac) }
        let out = s.sanitized()
        #expect(BlockedApps.neverBlock.isDisjoint(with: Set(out.disabledDefaultApps)))
        #expect(out.disabledDefaultApps.count == BlockedApps.maxDisabled)
        #expect(out.disabledDefaultApps.filter { $0 == "a" }.count == 1 && out.disabledDefaultApps.contains("b"))
        #expect(BlockedApps.neverBlock.isDisjoint(with: Set(out.customApps.map(\.id))))
        #expect(out.customApps.count == BlockedApps.maxCustom)
        #expect(out.customApps.first?.id == "c" && out.customApps.first?.name.count == BlockedApps.maxNameLength)
        #expect(out.customApps.filter { $0.id == "c" }.count == 1)
    }

    @Test func aDenylistedWindowsIdIsNotMisreadAsMac() {
        var s = Settings.test()
        s.customApps = [.init(id: "com.apple.finder", name: "F", platform: .windows)]   // another platform's entry: kept, never applied
        #expect(s.sanitized().customApps.count == 1)
        #expect(BlockedApps.effective(s, defaults: []).isEmpty)
    }

    @Test func changingTheListDuringABlockIsRefusedAndNothingChanges() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let h = Harness(at: FakeSchedule.at(.asr)); defer { h.cleanup() }
        let store = SettingsStore(directory: dir)
        store.attach(h.gate)
        h.gate.athanFired(.asr, at: FakeSchedule.at(.asr))
        #expect(throws: SettingsError.blocked) { try store.mutate { $0.customApps = [.init(id: "x", name: "x", platform: .mac)] } }
        #expect(throws: SettingsError.blocked) { try store.mutate { $0.emergencyExitsEnabled = false } }
        #expect(throws: SettingsError.blocked) { try store.mutate { $0.checkForUpdates = false } }
        #expect(store.settings.customApps.isEmpty && store.settings.emergencyExitsEnabled)
    }
}
