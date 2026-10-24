// BlockedAppsFlowTests.swift — Settings → Blocked apps, and the two v2 switches.

import Foundation
import Testing
@testable import GoPray

@MainActor @Suite("Blocked apps flow")
struct BlockedAppsFlowTests {
    @Test func everyDefaultIsListedAndOnToStartWith() {
        let f = UIFixture(); defer { f.cleanup() }
        let m = f.settingsModel()
        #expect(m.defaultAppRows.count == CodingApps.defaults.count)
        #expect(m.defaultAppRows.allSatisfy { $0.isOn })
        #expect(m.customAppRows.isEmpty)
    }

    @Test func switchingADefaultOffSavesItAndBackOnClearsIt() {
        let f = UIFixture(); defer { f.cleanup() }
        let m = f.settingsModel()
        m.setDefaultApp("com.apple.Safari", on: false)
        #expect(f.store.settings.disabledDefaultApps == ["com.apple.Safari"])
        #expect(m.defaultAppRows.first { $0.id == "com.apple.Safari" }?.isOn == false)
        #expect(!BlockedApps.effective(f.store.settings, defaults: CodingApps.bundleIDs).contains("com.apple.Safari"))
        m.setDefaultApp("com.apple.Safari", on: true)
        #expect(f.store.settings.disabledDefaultApps.isEmpty)
    }

    @Test func aPickedAppIsSavedAndCanBeRemoved() {
        let f = UIFixture(); defer { f.cleanup() }
        let m = f.settingsModel()
        m.addApp(.init(id: "com.figma.Desktop", name: "Figma"))
        #expect(m.customAppRows == [.init(id: "com.figma.Desktop", name: "Figma", isOn: true)])
        #expect(BlockedApps.effective(f.store.settings, defaults: CodingApps.bundleIDs).contains("com.figma.Desktop"))
        m.removeCustomApp("com.figma.Desktop")
        #expect(m.customAppRows.isEmpty)
    }

    @Test func aMacOSAppIsRefusedWithTheRightLine() {
        let f = UIFixture(); defer { f.cleanup() }
        let m = f.settingsModel()
        m.addApp(.init(id: "com.apple.finder", name: "Finder"))
        #expect(m.notice == "Go Pray can't rest that one. It's part of macOS.")
        #expect(f.store.settings.customApps.isEmpty)
    }

    @Test func aDuplicateIsRefusedAndASwitchedOffDefaultComesBack() {
        let f = UIFixture(); defer { f.cleanup() }
        let m = f.settingsModel()
        m.addApp(.init(id: "x.app", name: "X")); m.addApp(.init(id: "x.app", name: "X"))
        #expect(m.notice == "Already on the list." && f.store.settings.customApps.count == 1)
        m.addApp(.init(id: "com.google.Chrome", name: "Chrome"))
        #expect(m.notice == "Already on the list.")
        m.setDefaultApp("com.google.Chrome", on: false)
        m.addApp(.init(id: "com.google.Chrome", name: "Chrome"))
        #expect(f.store.settings.disabledDefaultApps.isEmpty)
    }

    @Test func everythingOffShowsTheEmptyListCount() {
        let f = UIFixture(); defer { f.cleanup() }
        let m = f.settingsModel()
        for r in m.defaultAppRows { m.setDefaultApp(r.id, on: false) }
        #expect(m.effectiveAppCount == 0)
    }

    @Test func nothingChangesDuringABlock() {
        let f = UIFixture(); defer { f.cleanup() }
        let m = f.settingsModel()
        f.startBlock()
        m.setDefaultApp("com.apple.Safari", on: false)
        #expect(m.notice == GPCopy.blockedLine)
        m.addApp(.init(id: "x.app", name: "X"))
        m.set(\.emergencyExitsEnabled, to: false)
        #expect(f.store.settings.disabledDefaultApps.isEmpty && f.store.settings.customApps.isEmpty)
        #expect(f.store.settings.emergencyExitsEnabled)
    }

    @Test func theTwoSwitchesSave() {
        let f = UIFixture(); defer { f.cleanup() }
        let m = f.settingsModel()
        m.set(\.emergencyExitsEnabled, to: false); m.set(\.checkForUpdates, to: false)
        #expect(!f.store.settings.emergencyExitsEnabled && !f.store.settings.checkForUpdates)
    }

    @Test func theExitsLineSaysHowManyAreLeftThisYear() {
        let f = UIFixture(); defer { f.cleanup() }
        let m = f.settingsModel()
        #expect(m.exitsLine == "Emergency exits: 5 of 5 left this year")
    }

    @Test func theAppPickerReadsABundle() throws {
        let url = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard case .picked(let app) = AppPicker.read(url) else { Issue.record("not picked"); return }
        #expect(app.id == "com.apple.calculator" && !app.name.isEmpty)
        if case .unreadable = AppPicker.read(URL(fileURLWithPath: "/tmp/nope.app")) {} else { Issue.record("should be unreadable") }
    }
}
