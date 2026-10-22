// FakeMediaPauser.swift — records pauseOthers() calls. Never touches the real MediaRemote.

import Foundation
@testable import GoPray

@MainActor final class FakeMediaPauser: MediaPausing {
    private(set) var calls = 0
    /// What the player said about itself at the moment of each call (pause must come before the sound).
    var wasPlayingAtCall: [Bool] = []
    var probe: (() -> Bool)?

    func pauseOthers() {
        calls += 1
        wasPlayingAtCall.append(probe?() ?? false)
    }
}
