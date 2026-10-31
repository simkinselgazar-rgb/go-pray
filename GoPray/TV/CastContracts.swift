// CastContracts.swift — the seams between the Google TV lanes (Google TV Plan §5). Owner: PM.
// Protocols and one value type only: no network, no files. A change is a PM amendment, broadcast to every lane.
//   CastTV (lane A) is built on CastMediaSource, CastServing and TVPowering.
//   CastVideo (lane B) is a CastMediaSource. CastServer (lane C) is a CastServing. AndroidRemote (lane D) is a TVPowering.

import Foundation

/// Makes the video for one (prayer, voice): the painting plus the Athan, once, cached. Returns a local file.
protocol CastMediaSource: Sendable {
    func prepare(prayer: Prayer, voice: Voice) async throws -> URL
}

/// A file being served to one TV. `url` is `http://<mac>:<port>/a/<token>.mp4`. `stop` closes the listener and every
/// connection; safe to call more than once.
struct CastServed: Sendable {
    let url: URL
    let stop: @Sendable () -> Void
}

/// A tiny LAN web server, up only during a cast. Answers the one TV (`peer`), one random path, one file.
protocol CastServing: Sendable {
    func serve(file: URL, on localAddress: String, forPeer peer: String) throws -> CastServed
}

/// The TV's own remote protocol (Android TV Remote v2), used only to turn a TV back off that was off before the Athan.
protocol TVPowering: Sendable {
    /// Settings only, step 1 (press "Pair remote"): opens the pairing session; the TV then shows a 6-character code.
    /// The session is held up to 120 s for `pair`. True = the code is on the TV's screen.
    func startPairing(_ tv: TVDevice) async throws -> Bool
    /// Settings only, step 2: the 6-character code the TV shows, sent on the held session. `.paired` on success,
    /// `.denied` on a wrong code, `.unsupported` when there is no held session.
    func pair(_ tv: TVDevice, code: String) async throws -> TVPairResult
    /// Only called when the TV was in standby before the Athan. True = the TV reported itself off.
    func turnOff(_ tv: TVDevice) async throws -> Bool
    func isPaired(_ tv: TVDevice) -> Bool
    func forget(_ tv: TVDevice)
}
