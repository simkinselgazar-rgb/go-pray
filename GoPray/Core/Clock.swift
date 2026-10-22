// Clock.swift — the wall clock behind every timer rule. Owner: PM.
// The protocol lives in Contracts.swift.

import Foundation

struct SystemClock: Clock {
    var now: Date { Date() }
}

/// Settable clock for tests and the debug menu. Thread-safe so it can be
/// `Sendable` and shared with code on any actor.
final class FakeClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    var now: Date {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}
