// TestHostDirectoryTests.swift — a hosted test run never touches the real support folder. Owner: PM.

import Foundation
import Testing
@testable import GoPray

@MainActor @Suite("Test host support folder")
struct TestHostDirectoryTests {
    let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].standardizedFileURL.path
    let temp = FileManager.default.temporaryDirectory.standardizedFileURL.path

    private func isTemp(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        return p.hasPrefix(temp) && !p.hasPrefix(real)
    }

    @Test func everyDefaultPathIsATempFolderUnderTests() {
        #expect(TestHost.isActive)
        #expect(isTemp(StateStore.supportBase()))
        #expect(isTemp(StateStore.defaultDirectory()))
        #expect(isTemp(SettingsStore().fileURL))
        #expect(isTemp(InstanceLock.defaultURL()))
        #expect(isTemp(SceneStillRenderer().cacheDirectory))
    }
}
