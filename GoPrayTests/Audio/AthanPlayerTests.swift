// AthanPlayerTests.swift — lane C. Real audio plays at most 3 s at volume 0.1.

import Foundation
import Testing
@testable import GoPray

@MainActor struct AthanPlayerTests {
    static let appBundle = Bundle(for: AthanPlayer.self)

    @Test func fajrOffsetIsNineSeconds() {
        #expect(AthanPlayer.startOffset(for: .fajr) == 9.0)
        for p in [Prayer.dhuhr, .asr, .maghrib, .isha] { #expect(AthanPlayer.startOffset(for: p) == 0) }
    }

    @Test func catalogueHas28VoicesAndNoYusufIslam() {
        #expect(VoiceCatalog.sunni.count == 16)
        #expect(VoiceCatalog.shia.count == 12)
        #expect(VoiceCatalog.all.count == 28)
        #expect(!VoiceCatalog.all.contains { $0.stem.lowercased().contains("yusuf") })
    }

    @Test func everyVoiceMapsToABundledFileAndFajrToo() throws {
        for e in VoiceCatalog.all {
            let url = try VoiceCatalog.url(prayer: .dhuhr, voice: e.voice, bundle: Self.appBundle)
            #expect(url.lastPathComponent == "\(e.stem).mp3")
            #expect(url.deletingLastPathComponent().lastPathComponent == (e.voice == .sunni(e.stem) ? "sunni" : "shia"))
        }
        let fajr = try VoiceCatalog.url(prayer: .fajr, voice: .sunni("Adhan-Makkah"), bundle: Self.appBundle)
        #expect(fajr.lastPathComponent == "\(VoiceCatalog.fajrStem).mp3")
        // Fajr ignores the voice, even an invalid one.
        let fajr2 = try VoiceCatalog.url(prayer: .fajr, voice: .shia("nope"), bundle: Self.appBundle)
        #expect(fajr2 == fajr)
    }

    @Test func bundledFilesAreExactlyTheCatalogue() throws {
        let root = try #require(Self.appBundle.url(forResource: "athan", withExtension: nil))
        for (dir, entries) in [("sunni", VoiceCatalog.sunni), ("shia", VoiceCatalog.shia)] {
            let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(dir).path)
                .filter { $0.hasSuffix(".mp3") }
            #expect(Set(files) == Set(entries.map { "\($0.stem).mp3" }))
        }
    }

    @Test func unknownVoiceThrows() {
        let player = AthanPlayer(bundle: Self.appBundle, pauser: FakeMediaPauser())
        #expect(throws: AthanError.unknownVoice) { try player.play(prayer: .dhuhr, voice: .sunni("Nope"), volume: 0.1) }
        #expect(!player.isPlaying)
    }

    @Test func missingFileThrowsAndDoesNotPlay() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gopray-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let empty = try #require(Bundle(path: dir.path))
        let player = AthanPlayer(bundle: empty, pauser: FakeMediaPauser())
        #expect(throws: AthanError.missingFile("Abdul-Basit")) { try player.play(prayer: .asr, voice: .sunni("Abdul-Basit"), volume: 0.1) }
        #expect(throws: AthanError.missingFile(VoiceCatalog.fajrStem)) { try player.play(prayer: .fajr, voice: .sunni("Abdul-Basit"), volume: 0.1) }
        #expect(!player.isPlaying)
        #expect(player.remainingMs() == 0)
    }

    @Test func fajrPlaysFromNineSecondsAndStopIsSilentAndIdempotent() async throws {
        let player = AthanPlayer(bundle: Self.appBundle, pauser: FakeMediaPauser())
        var finished = 0
        player.onFinished = { finished += 1 }
        try player.play(prayer: .fajr, voice: .sunni("Adhan-Makkah"), volume: 0.1)
        #expect(player.isPlaying)
        #expect(player.position >= 9.0 && player.position < 9.5)
        #expect(player.remainingMs() > 0 && player.remainingMs() <= 195_300 - 9_000)
        try await Task.sleep(for: .seconds(1))
        #expect(player.position >= 9.9)
        player.stop()
        player.stop()
        #expect(!player.isPlaying)
        #expect(player.remainingMs() == 0)
        try await Task.sleep(for: .milliseconds(200))
        #expect(finished == 0)   // Silence stops sound only; no onFinished
    }

    @Test func otherPrayersStartAtZero() async throws {
        let player = AthanPlayer(bundle: Self.appBundle, pauser: FakeMediaPauser())
        try player.play(prayer: .dhuhr, voice: .shia("Salimi"), volume: 0)   // volume 0 still plays
        #expect(player.isPlaying)
        #expect(player.position < 0.5)
        player.stop()
    }

    // MARK: other media is paused right before the sound

    @Test func goodFilePausesOthersOnceBeforeTheSoundStarts() throws {
        let fake = FakeMediaPauser()
        let player = AthanPlayer(bundle: Self.appBundle, pauser: fake)
        fake.probe = { player.isPlaying }
        try player.play(prayer: .dhuhr, voice: .sunni("Adhan-Makkah"), volume: 0)
        #expect(fake.calls == 1)
        #expect(fake.wasPlayingAtCall == [false])
        #expect(player.isPlaying)
        player.stop()
    }

    @Test func badVoiceAndMissingFileNeverPause() throws {
        let fake = FakeMediaPauser()
        let player = AthanPlayer(bundle: Self.appBundle, pauser: fake)
        #expect(throws: AthanError.unknownVoice) { try player.play(prayer: .dhuhr, voice: .sunni("Nope"), volume: 0) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gopray-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let empty = AthanPlayer(bundle: try #require(Bundle(path: dir.path)), pauser: fake)
        #expect(throws: AthanError.missingFile("Abdul-Basit")) { try empty.play(prayer: .asr, voice: .sunni("Abdul-Basit"), volume: 0) }
        #expect(fake.calls == 0)
    }

    @Test func stopNeverPausesAndTwoPlaysPauseTwice() throws {
        let fake = FakeMediaPauser()
        let player = AthanPlayer(bundle: Self.appBundle, pauser: fake)
        player.stop()
        #expect(fake.calls == 0)
        try player.play(prayer: .dhuhr, voice: .shia("Salimi"), volume: 0)
        player.stop()
        #expect(fake.calls == 1)
        try player.play(prayer: .dhuhr, voice: .shia("Salimi"), volume: 0)
        try player.play(prayer: .asr, voice: .shia("Salimi"), volume: 0)
        #expect(fake.calls == 3)
        player.stop()
    }
}
