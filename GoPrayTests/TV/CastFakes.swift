// CastFakes.swift — in-memory fakes for the Google TV seams (CastContracts.swift). Owner: PM.
// Every lane's tests use these; none touches the network, the disk or the Keychain.

import Foundation
@testable import GoPray

final class MemoryMediaSource: CastMediaSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(prayer: Prayer, voice: Voice)] = []
    /// Set to make `prepare` throw.
    var failure: Error? { get { lock.withLock { _failure } } set { lock.withLock { _failure = newValue } } }
    private var _failure: Error?
    var file = URL(fileURLWithPath: "/tmp/gopray-test.mp4")
    var calls: [(prayer: Prayer, voice: Voice)] { lock.withLock { _calls } }

    func prepare(prayer: Prayer, voice: Voice) async throws -> URL {
        lock.withLock { _calls.append((prayer, voice)) }
        if let failure { throw failure }
        return file
    }
}

final class FakeServing: CastServing, @unchecked Sendable {
    struct Call: Equatable { var file: URL; var localAddress: String; var peer: String }
    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _stops = 0
    /// Set to make `serve` throw.
    var failure: Error? { get { lock.withLock { _failure } } set { lock.withLock { _failure = newValue } } }
    private var _failure: Error?
    var url = URL(string: "http://127.0.0.1:9/a/0123456789abcdef0123456789abcdef.mp4")!
    var calls: [Call] { lock.withLock { _calls } }
    /// How many times the returned `stop` closure ran.
    var stops: Int { lock.withLock { _stops } }

    func serve(file: URL, on localAddress: String, forPeer peer: String) throws -> CastServed {
        if let failure { throw failure }
        lock.withLock { _calls.append(.init(file: file, localAddress: localAddress, peer: peer)) }
        return CastServed(url: url) { [weak self] in self?.lock.withLock { self?._stops += 1 } }
    }
}

final class FakePower: TVPowering, @unchecked Sendable {
    private let lock = NSLock()
    private var _turnOffs: [TVDevice] = []
    private var _pairs: [(tv: TVDevice, code: String)] = []
    private var _forgotten: [TVDevice] = []
    var paired: Bool { get { lock.withLock { _paired } } set { lock.withLock { _paired = newValue } } }
    private var _paired = true
    var pairResult: TVPairResult { get { lock.withLock { _pairResult } } set { lock.withLock { _pairResult = newValue } } }
    private var _pairResult: TVPairResult = .paired
    var turnOffResult: Bool { get { lock.withLock { _off } } set { lock.withLock { _off = newValue } } }
    private var _off = true
    var turnOffFailure: Error? { get { lock.withLock { _fail } } set { lock.withLock { _fail = newValue } } }
    private var _fail: Error?
    var turnOffs: [TVDevice] { lock.withLock { _turnOffs } }
    private var _starts: [TVDevice] = []
    var starts: [TVDevice] { lock.withLock { _starts } }
    var startResult: Bool { get { lock.withLock { _startResult } } set { lock.withLock { _startResult = newValue } } }
    private var _startResult = true
    var pairs: [(tv: TVDevice, code: String)] { lock.withLock { _pairs } }
    var forgotten: [TVDevice] { lock.withLock { _forgotten } }

    func startPairing(_ tv: TVDevice) async throws -> Bool {
        lock.withLock { _starts.append(tv) }
        return startResult
    }
    func pair(_ tv: TVDevice, code: String) async throws -> TVPairResult {
        lock.withLock { _pairs.append((tv, code)) }
        return pairResult
    }
    func turnOff(_ tv: TVDevice) async throws -> Bool {
        lock.withLock { _turnOffs.append(tv) }
        if let turnOffFailure { throw turnOffFailure }
        return turnOffResult
    }
    func isPaired(_ tv: TVDevice) -> Bool { paired }
    func forget(_ tv: TVDevice) { lock.withLock { _forgotten.append(tv) } }
}
