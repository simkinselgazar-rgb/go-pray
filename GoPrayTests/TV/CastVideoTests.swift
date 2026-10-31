// CastVideoTests.swift — CastVideo renders a real mp4 in these tests (Google TV Plan §6, lane B).
// Real bundle audio and stills, a real AVAssetWriter, a throwaway cache folder. No network.

import AVFoundation
import Foundation
import Testing
@testable import GoPray

private let appBundle = Bundle(for: CastVideo.self)

private func freshDirectory(_ name: String) -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gopray-castvideo-tests")
        .appendingPathComponent(name, isDirectory: true)
    try? FileManager.default.removeItem(at: dir)
    return dir
}

/// Top-level mp4 atoms in file order, e.g. ["ftyp", "moov", "mdat"].
private func topLevelAtoms(_ url: URL) throws -> [String] {
    let h = try FileHandle(forReadingFrom: url)
    defer { try? h.close() }
    let size = try h.seekToEnd()
    var offset: UInt64 = 0
    var names: [String] = []
    while offset + 8 <= size {
        try h.seek(toOffset: offset)
        guard let head = try h.read(upToCount: 8), head.count == 8 else { break }
        var len = UInt64(head[0]) << 24 | UInt64(head[1]) << 16 | UInt64(head[2]) << 8 | UInt64(head[3])
        names.append(String(decoding: head[4..<8], as: UTF8.self))
        if len == 1 {
            guard let big = try h.read(upToCount: 8), big.count == 8 else { break }
            len = big.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        }
        if len < 8 { break }
        offset += len
    }
    return names
}

private func seconds(of mp3: String, in sub: String) async throws -> Double {
    let u = try #require(appBundle.url(forResource: mp3, withExtension: "mp3", subdirectory: "athan/\(sub)"))
    return try await AVURLAsset(url: u).load(.duration).seconds
}

@Suite("CastVideo", .serialized) struct CastVideoTests {
    let voice = Voice.sunni("Adhan-Makkah")

    @Test func rendersARealFileTheTVCanPlay() async throws {
        let dir = freshDirectory("render")
        let video = CastVideo(bundle: appBundle, directory: dir)
        let started = Date()
        let file = try await video.prepare(prayer: .maghrib, voice: voice)
        let took = Date().timeIntervalSince(started)
        #expect(took <= 15, "render took \(took) s")

        let audioLength = try await seconds(of: "Adhan-Makkah", in: "sunni")
        let asset = AVURLAsset(url: file)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - (audioLength + CastVideo.tailSeconds)) < 2, "duration \(duration)")

        let v = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await v.load(.naturalSize)
        #expect(size.width == 1920 && size.height == 1080)
        let a = try await asset.loadTracks(withMediaType: .audio)
        #expect(a.count == 1)

        let atoms = try topLevelAtoms(file)
        let moov = try #require(atoms.firstIndex(of: "moov"))
        let mdat = try #require(atoms.firstIndex(of: "mdat"))
        #expect(moov < mdat, "atoms \(atoms)")
        let bytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        #expect(bytes > 100_000 && bytes < CastVideo.cacheLimitBytes)
        try? FileManager.default.copyItem(at: file, to: dir.deletingLastPathComponent().appendingPathComponent("sample-maghrib.mp4"))
    }

    @Test func theSilentTailReallyIsSilent() async throws {
        let dir = freshDirectory("tail")
        let file = try await CastVideo(bundle: appBundle, directory: dir).prepare(prayer: .dhuhr, voice: voice)
        let asset = AVURLAsset(url: file)
        let duration = try await asset.load(.duration).seconds
        let reader = try AVAssetReader(asset: asset)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: duration - 20, preferredTimescale: 600), duration: .positiveInfinity)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(out)
        #expect(reader.startReading())
        var peak: Int16 = 0
        while let buf = out.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buf) {
            var length = 0; var ptr: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr)
            let p = UnsafeRawBufferPointer(start: ptr, count: length).bindMemory(to: Int16.self)
            for s in p { peak = max(peak, s.magnitude > Int16.max.magnitude ? Int16.max : Int16(s.magnitude)) }
        }
        #expect(peak < 200, "peak \(peak)")
    }

    @Test func aCachedFileIsReturnedWithoutRenderingAgain() async throws {
        let dir = freshDirectory("hit")
        let video = CastVideo(bundle: appBundle, directory: dir)
        let first = try await video.prepare(prayer: .asr, voice: voice)
        let stamp = try first.resourceValues(forKeys: [.contentModificationDateKey, .fileResourceIdentifierKey])
        let again = try await video.prepare(prayer: .asr, voice: voice)
        let stamp2 = try again.resourceValues(forKeys: [.contentModificationDateKey, .fileResourceIdentifierKey])
        #expect(again == first)
        #expect(stamp.contentModificationDate == stamp2.contentModificationDate)
        #expect((stamp.fileResourceIdentifier as? NSObject) == (stamp2.fileResourceIdentifier as? NSObject))
    }

    @Test func aCorruptOrPartialCachedFileIsRenderedAgain() async throws {
        let dir = freshDirectory("corrupt")
        let video = CastVideo(bundle: appBundle, directory: dir)
        let file = try await video.prepare(prayer: .isha, voice: voice)
        let good = try Data(contentsOf: file)

        try Data("not a movie".utf8).write(to: file)
        let a = try await video.prepare(prayer: .isha, voice: voice)
        #expect(a == file)
        #expect(try Data(contentsOf: a).count > 100_000)

        try good.prefix(good.count / 3).write(to: file)   // a half-written download
        let b = try await video.prepare(prayer: .isha, voice: voice)
        let d = try await AVURLAsset(url: b).load(.duration).seconds
        #expect(d > CastVideo.tailSeconds + 1)

        try Data().write(to: file)                          // empty
        let c = try await video.prepare(prayer: .isha, voice: voice)
        #expect(try Data(contentsOf: c).count > 100_000)
    }

    @Test func fajrStartsNineSecondsInAndIgnoresTheVoice() async throws {
        let dir = freshDirectory("fajr")
        let video = CastVideo(bundle: appBundle, directory: dir)
        let a = try await video.prepare(prayer: .fajr, voice: .sunni("Saber"))
        let b = try await video.prepare(prayer: .fajr, voice: .shia("Aghati"))
        #expect(a == b)
        let audioLength = try await seconds(of: VoiceCatalog.fajrStem, in: "fajr")
        let duration = try await AVURLAsset(url: a).load(.duration).seconds
        #expect(abs(duration - (audioLength - VoiceCatalog.fajrStartOffset + CastVideo.tailSeconds)) < 2, "duration \(duration)")
    }

    @Test func anUnknownVoiceThrowsAndWritesNothing() async throws {
        let dir = freshDirectory("unknown")
        let video = CastVideo(bundle: appBundle, directory: dir)
        await #expect(throws: AthanError.unknownVoice) {
            _ = try await video.prepare(prayer: .asr, voice: .sunni("../../etc/passwd"))
        }
        #expect(!FileManager.default.fileExists(atPath: dir.path)
                || ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty)
    }

    @Test func fileNamesAreEnumNamedAndFajrIsShared() {
        #expect(CastVideo.fileName(prayer: .fajr, voice: .shia("Aghati")) == "fajr.mp4")
        #expect(CastVideo.fileName(prayer: .asr, voice: .sunni("Saber")) == "asr-sunni.Saber.mp4")
    }

    @Test func cleanupDropsOtherVoicesAndTempFilesButKeepsTheChosenVoice() throws {
        let dir = freshDirectory("cleanup")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keep = ["fajr.mp4", "asr-sunni.Saber.mp4"]
        let drop = ["asr-sunni.Hafez.mp4", ".abc.tmp.mp4", "isha-shia.Aghati.mp4"]
        for n in keep + drop { try Data("x".utf8).write(to: dir.appendingPathComponent(n)) }
        CastVideo(bundle: appBundle, directory: dir).cleanup(keeping: .sunni("Saber"))
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        #expect(left == Set(keep))
    }
}
