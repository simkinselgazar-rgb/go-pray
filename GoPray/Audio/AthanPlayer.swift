// AthanPlayer.swift — AthanPlaying on AVAudioPlayer. Owner: lane C.
// Fajr always plays Sheikh Hamed from 9.0 s (spike Q6: set currentTime after
// prepareToPlay, before play). No CoreAudio override: the system mute is respected.
// stop() never calls onFinished; only a natural end does (the gate handles its own stops).

import AVFoundation
import Foundation
import os

private let audioLog = Logger(subsystem: "com.ahmedelgazar.gopray", category: "audio")

@MainActor final class AthanPlayer: NSObject, AthanPlaying, AVAudioPlayerDelegate {
    var onFinished: (() -> Void)?
    var isPlaying: Bool { player?.isPlaying ?? false }
    /// Seconds into the file. 0 when nothing is loaded.
    var position: TimeInterval { player?.currentTime ?? 0 }

    private let bundle: Bundle
    private let pauser: MediaPausing
    private var player: AVAudioPlayer?

    init(bundle: Bundle = .main, pauser: MediaPausing = MediaRemotePauser()) {
        self.bundle = bundle
        self.pauser = pauser
        super.init()
    }

    /// The offset this prayer starts at, in seconds.
    static func startOffset(for prayer: Prayer) -> TimeInterval {
        prayer == .fajr ? VoiceCatalog.fajrStartOffset : 0
    }

    func play(prayer: Prayer, voice: Voice, volume: Float) throws {
        stop()
        let url = try VoiceCatalog.url(prayer: prayer, voice: voice, bundle: bundle)
        let p: AVAudioPlayer
        do { p = try AVAudioPlayer(contentsOf: url) } catch {
            audioLog.error("cannot decode \(url.lastPathComponent, privacy: .public)")
            throw AthanError.cannotDecode(url.lastPathComponent)
        }
        p.delegate = self
        p.volume = min(max(volume, 0), 1)
        p.prepareToPlay()
        let offset = Self.startOffset(for: prayer)
        if offset > 0 { p.currentTime = min(offset, max(0, p.duration - 0.1)) }
        pauser.pauseOthers()   // the one place other media is paused; a throw above never gets here
        guard p.play() else { throw AthanError.cannotDecode(url.lastPathComponent) }
        player = p
    }

    /// Idempotent. Does not call `onFinished`.
    func stop() {
        guard let p = player else { return }
        player = nil
        p.delegate = nil
        p.stop()
    }

    func remainingMs() -> Int {
        guard let p = player, p.isPlaying else { return 0 }
        return max(0, Int(((p.duration - p.currentTime) * 1000).rounded()))
    }

    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(p)
        Task { @MainActor in
            guard let cur = self.player, ObjectIdentifier(cur) == id else { return }
            self.player = nil
            self.onFinished?()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ p: AVAudioPlayer, error: Error?) {
        let id = ObjectIdentifier(p)
        Task { @MainActor in
            guard let cur = self.player, ObjectIdentifier(cur) == id else { return }
            self.player = nil
            self.onFinished?()
        }
    }
}
