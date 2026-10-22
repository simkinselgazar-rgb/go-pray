// MediaPauserTests.swift — loads the private symbol; NEVER sends a pause (a test run must not stop Ahmed's music).

import Testing
@testable import GoPray

@MainActor struct MediaPauserTests {
    @Test func mediaRemoteSymbolLoadsOnThisMacOS() {
        #expect(MediaRemotePauser.isAvailable)
    }
}
